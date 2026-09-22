# Decision 8's experiment on `github`, 2026-09-22

`zig build bench-linux` built `uring_nop_safe` (ReleaseSafe, the mode rotor ships in) and
`uring_nop_fast` (ReleaseFast, which exists only in this benchmark), and the two ran alternately
five times on a GitHub-hosted `ubuntu-24.04` runner: an Intel Xeon Platinum 8370C at 2.80 GHz, 4
virtual processors, Linux 6.17.0-1022-azure. The same job ran the cost probes first
(`costs-github-2026-09-22.md`).

`orbstack` could not decide this question on 2026-09-22: its rounds disagreed by 25 percent and
ReleaseSafe came out faster in four of five. This machine's rounds repeat to within 1 ns.

```text
== round 1
uring nop, ReleaseSafe, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 294 | 454 | 294 |
| 8 | 809 | 887 | 101 |
| 32 | 2580 | 2739 | 80 |
| 64 | 4948 | 5212 | 77 |
| 128 | 9787 | 14512 | 76 |
uring nop, ReleaseFast, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 276 | 317 | 276 |
| 8 | 757 | 823 | 94 |
| 32 | 2379 | 2495 | 74 |
| 64 | 4502 | 5157 | 70 |
| 128 | 8901 | 11413 | 69 |
== round 2
uring nop, ReleaseSafe, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 293 | 456 | 293 |
| 8 | 813 | 883 | 101 |
| 32 | 2570 | 2736 | 80 |
| 64 | 4939 | 5432 | 77 |
| 128 | 9764 | 14514 | 76 |
uring nop, ReleaseFast, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 341 | 396 | 341 |
| 8 | 754 | 853 | 94 |
| 32 | 2361 | 2459 | 73 |
| 64 | 4491 | 4740 | 70 |
| 128 | 8886 | 11524 | 69 |
== round 3
uring nop, ReleaseSafe, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 294 | 538 | 294 |
| 8 | 802 | 885 | 100 |
| 32 | 2569 | 2690 | 80 |
| 64 | 4967 | 5193 | 77 |
| 128 | 9903 | 14276 | 77 |
uring nop, ReleaseFast, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 278 | 315 | 278 |
| 8 | 755 | 803 | 94 |
| 32 | 2355 | 2498 | 73 |
| 64 | 4483 | 4698 | 70 |
| 128 | 8883 | 10913 | 69 |
== round 4
uring nop, ReleaseSafe, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 286 | 319 | 286 |
| 8 | 800 | 889 | 100 |
| 32 | 2563 | 3267 | 80 |
| 64 | 4948 | 5244 | 77 |
| 128 | 9761 | 14107 | 76 |
uring nop, ReleaseFast, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 279 | 333 | 279 |
| 8 | 757 | 804 | 94 |
| 32 | 2357 | 2457 | 73 |
| 64 | 4507 | 4716 | 70 |
| 128 | 8915 | 10631 | 69 |
== round 5
uring nop, ReleaseSafe, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 356 | 447 | 356 |
| 8 | 801 | 885 | 100 |
| 32 | 2566 | 2703 | 80 |
| 64 | 4949 | 6025 | 77 |
| 128 | 9814 | 14399 | 76 |
uring nop, ReleaseFast, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 284 | 336 | 284 |
| 8 | 759 | 815 | 94 |
| 32 | 2364 | 2490 | 73 |
| 64 | 4495 | 4863 | 70 |
| 128 | 8866 | 11857 | 69 |
```
