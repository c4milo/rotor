# A vector `memset` in the benchmark programs, GitHub runners, 2026-10-19

Two runs of the `comparison` job of `.github/workflows/ci.yml`. Both started by hand at the same
time, with `comparison_runs` set to `[1, 2, 3, 4]`:

- Before: run 39357382891, on main at `1562378`.
- After: run 39357380302, on the branch `memset-measure` at `169d003`. That commit links the vector
  `memset` of `bench/harness/memset.zig` into every Linux program under bench/.

Each job ran on its own runner, and the pool gave these processors:

| processor | runs before | runs after |
|---|---:|---:|
| arm64, `CPU implementer 0x41 part 0xd49` | 4 | 4 |
| AMD EPYC 7763 64-Core Processor | 1 | 3 |
| INTEL(R) XEON(R) PLATINUM 8573C | 1 | 1 |
| AMD EPYC 9V45 96-Core Processor | 1 | 0 |
| AMD EPYC 9V74 80-Core Processor | 1 | 0 |

Every run passed the echo baseline of `bench/baseline/echo.txt`. No row moved past the spread
between runners. The runs before and after are not paired on one runner, so they cannot resolve
a change of a few percent.

## arm64: echoes per second

The lowest and highest rate of each phase's four runs, and the change of the medians. The rates of
one phase overlap the rates of the other in every row.

| connections | payload bytes | candidate | before | after | change of the median, percent |
|---:|---:|---|---|---|---:|
| 16 | 4096 | rotor | 203,631 to 231,093 | 222,618 to 230,750 | +1.5 |
| 16 | 4096 | libuv | 166,117 to 190,243 | 184,866 to 190,252 | +0.8 |
| 16 | 4096 | libxev | 178,711 to 210,747 | 200,995 to 206,815 | +1.9 |
| 16 | 4096 | std.Io.Threaded | 129,314 to 146,888 | 142,389 to 146,175 | -1.0 |
| 16 | 8192 | rotor | 189,403 to 211,264 | 204,856 to 208,850 | +0.9 |
| 16 | 8192 | libuv | 150,020 to 174,913 | 172,638 to 177,066 | +0.7 |
| 16 | 8192 | libxev | 166,955 to 189,826 | 180,400 to 191,036 | +0.4 |
| 16 | 8192 | std.Io.Threaded | 120,457 to 136,309 | 130,470 to 134,361 | +0.9 |
| 16 | 16384 | rotor | 145,509 to 164,481 | 152,204 to 160,554 | -2.6 |
| 16 | 16384 | libuv | 129,013 to 147,480 | 142,106 to 146,314 | -0.6 |
| 16 | 16384 | libxev | 135,749 to 155,834 | 152,887 to 157,793 | +0.8 |
| 16 | 16384 | std.Io.Threaded | 102,881 to 114,220 | 112,642 to 115,372 | +1.6 |
| 16 | 65536 | rotor | 47,508 to 54,249 | 51,078 to 52,329 | -3.0 |
| 16 | 65536 | libuv | 51,099 to 56,393 | 52,488 to 55,070 | -0.3 |
| 16 | 65536 | libxev | 48,301 to 55,593 | 52,314 to 54,485 | +1.4 |
| 16 | 65536 | std.Io.Threaded | 44,711 to 52,637 | 50,486 to 51,788 | -0.1 |
| 64 | 4096 | rotor | 201,726 to 221,451 | 218,365 to 227,664 | +0.6 |
| 64 | 4096 | libuv | 162,859 to 184,570 | 183,128 to 187,124 | +0.8 |
| 64 | 4096 | libxev | 173,060 to 209,459 | 199,452 to 214,906 | +0.2 |
| 64 | 4096 | std.Io.Threaded | 125,986 to 136,491 | 132,976 to 139,685 | +1.1 |
| 64 | 8192 | rotor | 169,545 to 194,390 | 182,610 to 193,234 | -1.5 |
| 64 | 8192 | libuv | 148,865 to 169,093 | 165,252 to 168,940 | +0.6 |
| 64 | 8192 | libxev | 147,087 to 182,221 | 172,392 to 182,458 | -0.4 |
| 64 | 8192 | std.Io.Threaded | 115,057 to 125,380 | 123,020 to 125,998 | -0.4 |
| 64 | 16384 | rotor | 133,102 to 153,905 | 143,023 to 153,704 | -1.7 |
| 64 | 16384 | libuv | 123,464 to 140,808 | 133,285 to 141,167 | -1.0 |
| 64 | 16384 | libxev | 127,068 to 149,225 | 135,850 to 146,129 | +0.0 |
| 64 | 16384 | std.Io.Threaded | 102,588 to 112,945 | 104,501 to 110,013 | +1.2 |
| 64 | 65536 | rotor | 46,982 to 55,196 | 49,862 to 52,318 | -3.5 |
| 64 | 65536 | libuv | 49,705 to 56,410 | 51,923 to 54,573 | -0.2 |
| 64 | 65536 | libxev | 46,885 to 53,790 | 51,129 to 52,028 | -1.5 |
| 64 | 65536 | std.Io.Threaded | 45,704 to 53,342 | 49,575 to 52,165 | -0.9 |

## x86-64: `std.Io.Threaded` as thousandths of rotor

Each run's ratio, or `-` for a run whose row or rotor's row disagreed.

### AMD EPYC 7763

| connections | payload bytes | before | after |
|---:|---:|---|---|
| 16 | 4096 | 506 | 505, 512, 510 |
| 16 | 8192 | 489 | 503, 517, 517 |
| 16 | 16384 | 496 | 506, 528, 516 |
| 16 | 65536 | 637 | 639, 675, 675 |
| 64 | 4096 | 540 | 530, 511, 511 |
| 64 | 8192 | 530 | 515, 529, 520 |
| 64 | 16384 | 526 | 521, 536, 532 |
| 64 | 65536 | 650 | 633, 669, 682 |

### INTEL(R) XEON(R) PLATINUM 8573C

| connections | payload bytes | before | after |
|---:|---:|---|---|
| 16 | 4096 | 575 | 581 |
| 16 | 8192 | 575 | 579 |
| 16 | 16384 | 571 | 562 |
| 16 | 65536 | 700 | - |
| 64 | 4096 | 577 | - |
| 64 | 8192 | 550 | 531 |
| 64 | 16384 | 536 | 528 |
| 64 | 65536 | 737 | 734 |

## Why `std.Io.Threaded` did not gain

Before the runs, I expected a gain for `std.Io.Threaded`. Its `netSendPosix` fills 6,912 bytes of
`undefined` locals on each call, and compiler_rt's `memset` stored them one byte at a time. But
`std_io_echo` sends with `writer.interface.writeAll`, which reaches `netWritePosix`. That function
calls `memset` with a length known only at run time, and the runs show no gain from it. rotor's
measured functions call no `memset`, so its rows had no cause to move.
