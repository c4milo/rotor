#!/bin/sh
#
# count_calls_macos: the system calls an echo server makes per echo on macOS, the kqueue half of
# `count_calls.sh`. macOS has no tracepoint a process without root can read. Its kernel keeps two
# counts for each process, the Unix system calls and the Mach traps, and `task_calls` reads them.
# The script reads them before and after one client run, and divides by the echoes the client
# completed.
#
# Nothing stops the server, and nothing is traced. The counts say how many calls, and not which
# ones: a kevent and a read are one call each. A change that adds about one call per echo shows in
# them, which is what the gate holds them to. A call that the commpage answers, as
# `mach_absolute_time` is, enters no kernel and is not counted.
#
# Run it with the echo programs in BIN, which is zig-out/bin by default, as the `calls` job of
# `.github/workflows/ci.yml` runs it:
#
#     zig build bench-echo
#     SECONDS_PER_RUN=1 sh bench/calls/count_calls_macos.sh
#
# libuv and libxev are counted too when BIN holds them, from `zig build bench-alternatives
# -Dalternatives`. A program that is missing is skipped. The server is idle while the counts are
# read, so a read finds it blocked in its kevent and adds nothing of the server's own.
set -u
BIN=${BIN:-zig-out/bin}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
CONNECTIONS=${CONNECTIONS:-16}
SECONDS_PER_RUN=${SECONDS_PER_RUN:-3}
PORT=35000

if [ ! -x "$BIN/task_calls" ]; then
  echo "count_calls_macos: $BIN/task_calls is missing; run 'zig build bench-echo'" >&2
  exit 2
fi

# measure LABEL PAYLOAD PROGRAM [ARGS...]
measure() {
  label=$1; payload=$2; program=$3; shift 3
  if [ ! -x "$BIN/$program" ]; then return; fi
  PORT=$((PORT + 1))
  "$BIN/$program" "$PORT" "$@" >/dev/null 2>&1 &
  server=$!
  sleep 1
  before=$("$BIN/task_calls" "$server")
  "$BIN/echo_client" "$PORT" --connections "$CONNECTIONS" --payload "$payload" \
    --seconds "$SECONDS_PER_RUN" --warmup 0 > "$WORK/client.json" 2>&1
  after=$("$BIN/task_calls" "$server")
  echoes=$(grep -o '"operations":[0-9]*' "$WORK/client.json" | head -1 | cut -d: -f2)
  # The kernel keeps each count in 32 bits, so a difference is taken modulo 2^32.
  awk -v label="$label" -v payload="$payload" -v echoes="${echoes:-0}" \
    -v before="$before" -v after="$after" 'BEGIN {
      if (echoes + 0 == 0 || split(before, b, " ") != 2 || split(after, a, " ") != 2) {
        print "| " payload " | " label " | 0 | no echoes |"
        exit
      }
      unix = (a[1] - b[1] + 4294967296) % 4294967296
      mach = (a[2] - b[2] + 4294967296) % 4294967296
      printf "| %s | %s | %d | %.3f | %.3f |\n", payload, label, echoes, unix / echoes,
        mach / echoes
    }'
  kill "$server" 2>/dev/null
  wait "$server" 2>/dev/null
}

echo "calls per echo, counted by the kernel for the server's process"
echo "os: macOS $(sw_vers -productVersion), $(uname -m), $(sysctl -n hw.ncpu) CPUs"
echo "connections: $CONNECTIONS, seconds per run: $SECONDS_PER_RUN"
echo
echo "| payload | candidate | echoes | unix calls | mach traps |"
echo "|---:|---|---:|---:|---:|"
for payload in 65536 4096; do
  buffer=$payload
  measure rotor "$payload" rotor_echo --buffer-bytes "$buffer"
  measure "rotor (accumulate)" "$payload" rotor_echo --shape accumulate --buffer-bytes "$buffer"
  measure "rotor (group single)" "$payload" rotor_echo --shape group_single \
    --buffer-bytes "$buffer"
  measure libuv "$payload" libuv_echo --buffers one
  measure libxev "$payload" libxev_echo
done

# A clean run exits 0; the last `wait` answers the status of the server it stopped.
exit 0
