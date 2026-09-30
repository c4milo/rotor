# One cross-core message sent with `Loop.post`, GitHub macOS runners, 2026-09-29

Decision 4, its amendment of 2026-09-29: a loop can post with a call, `Loop.post`, that takes no
operation and makes no event, and `rotor_post` sends each message with it. Before, it sent a post
operation, whose event the sender's next tick handed over.

Run 36665110361 of the `crosscore-ab` workflow, on the branch `experiment/loop-post`, from 03:38 UTC
on 2026-09-30. The branch is never merged; its last commit adds the workflow and the script
`bench/crosscore/scratch_ab.sh`. Three jobs, each on a `macos-latest` runner of its own: `Apple M1
(Virtual)`, 3 processors, 7 GiB, macOS 26.6.2 build 25G83. Each built `6e4c0b7` and the branch,
whose `rotor_post` sends with `Loop.post`, then ran 10 rounds, each round:

```bash
crosscore_runner --directory "$before" --rounds 5
crosscore_runner --directory "$after" --rounds 5
```

The runners' load averages were 19 to 24 when the rounds began and 0.8 to 2.0 when they ended.
Every row carried **OTHER WORK**, and most carried **RUNS DISAGREE**.

Each cell is the median of the runner's 10 round medians, in messages per second:

| candidate | job 109727998539 | job 109727998645 | job 109727998449 |
|---|---:|---:|---:|
| rotor, post operations (`6e4c0b7`) | 267,362 | 242,794 | 234,800 |
| rotor, `Loop.post` | 285,740 | 251,034 | 238,888 |
| libuv, in the rounds before | 268,305 | 245,766 | 249,041 |
| libuv, in the rounds after | 271,513 | 254,871 | 245,817 |
| libxev, in the rounds after | 228,978 | 208,952 | 208,126 |

rotor over libuv in the same `crosscore_runner` call, the median of each runner's 10 rounds:

| build | job 109727998539 | job 109727998645 | job 109727998449 |
|---|---:|---:|---:|
| post operations | 0.983 | 0.965 | 0.945 |
| `Loop.post` | 1.034 | 0.992 | 0.978 |

Paired by round, over all 30:

| measure | median | rounds higher | one-sided sign test |
|---|---:|---:|---:|
| rotor after over rotor before | 1.033 | 19 of 30 | p = 0.10 |
| rotor over libuv, after over before | 1.026 | 20 of 30 | p = 0.049 |

The second measure divides out how far the runner moved between the two calls, which the first
does not, and it is the one that clears 5 percent. The evidence is weaker than that of the change of
the same evening (`crosscore-own-work-github-macos-2026-09-29.md`: 22 of 30), and every runner's
median moved the same way. The rate on `mac` is still to be taken.

## Each round

The median rate of each round's five runs, in messages per second.

### Job 109727998539

| round | rotor before | rotor after | libuv before | libuv after | libxev before | libxev after |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 307,203 | 235,111 | 284,462 | 276,622 | 231,433 | 213,080 |
| 2 | 220,435 | 217,280 | 221,424 | 219,858 | 180,609 | 180,681 |
| 3 | 214,792 | 267,145 | 236,946 | 260,728 | 199,831 | 227,576 |
| 4 | 254,562 | 281,557 | 262,261 | 270,021 | 193,760 | 230,379 |
| 5 | 270,856 | 271,967 | 274,349 | 251,075 | 218,117 | 210,360 |
| 6 | 226,987 | 289,922 | 251,372 | 255,598 | 232,422 | 210,687 |
| 7 | 263,867 | 294,025 | 249,386 | 273,005 | 202,015 | 237,129 |
| 8 | 283,240 | 293,425 | 289,292 | 291,069 | 240,334 | 246,249 |
| 9 | 280,115 | 290,412 | 291,912 | 294,127 | 245,862 | 262,716 |
| 10 | 299,225 | 307,032 | 293,438 | 294,312 | 245,267 | 246,160 |

### Job 109727998645

| round | rotor before | rotor after | libuv before | libuv after | libxev before | libxev after |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 164,868 | 241,249 | 191,249 | 205,078 | 156,343 | 207,572 |
| 2 | 235,836 | 225,341 | 239,631 | 245,649 | 207,054 | 199,410 |
| 3 | 243,199 | 250,534 | 244,767 | 255,050 | 206,230 | 190,179 |
| 4 | 245,361 | 256,918 | 244,077 | 250,566 | 212,856 | 202,327 |
| 5 | 274,076 | 240,961 | 289,712 | 254,692 | 241,137 | 217,889 |
| 6 | 242,390 | 289,144 | 268,016 | 256,894 | 205,782 | 252,818 |
| 7 | 229,456 | 201,745 | 246,765 | 201,546 | 207,322 | 194,978 |
| 8 | 237,823 | 260,865 | 227,089 | 282,551 | 188,738 | 226,198 |
| 9 | 268,562 | 299,193 | 285,404 | 298,625 | 241,101 | 262,544 |
| 10 | 274,111 | 251,535 | 260,172 | 289,313 | 219,476 | 210,332 |

### Job 109727998449

| round | rotor before | rotor after | libuv before | libuv after | libxev before | libxev after |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 268,273 | 287,529 | 291,691 | 293,040 | 245,577 | 242,329 |
| 2 | 281,709 | 261,953 | 292,372 | 246,875 | 249,600 | 205,463 |
| 3 | 229,048 | 215,433 | 245,412 | 231,349 | 197,200 | 200,518 |
| 4 | 235,378 | 287,940 | 259,053 | 280,889 | 222,398 | 233,062 |
| 5 | 261,308 | 237,507 | 267,382 | 254,525 | 215,582 | 210,296 |
| 6 | 233,235 | 238,062 | 243,914 | 244,130 | 209,452 | 209,011 |
| 7 | 221,352 | 239,713 | 247,601 | 238,252 | 208,947 | 207,240 |
| 8 | 235,042 | 233,323 | 239,600 | 252,252 | 214,678 | 218,980 |
| 9 | 234,559 | 231,792 | 241,081 | 244,759 | 206,700 | 204,265 |
| 10 | 229,942 | 247,676 | 250,481 | 242,216 | 211,859 | 194,197 |
