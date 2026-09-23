# CPU per echo on `orbstack`, 2026-09-22

`bench/calls/cpu_per_echo.sh`, run once in the Linux gates' debian image with `seccomp=unconfined`,
at 22:23 local time (2026-09-23 02:23 UTC). The programs were built for `aarch64-linux-gnu` from the tree of the commit that records this file,
as `bench/calls/cpu_per_echo.sh`'s header says, before the runner's command line moved into
`echo_runner_setup.zig`; that move changed no argument, and a test now holds the arguments.

Load average before the run, the `mac` machine's, whose cores this virtual machine runs on:
6.80 6.36 6.42. The machine was busy, and each row is one run of three seconds, so the rows
locate a cost and are not a comparison. `echo-sized-pool-orbstack-2026-09-22.md` is the comparison.

It is the measurement that found why rotor's group shape ran at half the rate of the other
candidates on this machine: with the whole 64 MiB pool as its group, the server spent 22.04 µs per
64 KiB echo, nearly all of it in the kernel, against 7.54 µs with 32 buffers. The 64 KiB row with
2048 buffers is the server refusing a group larger than its pool, which is what it should do.

```text
cpu per echo, from /proc/<pid>/schedstat and /proc/<pid>/stat
os: Linux 7.0.14-orbstack-00380-ga7e0a2dc9535, aarch64, 10 CPUs
connections: 16, seconds per run: 3

| payload | server | echoes | cpu µs per echo | busy % | in the kernel % | switches per echo |
|---:|---|---:|---:|---:|---:|---:|
| 4096 | rotor (group, the whole pool) | 599926 | 3.41 | 68.1 | 97.5 | 0.051 |
| 4096 | rotor (group, 2048 buffers) | 703204 | 3.04 | 71.3 | 97.6 | 0.042 |
| 4096 | rotor (group, 256 buffers) | 1491055 | 1.83 | 91.1 | 95.6 | 0.007 |
| 4096 | rotor (group, 32 buffers) | 1594188 | 1.75 | 93.2 | 95.0 | 0.005 |
| 4096 | rotor (accumulate) | 1452478 | 1.97 | 95.6 | 95.8 | 0.003 |
| 4096 | libxev | 1274778 | 2.23 | 94.7 | 97.9 | 0.004 |
| 65536 | rotor (group, the whole pool) | 112451 | 22.04 | 82.6 | 99.6 | 0.060 |
| 65536 | rotor (group, 2048 buffers) | refused by the server | | | | |
| 65536 | rotor (group, 256 buffers) | 140875 | 17.08 | 80.2 | 99.6 | 0.062 |
| 65536 | rotor (group, 32 buffers) | 277045 | 7.54 | 69.7 | 98.6 | 0.050 |
| 65536 | rotor (accumulate) | 228089 | 9.17 | 69.7 | 98.1 | 0.054 |
| 65536 | libxev | 237848 | 8.93 | 70.8 | 99.1 | 0.058 |
```
