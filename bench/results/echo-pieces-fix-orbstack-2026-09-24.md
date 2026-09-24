# rotor_echo before and after the pieces fix, on `orbstack`, 2026-09-24

The fix is the commit that records this file: each piece of a connection's stream keeps its own
buffer, and one send goes out at a time (`bench/alternatives/README.md`, "A third bug in
rotor_echo"). "old" is `rotor_echo` built from `e7fe15b`, the commit before it. "new" is the fix.
Both were built by `zig build bench-linux` for `aarch64-linux-musl` in ReleaseSafe and run in the
Linux gates' alpine image with `seccomp=unconfined`, so on io_uring. The container reported Linux
7.0.14-orbstack-00380-ga7e0a2dc9535.

**The machine was not idle.** Other sessions ran builds and containers on it throughout. The load
average of the `mac` machine was 12.14 before the first batch and 8.68 after it, and 8.33 before
the second batch and 27.12 after it. Every row below has a spread far above the 10 percent at which
`harness.series` calls a row unreliable, so no row here is a speed claim.

Each run is `echo_client` against one server for four seconds after a one-second warm-up, with the
server sized as `echo_runner` sizes it: a buffer the size of the payload, and a group of two
buffers per connection and never fewer than 32. The two servers alternate, and the one that runs
first changes every round.

## First batch, five rounds

| round | connections | payload | old per second | new per second | ran first |
|---:|---:|---:|---:|---:|---|
| 1 | 16 | 64 KiB | 19,171 | 39,132 | old |
| 2 | 16 | 64 KiB | 69,641 | 41,392 | new |
| 3 | 16 | 64 KiB | 87,669 | 64,315 | old |
| 4 | 16 | 64 KiB | 67,244 | 30,612 | new |
| 5 | 16 | 64 KiB | 86,306 | 60,430 | old |
| 1 | 64 | 64 KiB | 27,907 | 16,609 | old |
| 2 | 64 | 64 KiB | 33,418 | 36,588 | new |
| 3 | 64 | 64 KiB | 39,397 | 14,578 | old |
| 4 | 64 | 64 KiB | 28,998 | 33,249 | new |
| 5 | 64 | 64 KiB | 37,534 | 33,352 | old |
| 1 | 16 | 4 KiB | 168,653 | 371,640 | old |
| 2 | 16 | 4 KiB | 493,032 | 446,787 | new |
| 3 | 16 | 4 KiB | 165,706 | 398,043 | old |
| 4 | 16 | 4 KiB | 459,228 | 436,347 | new |
| 5 | 16 | 4 KiB | 494,765 | 463,338 | old |

## Second batch, eight rounds

The load rose during rounds 5 to 8, and both servers slowed with it.

| round | connections | payload | old per second | new per second | ran first |
|---:|---:|---:|---:|---:|---|
| 1 | 16 | 64 KiB | 79,602 | 59,136 | old |
| 2 | 16 | 64 KiB | 79,511 | 55,807 | new |
| 3 | 16 | 64 KiB | 77,382 | 60,826 | old |
| 4 | 16 | 64 KiB | 86,857 | 67,168 | new |
| 5 | 16 | 64 KiB | 17,978 | 7,501 | old |
| 6 | 16 | 64 KiB | 15,578 | 13,422 | new |
| 7 | 16 | 64 KiB | 7,851 | 6,275 | old |
| 8 | 16 | 64 KiB | 13,676 | 5,548 | new |
| 1 | 64 | 64 KiB | 38,765 | 37,699 | old |
| 2 | 64 | 64 KiB | 38,265 | 35,199 | new |
| 3 | 64 | 64 KiB | 39,332 | 43,052 | old |
| 4 | 64 | 64 KiB | 11,084 | 19,961 | new |
| 5 | 64 | 64 KiB | 9,490 | 8,768 | old |
| 6 | 64 | 64 KiB | 11,730 | 15,866 | new |
| 7 | 64 | 64 KiB | 10,495 | 11,121 | old |
| 8 | 64 | 64 KiB | 14,866 | 16,979 | new |

## What the pairs say

- At 16 connections and 64 KiB, old was faster in 12 of the 13 pairs. In the four calm rounds of
  the second batch, new ran at 0.70 to 0.79 of old.
- At 64 connections and 64 KiB, old was faster in 6 of 13 pairs: no direction.
- At 16 connections and 4 KiB, where the old server never overlapped two pieces, old was faster in
  3 of 5 pairs: no direction.

## Why the old server was faster: its group shrank

Each overlap of two pieces lost one buffer id and put another into io_uring's ring twice, so the
ring cycled through fewer and fewer distinct buffers. A temporary counter in each server printed
how many distinct buffer ids had been received into, once per 20,000 receives. 16 connections,
64 KiB, a group of 32, twelve seconds after a one-second warm-up, one run each:

| server | distinct buffer ids in each window of 20,000 receives |
|---|---|
| old | 32, 26, 22, 18, 17, 16, 14, 13, 12 |
| new | 32 in each of 18 windows |

A shorter run of the same pair gave 32, 20, 13 for old and 32 for new. These are counts and make no
speed claim. `bench/alternatives/README.md` records that on `orbstack` the size of the group
decides how much of each 64 KiB copy misses the cache: 22.04 µs of server time per echo with the
whole pool against 7.54 µs with 32 buffers. An old server with 12 buffers in use had a smaller
working set than a correct server with a group of 32.
