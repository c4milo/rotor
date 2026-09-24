# Calls per echo with a single-shot receive from the group, on `orbstack`, 2026-09-23

`bench/calls/count_calls.sh`, run four times in a privileged container of the Linux gate's alpine
image, with a directory that held only `echo_client` and one build of `rotor_epoll`, so each run
counted rotor's three epoll rows and skipped every other candidate. Both builds came from
`zig build bench-linux`:

- **before**: the tree of `50c891f`, where a receive from a group is never tried at the flush.
- **after**: the same tree with the commit that records this file, where a single-shot receive
  from a group is tried at the flush like any other receive.

The runs alternate, before and after, twice. The load average of the `mac` machine, whose cores
`orbstack` runs on, is written before each run: it fell from 27 to 7 during the four, so the echo
counts are not a result. The calls per echo are counts, and every run's overrun count is 0, so no
event was lost. Only the `group single` rows differ between the builds: the other two shapes
never reach the changed path.

```text
== base round 1, load 27.20
calls per echo, counted by the kernel's tracepoints
os: Linux 7.0.14-orbstack-00380-ga7e0a2dc9535, aarch64, 10 CPUs
connections: 16, seconds per run: 3

| payload | candidate | echoes | overruns | io_uring_enter | io_uring requests | poll arms | io-wq jobs | reads | writes | epoll_ctl | epoll waits | other calls | requests by opcode |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 65536 | rotor on epoll | 124032 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.001 | 1.001 | 0.000 | 0.195 | 0.000 |  |
| 65536 | rotor on epoll (accumulate) | 182725 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.552 | 1.000 | 0.695 | 0.190 | 0.000 |  |
| 65536 | rotor on epoll (group single) | 189230 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.000 | 1.000 | 1.189 | 0.174 | 0.000 |  |
| 4096 | rotor on epoll | 689359 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.000 | 1.000 | 0.000 | 0.128 | 0.000 |  |
| 4096 | rotor on epoll (accumulate) | 684546 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.205 | 1.000 | 0.357 | 0.139 | 0.000 |  |
| 4096 | rotor on epoll (group single) | 531341 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.000 | 1.000 | 1.460 | 0.157 | 0.000 |  |
== after round 1, load 10.89
calls per echo, counted by the kernel's tracepoints
os: Linux 7.0.14-orbstack-00380-ga7e0a2dc9535, aarch64, 10 CPUs
connections: 16, seconds per run: 3

| payload | candidate | echoes | overruns | io_uring_enter | io_uring requests | poll arms | io-wq jobs | reads | writes | epoll_ctl | epoll waits | other calls | requests by opcode |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 65536 | rotor on epoll | 218188 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.000 | 1.000 | 0.000 | 0.166 | 0.000 |  |
| 65536 | rotor on epoll (accumulate) | 214070 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.515 | 1.000 | 0.659 | 0.183 | 0.000 |  |
| 65536 | rotor on epoll (group single) | 206828 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.512 | 1.001 | 0.681 | 0.182 | 0.000 |  |
| 4096 | rotor on epoll | 800606 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.000 | 1.000 | 0.000 | 0.128 | 0.000 |  |
| 4096 | rotor on epoll (accumulate) | 604112 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.244 | 1.000 | 0.422 | 0.142 | 0.000 |  |
| 4096 | rotor on epoll (group single) | 692161 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.206 | 1.000 | 0.364 | 0.139 | 0.000 |  |
== base round 2, load 6.79
calls per echo, counted by the kernel's tracepoints
os: Linux 7.0.14-orbstack-00380-ga7e0a2dc9535, aarch64, 10 CPUs
connections: 16, seconds per run: 3

| payload | candidate | echoes | overruns | io_uring_enter | io_uring requests | poll arms | io-wq jobs | reads | writes | epoll_ctl | epoll waits | other calls | requests by opcode |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 65536 | rotor on epoll | 217243 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.000 | 1.000 | 0.000 | 0.167 | 0.000 |  |
| 65536 | rotor on epoll (accumulate) | 189969 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.525 | 1.000 | 0.667 | 0.192 | 0.000 |  |
| 65536 | rotor on epoll (group single) | 184123 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.000 | 1.000 | 1.251 | 0.177 | 0.000 |  |
| 4096 | rotor on epoll | 711748 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.000 | 1.000 | 0.000 | 0.128 | 0.000 |  |
| 4096 | rotor on epoll (accumulate) | 642500 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.212 | 1.000 | 0.379 | 0.140 | 0.000 |  |
| 4096 | rotor on epoll (group single) | 555389 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.000 | 1.000 | 1.395 | 0.160 | 0.000 |  |
== after round 2, load 7.54
calls per echo, counted by the kernel's tracepoints
os: Linux 7.0.14-orbstack-00380-ga7e0a2dc9535, aarch64, 10 CPUs
connections: 16, seconds per run: 3

| payload | candidate | echoes | overruns | io_uring_enter | io_uring requests | poll arms | io-wq jobs | reads | writes | epoll_ctl | epoll waits | other calls | requests by opcode |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 65536 | rotor on epoll | 180194 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.000 | 1.000 | 0.000 | 0.177 | 0.000 |  |
| 65536 | rotor on epoll (accumulate) | 182516 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.547 | 1.000 | 0.698 | 0.192 | 0.000 |  |
| 65536 | rotor on epoll (group single) | 171009 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.548 | 1.001 | 0.715 | 0.193 | 0.000 |  |
| 4096 | rotor on epoll | 697484 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.000 | 1.000 | 0.000 | 0.133 | 0.000 |  |
| 4096 | rotor on epoll (accumulate) | 574206 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.196 | 1.000 | 0.338 | 0.140 | 0.000 |  |
| 4096 | rotor on epoll (group single) | 623080 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.214 | 1.000 | 0.368 | 0.140 | 0.000 |  |
```
