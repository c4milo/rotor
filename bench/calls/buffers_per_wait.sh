#!/bin/sh
#
# buffers_per_wait: how many provided buffers the kernel takes from rotor's io_uring buffer ring
# between two `io_uring_enter` calls of the echo server. A ring that the loop refills before each
# wait must hold at least that many entries, or a receive ends with `buffers_exhausted` while the
# loop still holds free buffers (bench/alternatives/README.md, "Kernel calls per echo").
#
# The kernel's tracepoints give it without stopping the server: `raw_syscalls/sys_enter` for each
# `io_uring_enter`, and `io_uring/io_uring_complete` for each completion whose flags carry
# IORING_CQE_F_BUFFER, bit 0. Every completion of this server is posted inside one of its own
# `io_uring_enter` calls, because rotor sets its ring up with DEFER_TASKRUN, so the completions
# between two enters are the ones the second enter posted. A completion whose result is -ENOBUFS
# is a receive that found the group empty; the table counts those too.
#
# The first second of a run is reported apart from the rest. In it the client connects, and the
# server submits a receive for each new connection, many in one `io_uring_enter`: each receive that
# finds bytes already there takes a buffer during the submission itself. After it, the server only
# gives buffers back and waits.
#
# Run it as root where tracefs and io_uring are allowed, with the echo programs in BIN, which is /b
# by default. In a privileged container, with the programs built for it mounted there:
#
#     zig build bench-echo -Dtarget=aarch64-linux-gnu --prefix /tmp/calls
#     docker run --rm --privileged -v /tmp/calls/bin:/b:ro \
#       -v "$PWD/bench/calls/buffers_per_wait.sh:/burst.sh:ro" <image> sh /burst.sh
#
# Tracing state belongs to the kernel and not to the container, so every run starts from a reset,
# and the script turns every event off and restores the buffer's default size when it exits.
set -u
BIN=${BIN:-/b}
# Each run's files go in a directory of its own. A fixed name in /tmp failed on the GitHub runner:
# a file the unprivileged CPU script had left there could not be opened by root, so the client
# never ran and every row read zero.
WORK=$(mktemp -d)
T=/sys/kernel/tracing
mount -t tracefs nodev "$T" 2>/dev/null
SECONDS_PER_RUN=${SECONDS_PER_RUN:-4}
PORT=34000
# Room for the events a run makes between two reads of trace_pipe, per CPU.
BUFFER_KB=16384
# The kernel's default, restored on exit.
DEFAULT_BUFFER_KB=1408
PROGRAM=rotor_echo
ENTER=426

reset() {
  echo 0 > "$T/tracing_on"
  echo 0 > "$T/events/enable"
  echo 0 > "$T/events/raw_syscalls/sys_enter/filter"
  echo 0 > "$T/events/io_uring/io_uring_complete/filter"
  echo > "$T/trace"
}

restore() {
  reset
  echo "$DEFAULT_BUFFER_KB" > "$T/buffer_size_kb"
  echo 1 > "$T/tracing_on"
}

trap 'restore; rm -rf "$WORK"' EXIT INT TERM
reset
echo "$BUFFER_KB" > "$T/buffer_size_kb"

# Prints one run's row from the trace: the buffers taken between two enters, as a distribution
# over the enters of the run.
row() {
  awk -v payload="$1" -v connections="$2" -v group="$3" -v echoes="$4" -v overruns="$5" '
    / sys_enter: NR / {
      for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+:$/) now = $i + 0
      if (!started) first = now
      else if (now - first < 1) { if (taken > most_first) most_first = taken }
      else { per_wait[taken]++; waits++; total += taken }
      started = 1; taken = 0
      next
    }
    / io_uring_complete:/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "result") result = $(i + 1) + 0
        if ($i == "cflags") flags = $(i + 1)
      }
      if (result == -105) empty++
      else if (flags ~ /[13579bdf]$/) taken++
      next
    }
    function at(fraction,   seen, n) {
      seen = 0
      for (n = 0; n <= most; n++) {
        seen += per_wait[n]
        if (seen >= fraction * waits) return n
      }
      return most
    }
    END {
      if (waits == 0) {
        printf "| %s | %s | %s | %d | %d | 0 | | | | | | %d | %d |\n", payload, connections,
          group, echoes, most_first, empty, overruns
        exit
      }
      most = 0
      for (n in per_wait) if (n + 0 > most) most = n + 0
      printf "| %s | %s | %s | %d | %d | %d | %.2f | %d | %d | %d | %d | %d | %d |\n", payload,
        connections, group, echoes, most_first, waits, total / waits, at(0.5), at(0.99),
        at(0.999), most, empty + 0, overruns
    }' "$WORK/events.txt"
}

# measure PAYLOAD CONNECTIONS GROUP_BUFFERS
measure() {
  payload=$1; connections=$2; group=$3
  PORT=$((PORT + 1))
  "$BIN/$PROGRAM" "$PORT" --buffer-bytes "$payload" --group-buffers "$group" >/dev/null 2>&1 &
  server=$!
  sleep 1
  if ! kill -0 "$server" 2>/dev/null; then
    echo "| $payload | $connections | $group | refused by the server | | | | | | | | | |"
    return
  fi
  reset
  echo "comm == \"$PROGRAM\" && id == $ENTER" > "$T/events/raw_syscalls/sys_enter/filter"
  echo "comm == \"$PROGRAM\"" > "$T/events/io_uring/io_uring_complete/filter"
  echo 1 > "$T/events/raw_syscalls/sys_enter/enable"
  echo 1 > "$T/events/io_uring/io_uring_complete/enable"
  cat "$T/trace_pipe" > "$WORK/events.txt" &
  reader=$!
  echo 1 > "$T/tracing_on"
  "$BIN/echo_client" "$PORT" --connections "$connections" --payload "$payload" \
    --seconds "$SECONDS_PER_RUN" --warmup 0 > "$WORK/client.json" 2>&1
  echo 0 > "$T/tracing_on"
  sleep 1
  kill "$reader" 2>/dev/null
  wait "$reader" 2>/dev/null
  overruns=$(cat "$T"/per_cpu/cpu*/stats | awk '/^overrun/ { total += $2 } END { print total + 0 }')
  echoes=$(grep -o '"operations":[0-9]*' "$WORK/client.json" | head -1 | cut -d: -f2)
  reset
  row "$payload" "$connections" "$group" "${echoes:-0}" "$overruns"
  kill "$server" 2>/dev/null
  wait "$server" 2>/dev/null
}

# The group the echo runner gives: two buffers per connection, never fewer than 32, rounded up to
# a power of two (bench/echo/echo_runner_setup.zig).
sized() {
  wanted=$(( $1 * 2 )); if [ "$wanted" -lt 32 ]; then wanted=32; fi
  count=1; while [ "$count" -lt "$wanted" ]; do count=$((count * 2)); done
  echo "$count"
}

echo "provided buffers taken per io_uring_enter, counted by the kernel's tracepoints"
echo "os: Linux $(uname -r), $(uname -m), $(nproc) CPUs"
echo "seconds per run: $SECONDS_PER_RUN"
echo
echo "| payload | connections | group buffers | echoes | first second, most per wait \
| waits after it | buffers per wait, mean | p50 | p99 | p999 | most \
| receives that found the group empty | overruns |"
echo "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
# At 64 KiB, 512 connections would need a group of 64 MiB of buffers, which is rotor_echo's whole
# pool with no room for the ring, so that row is left out.
for payload in 4096 65536; do
  most_connections=512; if [ "$payload" -gt 4096 ]; then most_connections=256; fi
  for connections in 16 64 256 512; do
    if [ "$connections" -gt "$most_connections" ]; then continue; fi
    measure "$payload" "$connections" "$(sized "$connections")"
  done
done

# A clean run exits 0; the last `wait` answers the status of the server it stopped.
exit 0
