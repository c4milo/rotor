# Echo on `orbstack`, 2026-09-22

`echo_runner --directory /b --connections 16 --payloads 4096,65536 --rounds 3`, in the Linux
gate's debian image with `seccomp=unconfined`, at 21:58 local time (2026-09-23 01:58 UTC). The
programs were built on commit `b84aad0` with `zig build bench-echo -Dtarget=aarch64-linux-gnu`
and `zig build bench-alternatives -Dalternatives -Dtarget=aarch64-linux-gnu`; the commits after it
up to `979abb7` touch neither the echo servers nor the client. io_uring, one core, three runs per row.

Load average before the run, the `mac` machine's: 4.93 5.43 6.04. The machine was busy, and eight
of the ten rows carry a verdict: `RUNS DISAGREE`, a spread over the harness's threshold, or `OTHER
WORK`, which the harness reads before and after every run. None of the rows is a clean comparison.
One difference is far larger than any spread in the table, and it is why this file is kept: rotor's
default shape, a multishot receive into a provided-buffer group, runs at about half the rate of
rotor's own accumulate shape and of libxev, at both payloads. On `github` the two rotor shapes are
level (`echo-github-2026-09-22.md`). `bench/alternatives/README.md` says what is known of it.

```text
echo_runner: std.Io.Uring is not run: it does not compile on the pinned Zig
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 207382 | 829543 | 79359 | 137215 | 218111 | 618495 | 35438592 | 8 | 27 | 9 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 4096 | even | 3 | 467655 | 1870633 | 24447 | 116223 | 266239 | 1613823 | 2007040 | 39 | 11 | 7 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 16 | 4096 | even | 3 | 384275 | 1537109 | 43775 | 72191 | 112639 | 247807 | 1724416 | 19 | 31 | 9 | **RUNS DISAGREE** |
| echo | libxev | 9ce8e8e | 0 | 16 | 4096 | even | 3 | 491475 | 1965917 | 27007 | 100351 | 161791 | 250879 | 1413120 | 34 | 15 | 7 | **RUNS DISAGREE** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 4096 | even | 3 | 163046 | 652203 | 94719 | 177151 | 618495 | 1794047 | 7249920 | 5 | 51 | 19 | **OTHER WORK** |
| echo | rotor | this tree | 0 | 16 | 65536 | even | 3 | 46712 | 186861 | 352255 | 634879 | 794623 | 1368063 | 35430400 | 12 | 11 | 5 | **RUNS DISAGREE** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 65536 | even | 3 | 89466 | 357877 | 194559 | 452607 | 602111 | 1114111 | 2920448 | 10 | 23 | 13 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 16 | 65536 | even | 3 | 104211 | 416859 | 111615 | 428031 | 913407 | 1187839 | 2711552 | 29 | 39 | 13 | **RUNS DISAGREE** |
| echo | libxev | 9ce8e8e | 0 | 16 | 65536 | even | 3 | 80788 | 323161 | 195583 | 430079 | 565247 | 2260991 | 2215936 | 21 | 23 | 8 | **RUNS DISAGREE** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 65536 | even | 3 | 75587 | 302354 | 216063 | 360447 | 425983 | 1015807 | 7286784 | 0 | 39 | 18 |  |
```
