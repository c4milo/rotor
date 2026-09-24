# The echo client's check against servers that fail, on `orbstack`, 2026-09-24

Which runs fail, not how fast any run is. Three trees, each built with `zig build bench-echo
-Dtarget=aarch64-linux-musl`, and run in the Linux gate's alpine image with `seccomp=unconfined`,
so rotor runs io_uring:

- **before** (`linux-base`): the tree of `e7fe15b`. Its client compares nothing. Its `rotor_echo`
  let a second piece of a message overwrite the first piece's send record, which
  `bench/alternatives/README.md` describes.
- **after** (`linux-after`): that tree with the change this file came with.
- **fixed** (`linux-fixed`): the tree of the other session's commit `fd49118`, whose `bench/echo`
  files are the ones `db9e39e` put on main.

The server was `rotor_echo PORT --buffer-bytes 65536 --group-buffers 32` and the client
`echo_client PORT --connections 16 --payload 65536 --seconds 3 --warmup 1`, three runs per pair.
The first line is the kernel the container reported. The host's load average was high.

```text
7.0.14-orbstack-00380-ga7e0a2dc9535
server=before client=before round=1 exit=0 "operations":262323,"operations_per_second":87433
server=before client=before round=2 exit=0 "operations":234201,"operations_per_second":78058
server=before client=before round=3 exit=0 "operations":184656,"operations_per_second":61550
server=before client=after round=1 exit=1 error: CandidateCorrupted
server=before client=after round=2 exit=1 error: CandidateCorrupted
server=before client=after round=3 exit=1 error: CandidateCorrupted
server=fixed client=after round=1 exit=0 "operations":190843,"operations_per_second":63606
server=fixed client=after round=2 exit=0 "operations":163941,"operations_per_second":54645
server=fixed client=after round=3 exit=0 "operations":185172,"operations_per_second":61720
```

Then the server was killed with SIGKILL two seconds into a run of `--connections 16 --payload 4096
--seconds 3 --warmup 1`, which is one second into the measured span:

```text
client=linux-base exit=0 "duration_ns":1004296612,"operations":446295
client=linux-after exit=1 error: CandidateClosed
```

The client before the change reported 1.004 seconds of a 3-second span as a row, and exited 0.
