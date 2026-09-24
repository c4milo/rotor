# Serving an epoll readiness until a call would block, on `orbstack`, 2026-09-23

`rotor_datagram_epoll --in-flight N --seconds 2`, for N of 1 and 64, in the Linux gate's alpine
image under Docker's default seccomp profile, which refuses io_uring. Linux
7.0.14-orbstack-00380-ga7e0a2dc9535, aarch64. Five rounds, each running the build before and the
build after once, alternating. The programs were built by `zig build bench-linux`.

- **before**: the tree of `4f1b319`, where an epoll readiness serves one operation per direction.
- **after**: the same tree with a change that served a direction until a call would block, fails or
  moves nothing. It was never pushed: decision 20 records why it was dropped.

The `mac` machine, whose cores `orbstack` runs on, was busy: its load average was about 11 for the
whole run, so the times are not a claim. The ticks are counts and do not depend on the load.

Each line is `backend build round` followed by the program's own line:
`datagram-echo <candidate> <version> <in_flight> <bytes> <round_trips> <span_ns> <p50> <p99> <p999> <ticks> <lost>`.

```text
epoll before round=1 datagram-echo rotor this-tree 1 1200 719022 2000005115 2416 6416 101543 1438044 0
epoll after round=1 datagram-echo rotor this-tree 1 1200 589109 2000003032 2751 8875 149126 1178218 0
epoll before round=2 datagram-echo rotor this-tree 1 1200 747732 2000001283 2375 6334 67542 1495464 0
epoll after round=2 datagram-echo rotor this-tree 1 1200 649228 2000000699 2791 3500 44625 1298456 0
epoll before round=3 datagram-echo rotor this-tree 1 1200 739045 2000000866 2416 7209 79042 1478090 0
epoll after round=3 datagram-echo rotor this-tree 1 1200 656170 2000000491 2792 6084 52584 1312340 0
epoll before round=4 datagram-echo rotor this-tree 1 1200 760410 2000005074 2417 6042 26750 1520820 0
epoll after round=4 datagram-echo rotor this-tree 1 1200 664483 2000002407 2750 3417 32126 1328966 0
epoll before round=5 datagram-echo rotor this-tree 1 1200 763288 2000001199 2416 5750 44000 1526576 0
epoll after round=5 datagram-echo rotor this-tree 1 1200 653069 2000000866 2750 6833 47833 1306138 0
epoll before round=1 datagram-echo rotor this-tree 64 1200 817903 2000162992 141584 358627 754423 817904 0
epoll after round=1 datagram-echo rotor this-tree 64 1200 892352 2000065784 127501 520379 1320177 27886 0
epoll before round=2 datagram-echo rotor this-tree 64 1200 829869 2000102534 142252 406503 798381 829870 0
epoll after round=2 datagram-echo rotor this-tree 64 1200 866048 2000107575 126751 482670 1119759 27064 0
epoll before round=3 datagram-echo rotor this-tree 64 1200 797439 2000124992 143835 372128 678005 797440 0
epoll after round=3 datagram-echo rotor this-tree 64 1200 910016 2000007657 126667 354795 817340 28438 0
epoll before round=4 datagram-echo rotor this-tree 64 1200 827905 2000131325 142042 540254 1390803 827906 0
epoll after round=4 datagram-echo rotor this-tree 64 1200 868928 2000011407 127209 345794 672589 27154 0
epoll before round=5 datagram-echo rotor this-tree 64 1200 828466 2000102992 142126 424711 767423 828467 0
epoll after round=5 datagram-echo rotor this-tree 64 1200 824330 2000022366 126918 385128 652255 25762 0
```
