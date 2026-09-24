# Echo with a single-shot receive from the group, on `mac`, 2026-09-23

`rotor_echo PORT --shape group_single --buffer-bytes B` under `echo_client PORT --connections 16
--payload B --seconds 2 --warmup 0`, on macOS 26.6.2, for B of 4096 and 65536. Five rounds, each
running the build before and the build after once, alternating. Both came from
`zig build bench-echo`:

- **before**: the tree of `50c891f`, where kqueue's flush never tries a receive from a group.
- **after**: that tree with kqueue's flush trying a single-shot receive from a group, as epoll's
  now does. It was not kept: decision 12, point 4 says why.

Each line is the payload, the build, the round, the machine's 1-minute load average before the run,
and the echoes per second the client measured. The load was about 7, so no time here is a claim.

```text
4096 base 1 load=6.65 139322
4096 after 1 load=6.65 137780
4096 base 2 load=6.68 148176
4096 after 2 load=6.68 135793
4096 base 3 load=6.62 127638
4096 after 3 load=6.62 139763
4096 base 4 load=6.62 156686
4096 after 4 load=6.57 141707
4096 base 5 load=6.57 159072
4096 after 5 load=6.77 149651
65536 base 1 load=6.77 51825
65536 after 1 load=6.94 49528
65536 base 2 load=6.94 51489
65536 after 2 load=7.03 52081
65536 base 3 load=7.03 50864
65536 after 3 load=6.87 50065
65536 base 4 load=6.87 48521
65536 after 4 load=7.36 47340
65536 base 5 load=7.36 51359
65536 after 5 load=7.36 51959
```
