#!/usr/bin/env bash
#
# linux_test: runs the io_uring probe, then every test executable that `zig build test-linux`
# installed under zig-out/linux/, then the halt check on every halt scenario executable it
# installed, each in a Linux container, and stops at the first one that fails.
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
# The halt check (tools/halt_check.zig) proves that an assertion halts: it runs each scenario of an
# executable in a child process that must die by a signal. `zig build halt-check` runs it on the
# host, which is a Mac. A scenario whose path, with its assertion deleted, makes a Linux system call
# cannot be proved there, because macOS runs some other call in its place (build/halt.zig). Those
# scenarios run here, on the kernel they were written for. The script runs the check by name and
# the scenario executables by a second manifest, one per line, each name followed by the
# arguments the check takes after it. The canary is listed there too, so the run also proves that
# the check built for Linux reports a scenario that did not halt.
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
# Docker's default seccomp profile refuses io_uring_setup with EPERM, so an io_uring container runs
# without that profile. Without this option the probe reports the refusal and the run fails.
readonly security_option='seccomp=unconfined'
# The scenarios of src/conformance/conformance_families.zig run over IPv6 loopback and do not skip
# without it. Docker may start a container with IPv6 switched off, which removes `::1`, so every
# container here switches it on. The setting is the container's own network namespace's.
readonly ipv6_option='net.ipv6.conf.all.disable_ipv6=0'
# The executables that run under Docker's DEFAULT profile instead: the epoll module's own tests,
# the conformance suite against it, and its halt scenarios. The epoll backend exists for a container
# nobody relaxed (docs/decisions/0020-an-epoll-backend.md), so relaxing it for these would prove
# nothing: they must pass in the environment that refuses io_uring.
readonly confined_executables=' epoll conformance-epoll epoll_linux_scenarios linux-shared '
# The executables that run twice, once each way. The public module chooses its backend when the
# process starts: io_uring where the kernel gives a ring, epoll where it refuses one (decision 20,
# open question 5). Each run takes the other branch, so each is tested where it is chosen.
readonly both_ways_tests=' rotor '
# The directory `zig build test-linux` installs into, relative to the top of the work tree.
readonly install_directory='zig-out/linux'
# The file `zig build test-linux` touches after its last install (build/linux.zig).
readonly stamp_name='.test-linux-stamp'
# The file that lists the installed test executables, one name per line, in run order.
readonly manifest_name='tests.manifest'
# The file that lists the installed halt scenario executables, one per line, in run order, each
# name followed by the arguments the halt check takes after it.
readonly halt_manifest_name='halt.manifest'
# The halt check, which runs on every executable the halt manifest lists.
readonly halt_check_name='halt_check'
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
readonly halt_manifest="$out/$halt_manifest_name"

# Prints why the run cannot go on, and ends it.
fail() {
  echo "linux_test: $*" >&2
  exit 1
}

# Refuses an install that is missing, incomplete, or older than a source.
require_fresh_install() {
  local required stale
  for required in "$stamp" "$manifest" "$halt_manifest" "$out/$probe_name" \
    "$out/$halt_check_name"; do
    if [[ ! -f "$required" ]]; then
      fail "$required is missing; run 'zig build test-linux' first"
    fi
  done
  if [[ ! -s "$manifest" ]]; then
    fail "$manifest lists no test executable"
  fi
  if [[ ! -s "$halt_manifest" ]]; then
    fail "$halt_manifest lists no halt scenario executable"
  fi
  stale="$(find "${source_paths[@]}" -type f \( -name '*.zig' -o -name '*.zon' \) \
    -newer "$stamp" -print -quit)"
  if [[ -n "$stale" ]]; then
    fail "$stale is newer than the install; rerun 'zig build test-linux'"
  fi
}

# Runs one command in a fresh container with the install directory mounted read-only, and with the
# seccomp profile relaxed so io_uring works.
in_container() {
  docker run --rm --security-opt "$security_option" --sysctl "$ipv6_option" \
    --volume "$out:$mount_point:ro" "$image" "$@" </dev/null
}

# The same, under Docker's default seccomp profile: no --security-opt at all. This is where
# io_uring_setup is refused, and where the epoll backend has to work.
in_default_container() {
  docker run --rm --sysctl "$ipv6_option" \
    --volume "$out:$mount_point:ro" "$image" "$@" </dev/null
}

# Copies one installed executable into a container of the runner's kind and runs it there. The
# inner script takes the mount point, the run directory and the name as its arguments, so the
# container's shell expands them and this one does not.
run_with() {
  local runner="$1"
  local name="$2"
  # shellcheck disable=SC2016
  if ! "$runner" sh -c 'mkdir -p "$2" && cp "$1/$3" "$2/" && exec "$2/$3"' \
    sh "$mount_point" "$run_directory" "$name"; then
    fail "$name failed; nothing after it was run"
  fi
}

# Runs one installed executable: relaxed, confined, or both, as the lists above say.
run() {
  local name="$1"
  if [[ "$both_ways_tests" == *" $name "* ]]; then
    echo "linux_test: $name, with io_uring"
    run_with in_container "$name"
    echo "linux_test: $name, under Docker's default seccomp profile, which refuses io_uring"
    run_with in_default_container "$name"
  elif [[ "$confined_executables" == *" $name "* ]]; then
    echo "linux_test: $name, under Docker's default seccomp profile, which refuses io_uring"
    run_with in_default_container "$name"
  else
    echo "linux_test: $name"
    run_with in_container "$name"
  fi
}

# Runs the halt check on one scenario executable in a container of the runner's kind. The check
# and the scenario executable are copied in together, and the arguments after the name go to the
# check. The inner script takes its paths and names as arguments, as run_with's does.
halt_with() {
  local runner="$1"
  local name="$2"
  shift 2
  # shellcheck disable=SC2016
  if ! "$runner" sh -c 'mkdir -p "$2" && cp "$1/$3" "$1/$4" "$2/" && directory="$2" &&
    check="$3" && scenarios="$4" && shift 4 &&
    exec "$directory/$check" "$directory/$scenarios" "$@"' \
    sh "$mount_point" "$run_directory" "$halt_check_name" "$name" "$@"; then
    fail "the halt check failed on $name; nothing after it was run"
  fi
}

# Runs the halt check on one installed scenario executable, relaxed or confined as the lists above
# say. The arguments after the name go to the check.
run_halt() {
  local name="$1"
  if [[ "$confined_executables" == *" $name "* ]]; then
    echo "linux_test: halt check on $name, under Docker's default seccomp profile"
    halt_with in_default_container "$@"
  else
    echo "linux_test: halt check on $name"
    halt_with in_container "$@"
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

# The same for the halt manifest. Each line is a name and then the check's arguments, so it is
# read as words.
while read -r -a words; do
  if [[ ${#words[@]} -eq 0 ]]; then
    continue
  fi
  run_halt "${words[@]}"
done <"$halt_manifest"

echo "linux_test: all passed"
