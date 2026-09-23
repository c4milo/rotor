# Calls per echo on `orbstack`, 2026-09-22

`bench/calls/count_calls.sh`, run once in a privileged container on the `orbstack` virtual machine,
at 22:04 local time (2026-09-23 02:04 UTC), on commit `979abb7` with the script uncommitted beside
it. The programs were built as the script's header says, for `aarch64-linux-gnu`, and `rotor_epoll`
is `bench/echo/rotor_echo.zig` built against the epoll backend. The container image is the Linux
gates' debian image.

Load average before the run, the `mac` machine's, whose cores this virtual machine runs on:
4.38 5.32 5.83.

Each row is one server under one client for three seconds, 16 connections, counted by the kernel's
tracepoints and divided by the echoes the client completed. Every run's overrun count is 0, so no
event was lost. The throughput a traced run reached is not a result: tracing costs each server a
little per system call. The echo rows of `echo-orbstack-2026-09-22.md` are the throughput.

```text
calls per echo, counted by the kernel's tracepoints
os: Linux 7.0.14-orbstack-00380-ga7e0a2dc9535, aarch64, 10 CPUs
connections: 16, seconds per run: 3

| payload | candidate | echoes | overruns | io_uring_enter | io_uring requests | poll arms | io-wq jobs | reads | writes | epoll_ctl | epoll waits | other calls | requests by opcode |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 65536 | rotor | 102547 | 0 | 0.216 | 1.002 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | CLOSE 0.000, ASYNC_CANCEL 0.000, RECV 0.000, SEND 1.001 |
| 65536 | rotor (accumulate) | 221242 | 0 | 0.240 | 2.003 | 0.715 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | CLOSE 0.000, ASYNC_CANCEL 0.000, RECV 1.003, SEND 1.000 |
| 65536 | libuv | 228491 | 0 | 0.173 | 2.000 | 0.000 | 0.000 | 1.000 | 1.000 | 0.000 | 0.086 | 0.000 | EPOLL 2.000 |
| 65536 | libxev | 224522 | 0 | 0.215 | 2.010 | 0.809 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | CLOSE 0.000, ACCEPT 0.000, RECV 1.005, SEND 1.005 |
| 65536 | rotor on epoll | 289360 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.000 | 1.000 | 0.000 | 0.154 | 0.000 |  |
| 65536 | rotor on epoll (accumulate) | 248391 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.505 | 1.000 | 0.652 | 0.178 | 0.000 |  |
| 4096 | rotor | 522979 | 0 | 0.172 | 1.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | CLOSE 0.000, ASYNC_CANCEL 0.000, RECV 0.000, SEND 1.000 |
| 4096 | rotor (accumulate) | 1104372 | 0 | 0.136 | 2.000 | 0.168 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | CLOSE 0.000, ASYNC_CANCEL 0.000, RECV 1.000, SEND 1.000 |
| 4096 | libuv | 544887 | 0 | 0.169 | 2.000 | 0.000 | 0.000 | 1.000 | 1.000 | 0.000 | 0.084 | 0.000 | EPOLL 2.000 |
| 4096 | libxev | 858945 | 0 | 0.136 | 2.000 | 0.205 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | CLOSE 0.000, ACCEPT 0.000, RECV 1.000, SEND 1.000 |
| 4096 | rotor on epoll | 969120 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.000 | 1.000 | 0.000 | 0.123 | 0.000 |  |
| 4096 | rotor on epoll (accumulate) | 1001329 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.115 | 1.000 | 0.208 | 0.131 | 0.000 |  |
```
