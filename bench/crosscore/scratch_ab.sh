#!/bin/bash
# Experiment for the cross-core gap, never for main. On one macOS runner it measures:
#   - instructions per round trip, user and kernel together, of rotor before and after this
#     branch's changes, libuv and libxev (a long run minus a short one, as /usr/bin/time -l counts);
#   - the cross-core comparison before and after, in alternating rounds, with libuv and libxev;
#   - rotor after, without the user-interactive QoS class, and libuv with it.
# Usage: scratch_ab.sh BASE_COMMIT ROUNDS
set -euo pipefail
base="$1"
rounds="$2"
root="$(pwd)"
before_tree="$root/../before"

git fetch -q origin "$base"
git worktree add -q "$before_tree" "$base"
(cd "$before_tree" && zig build bench-crosscore bench-alternatives)
zig build bench-crosscore bench-alternatives
before="$before_tree/zig-out/bin"
after="$root/zig-out/bin"
runner="$after/crosscore_runner"

sysctl machdep.cpu.brand_string hw.ncpu hw.memsize
sw_vers
uptime
ps -Ao pcpu,comm -r | head -8

count() {
  /usr/bin/time -l "$1" --samples "$2" --warmup 0 2>&1 >/dev/null |
    awk '/instructions retired/ {i=$1} /cycles elapsed/ {c=$1} END {print i + 0, c + 0}'
}
per_round_trip() {
  local short=2000 long=202000 si sc li lc
  read -r si sc < <(count "$2" "$short")
  read -r li lc < <(count "$2" "$long")
  echo "instructions per round trip: $1 $(( (li - si) / (long - short) )), cycles $(( (lc - sc) / (long - short) ))"
}
for round in 1 2 3; do
  per_round_trip "rotor before" "$before/rotor_post"
  per_round_trip "rotor after" "$after/rotor_post"
  per_round_trip "libuv" "$after/libuv_async"
  per_round_trip "libxev" "$after/libxev_async"
done

for round in $(seq 1 "$rounds"); do
  echo "## Round $round, before"
  "$runner" --directory "$before" --rounds 5
  echo "## Round $round, after"
  "$runner" --directory "$after" --rounds 5
  echo "## Round $round, after, rotor without the QoS class"
  ROTOR_BENCH_QOS=off "$runner" --directory "$after" --rounds 5 --only rotor
  echo "## Round $round, after, libuv with the user-interactive QoS class"
  LIBUV_BENCH_QOS=on "$runner" --directory "$after" --rounds 5 --only libuv
done
uptime
