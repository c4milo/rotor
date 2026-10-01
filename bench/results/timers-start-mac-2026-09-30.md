# When a timer's delay starts, `mac`, 2026-09-30

Decision 14, rule 6: a timer's delay runs from `now_ns` as the caller saw it at submit, and no
longer from the reading of the tick after the submit. `rotor_timers` from two builds of the same
tree, `d408ede` and the change, with libxev's and libuv's programs, five rounds, each round running
every candidate once in this order, two seconds each, 1 ms period:

```bash
rotor_timers --mode oneshot --timers N --period-us 1000 --seconds 2      # each build
rotor_timers --mode repeating --timers N --period-us 1000 --seconds 2    # the change
libxev_timers --timers N --period-us 1000 --seconds 2
libuv_timers --timers N --period-us 1000 --seconds 2
```

`mac`: Apple M1 Pro, macOS 26.6.2. The load average was 7.4 when the rounds began and 10.9 when
they ended; other sessions were working on the machine, so these are not quiet rows. The
percentiles are lateness: how far past the time the program asked for each timer fired. No
candidate fired a timer before that time in a count taken the same evening.


## 4,096 timers

The median of the five rounds, with their range:

| candidate | fires per second | p50 late, µs | p99 late, µs |
|---|---:|---:|---:|
| rotor one-shot, from the next tick | 2,359,683 (2,303,712 to 2,655,815) | 557 (537 to 1,109) | 2,226 (558 to 4,744) |
| rotor one-shot, from `now_ns` | 3,552,253 (3,483,205 to 3,836,501) | 95 (62 to 146) | 580 (522 to 947) |
| rotor repeating, from `now_ns` | 4,094,155 (4,093,698 to 4,094,213) | 536 (431 to 778) | 902 (489 to 1,454) |
| libxev | 3,027,815 (2,702,115 to 3,406,339) | 263 (82 to 582) | 1,218 (1,176 to 2,255) |
| libuv | 2,077,177 (1,990,885 to 2,194,012) | 854 (852 to 976) | 1,313 (906 to 2,002) |

Each run, in the order they ran:

| round | candidate | fires per second | p50 late, µs | p99 late, µs |
|---:|---|---:|---:|---:|
| 1 | rotor one-shot, from the next tick | 2,624,371 | 542 | 4,288 |
| 1 | rotor one-shot, from `now_ns` | 3,825,122 | 65 | 522 |
| 1 | rotor repeating, from `now_ns` | 4,094,112 | 431 | 497 |
| 1 | libxev | 2,702,115 | 486 | 1,218 |
| 1 | libuv | 2,077,177 | 976 | 1,607 |
| 2 | rotor one-shot, from the next tick | 2,331,584 | 713 | 2,226 |
| 2 | rotor one-shot, from `now_ns` | 3,483,205 | 95 | 947 |
| 2 | rotor repeating, from `now_ns` | 4,093,698 | 632 | 1,454 |
| 2 | libxev | 2,948,933 | 173 | 1,189 |
| 2 | libuv | 2,000,385 | 852 | 1,313 |
| 3 | rotor one-shot, from the next tick | 2,359,683 | 557 | 1,114 |
| 3 | rotor one-shot, from `now_ns` | 3,552,253 | 142 | 580 |
| 3 | rotor repeating, from `now_ns` | 4,094,155 | 536 | 902 |
| 3 | libxev | 3,189,541 | 263 | 2,255 |
| 3 | libuv | 2,194,012 | 854 | 933 |
| 4 | rotor one-shot, from the next tick | 2,655,815 | 537 | 558 |
| 4 | rotor one-shot, from `now_ns` | 3,836,501 | 62 | 530 |
| 4 | rotor repeating, from `now_ns` | 4,094,185 | 444 | 489 |
| 4 | libxev | 3,406,339 | 82 | 1,176 |
| 4 | libuv | 2,110,904 | 852 | 906 |
| 5 | rotor one-shot, from the next tick | 2,303,712 | 1,109 | 4,744 |
| 5 | rotor one-shot, from `now_ns` | 3,517,382 | 146 | 630 |
| 5 | rotor repeating, from `now_ns` | 4,094,213 | 778 | 1,170 |
| 5 | libxev | 3,027,815 | 582 | 1,335 |
| 5 | libuv | 1,990,885 | 892 | 2,002 |

## 256 timers

The median of the five rounds, with their range:

| candidate | fires per second | p50 late, µs | p99 late, µs |
|---|---:|---:|---:|
| rotor one-shot, from the next tick | 216,199 (179,916 to 240,911) | 127 (56 to 310) | 1,077 (93 to 3,843) |
| rotor one-shot, from `now_ns` | 225,325 (195,529 to 246,673) | 51 (32 to 175) | 1,444 (71 to 6,661) |
| rotor repeating, from `now_ns` | 255,966 (255,773 to 255,974) | 79 (54 to 94) | 3,287 (2,326 to 7,119) |
| libxev | 187,154 (171,274 to 199,620) | 347 (295 to 377) | 1,142 (902 to 3,079) |
| libuv | 176,871 (166,573 to 199,725) | 329 (285 to 347) | 2,051 (328 to 3,412) |

Each run, in the order they ran:

| round | candidate | fires per second | p50 late, µs | p99 late, µs |
|---:|---|---:|---:|---:|
| 1 | rotor one-shot, from the next tick | 216,199 | 127 | 1,077 |
| 1 | rotor one-shot, from `now_ns` | 228,699 | 93 | 616 |
| 1 | rotor repeating, from `now_ns` | 255,974 | 92 | 2,326 |
| 1 | libxev | 199,620 | 295 | 902 |
| 1 | libuv | 199,725 | 285 | 328 |
| 2 | rotor one-shot, from the next tick | 240,911 | 56 | 93 |
| 2 | rotor one-shot, from `now_ns` | 246,673 | 32 | 71 |
| 2 | rotor repeating, from `now_ns` | 255,972 | 54 | 3,883 |
| 2 | libxev | 191,160 | 347 | 1,025 |
| 2 | libuv | 176,871 | 347 | 3,412 |
| 3 | rotor one-shot, from the next tick | 201,772 | 160 | 2,693 |
| 3 | rotor one-shot, from `now_ns` | 225,325 | 46 | 1,444 |
| 3 | rotor repeating, from `now_ns` | 255,966 | 94 | 3,287 |
| 3 | libxev | 172,309 | 377 | 2,118 |
| 3 | libuv | 166,573 | 329 | 2,051 |
| 4 | rotor one-shot, from the next tick | 179,916 | 310 | 3,843 |
| 4 | rotor one-shot, from `now_ns` | 223,180 | 175 | 2,641 |
| 4 | rotor repeating, from `now_ns` | 255,886 | 54 | 7,119 |
| 4 | libxev | 187,154 | 351 | 1,142 |
| 4 | libuv | 192,921 | 287 | 424 |
| 5 | rotor one-shot, from the next tick | 235,218 | 59 | 609 |
| 5 | rotor one-shot, from `now_ns` | 195,529 | 51 | 6,661 |
| 5 | rotor repeating, from `now_ns` | 255,773 | 79 | 2,715 |
| 5 | libxev | 171,274 | 339 | 3,079 |
| 5 | libuv | 169,631 | 334 | 2,246 |
