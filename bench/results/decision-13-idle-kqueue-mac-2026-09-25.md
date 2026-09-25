# Decision 13's idle case on kqueue, `mac`, 2026-09-25

`rotor_post` from the two builds of `bench/results/crosscore-kqueue-skip-poll-mac-2026-09-25.md`,
run straight after its cross-core rounds in the same quiet spell: commit `507c762`, and the same
commit with the skipped poll, named `skip`. For each gap before a ping, 0, 20, 100, 1,000 and
1,500 µs, each build ran four modes in turn, 2,000 round trips each after 200 not measured:
`waiting`, `spin_then_wait` (the program polls 50 µs), `spin_budget` (the loop's own 50 µs
`spin_budget_ns`) and `spinning`. Three rounds, alternating `507c762` then `skip`. The command, per
gap and mode:

```sh
rotor_post --mode "$mode" --gap-us "$gap" --samples 2000 --warmup 200
```

Each `rotor_post:` line gives the CPU time the answering loop used per round trip; the JSON line
after it is the run's result, whose `p50_ns` is one message, half a round trip. The measuring side
waits out the gap on its core and never sleeps, so only the answering loop can be asleep when a
ping comes. macOS's `CLOCK_MONOTONIC`, which the harness reads, advances in steps of 1,000 ns
(`clock_getres`, and the smallest step seen in a million reads, on this machine on 2026-09-25), so
a message's time moves in steps of about 500 ns, and 0 means the round trip took less than one step.
Decision 13 reads these runs.

The machine, as the cross-core file records it: Apple M1 Pro, 10 cores, 32 GiB, macOS 26.6.2
(25G83). The load average before the first round was 1.49 1.42 2.32.

## Round 1, `507c762`

```text
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 4337 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":16326000,"operations":4000,"operations_per_second":245007,"p50_ns":3503,"p99_ns":8511,"p999_ns":11519,"p9999_ns":26000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 1369 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":2645000,"operations":4000,"operations_per_second":1512287,"p50_ns":501,"p99_ns":1003,"p999_ns":1003,"p9999_ns":2500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 923 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":1763000,"operations":4000,"operations_per_second":2268859,"p50_ns":501,"p99_ns":1000,"p999_ns":1000,"p9999_ns":1000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 1016 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":1967000,"operations":4000,"operations_per_second":2033553,"p50_ns":501,"p99_ns":1000,"p999_ns":1000,"p9999_ns":1000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 2421 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8690000,"operations":4000,"operations_per_second":460299,"p50_ns":2007,"p99_ns":7519,"p999_ns":16063,"p9999_ns":20000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 20408 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":816000,"operations":4000,"operations_per_second":4901960,"p50_ns":0,"p99_ns":501,"p999_ns":501,"p9999_ns":2500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 20304 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":592000,"operations":4000,"operations_per_second":6756756,"p50_ns":0,"p99_ns":501,"p999_ns":501,"p9999_ns":2000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 20456 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":904000,"operations":4000,"operations_per_second":4424778,"p50_ns":0,"p99_ns":500,"p999_ns":500,"p9999_ns":500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 2170 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":7961000,"operations":4000,"operations_per_second":502449,"p50_ns":1503,"p99_ns":5503,"p999_ns":14527,"p9999_ns":17000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 52837 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":51917000,"operations":4000,"operations_per_second":77046,"p50_ns":13055,"p99_ns":19071,"p999_ns":24575,"p9999_ns":42000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 53310 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":46354000,"operations":4000,"operations_per_second":86292,"p50_ns":12543,"p99_ns":19583,"p999_ns":22527,"p9999_ns":35500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 100503 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":995000,"operations":4000,"operations_per_second":4020100,"p50_ns":0,"p99_ns":1003,"p999_ns":3007,"p9999_ns":3500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 3008 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":13347000,"operations":4000,"operations_per_second":299692,"p50_ns":3503,"p99_ns":6527,"p999_ns":17023,"p9999_ns":32500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 54297 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":56305000,"operations":4000,"operations_per_second":71041,"p50_ns":14527,"p99_ns":19583,"p999_ns":23039,"p9999_ns":39000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 54737 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57027000,"operations":4000,"operations_per_second":70142,"p50_ns":14527,"p99_ns":19583,"p999_ns":23039,"p9999_ns":24000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1000374 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":1080000,"operations":4000,"operations_per_second":3703703,"p50_ns":0,"p99_ns":2007,"p999_ns":3503,"p9999_ns":20500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 7239 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":11983000,"operations":4000,"operations_per_second":333806,"p50_ns":3007,"p99_ns":8031,"p999_ns":29567,"p9999_ns":60500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 56791 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":54619000,"operations":4000,"operations_per_second":73234,"p50_ns":13055,"p99_ns":19583,"p999_ns":23551,"p9999_ns":38000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 57867 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":54902000,"operations":4000,"operations_per_second":72857,"p50_ns":13055,"p99_ns":19583,"p999_ns":21503,"p9999_ns":37000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1500376 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":1025000,"operations":4000,"operations_per_second":3902439,"p50_ns":0,"p99_ns":2007,"p999_ns":4511,"p9999_ns":5000,"overflow":0,"peak_rss_bytes":0}
```

## Round 1, `skip`

```text
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 1936 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":7442000,"operations":4000,"operations_per_second":537489,"p50_ns":1503,"p99_ns":4015,"p999_ns":9535,"p9999_ns":14000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 596 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":1125000,"operations":4000,"operations_per_second":3555555,"p50_ns":501,"p99_ns":501,"p999_ns":6527,"p9999_ns":10000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 437 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":815000,"operations":4000,"operations_per_second":4907975,"p50_ns":0,"p99_ns":501,"p999_ns":501,"p9999_ns":1000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 456 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":854000,"operations":4000,"operations_per_second":4683840,"p50_ns":0,"p99_ns":500,"p999_ns":500,"p9999_ns":500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 1997 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":7836000,"operations":4000,"operations_per_second":510464,"p50_ns":1503,"p99_ns":6527,"p999_ns":19071,"p9999_ns":22000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 20005 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4000,"operations":4000,"operations_per_second":1000000000,"p50_ns":0,"p99_ns":0,"p999_ns":0,"p9999_ns":1500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 20003 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3000,"operations":4000,"operations_per_second":1333333333,"p50_ns":0,"p99_ns":0,"p999_ns":0,"p9999_ns":1500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 20031 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8000,"operations":4000,"operations_per_second":500000000,"p50_ns":0,"p99_ns":0,"p999_ns":501,"p9999_ns":1500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 1896 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":6682000,"operations":4000,"operations_per_second":598623,"p50_ns":1003,"p99_ns":5023,"p999_ns":15551,"p9999_ns":33000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 52823 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":50369000,"operations":4000,"operations_per_second":79413,"p50_ns":12543,"p99_ns":18047,"p999_ns":21119,"p9999_ns":54000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 52883 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":47612000,"operations":4000,"operations_per_second":84012,"p50_ns":12543,"p99_ns":20095,"p999_ns":23551,"p9999_ns":31500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 100106 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":217000,"operations":4000,"operations_per_second":18433179,"p50_ns":0,"p99_ns":501,"p999_ns":1503,"p9999_ns":2000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 2683 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":12955000,"operations":4000,"operations_per_second":308761,"p50_ns":3503,"p99_ns":6527,"p999_ns":18047,"p9999_ns":24500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 54214 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":56928000,"operations":4000,"operations_per_second":70264,"p50_ns":14015,"p99_ns":19071,"p999_ns":21503,"p9999_ns":22000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 54490 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":56406000,"operations":4000,"operations_per_second":70914,"p50_ns":14527,"p99_ns":19071,"p999_ns":23551,"p9999_ns":50500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 999392 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":266000,"operations":4000,"operations_per_second":15037593,"p50_ns":0,"p99_ns":1503,"p999_ns":7007,"p9999_ns":13000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 6764 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10739000,"operations":4000,"operations_per_second":372474,"p50_ns":2511,"p99_ns":7519,"p999_ns":12543,"p9999_ns":17500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 56799 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":53889000,"operations":4000,"operations_per_second":74226,"p50_ns":13055,"p99_ns":19583,"p999_ns":22015,"p9999_ns":24000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 57029 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":54256000,"operations":4000,"operations_per_second":73724,"p50_ns":12543,"p99_ns":19583,"p999_ns":24575,"p9999_ns":47500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1499404 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":190000,"operations":4000,"operations_per_second":21052631,"p50_ns":0,"p99_ns":1503,"p999_ns":3007,"p9999_ns":4000,"overflow":0,"peak_rss_bytes":0}
```

## Round 2, `507c762`

```text
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 2399 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9433000,"operations":4000,"operations_per_second":424043,"p50_ns":2007,"p99_ns":5503,"p999_ns":11007,"p9999_ns":22500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 919 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":1781000,"operations":4000,"operations_per_second":2245929,"p50_ns":501,"p99_ns":1000,"p999_ns":1000,"p9999_ns":1000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 729 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":1395000,"operations":4000,"operations_per_second":2867383,"p50_ns":501,"p99_ns":1000,"p999_ns":1000,"p9999_ns":1000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 845 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":1631000,"operations":4000,"operations_per_second":2452483,"p50_ns":501,"p99_ns":1000,"p999_ns":1000,"p9999_ns":1000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 2294 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8028000,"operations":4000,"operations_per_second":498256,"p50_ns":1503,"p99_ns":5023,"p999_ns":10047,"p9999_ns":14500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 20396 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":797000,"operations":4000,"operations_per_second":5018820,"p50_ns":0,"p99_ns":501,"p999_ns":501,"p9999_ns":3000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 20348 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":699000,"operations":4000,"operations_per_second":5722460,"p50_ns":0,"p99_ns":501,"p999_ns":501,"p9999_ns":5000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 20447 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":897000,"operations":4000,"operations_per_second":4459308,"p50_ns":0,"p99_ns":501,"p999_ns":1503,"p9999_ns":3000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 2253 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8466000,"operations":4000,"operations_per_second":472478,"p50_ns":1503,"p99_ns":8511,"p999_ns":15551,"p9999_ns":18500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 52824 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":50907000,"operations":4000,"operations_per_second":78574,"p50_ns":13055,"p99_ns":19583,"p999_ns":22015,"p9999_ns":24000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 53206 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":47758000,"operations":4000,"operations_per_second":83755,"p50_ns":12543,"p99_ns":20607,"p999_ns":23039,"p9999_ns":41000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 100290 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":618000,"operations":4000,"operations_per_second":6472491,"p50_ns":0,"p99_ns":501,"p999_ns":501,"p9999_ns":2000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 3095 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":14021000,"operations":4000,"operations_per_second":285286,"p50_ns":3503,"p99_ns":9535,"p999_ns":16511,"p9999_ns":22500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 54400 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57481000,"operations":4000,"operations_per_second":69588,"p50_ns":14527,"p99_ns":19583,"p999_ns":22527,"p9999_ns":33000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 54609 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":55994000,"operations":4000,"operations_per_second":71436,"p50_ns":14015,"p99_ns":19071,"p999_ns":21503,"p9999_ns":22000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1000293 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":1001000,"operations":4000,"operations_per_second":3996003,"p50_ns":0,"p99_ns":1503,"p999_ns":4015,"p9999_ns":13500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 6956 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":11587000,"operations":4000,"operations_per_second":345214,"p50_ns":3007,"p99_ns":8031,"p999_ns":24575,"p9999_ns":41000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 56805 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":54843000,"operations":4000,"operations_per_second":72935,"p50_ns":13055,"p99_ns":19583,"p999_ns":39167,"p9999_ns":49500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 57558 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":54029000,"operations":4000,"operations_per_second":74034,"p50_ns":13055,"p99_ns":19583,"p999_ns":36095,"p9999_ns":41000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1499983 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":1090000,"operations":4000,"operations_per_second":3669724,"p50_ns":0,"p99_ns":2511,"p999_ns":4015,"p9999_ns":19500,"overflow":0,"peak_rss_bytes":0}
```

## Round 2, `skip`

```text
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 1735 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":6848000,"operations":4000,"operations_per_second":584112,"p50_ns":1503,"p99_ns":3503,"p999_ns":5503,"p9999_ns":7000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 561 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":1059000,"operations":4000,"operations_per_second":3777148,"p50_ns":500,"p99_ns":500,"p999_ns":500,"p9999_ns":500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 441 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":828000,"operations":4000,"operations_per_second":4830917,"p50_ns":0,"p99_ns":500,"p999_ns":500,"p9999_ns":500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 460 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":872000,"operations":4000,"operations_per_second":4587155,"p50_ns":0,"p99_ns":500,"p999_ns":500,"p9999_ns":500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 2084 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8110000,"operations":4000,"operations_per_second":493218,"p50_ns":1503,"p99_ns":8031,"p999_ns":21119,"p9999_ns":25500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 20003 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":6000,"operations":4000,"operations_per_second":666666666,"p50_ns":0,"p99_ns":0,"p999_ns":0,"p9999_ns":3000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 20009 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":2000,"operations":4000,"operations_per_second":2000000000,"p50_ns":0,"p99_ns":0,"p999_ns":0,"p9999_ns":500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 20002 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":1,"operations":4000,"operations_per_second":4000000000000,"p50_ns":0,"p99_ns":0,"p999_ns":0,"p9999_ns":0,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 1812 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":6293000,"operations":4000,"operations_per_second":635626,"p50_ns":1003,"p99_ns":5503,"p999_ns":20095,"p9999_ns":22000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 52743 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":50126000,"operations":4000,"operations_per_second":79798,"p50_ns":12543,"p99_ns":19071,"p999_ns":22015,"p9999_ns":24500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 52896 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":46634000,"operations":4000,"operations_per_second":85774,"p50_ns":12543,"p99_ns":19583,"p999_ns":23551,"p9999_ns":30500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 100019 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26000,"operations":4000,"operations_per_second":153846153,"p50_ns":0,"p99_ns":0,"p999_ns":2007,"p9999_ns":7500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 2751 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":13116000,"operations":4000,"operations_per_second":304971,"p50_ns":3503,"p99_ns":7519,"p999_ns":20095,"p9999_ns":29000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 53949 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":56032000,"operations":4000,"operations_per_second":71387,"p50_ns":14015,"p99_ns":19071,"p999_ns":22015,"p9999_ns":24000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 54545 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57391000,"operations":4000,"operations_per_second":69697,"p50_ns":14527,"p99_ns":19071,"p999_ns":22015,"p9999_ns":24000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 999838 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":164000,"operations":4000,"operations_per_second":24390243,"p50_ns":0,"p99_ns":1003,"p999_ns":2511,"p9999_ns":3500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 6873 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":11106000,"operations":4000,"operations_per_second":360165,"p50_ns":2511,"p99_ns":8511,"p999_ns":23551,"p9999_ns":25000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 56691 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":53863000,"operations":4000,"operations_per_second":74262,"p50_ns":13055,"p99_ns":20095,"p999_ns":22015,"p9999_ns":37500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 56918 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":53761000,"operations":4000,"operations_per_second":74403,"p50_ns":13055,"p99_ns":19583,"p999_ns":22015,"p9999_ns":62000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1499968 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":178000,"operations":4000,"operations_per_second":22471910,"p50_ns":0,"p99_ns":1003,"p999_ns":6527,"p9999_ns":12500,"overflow":0,"peak_rss_bytes":0}
```

## Round 3, `507c762`

```text
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 2361 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9165000,"operations":4000,"operations_per_second":436442,"p50_ns":2007,"p99_ns":5023,"p999_ns":17023,"p9999_ns":20500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 907 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":1755000,"operations":4000,"operations_per_second":2279202,"p50_ns":501,"p99_ns":1003,"p999_ns":1003,"p9999_ns":2500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 816 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":1579000,"operations":4000,"operations_per_second":2533248,"p50_ns":501,"p99_ns":1000,"p999_ns":1000,"p9999_ns":1000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 767 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":1476000,"operations":4000,"operations_per_second":2710027,"p50_ns":501,"p99_ns":1000,"p999_ns":1000,"p9999_ns":1000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 2537 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9928000,"operations":4000,"operations_per_second":402900,"p50_ns":2007,"p99_ns":14015,"p999_ns":17535,"p9999_ns":18000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 20411 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":810000,"operations":4000,"operations_per_second":4938271,"p50_ns":0,"p99_ns":501,"p999_ns":501,"p9999_ns":5000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 20206 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":403000,"operations":4000,"operations_per_second":9925558,"p50_ns":0,"p99_ns":500,"p999_ns":500,"p9999_ns":500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 20431 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":858000,"operations":4000,"operations_per_second":4662004,"p50_ns":0,"p99_ns":500,"p999_ns":500,"p9999_ns":500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 2388 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9235000,"operations":4000,"operations_per_second":433134,"p50_ns":1503,"p99_ns":9535,"p999_ns":19071,"p9999_ns":34500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 52728 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":51113000,"operations":4000,"operations_per_second":78257,"p50_ns":13055,"p99_ns":18559,"p999_ns":22015,"p9999_ns":23000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 53179 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":47440000,"operations":4000,"operations_per_second":84317,"p50_ns":12543,"p99_ns":20095,"p999_ns":21503,"p9999_ns":40000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 100362 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":722000,"operations":4000,"operations_per_second":5540166,"p50_ns":0,"p99_ns":501,"p999_ns":1003,"p9999_ns":2000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 3081 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":13923000,"operations":4000,"operations_per_second":287294,"p50_ns":3503,"p99_ns":9023,"p999_ns":20095,"p9999_ns":24500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 54304 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":56493000,"operations":4000,"operations_per_second":70805,"p50_ns":14015,"p99_ns":19071,"p999_ns":22527,"p9999_ns":24000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 54555 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":56553000,"operations":4000,"operations_per_second":70730,"p50_ns":14015,"p99_ns":18559,"p999_ns":22527,"p9999_ns":30000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1000324 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":1059000,"operations":4000,"operations_per_second":3777148,"p50_ns":0,"p99_ns":2007,"p999_ns":4511,"p9999_ns":5000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 7167 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":12184000,"operations":4000,"operations_per_second":328299,"p50_ns":3007,"p99_ns":10047,"p999_ns":20607,"p9999_ns":57000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 56786 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":54602000,"operations":4000,"operations_per_second":73257,"p50_ns":13055,"p99_ns":20095,"p999_ns":23551,"p9999_ns":45000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 57883 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":54887000,"operations":4000,"operations_per_second":72877,"p50_ns":13055,"p99_ns":19583,"p999_ns":24575,"p9999_ns":60000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1500265 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":1022000,"operations":4000,"operations_per_second":3913894,"p50_ns":0,"p99_ns":2007,"p999_ns":3503,"p9999_ns":5000,"overflow":0,"peak_rss_bytes":0}
```

## Round 3, `skip`

```text
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 1892 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":7405000,"operations":4000,"operations_per_second":540175,"p50_ns":1503,"p99_ns":4015,"p999_ns":7007,"p9999_ns":10000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 560 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":1055000,"operations":4000,"operations_per_second":3791469,"p50_ns":500,"p99_ns":500,"p999_ns":500,"p9999_ns":500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 435 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":803000,"operations":4000,"operations_per_second":4981320,"p50_ns":0,"p99_ns":501,"p999_ns":501,"p9999_ns":1000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 470 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":881000,"operations":4000,"operations_per_second":4540295,"p50_ns":0,"p99_ns":501,"p999_ns":501,"p9999_ns":11000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 1994 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":7924000,"operations":4000,"operations_per_second":504795,"p50_ns":1503,"p99_ns":7007,"p999_ns":19071,"p9999_ns":20000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 20004 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":1000,"operations":4000,"operations_per_second":4000000000,"p50_ns":0,"p99_ns":0,"p999_ns":0,"p9999_ns":500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 20011 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3000,"operations":4000,"operations_per_second":1333333333,"p50_ns":0,"p99_ns":0,"p999_ns":500,"p9999_ns":500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 20008 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":11000,"operations":4000,"operations_per_second":363636363,"p50_ns":0,"p99_ns":0,"p999_ns":0,"p9999_ns":5500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 1828 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":6708000,"operations":4000,"operations_per_second":596302,"p50_ns":1003,"p99_ns":6015,"p999_ns":20095,"p9999_ns":23000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 52880 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":48160000,"operations":4000,"operations_per_second":83056,"p50_ns":12543,"p99_ns":19071,"p999_ns":22015,"p9999_ns":24000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 52803 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":46502000,"operations":4000,"operations_per_second":86017,"p50_ns":12543,"p99_ns":18559,"p999_ns":21503,"p9999_ns":25000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 100118 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":404000,"operations":4000,"operations_per_second":9900990,"p50_ns":0,"p99_ns":501,"p999_ns":6015,"p9999_ns":22500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 2751 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":13328000,"operations":4000,"operations_per_second":300120,"p50_ns":3503,"p99_ns":10047,"p999_ns":18559,"p9999_ns":29000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 54369 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57035000,"operations":4000,"operations_per_second":70132,"p50_ns":14527,"p99_ns":19071,"p999_ns":22015,"p9999_ns":26000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 54373 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":56083000,"operations":4000,"operations_per_second":71322,"p50_ns":14015,"p99_ns":19583,"p999_ns":23039,"p9999_ns":33000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 999969 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":174000,"operations":4000,"operations_per_second":22988505,"p50_ns":0,"p99_ns":1003,"p999_ns":3007,"p9999_ns":16500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 6858 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":11281000,"operations":4000,"operations_per_second":354578,"p50_ns":2511,"p99_ns":8511,"p999_ns":17023,"p9999_ns":44500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 56622 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":52919000,"operations":4000,"operations_per_second":75587,"p50_ns":12543,"p99_ns":19071,"p999_ns":22015,"p9999_ns":28000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 56942 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":55390000,"operations":4000,"operations_per_second":72215,"p50_ns":13055,"p99_ns":19583,"p999_ns":22015,"p9999_ns":848000,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1499902 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":259000,"operations":4000,"operations_per_second":15444015,"p50_ns":0,"p99_ns":1503,"p999_ns":3007,"p9999_ns":6500,"overflow":0,"peak_rss_bytes":0}
```
