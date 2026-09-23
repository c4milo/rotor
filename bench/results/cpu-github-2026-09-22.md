# CPU per echo on `github`, 2026-09-22

`bench/calls/cpu_per_echo.sh`, run by the `comparison` job of `.github/workflows/ci.yml` on commit
`86a7ade`, run 35811462374, right after that run's echo, storm, timer and cross-core steps
(`echo-sized-pool-github-2026-09-22.md`). A GitHub-hosted `ubuntu-24.04` runner: AMD EPYC 9V74,
4 CPUs. Each row is one run of three seconds at 16 connections, so the rows locate a cost and are
not a comparison.

It answers why this runner showed rotor's group and accumulate shapes level with the whole pool as
the group, where `orbstack` showed the group far behind (`cpu-orbstack-2026-09-22.md`). Two causes
fit: a client that limits the run, or a machine on which the whole pool costs no more than a small
group. The client was at its limit, at 100 percent of a core in every row. But the server's CPU per
echo shows no cost of group size for the client to hide: 6.08 µs per 4 KiB echo with the whole pool
and 6.11 µs with 32 buffers, and 20.42 against 19.80 µs per 64 KiB echo. On `orbstack` the 64 KiB pair
was 22.04 against 7.54 µs. So on this machine a group cycling through all 64 MiB costs the server
about what 32 buffers do. Which part of the machine makes the difference was not separated.

The 64 KiB row with 2048 buffers is the server refusing a group larger than its pool.

```text
cpu per echo, from /proc/<pid>/schedstat and /proc/<pid>/stat
os: Linux 6.17.0-1022-azure, x86_64, 4 CPUs
connections: 16, seconds per run: 3
```

| payload | server | echoes | cpu µs per echo | busy % | in the kernel % | switches per echo | client busy % |
|---:|---|---:|---:|---:|---:|---:|---:|
| 4096 | rotor (group, the whole pool) | 493101 | 6.08 | 100.0 | 98.7 | 0.000 | 99.7 |
| 4096 | rotor (group, 2048 buffers) | 491627 | 6.09 | 99.8 | 98.3 | 0.002 | 100.0 |
| 4096 | rotor (group, 256 buffers) | 491872 | 6.10 | 100.0 | 99.0 | 0.000 | 100.0 |
| 4096 | rotor (group, 32 buffers) | 490638 | 6.11 | 100.0 | 98.7 | 0.000 | 100.0 |
| 4096 | rotor (accumulate) | 460042 | 6.51 | 99.9 | 98.7 | 0.001 | 100.0 |
| 4096 | libxev | 438669 | 6.84 | 100.0 | 99.3 | 0.000 | 100.0 |
| 65536 | rotor (group, the whole pool) | 146902 | 20.42 | 100.0 | 99.7 | 0.001 | 100.0 |
| 65536 | rotor (group, 2048 buffers) | refused by the server | | | | | |
| 65536 | rotor (group, 256 buffers) | 148532 | 20.07 | 99.4 | 99.3 | 0.011 | 100.0 |
| 65536 | rotor (group, 32 buffers) | 150458 | 19.80 | 99.3 | 99.0 | 0.014 | 100.0 |
| 65536 | rotor (accumulate) | 157813 | 19.01 | 100.0 | 99.3 | 0.000 | 100.0 |
| 65536 | libxev | 155133 | 19.35 | 100.1 | 100.0 | 0.000 | 100.3 |

The same job's kernel-call count printed no numbers: it runs as root, and it could not open the
`/tmp/client.json` the CPU script had left, so the client never started. The scripts now keep
their files in a directory of their own.
