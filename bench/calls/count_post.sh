#!/bin/sh
#
# count_post: the system calls one cross-core message costs, counted by the kernel's raw_syscalls
# tracepoint while `rotor_post`'s ping-pong runs. A loop that has only posts, and no operation
# waiting on a socket, is where a poll with nothing to report shows up, which an echo cannot show.
#
# Run it as root where tracefs is allowed, with the program in BIN, which is /b by default. In a
# privileged container, with `zig build bench-linux` built for it:
#
#     docker run --rm --privileged -v "$PWD/zig-out/linux-bench:/b:ro" \
#       -v "$PWD/bench/calls/count_post.sh:/count.sh:ro" <image> sh /count.sh post_epoll
#
# Arguments after the program go to it; the default is 20,000 round trips after 1,000 unmeasured
# ones. The trace follows the program's threads by name, which the kernel cuts to 15 characters,
# so a longer name matches nothing. A run whose buffer overflowed says so in its overruns, and its
# counts are then not to be used. Tracing state is global to the kernel, so the script leaves it
# off when it exits, whatever happened.
set -u
BIN=${BIN:-/b}
T=/sys/kernel/tracing
mount -t tracefs nodev "$T" 2>/dev/null
program=$1
shift
[ $# -eq 0 ] && set -- --samples 20000 --warmup 1000
WORK=$(mktemp -d)
# Room for the events of one run, per CPU, and the kernel's default, restored on exit.
BUFFER_KB=65536
DEFAULT_BUFFER_KB=1408

reset() {
  echo 0 > "$T/tracing_on"
  echo 0 > "$T/events/enable"
  echo 0 > "$T/events/raw_syscalls/sys_enter/filter"
  echo > "$T/trace"
}
restore() {
  reset
  echo "$DEFAULT_BUFFER_KB" > "$T/buffer_size_kb"
  echo 1 > "$T/tracing_on"
  rm -rf "$WORK"
}
trap restore EXIT INT TERM
reset
echo "$BUFFER_KB" > "$T/buffer_size_kb"

# The system call numbers this script names, by architecture.
case "$(uname -m)" in
  aarch64) NAMES="22:epoll_pwait 441:epoll_pwait2 21:epoll_ctl 63:read 64:write 98:futex" ;;
  x86_64) NAMES="281:epoll_pwait 441:epoll_pwait2 233:epoll_ctl 0:read 1:write 202:futex" ;;
  *) echo "count_post: no system call numbers for $(uname -m)" >&2; exit 2 ;;
esac

echo "comm == \"$program\"" > "$T/events/raw_syscalls/sys_enter/filter"
echo 1 > "$T/events/raw_syscalls/sys_enter/enable"
cat "$T/trace_pipe" > "$WORK/events.txt" &
reader=$!
echo 1 > "$T/tracing_on"
"$BIN/$program" "$@" > "$WORK/out.txt" 2>&1
echo 0 > "$T/tracing_on"
sleep 1
kill "$reader" 2>/dev/null
wait "$reader" 2>/dev/null
overruns=$(cat "$T"/per_cpu/cpu*/stats | awk '/^overrun/ { total += $2 } END { print total + 0 }')
messages=$(grep -o '"operations":[0-9]*' "$WORK/out.txt" | cut -d: -f2)
if [ "${messages:-0}" -eq 0 ]; then echo "count_post: $program reported no messages" >&2; exit 1; fi
awk -v messages="$messages" -v overruns="$overruns" -v program="$program" -v names="$NAMES" '
  BEGIN {
    n = split(names, list, " ")
    for (i = 1; i <= n; i++) { split(list[i], pair, ":"); name[pair[1]] = pair[2] }
  }
  / sys_enter: NR / {
    for (i = 1; i <= NF; i++) if ($i == "NR") nr = $(i + 1)
    count[(nr in name) ? name[nr] : "other"]++
    total++
  }
  END {
    printf "%s: %d messages, overruns %d, calls per message %.3f:", \
      program, messages, overruns, total / messages
    for (kind in count) printf " %s %.3f", kind, count[kind] / messages
    printf "\n"
  }' "$WORK/events.txt"
