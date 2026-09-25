# System calls per cross-core message after io_uring's posts moved to the mailbox rings, `orbstack`, 2026-09-25

The count of `calls-crosscore-uring-epoll-orbstack-2026-09-25.md` taken again after the change of
decision 4's amendment of 2026-09-25, from the working tree that became that change, the same way:
`bench/calls/count_post.sh` in a privileged container on `orbstack` (Linux
7.0.14-orbstack-00380-ga7e0a2dc9535), 20,000 round trips after 1,000 not counted.
`other` is every call the script does not name, which for `post_uring` is `io_uring_enter`.

```text
mode waiting: post_uring: 40000 messages, overruns 0, calls per message 2.101: other 2.101 futex 0.000
mode waiting: post_epoll: 40000 messages, overruns 0, calls per message 3.150: other 0.001 read 1.050 write 1.050 epoll_ctl 0.000 epoll_pwait2 1.050 futex 0.000
mode spinning: post_uring: 40000 messages, overruns 0, calls per message 0.002: other 0.002 futex 0.000
mode spinning: post_epoll: 40000 messages, overruns 0, calls per message 0.002: other 0.001 epoll_ctl 0.000 epoll_pwait2 0.000 futex 0.000
mode spin-budget: post_uring: 40000 messages, overruns 0, calls per message 0.002: other 0.002 futex 0.000
mode spin-budget: post_epoll: 40000 messages, overruns 0, calls per message 0.002: other 0.001 read 0.000 write 0.000 epoll_ctl 0.000 epoll_pwait2 0.000 futex 0.000
```
