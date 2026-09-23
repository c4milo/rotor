# Echo with rotor's group sized per connection, on `orbstack`, 2026-09-22

`echo_runner --directory /b --connections 16,64 --payloads 4096,65536 --rounds 3`, in the Linux
gates' debian image with `seccomp=unconfined`, at 22:24 local time (2026-09-23 02:24 UTC). io_uring,
one core, three runs per row. The programs were built for `aarch64-linux-gnu` from the tree of the commit that records this file,
as `bench/calls/cpu_per_echo.sh`'s header says, before the runner's command line moved into
`echo_runner_setup.zig`; that move changed no argument, and a test now holds the arguments.

The runner starts rotor's group shape with `--group-buffers`, two buffers per connection with a
floor of 32, where before this run it used the whole 64 MiB pool. `echo-orbstack-2026-09-22.md` is
the run before, at 16 connections.

Load average before the run, the `mac` machine's: 5.96 6.19 6.35. Seven of the twenty rows carry a
verdict, four of the five 64 KiB rows at 64 connections among them, so those rows say nothing. At 16
connections, and at 64 connections with 4 KiB, rotor's rows are clean and lead: 480,515 echoes per
second at 16 connections and 4 KiB, where the whole pool gave 207,382, and 84,406 at 64 KiB, where
it gave 46,712. rotor's peak memory at 16 connections and 4 KiB is 2.0 MB, where it was 35.4 MB.

```text
echo_runner: std.Io.Uring is not run: it does not compile on the pinned Zig
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 480515 | 1922069 | 23167 | 126463 | 246783 | 835583 | 2007040 | 9 | 27 | 9 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 4096 | even | 3 | 468107 | 1872446 | 25087 | 113151 | 185343 | 389119 | 2011136 | 3 | 15 | 6 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 4096 | even | 3 | 324215 | 1296870 | 52223 | 111103 | 181247 | 342015 | 1740800 | 4 | 23 | 10 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 4096 | even | 3 | 400033 | 1600144 | 28415 | 118783 | 217087 | 2392063 | 1413120 | 2 | 7 | 4 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 4096 | even | 3 | 161224 | 644910 | 99327 | 152575 | 276479 | 1212415 | 7282688 | 6 | 19 | 8 |  |
| echo | rotor | this tree | 0 | 16 | 65536 | even | 3 | 84406 | 337636 | 178175 | 456703 | 696319 | 2375679 | 3973120 | 3 | 23 | 9 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 65536 | even | 3 | 78669 | 314685 | 182271 | 536575 | 737279 | 1900543 | 2924544 | 13 | 23 | 13 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 16 | 65536 | even | 3 | 78202 | 312814 | 193535 | 692223 | 1040383 | 1220607 | 2715648 | 5 | 11 | 4 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 65536 | even | 3 | 74315 | 297271 | 188415 | 528383 | 667647 | 1236991 | 2215936 | 5 | 11 | 5 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 65536 | even | 3 | 71765 | 287065 | 222207 | 378879 | 651263 | 1728511 | 7282688 | 0 | 27 | 13 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 482027 | 1928128 | 86527 | 333823 | 552959 | 1376255 | 3002368 | 8 | 43 | 12 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 4096 | even | 3 | 442177 | 1768797 | 88575 | 380927 | 1081343 | 2834431 | 3002368 | 9 | 19 | 13 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 4096 | even | 3 | 323419 | 1293734 | 196607 | 483327 | 696319 | 1646591 | 3002368 | 6 | 11 | 7 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 4096 | even | 3 | 440151 | 1760668 | 103423 | 372735 | 1302527 | 6815743 | 3002368 | 13 | 15 | 8 | **RUNS DISAGREE** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 4096 | even | 3 | 174406 | 697645 | 368639 | 618495 | 1949695 | 6127615 | 26820608 | 21 | 39 | 15 | **RUNS DISAGREE** |
| echo | rotor | this tree | 0 | 64 | 65536 | even | 3 | 41451 | 165837 | 1384447 | 3309567 | 7274495 | 15990760 | 10272768 | 37 | 47 | 16 | **RUNS DISAGREE** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 65536 | even | 3 | 42384 | 169572 | 1392639 | 3309567 | 18481151 | 34865151 | 6074368 | 92 | 23 | 12 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 64 | 65536 | even | 3 | 46068 | 184347 | 1163263 | 3637247 | 4784127 | 5996543 | 6434816 | 85 | 15 | 7 | **RUNS DISAGREE** |
| echo | libxev | 9ce8e8e | 0 | 64 | 65536 | even | 3 | 42836 | 171367 | 1425407 | 3014655 | 4653055 | 11329983 | 5378048 | 44 | 15 | 9 | **RUNS DISAGREE** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 65536 | even | 3 | 46628 | 186571 | 1294335 | 2392063 | 3964927 | 7536639 | 26816512 | 8 | 19 | 8 |  |
```
