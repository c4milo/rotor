#!/usr/bin/env bash
#
# stress_test: runs the io_uring module's tests many times under load, in a Linux container, and
# fails when one run fails.
#
#     zig build test-linux && bash tools/stress_test.sh [rounds] [copies] [busy]
#
# Under load the kernel can end a wait for one completion before that completion is in the ring
# (decision 6, "The wait timer", amendment of 2026-11-06). The tick then enters again, at most
# `empty_wakes_max` times. An enter with a bound does the same while time is left (amendment of
# 2026-11-07). That return comes only under load, so no single run of `zig build test` or of the
# Linux gate shows it. This gate runs `copies` copies of the uring test executable at a time,
# beside `busy` loops that only spin, for `rounds` rounds. With the enter again removed, 6 of 1,600
# runs failed at a load average of 15 to 23. With it, 0 of 4,800 failed at 18 to 35. Decision 6
# holds the counts for the enter with a bound.
#
# `zig build test` does not run it: it needs Docker, as the Linux gate does, and it takes minutes.

set -euo pipefail

# The Linux gate's image, pinned by digest (tools/linux_test.sh).
readonly image='alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc'
# Docker's default seccomp profile refuses io_uring_setup with EPERM.
readonly security_option='seccomp=unconfined'
readonly install_directory='zig-out/linux'
readonly executable='uring'

# The defaults are the run that showed the failure: 100 rounds of 16 copies beside 16 busy loops.
readonly rounds="${1:-100}"
readonly copies="${2:-16}"
readonly busy="${3:-16}"

fail() {
  echo "stress_test: $*" >&2
  exit 1
}

cd "$(dirname "$0")/.."
[[ -x "$install_directory/$executable" ]] ||
  fail "no $install_directory/$executable; run zig build test-linux first"
command -v docker >/dev/null 2>&1 || fail "no docker on PATH"

# The loop that runs inside the container. It prints one line per failed run and a last line with
# the counts, and it exits 1 when a run failed.
readonly script='
set -u
rounds=$1; copies=$2; busy=$3
i=0
while [ $i -lt $busy ]; do sh -c "while :; do :; done" & i=$((i+1)); done
runs=0; fails=0; r=0
while [ $r -lt $rounds ]; do
  p=0
  while [ $p -lt $copies ]; do
    (/in/uring > /tmp/out.$p 2>&1; echo $? > /tmp/rc.$p) & p=$((p+1))
  done
  wait_for=0
  while [ $wait_for -lt $copies ]; do
    while [ ! -s /tmp/rc.$wait_for ]; do sleep 0.05; done
    rc=$(cat /tmp/rc.$wait_for); rm /tmp/rc.$wait_for
    runs=$((runs+1))
    if [ "$rc" != 0 ]; then
      fails=$((fails+1))
      echo "stress_test: run $runs failed:"
      grep -E "FAIL|failed|\.zig:[0-9]+" /tmp/out.$wait_for | head -12
    fi
    wait_for=$((wait_for+1))
  done
  r=$((r+1))
done
echo "stress_test: runs=$runs fails=$fails load=$(cut -d" " -f1-3 /proc/loadavg)"
pkill -f "while :; do :; done" || true
[ $fails -eq 0 ]
'

echo "stress_test: $rounds rounds of $copies copies of $executable beside $busy busy loops"
docker run --rm --security-opt "$security_option" \
  -v "$PWD/$install_directory:/in:ro" "$image" \
  sh -c "$script" stress_test "$rounds" "$copies" "$busy"
echo "stress_test: all passed"
