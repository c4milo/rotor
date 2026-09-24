# Serving a kqueue readiness until its amount is used, on `mac`, 2026-09-23

`rotor_datagram --in-flight N --seconds 2`, for N of 1 and 64, on macOS 26.6.2. Five rounds, each
running the build before and the build after once, alternating. The programs were built by
`zig build bench-echo`.

- **before**: the tree of `4f1b319`, where a kqueue readiness serves one operation.
- **after**: the tree of `f120ab5`, where it serves operations until the amount in its `data` is
  used (decision 12, point 3).

The machine was busy: `load` is its 1-minute load average before each run, about 11, so the times
are not a claim. The ticks are counts and do not depend on the load. At 1 in flight the two builds
make the same calls, and the times differ by as much between rounds as between builds.

Each line is `backend build round load` followed by the program's own line:
`datagram-echo <candidate> <version> <in_flight> <bytes> <round_trips> <span_ns> <p50> <p99> <p999> <ticks> <lost>`.

```text
kqueue before round=1 load=11.21 datagram-echo rotor this-tree 1 1200 72131 2000053000 19000 123000 180000 278491 0
kqueue after round=1 load=11.21 datagram-echo rotor this-tree 1 1200 51046 2036428000 25000 145000 376000 199601 0
kqueue before round=2 load=11.21 datagram-echo rotor this-tree 1 1200 76683 2000044000 20000 109000 182000 300200 0
kqueue after round=2 load=11.27 datagram-echo rotor this-tree 1 1200 76673 2000002000 19000 120000 246000 299958 0
kqueue before round=3 load=11.27 datagram-echo rotor this-tree 1 1200 77211 2000028000 20000 111000 157000 302749 0
kqueue after round=3 load=11.01 datagram-echo rotor this-tree 1 1200 65506 2000002000 24000 122000 192000 254671 0
kqueue before round=4 load=11.01 datagram-echo rotor this-tree 1 1200 71782 2000003000 20000 128000 267000 267863 0
kqueue after round=4 load=11.01 datagram-echo rotor this-tree 1 1200 70285 2000022000 20000 123000 230000 263393 0
kqueue before round=5 load=10.85 datagram-echo rotor this-tree 1 1200 54975 2000019000 24000 149000 463000 211182 0
kqueue after round=5 load=10.85 datagram-echo rotor this-tree 1 1200 37893 2000029000 30000 259000 1577000 145271 0
kqueue before round=1 load=12.78 datagram-echo rotor this-tree 64 1200 122734 2000504000 993000 2360000 4163000 122755 0
kqueue after round=1 load=12.78 datagram-echo rotor this-tree 64 1200 175301 2000354000 678000 1664000 2880000 5857 0
kqueue before round=2 load=12.24 datagram-echo rotor this-tree 64 1200 117815 2000526000 1019000 2634000 3867000 117837 0
kqueue after round=2 load=12.24 datagram-echo rotor this-tree 64 1200 146754 2000781000 788000 2522000 5185000 4820 0
kqueue before round=3 load=12.24 datagram-echo rotor this-tree 64 1200 121986 2000423000 990000 2624000 4567000 122009 0
kqueue after round=3 load=12.14 datagram-echo rotor this-tree 64 1200 155990 2000443000 750000 2481000 4341000 5140 0
kqueue before round=4 load=12.14 datagram-echo rotor this-tree 64 1200 118147 2000483000 986000 2755000 4681000 118169 0
kqueue after round=4 load=12.53 datagram-echo rotor this-tree 64 1200 140937 2000790000 742000 3413000 15642000 4639 0
kqueue before round=5 load=12.53 datagram-echo rotor this-tree 64 1200 125056 2000594000 987000 2076000 3039000 125090 0
kqueue after round=5 load=12.53 datagram-echo rotor this-tree 64 1200 155277 2000425000 776000 2335000 5379000 5101 0
```
