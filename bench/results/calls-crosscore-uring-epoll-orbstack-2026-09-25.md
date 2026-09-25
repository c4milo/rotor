# System calls per cross-core message, io_uring against epoll, `orbstack`, 2026-09-25

`bench/calls/count_post.sh` counted the system calls of `rotor_post`'s ping-pong, built for Linux
by `zig build bench-linux` as `post_uring` and `post_epoll` from commit `9a603db`, in a privileged
container on `orbstack` (Linux 7.0.14-orbstack-00380-ga7e0a2dc9535). Each run is 20,000 round trips after 1,000
not counted, so 40,000 messages. `other` is every call the script does not name, which for
`post_uring` is `io_uring_enter`. Command, for each program and mode:

```sh
docker run --rm --privileged -v "$PWD/zig-out/linux-bench:/b:ro" \
  -v "$PWD/bench/calls/count_post.sh:/count.sh:ro" <alpine image> \
  sh /count.sh <program> --mode <mode> --samples 20000 --warmup 1000
```

```text
mode waiting: post_uring: 40000 messages, overruns 0, calls per message 2.102: other 2.102 futex 0.000
mode waiting: post_epoll: 40000 messages, overruns 0, calls per message 3.150: other 0.001 read 1.049 write 1.049 epoll_ctl 0.000 epoll_pwait2 1.049 futex 0.000
mode spinning: post_uring: 40000 messages, overruns 0, calls per message 2.102: other 2.101 futex 0.000
mode spinning: post_epoll: 40000 messages, overruns 0, calls per message 0.002: other 0.001 epoll_ctl 0.000 epoll_pwait2 0.000 futex 0.000
mode spin-budget: post_uring: 40000 messages, overruns 0, calls per message 2.102: other 2.102 futex 0.000
mode spin-budget: post_epoll: 40000 messages, overruns 0, calls per message 0.002: other 0.001 read 0.000 write 0.000 epoll_ctl 0.000 epoll_pwait2 0.000 futex 0.000
```
