# Calls per cross-core message on epoll, on `orbstack`, 2026-09-24

`bench/calls/count_post.sh post_epoll --samples 20000 --warmup 1000`, in a privileged container of
the race gate's debian image. `post_epoll` is `bench/crosscore/rotor_post.zig` built against the
epoll backend by `zig build bench-linux`, in `waiting` mode: two loops on two threads send one
message back and forth, and each blocks until the other's arrives.

- **before**: the tree of `375b235`, where a tick that already has events to hand over still polls
  epoll, which can report only the loop's own wake.
- **after**: the same tree with that poll skipped when no operation waits for readiness.

Three rounds, alternating. Every run's overrun count is 0, so no event was lost. The per-second
figures moved with the load of the `mac` machine, whose cores `orbstack` runs on, and are not a
result. The first round was counted by the same script before it moved into `bench/calls/`, and
named its call numbers the same way.

```text
before round 1: 40000 messages, calls per message 4.117: epoll_pwait2 2.072, read 1.022, write 1.022
after  round 1: 40000 messages, calls per message 3.150: epoll_pwait2 1.050, read 1.050, write 1.050
before round 2: 40000 messages, calls per message 4.172: epoll_pwait2 2.091, read 1.040, write 1.040
after  round 2: 40000 messages, calls per message 3.148: epoll_pwait2 1.049, read 1.049, write 1.049
before round 3: 40000 messages, calls per message 4.054: epoll_pwait2 2.052, read 1.000, write 1.000
after  round 3: 40000 messages, calls per message 3.147: epoll_pwait2 1.049, read 1.048, write 1.048
```
