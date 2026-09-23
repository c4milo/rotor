# Provided buffers taken per wait on `orbstack`, 2026-09-22

`bench/calls/buffers_per_wait.sh`, run once in the Linux gates' debian image with `--privileged`,
at 22:57 local time (2026-09-23 02:57 UTC). The programs were built for `aarch64-linux-gnu` from the
tree of the commit that records this file. Load average before the run, the `mac` machine's: 5.64
5.77 6.49. The rows are counts and make no speed claim.

It asks one question for the short-ring design in `bench/alternatives/README.md`: how many buffers
the kernel takes from rotor's io_uring buffer ring during one `io_uring_enter`. A ring that the loop
refills before each wait must hold at least that many entries.

```text
provided buffers taken per io_uring_enter, counted by the kernel's tracepoints
os: Linux 7.0.14-orbstack-00380-ga7e0a2dc9535, aarch64, 10 CPUs
seconds per run: 4
```

| payload | connections | group buffers | echoes | first second, most per wait | waits after it | buffers per wait, mean | p50 | p99 | p999 | most | receives that found the group empty | overruns |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 4096 | 16 | 32 | 1775165 | 16 | 152301 | 8.83 | 9 | 16 | 16 | 16 | 0 | 0 |
| 4096 | 64 | 128 | 1751069 | 64 | 35761 | 36.75 | 40 | 41 | 41 | 41 | 0 | 0 |
| 4096 | 256 | 512 | 1418424 | 41 | 27408 | 38.83 | 40 | 41 | 41 | 42 | 0 | 0 |
| 4096 | 512 | 1024 | 1127259 | 512 | 20882 | 39.72 | 40 | 40 | 41 | 41 | 0 | 0 |
| 65536 | 16 | 32 | 307204 | 17 | 47349 | 4.87 | 1 | 16 | 17 | 17 | 0 | 0 |
| 65536 | 64 | 128 | 178128 | 42 | 3726 | 35.33 | 40 | 41 | 41 | 41 | 0 | 0 |
| 65536 | 256 | 512 | 132185 | 256 | 2517 | 39.79 | 40 | 40 | 41 | 41 | 0 | 0 |

An earlier run of the same script, before it split out the first second, gave the same shape: at
most 41 buffers at p999 in every row, and a most of 64 and 256 at 64 and 256 connections.

What the rows show:

- **After the first second, no wait took more than 42 buffers**, at any connection count from 64 to
  512. At 16 connections a wait took at most 16 or 17: each connection has one message in flight,
  and a 64 KiB message sometimes arrives in two parts.
- **The kernel sets the 42.** Since Linux 6.13, io_uring runs at most 20 items of deferred
  completion work each time it runs that work (`IO_LOCAL_TW_DEFAULT_MAX` in `io_uring/tw.h`,
  commit `f46b9cdb22f7`, "io_uring: limit local tw done", read on 2026-09-22). rotor's rings use
  `DEFER_TASKRUN`, so every receive completion is such an item. The counts fit two runs per enter,
  plus a completion or two from the submission itself.
- **In the first second, one wait took a buffer for every connection** in four of the seven rows.
  The server submits a receive for each new connection, many in one enter, and a receive that finds
  bytes already there takes a buffer while it is submitted. That path does not go through the
  20-item limit.
- **No receive found the group empty** in any row, with the runner's group of two buffers per
  connection.

What this means for a short ring:

- On this kernel, a ring of 64 entries, refilled before each enter with one more entry for each
  receive submitted in that enter, would have covered every wait measured here.
- The 20-item limit is a constant in the kernel's source, not a promise of its interface. On 6.1 to
  6.12, which rotor supports (decision 2), the kernel runs all pending completion work in one go,
  as that commit's message says. There, one wait can take a buffer for every receive with bytes
  ready, and more than one for each: a multishot receive whose socket still holds bytes takes
  another buffer and tries again, up to `MULTISHOT_MAX_RETRY` times, 32 in `io_uring/net.c`, before
  it goes back on the work list (read the same day). A short ring on those kernels has no bound
  below the number of receives armed on the group.

The owner ruled the same day that rotor does not build a short ring. An application sizes its
group to the buffers it has in flight, as `docs/using.md` says.
