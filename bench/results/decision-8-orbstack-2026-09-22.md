# Decision 8's experiment on `orbstack`, 2026-09-22

`zig build bench-linux` built `uring_nop_safe` (ReleaseSafe) and `uring_nop_fast` (ReleaseFast),
and each ran five times in the Linux gate's container, alternating safe, fast, safe, fast, on
`--cpuset-cpus=2`, so both used one virtual CPU. `uring_post` (ReleaseSafe, pinning its two threads
to cores 0 and 1 itself) ran once after each pair. The `mac` machine's load average was 4.9 to 5.1
throughout. Decision 8 reads these in its results section.

## uring_nop_safe, round 1

```text
uring nop, ReleaseSafe, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 250 | 292 | 250 |
| 8 | 666 | 750 | 83 |
| 32 | 2042 | 2417 | 63 |
| 64 | 3750 | 4584 | 58 |
| 128 | 7333 | 13458 | 57 |
```

## uring_nop_fast, round 1

```text
uring nop, ReleaseFast, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 333 | 375 | 333 |
| 8 | 750 | 834 | 93 |
| 32 | 2250 | 2666 | 70 |
| 64 | 4250 | 5750 | 66 |
| 128 | 8209 | 12917 | 64 |
```

## uring_post, round 1

```text
uring post, ReleaseSafe, 20000 round trips per mode
| mode | round trip median ns | round trip p99 ns | one message ns |
|---|---|---|---|
| waiting | 22167 | 57459 | 11083 |
| spinning | 1626 | 5167 | 813 |
| spin then wait | 1416 | 5500 | 708 |
```

## uring_nop_safe, round 2

```text
uring nop, ReleaseSafe, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 250 | 333 | 250 |
| 8 | 666 | 833 | 83 |
| 32 | 2000 | 2375 | 62 |
| 64 | 3792 | 5042 | 59 |
| 128 | 7333 | 12709 | 57 |
```

## uring_nop_fast, round 2

```text
uring nop, ReleaseFast, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 292 | 375 | 292 |
| 8 | 750 | 958 | 93 |
| 32 | 2209 | 2625 | 69 |
| 64 | 4250 | 5291 | 66 |
| 128 | 8291 | 13542 | 64 |
```

## uring_post, round 2

```text
uring post, ReleaseSafe, 20000 round trips per mode
| mode | round trip median ns | round trip p99 ns | one message ns |
|---|---|---|---|
| waiting | 22792 | 61042 | 11396 |
| spinning | 1416 | 5667 | 708 |
| spin then wait | 1416 | 6333 | 708 |
```

## uring_nop_safe, round 3

```text
uring nop, ReleaseSafe, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 250 | 292 | 250 |
| 8 | 626 | 750 | 78 |
| 32 | 2000 | 2292 | 62 |
| 64 | 3792 | 4375 | 59 |
| 128 | 7333 | 11000 | 57 |
```

## uring_nop_fast, round 3

```text
uring nop, ReleaseFast, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 292 | 334 | 292 |
| 8 | 750 | 834 | 93 |
| 32 | 2250 | 2625 | 70 |
| 64 | 4250 | 5250 | 66 |
| 128 | 8209 | 16792 | 64 |
```

## uring_post, round 3

```text
uring post, ReleaseSafe, 20000 round trips per mode
| mode | round trip median ns | round trip p99 ns | one message ns |
|---|---|---|---|
| waiting | 22083 | 56959 | 11041 |
| spinning | 2708 | 6833 | 1354 |
| spin then wait | 1375 | 6042 | 687 |
```

## uring_nop_safe, round 4

```text
uring nop, ReleaseSafe, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 250 | 333 | 250 |
| 8 | 625 | 709 | 78 |
| 32 | 2000 | 2250 | 62 |
| 64 | 3791 | 4375 | 59 |
| 128 | 7333 | 10792 | 57 |
```

## uring_nop_fast, round 4

```text
uring nop, ReleaseFast, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 333 | 375 | 333 |
| 8 | 750 | 875 | 93 |
| 32 | 2209 | 2583 | 69 |
| 64 | 4292 | 5375 | 67 |
| 128 | 8292 | 13125 | 64 |
```

## uring_post, round 4

```text
uring post, ReleaseSafe, 20000 round trips per mode
| mode | round trip median ns | round trip p99 ns | one message ns |
|---|---|---|---|
| waiting | 22959 | 64918 | 11479 |
| spinning | 1334 | 6708 | 667 |
| spin then wait | 1542 | 6250 | 771 |
```

## uring_nop_safe, round 5

```text
uring nop, ReleaseSafe, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 334 | 417 | 334 |
| 8 | 833 | 1042 | 104 |
| 32 | 2500 | 2958 | 78 |
| 64 | 4667 | 5583 | 72 |
| 128 | 9084 | 35708 | 70 |
```

## uring_nop_fast, round 5

```text
uring nop, ReleaseFast, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 333 | 375 | 333 |
| 8 | 750 | 875 | 93 |
| 32 | 2250 | 2584 | 70 |
| 64 | 4291 | 5750 | 67 |
| 128 | 8292 | 13833 | 64 |
```

## uring_post, round 5

```text
uring post, ReleaseSafe, 20000 round trips per mode
| mode | round trip median ns | round trip p99 ns | one message ns |
|---|---|---|---|
| waiting | 22500 | 58293 | 11250 |
| spinning | 1333 | 5209 | 666 |
| spin then wait | 2750 | 5751 | 1375 |
```
