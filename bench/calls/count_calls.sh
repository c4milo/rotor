#!/bin/sh
#
# count_calls: the system calls an echo server makes per echo, and how io_uring ran its requests,
# counted by the kernel's own tracepoints. It answers "how many kernel calls does this loop spend
# on one echo", which a throughput row cannot.
#
# Nothing stops the server. `strace` would stop it on every call, and an io_uring server that runs
# slower gathers more completions per `io_uring_enter`, so strace undercounts exactly the calls in
# question. Here the kernel writes one event per call into its trace buffer, a reader streams them
# out through `trace_pipe`, and awk counts. A run whose buffer overflowed says so in its overruns
# column, and its counts are then not to be used.
#
# Run it as root where tracefs and io_uring are allowed, with the echo programs in BIN, which is /b
# by default. In a privileged container, with the programs built for it mounted there:
#
#     zig build bench-echo -Dtarget=aarch64-linux-gnu --prefix /tmp/calls
#     zig build bench-alternatives -Dalternatives -Dtarget=aarch64-linux-gnu --prefix /tmp/calls
#     docker run --rm --privileged -v /tmp/calls/bin:/b:ro \
#       -v "$PWD/bench/calls/count_calls.sh:/count.sh:ro" <image> sh /count.sh
#
# On a Linux host, as the comparison job of `.github/workflows/ci.yml` runs it:
#
#     sudo BIN=zig-out/bin sh bench/calls/count_calls.sh
#
# The image needs a shell, awk and cat; the Linux gates' debian image has them. rotor's echo server
# on the epoll backend is counted too when BIN holds `rotor_epoll`, which the build does not make:
#
#     zig build-exe -target aarch64-linux-gnu -O ReleaseSafe \
#       --dep core --dep backend --dep harness -Mroot=bench/echo/rotor_echo.zig \
#       -Mcore=src/core/core.zig --dep core \
#       -Mbackend=src/epoll/epoll.zig -Mharness=bench/harness/harness.zig \
#       -femit-bin=/tmp/calls/bin/rotor_epoll
#
# Only the server's own process is counted, by its name: the client runs on io_uring too, and on
# OrbStack the pid a container sees is not the one the kernel records. The kernel keeps 15
# characters of a name, which is why the epoll build is called `rotor_epoll`.
#
# Tracing state belongs to the kernel and not to the container, so every run starts from a reset,
# and the script turns every event off and restores the buffer's default size when it exits,
# whatever happened. Left on, a system-wide tracepoint costs every process on the machine.
set -u
BIN=${BIN:-/b}
# Each run's files go in a directory of its own. A fixed name in /tmp failed on the GitHub runner:
# a file the unprivileged CPU script had left there could not be opened by root, so the client
# never ran and every row read zero.
WORK=$(mktemp -d)
T=/sys/kernel/tracing
mount -t tracefs nodev "$T" 2>/dev/null
EVENTS="raw_syscalls/sys_enter io_uring/io_uring_submit_req io_uring/io_uring_poll_arm \
io_uring/io_uring_queue_async_work"
CONNECTIONS=${CONNECTIONS:-16}
SECONDS_PER_RUN=${SECONDS_PER_RUN:-3}
PORT=31000
# Room for the events a run makes between two reads of trace_pipe, per CPU.
BUFFER_KB=16384
# The kernel's default, restored on exit.
DEFAULT_BUFFER_KB=1408

reset() {
  echo 0 > "$T/tracing_on"
  echo 0 > "$T/events/enable"
  for e in $EVENTS; do echo 0 > "$T/events/$e/filter"; done
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

# The system call numbers this script names, by architecture: a read, a write, `epoll_ctl`, the
# three waits of epoll, and `io_uring_enter`, which is 426 everywhere.
case "$(uname -m)" in
  aarch64) READS="63 65 207 212"; WRITES="64 66 206 211"; CTL="21"; WAITS="22 441" ;;
  x86_64) READS="0 19 45 47"; WRITES="1 20 44 46"; CTL="233"; WAITS="232 281 441" ;;
  *) echo "count_calls: no system call numbers for $(uname -m)" >&2; exit 2 ;;
esac

# Counts one run's events and prints its row. The arguments are the label, the payload, the
# echoes the client completed and the buffer's overruns.
row() {
  awk -v label="$1" -v payload="$2" -v echoes="$3" -v overruns="$4" \
    -v reads="$READS" -v writes="$WRITES" -v ctl="$CTL" -v waits="$WAITS" '
    BEGIN {
      split(reads, list, " "); for (i in list) kind[list[i]] = "read"
      split(writes, list, " "); for (i in list) kind[list[i]] = "write"
      split(ctl, list, " "); for (i in list) kind[list[i]] = "ctl"
      split(waits, list, " "); for (i in list) kind[list[i]] = "wait"
      kind[426] = "enter"
    }
    / sys_enter: NR / {
      for (i = 1; i <= NF; i++) if ($i == "NR") nr = $(i + 1)
      counted[(nr in kind) ? kind[nr] : "other"]++
      next
    }
    / io_uring_submit_req:/ {
      for (i = 1; i <= NF; i++) if ($i == "opcode") opcode = $(i + 1)
      sub(/,$/, "", opcode)
      requests++
      by_opcode[opcode]++
      next
    }
    / io_uring_poll_arm:/ { arms++; next }
    / io_uring_queue_async_work:/ { workers++; next }
    function per(n) { return sprintf("%.3f", n / echoes) }
    END {
      if (echoes + 0 == 0) {
        print "| " payload " | " label " | 0 | " overruns " | no echoes |"
        exit
      }
      detail = ""
      for (opcode in by_opcode) {
        detail = detail (detail == "" ? "" : ", ") opcode " " per(by_opcode[opcode])
      }
      printf "| %s | %s | %d | %d | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n",
        payload, label, echoes, overruns, per(counted["enter"]), per(requests), per(arms),
        per(workers), per(counted["read"]), per(counted["write"]), per(counted["ctl"]),
        per(counted["wait"]), per(counted["other"]), detail
    }' "$WORK/events.txt"
}

# measure LABEL PAYLOAD PROGRAM [ARGS...]
measure() {
  label=$1; payload=$2; program=$3; shift 3
  if [ ! -x "$BIN/$program" ]; then return; fi
  PORT=$((PORT + 1))
  "$BIN/$program" "$PORT" "$@" >/dev/null 2>&1 &
  server=$!
  sleep 1
  reset
  for e in $EVENTS; do
    echo "comm == \"$program\"" > "$T/events/$e/filter"
    echo 1 > "$T/events/$e/enable"
  done
  cat "$T/trace_pipe" > "$WORK/events.txt" &
  reader=$!
  echo 1 > "$T/tracing_on"
  "$BIN/echo_client" "$PORT" --connections "$CONNECTIONS" --payload "$payload" \
    --seconds "$SECONDS_PER_RUN" --warmup 0 > "$WORK/client.json" 2>&1
  echo 0 > "$T/tracing_on"
  sleep 1
  kill "$reader" 2>/dev/null
  wait "$reader" 2>/dev/null
  overruns=$(cat "$T"/per_cpu/cpu*/stats | awk '/^overrun/ { total += $2 } END { print total + 0 }')
  echoes=$(grep -o '"operations":[0-9]*' "$WORK/client.json" | head -1 | cut -d: -f2)
  reset
  row "$label" "$payload" "${echoes:-0}" "$overruns"
  kill "$server" 2>/dev/null
  wait "$server" 2>/dev/null
}

echo "calls per echo, counted by the kernel's tracepoints"
echo "os: Linux $(uname -r), $(uname -m), $(nproc) CPUs"
echo "connections: $CONNECTIONS, seconds per run: $SECONDS_PER_RUN"
echo
echo "| payload | candidate | echoes | overruns | io_uring_enter | io_uring requests \
| poll arms | io-wq jobs | reads | writes | epoll_ctl | epoll waits | other calls \
| requests by opcode |"
echo "|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|"
for payload in 65536 4096; do
  buffer=$payload
  measure rotor "$payload" rotor_echo --buffer-bytes "$buffer"
  measure "rotor (accumulate)" "$payload" rotor_echo --shape accumulate --buffer-bytes "$buffer"
  measure libuv "$payload" libuv_echo --buffers one
  measure libxev "$payload" libxev_echo
  measure "rotor on epoll" "$payload" rotor_epoll --buffer-bytes "$buffer"
  measure "rotor on epoll (accumulate)" "$payload" rotor_epoll --shape accumulate \
    --buffer-bytes "$buffer"
done

# A clean run exits 0; the last `wait` answers the status of the server it stopped.
exit 0
