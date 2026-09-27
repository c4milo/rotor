# rotor on Linux 6.1, 2026-09-27

Debian 12's kernel package `linux-image-6.1.0-53-arm64`, version 6.1.187-1, SHA-256
`b7b22756c676a715c20476ddecfaf0890bc2804a9b76ebdb1aa42157ac6b28f8`, booted under QEMU with Apple's
hypervisor on `mac` (`-machine virt -accel hvf -cpu host -smp 4`). The Linux gate's executables, built
at `ca2946f`, ran from an initramfs: a small `init` mounted `/proc` and `/dev`, brought the loopback
interface up, and ran each in turn, the two conformance suites a second time with a 50 µs spin
budget. The root was the initramfs itself, an in-memory filesystem that refuses `O_DIRECT`, so the
file tests could not pass here; the kernel builds ext4 and the virtio disk as modules. No seccomp
profile applied, so the epoll suite ran where io_uring is allowed.

Decision 2 set the floor at 6.1 until this run, and Camilo raised it to 6.17 the same day.

## The io_uring probe

```text
uring_probe: kernel 6.1.0-53-arm64 aarch64
uring_probe: io_uring_setup: present, features 0x1fff
uring_probe: IORING_FEAT_NODROP: present, bit 0x2 of the features
uring_probe: IORING_FEAT_EXT_ARG: present, bit 0x100 of the features
uring_probe: IORING_OP_MSG_RING: present, opcode 40; IORING_REGISTER_PROBE lists opcodes up to 48
uring_probe: multishot accept: present, 2 accepts from 1 submission, the first with IORING_CQE_F_MORE
uring_probe: IORING_REGISTER_PBUF_RING: present, 4 buffers registered as group 7
uring_probe: multishot receive: present, 2 receives into provided buffers from 1 submission, the first with IORING_CQE_F_MORE
uring_probe: IORING_SETUP_SINGLE_ISSUER: present
uring_probe: IORING_SETUP_DEFER_TASKRUN: present
uring_probe: every IORING_SETUP flag the loop needs: present, flags 0x3280
uring_probe: IORING_REGISTER_IOWQ_MAX_WORKERS: present, capped at 2 per kind
uring_probe: MSG_RING into a DEFER_TASKRUN ring, one thread: present, sender res 0; receiver reaped user_data 0x726f746f72 res 1234 flags 0x0; sent user_data 0x726f746f72 res 1234 flags 0x0
uring_probe: IORING_MSG_RING_FLAGS_PASS (not required): missing, the sender's completion answered errno 22 (EINVAL)
uring_probe: the second thread posted after 50 ms; the receiver's wait ended after 53 ms
uring_probe: MSG_RING into a DEFER_TASKRUN ring, two threads: present, sender res 0; receiver reaped user_data 0x726f746f72 res 1234 flags 0x0; sent user_data 0x726f746f72 res 1234 flags 0x0
uring_probe: UDP_SEGMENT: present, setsockopt took it
uring_probe: UDP_GRO: present, setsockopt took it
uring_probe: IP_PKTINFO and IP_RECVTOS: present, both set
uring_probe: multishot recvmsg: missing, no buffer was selected
uring_probe: single-shot recvmsg layout: present, multishot=false, more=true, id 0
uring_probe:   recvmsg_out: namelen 1869901682, controllen 1633951858, payloadlen 1919377780, flags 0x70206d61
uring_probe:   prefix asked 112 (head 16 + name 32 + control 64); prefix written 3503853556
uring_probe:   cqe.res 132; payload sent 20; cqe.res - prefix 20
uring_probe:   VERDICT: cqe.res - prefix does NOT equal payloadlen; the head must be read
uring_probe: single-shot recvmsg layout: missing, payload starts at 112 and the bytes DO NOT MATCH
uring_probe: IOU_PBUF_RING_INC: missing, io_uring_register answered errno 22 (EINVAL)
uring_probe: IORING_RECVSEND_BUNDLE: present, a bundled send returned 20
uring_probe: every required feature is present
```

## How each program ended

```text
init: ended uring_probe: exit 0
init: ended core: exit 0
init: ended linux-shared: exit 1
init: ended uring: exit 0
init: ended conformance-uring: exit 1
init: ended conformance-uring ROTOR_CONFORMANCE_SPIN_NS=50000: exit 1
init: ended epoll: exit 0
init: ended conformance-epoll: exit 1
init: ended conformance-epoll ROTOR_CONFORMANCE_SPIN_NS=50000: exit 1
init: ended rotor: exit 0
init: ended bench-harness: exit 1
init: ended echo_check /bin/echo: exit 0
init: ended guide: exit 0
init: ended halt_check /bin/uring_linux_scenarios: exit 0
init: ended halt_check /bin/epoll_linux_scenarios: exit 0
```

## Every test that failed

```text
17/25 linux_shared_sync_file.test.open_file creates once, reopens what exists and refuses what is missing...FAIL (DirectIoUnsupported)
18/93 machine.test.collect fills every field this host reports...FAIL (TestUnexpectedResult)
20/76 conformance_offload.test.the refuse policy ends a file read with unsupported, where a file blocks the loop...FAIL (DirectIoUnsupported)
21/76 conformance_offload.test.the blocking policy performs a file read inline, on both backends...FAIL (DirectIoUnsupported)
22/76 conformance_offload.test.the offload policy completes a file read on the caller's own thread...FAIL (DirectIoUnsupported)
23/76 conformance_offload.test.the offload policy completes an fdatasync and an fsync on the caller's own thread...FAIL (PathAlreadyExists)
24/76 conformance_offload.test.an offloaded read of every block completes, so the ring is drained and reused...FAIL (PathAlreadyExists)
25/25 linux_shared_sync_socket.test.a socket's buffer is set to what the kernel allows, and read back in the same call...FAIL (TestUnexpectedResult)
25/76 conformance_offload.test.an offloaded result lands in the tick that waited for it, not the one after...FAIL (PathAlreadyExists)
26/76 conformance_offload.test.an offloaded read that is cancelled still ends with exactly one final event...FAIL (PathAlreadyExists)
27/76 conformance_offload.test.the offload policy leaves a socket operation's cancel alone...FAIL (PathAlreadyExists)
28/76 conformance_offload.test.the io_uring backend takes the policy and nothing changes...FAIL (PathAlreadyExists)
37/76 conformance_tcp.test.a multishot receive ends with one final 0 when the peer shuts its sending side...FAIL (BuffersExhausted)
38/76 conformance_file.test.a block written and synced reads back, and a read past the end returns 0...FAIL (DirectIoUnsupported)
50/76 conformance_registered.test.a file named by its registered index is written, synced and read as by its descriptor...FAIL (DirectIoUnsupported)
```

What the failures are:

- `DirectIoUnsupported`, and the `PathAlreadyExists` that files left behind by them cause: the
  in-memory root, not the kernel.
- `machine.test.collect fills every field this host reports`: the benchmark harness reads host
  details this virtual machine does not report.
- `a socket's buffer is set to what the kernel allows`: the test asked for more than a kernel at
  its default `net.core.rmem_max` allows. Fixed the same day, so it no longer depends on the limit.
- `a multishot receive ends with one final 0 when the peer shuts its sending side`, on io_uring
  alone: on 6.1 the receive ended with `buffers_exhausted` once its group had no buffer left,
  though no data waited for one, where 6.17 and 7.0 end it with 0 when the peer shuts. Read from
  the failure, not from the kernel's history.
