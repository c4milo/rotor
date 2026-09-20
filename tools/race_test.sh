#!/usr/bin/env bash
#
# race_test: runs every executable that `zig build test-race` installed under zig-out/race/, each
# in a Linux container, under ThreadSanitizer, and stops at the first one that exits non-zero.
#
#     zig build test-race && bash tools/race_test.sh
#
# rotor's loops are shared-nothing (docs/decisions/0004-threading.md). The memory two threads
# touch is the mailbox rings and the sleep flag of docs/decisions/0012-kqueue-internals.md,
# point 6, and the registry. This run is the evidence that their orderings hold in practice; it
# is not a proof, because a sanitizer reports the interleavings that happened and not the ones
# that could. `zig build test` does not run it: it needs Docker, as the Linux gate does.
#
# The image is glibc and not the Linux gate's alpine, because ThreadSanitizer's runtime needs a
# dynamic glibc (build/race.zig).

set -euo pipefail

# Pinned by digest so every run executes the same bytes. It is debian bookworm-slim, which
# supplies the glibc the sanitizer's runtime links against. The digest names a multi-platform
# index, so the same line serves arm64 and amd64. Resolve a new digest with
# `docker buildx imagetools inspect debian:bookworm-slim`.
readonly image='debian@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251'
# Docker's default seccomp profile refuses io_uring_setup, which the uring suite needs.
readonly security_option='seccomp=unconfined'
readonly install_directory='zig-out/race'
readonly stamp_name='.test-race-stamp'
readonly manifest_name='tests.manifest'
readonly source_paths=(src build tools build.zig build.zig.zon)
readonly mount_point='/t'
readonly run_directory='/tmp/bin'

cd "$(dirname "$0")/.."
readonly out="$PWD/$install_directory"
readonly stamp="$out/$stamp_name"
readonly manifest="$out/$manifest_name"

fail() {
  echo "race_test: $*" >&2
  exit 1
}

# Refuses an install that is missing, incomplete, or older than a source.
require_fresh_install() {
  local required stale
  for required in "$stamp" "$manifest"; do
    if [[ ! -f "$required" ]]; then
      fail "$required is missing; run 'zig build test-race' first"
    fi
  done
  if [[ ! -s "$manifest" ]]; then
    fail "$manifest lists no executable"
  fi
  stale="$(find "${source_paths[@]}" -type f \( -name '*.zig' -o -name '*.zon' \) \
    -newer "$stamp" -print -quit)"
  if [[ -n "$stale" ]]; then
    fail "$stale is newer than the install; rerun 'zig build test-race'"
  fi
}

in_container() {
  docker run --rm --security-opt "$security_option" \
    --volume "$out:$mount_point:ro" "$image" "$@" </dev/null
}

# Copies one installed executable into its container and runs it there, as the Linux gate does.
run() {
  local name="$1"
  echo "race_test: $name"
  # shellcheck disable=SC2016
  if ! in_container sh -c 'mkdir -p "$2" && cp "$1/$3" "$2/" && exec "$2/$3"' \
    sh "$mount_point" "$run_directory" "$name"; then
    fail "$name reported a race or failed; nothing after it was run"
  fi
}

require_fresh_install

if ! command -v docker >/dev/null 2>&1; then
  fail "no docker on PATH"
fi

while IFS= read -r name; do
  if [[ -z "$name" ]]; then
    continue
  fi
  run "$name"
done <"$manifest"

echo "race_test: no race reported"
