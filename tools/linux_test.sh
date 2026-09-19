#!/usr/bin/env bash
#
# linux_test: runs the io_uring probe and then every test executable that `zig build test-linux`
# installed under zig-out/linux/, each in a Linux container, and stops at the first one that
# exits non-zero.
#
#     zig build test-linux && bash tools/linux_test.sh
#
# rotor has no simulator. Its uring backend is tested against a real Linux kernel
# (docs/decisions/0010-no-simulator.md). The development machine is a Mac, so that kernel is the
# one Docker's virtual machine runs. On a Linux host it is the host's own.
#
# Before any test the script prints the kernel release the container sees (`uname -r`).
# docs/decisions/0002-scope.md sets the floor at Linux 6.1, and a pass or a measured number from
# an older kernel shows something else. The script does not compare version numbers, because a
# vendor's kernel can carry a feature under an older number. The probe decides instead. It runs
# first, asks the kernel for every feature that record lists, and exits non-zero naming the first
# one that is missing (tools/uring_probe.zig).
#
# The script runs the probe by name and the tests by the manifest `zig build test-linux` writes,
# one name per line. It never runs what it merely finds in the directory, so an executable an
# earlier build left behind is not run, and a listed executable that is missing fails the run.
#
# Every executable runs in a container of its own, so a test cannot leave a file or a socket
# behind for the next one. It is copied from the read-only bind mount to the container's own
# filesystem before it runs. A rebuild on the host during the run then cannot replace the file
# under it, and a test that creates files writes them to the container and never to the work
# tree. Files opened with O_DIRECT belong there too: the bind mount passes every call through
# the host's file sharing.
#
# The install under zig-out/linux/ must be newer than every source, or the run would pass on
# executables older than the tree. `zig build test-linux` touches a stamp file after its last
# install, and the script refuses to run when any source is newer than that stamp.

set -euo pipefail

# The container image, pinned by digest so every run executes the same bytes. It is alpine 3.20.
# The executables are static and take nothing from the image, so the image only has to supply a
# shell, `cp` and `uname`, and alpine supplies them in a few megabytes. The image never supplies
# the kernel: a container runs on the kernel of Docker's virtual machine, or of the host on
# Linux. The digest names a multi-platform index, so the same line serves arm64 and amd64.
# Resolve a new digest with `docker buildx imagetools inspect alpine:3.20`.
readonly image='alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc'
# Docker's default seccomp profile refuses io_uring_setup with EPERM, so every container runs
# without that profile. Without this option the probe reports the refusal and the run fails.
readonly security_option='seccomp=unconfined'
# The directory `zig build test-linux` installs into, relative to the top of the work tree.
readonly install_directory='zig-out/linux'
# The file `zig build test-linux` touches after its last install (build/linux.zig).
readonly stamp_name='.test-linux-stamp'
# The file that lists the installed test executables, one name per line, in run order.
readonly manifest_name='tests.manifest'
# The io_uring probe, which runs before any test.
readonly probe_name='uring_probe'
# Every path that holds a source of an installed executable, relative to the top of the work
# tree. Only the .zig and .zon files under them are compared to the stamp.
readonly source_paths=(src build tools build.zig build.zig.zon)
# Where the install directory is mounted in the container, read-only.
readonly mount_point='/t'
# Where an executable is copied before it runs, on the container's own filesystem.
readonly run_directory='/tmp/bin'
# The kernel floor of docs/decisions/0002-scope.md, printed beside the release for the reader.
readonly kernel_floor='6.1'

cd "$(dirname "$0")/.."
readonly out="$PWD/$install_directory"
readonly stamp="$out/$stamp_name"
readonly manifest="$out/$manifest_name"

# Prints why the run cannot go on, and ends it.
fail() {
  echo "linux_test: $*" >&2
  exit 1
}

# Refuses an install that is missing, incomplete, or older than a source.
require_fresh_install() {
  local required stale
  for required in "$stamp" "$manifest" "$out/$probe_name"; do
    if [[ ! -f "$required" ]]; then
      fail "$required is missing; run 'zig build test-linux' first"
    fi
  done
  if [[ ! -s "$manifest" ]]; then
    fail "$manifest lists no test executable"
  fi
  stale="$(find "${source_paths[@]}" -type f \( -name '*.zig' -o -name '*.zon' \) \
    -newer "$stamp" -print -quit)"
  if [[ -n "$stale" ]]; then
    fail "$stale is newer than the install; rerun 'zig build test-linux'"
  fi
}

# Runs one command in a fresh container with the install directory mounted read-only.
in_container() {
  docker run --rm --security-opt "$security_option" \
    --volume "$out:$mount_point:ro" "$image" "$@" </dev/null
}

# Copies one installed executable into its container and runs it there. The inner script takes
# the mount point, the run directory and the name as its arguments, so the container's shell
# expands them and this one does not.
run() {
  local name="$1"
  echo "linux_test: $name"
  # shellcheck disable=SC2016
  if ! in_container sh -c 'mkdir -p "$2" && cp "$1/$3" "$2/" && exec "$2/$3"' \
    sh "$mount_point" "$run_directory" "$name"; then
    fail "$name failed; nothing after it was run"
  fi
}

require_fresh_install

if ! command -v docker >/dev/null 2>&1; then
  fail "no docker on PATH"
fi
if ! release="$(in_container uname -r)"; then
  fail "docker could not run a container; start Docker and run this again"
fi
echo "linux_test: kernel $release (floor: Linux $kernel_floor, docs/decisions/0002-scope.md)"

run "$probe_name"

# Standard input is the manifest here, and in_container closes it for docker, so a container
# cannot read the names that are still to come.
while IFS= read -r name; do
  if [[ -z "$name" ]]; then
    continue
  fi
  run "$name"
done <"$manifest"

echo "linux_test: all passed"
