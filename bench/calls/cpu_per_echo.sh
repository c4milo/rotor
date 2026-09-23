#!/bin/sh
#
# cpu_per_echo: the CPU time an echo server spends per echo, and how much of it is in the kernel,
# for rotor's group shape at several group sizes beside the accumulate shape and libxev. It is
# how the working set of rotor's buffer group was found (bench/alternatives/README.md): a shape
# that made the fewest kernel calls spent the most kernel time per echo.
#
# The time comes from /proc/<pid>/schedstat, the nanoseconds the server ran and the times it was
# switched out, read before and after one client run. The user and system split comes from
# /proc/<pid>/stat, in clock ticks. Nothing is traced, so the servers run at full speed.
#
# The client's CPU comes from the shell's `times`, which prints the CPU time of the shell's
# finished children, read before and after the client runs. The client is the one child that
# finishes in between. A client busy near 100 percent limits the run, and then the rates it
# reaches say nothing about the servers.
#
# Run it where io_uring is allowed, with the echo programs in BIN, which is /b by default. In a
# container, with the programs built for it mounted there:
#
#     zig build bench-echo -Dtarget=aarch64-linux-gnu --prefix /tmp/calls
#     zig build bench-alternatives -Dalternatives -Dtarget=aarch64-linux-gnu --prefix /tmp/calls
#     docker run --rm --security-opt seccomp=unconfined -v /tmp/calls/bin:/b:ro \
#       -v "$PWD/bench/calls/cpu_per_echo.sh:/cpu.sh:ro" <image> sh /cpu.sh
#
# On a Linux host, as the comparison job of `.github/workflows/ci.yml` runs it:
#
#     BIN=zig-out/bin sh bench/calls/cpu_per_echo.sh
set -u
BIN=${BIN:-/b}
CONNECTIONS=${CONNECTIONS:-16}
SECONDS_PER_RUN=${SECONDS_PER_RUN:-3}
PORT=33000

# measure LABEL PAYLOAD PROGRAM [ARGS...]
measure() {
  label=$1; payload=$2; program=$3; shift 3
  PORT=$((PORT + 1))
  "$BIN/$program" "$PORT" "$@" >/dev/null 2>&1 &
  server=$!
  sleep 1
  if ! kill -0 "$server" 2>/dev/null; then
    echo "| $payload | $label | refused by the server | | | | | |"
    return
  fi
  read -r ran_before waited_before switched_before < "/proc/$server/schedstat"
  set -- $(cut -d' ' -f14,15 "/proc/$server/stat")
  user_before=$1; system_before=$2
  times > /tmp/times.before
  "$BIN/echo_client" "$PORT" --connections "$CONNECTIONS" --payload "$payload" \
    --seconds "$SECONDS_PER_RUN" --warmup 0 > /tmp/client.json 2>&1
  times > /tmp/times.after
  read -r ran_after waited_after switched_after < "/proc/$server/schedstat"
  set -- $(cut -d' ' -f14,15 "/proc/$server/stat")
  user_after=$1; system_after=$2
  echoes=$(grep -o '"operations":[0-9]*' /tmp/client.json | head -1 | cut -d: -f2)
  awk -v label="$label" -v payload="$payload" -v echoes="${echoes:-0}" \
    -v ran=$((ran_after - ran_before)) -v switched=$((switched_after - switched_before)) \
    -v user=$((user_after - user_before)) -v kernel=$((system_after - system_before)) \
    -v seconds="$SECONDS_PER_RUN" \
    -v client="$(awk -f /tmp/children.awk /tmp/times.before /tmp/times.after)" 'BEGIN {
      if (echoes == 0) { printf "| %s | %s | no echoes | | | | | |\n", payload, label; exit }
      ticks = user + kernel
      split(client, times, " ")
      printf "| %s | %s | %d | %.2f | %.1f | %.1f | %.3f | %.1f |\n", payload, label, echoes,
        ran / echoes / 1000, 100 * ran / (seconds * 1000000000),
        ticks == 0 ? 0 : 100 * kernel / ticks, switched / echoes,
        100 * (times[2] - times[1]) / seconds
    }'
  kill "$server" 2>/dev/null
  wait "$server" 2>/dev/null
}

# The second line of `times` holds the children's user and system time, as "0m1.250s 0m0.300s".
# This prints their sum in seconds, once per file it reads. `times` runs outside `$(...)`, because
# a subshell's children are its own and it has none.
cat > /tmp/children.awk <<'EOF'
FNR == 2 {
  total = 0
  for (i = 1; i <= 2; i++) {
    split($i, part, "m")
    sub(/s$/, "", part[2])
    total += part[1] * 60 + part[2]
  }
  print total
}
EOF

echo "cpu per echo, from /proc/<pid>/schedstat and /proc/<pid>/stat"
echo "os: Linux $(uname -r), $(uname -m), $(nproc) CPUs"
echo "connections: $CONNECTIONS, seconds per run: $SECONDS_PER_RUN"
echo
echo "| payload | server | echoes | cpu µs per echo | busy % | in the kernel % \
| switches per echo | client busy % |"
echo "|---:|---|---:|---:|---:|---:|---:|---:|"
for payload in 4096 65536; do
  measure "rotor (group, the whole pool)" "$payload" rotor_echo --buffer-bytes "$payload"
  for count in 2048 256 32; do
    measure "rotor (group, $count buffers)" "$payload" rotor_echo --buffer-bytes "$payload" \
      --group-buffers "$count"
  done
  measure "rotor (accumulate)" "$payload" rotor_echo --shape accumulate --buffer-bytes "$payload"
  measure libxev "$payload" libxev_echo
done
exit 0
