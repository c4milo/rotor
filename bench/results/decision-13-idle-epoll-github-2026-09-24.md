# Decision 13's idle case on epoll, `github`, 2026-09-24

`rotor_post` from commit `57dbc22`, in the CI job `costs`, started by hand three times; each start
got its own GitHub-hosted `ubuntu-24.04` runner. Each run has two sections from the same runner:
the idle case on io_uring (`zig-out/bin/rotor_post`) and on epoll (`zig-out/linux-bench/post_epoll`,
`rotor_post` built against epoll). For each gap before a ping, 0, 20, 100, 1,000 and 1,500 µs,
each ran four modes in turn, 2,000 round trips each after 200 not measured, three rounds:
`waiting`, `spin_then_wait` (the program polls 50 µs), `spin_budget` (the loop's own 50 µs
`spin_budget_ns`) and `spinning`. Each `rotor_post:` line gives the CPU time the answering loop
used per round trip; the JSON line after it is the run's result, whose `p50_ns` is one message,
half a round trip. Decision 13 reads them.

## Run 1: AMD EPYC 7763 64-Core Processor, CI run 36063942175

### io_uring

```text
model name	: AMD EPYC 7763 64-Core Processor
4
6.17.0-1022-azure
MemTotal:       16373452 kB
== round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14987 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":59769486,"operations":4000,"operations_per_second":66923,"p50_ns":16639,"p99_ns":19967,"p999_ns":27007,"p9999_ns":32511,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4678 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9246149,"operations":4000,"operations_per_second":432612,"p50_ns":2175,"p99_ns":3327,"p999_ns":14719,"p9999_ns":27081,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4548 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9013821,"operations":4000,"operations_per_second":443762,"p50_ns":2111,"p99_ns":3615,"p999_ns":12223,"p9999_ns":53039,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4541 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8993998,"operations":4000,"operations_per_second":444741,"p50_ns":2111,"p99_ns":3119,"p999_ns":14463,"p9999_ns":29335,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 15516 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":59583838,"operations":4000,"operations_per_second":67132,"p50_ns":16255,"p99_ns":19583,"p999_ns":28671,"p9999_ns":43411,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24999 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9558337,"operations":4000,"operations_per_second":418482,"p50_ns":2175,"p99_ns":9151,"p999_ns":12095,"p9999_ns":19867,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24763 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9138234,"operations":4000,"operations_per_second":437721,"p50_ns":2127,"p99_ns":3615,"p999_ns":10751,"p9999_ns":16185,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24730 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9102008,"operations":4000,"operations_per_second":439463,"p50_ns":2127,"p99_ns":3695,"p999_ns":10367,"p9999_ns":11301,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 16577 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":65390351,"operations":4000,"operations_per_second":61171,"p50_ns":16639,"p99_ns":19583,"p999_ns":28287,"p9999_ns":219176,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 60169 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":36492856,"operations":4000,"operations_per_second":109610,"p50_ns":8895,"p99_ns":13951,"p999_ns":19327,"p9999_ns":173866,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 59919 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":45517893,"operations":4000,"operations_per_second":87877,"p50_ns":8703,"p99_ns":12991,"p999_ns":1146879,"p9999_ns":1550884,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 105203 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9701203,"operations":4000,"operations_per_second":412319,"p50_ns":2143,"p99_ns":9727,"p999_ns":11199,"p9999_ns":20202,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20695 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":56332356,"operations":4000,"operations_per_second":71007,"p50_ns":14463,"p99_ns":21247,"p999_ns":39167,"p9999_ns":137037,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 60819 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":39513111,"operations":4000,"operations_per_second":101232,"p50_ns":9407,"p99_ns":14207,"p999_ns":37631,"p9999_ns":452645,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 64887 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":53284349,"operations":4000,"operations_per_second":75068,"p50_ns":13055,"p99_ns":16639,"p999_ns":24063,"p9999_ns":206152,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004827 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9789560,"operations":4000,"operations_per_second":408598,"p50_ns":2303,"p99_ns":4223,"p999_ns":10047,"p9999_ns":14292,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 30548 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":68904399,"operations":4000,"operations_per_second":58051,"p50_ns":17151,"p99_ns":21503,"p999_ns":28415,"p9999_ns":50294,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 72822 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":38463918,"operations":4000,"operations_per_second":103993,"p50_ns":9407,"p99_ns":14527,"p999_ns":33023,"p9999_ns":70457,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 73141 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":39427612,"operations":4000,"operations_per_second":101451,"p50_ns":9407,"p99_ns":15871,"p999_ns":45823,"p9999_ns":57668,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1504898 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9772283,"operations":4000,"operations_per_second":409320,"p50_ns":2303,"p99_ns":3743,"p999_ns":9151,"p9999_ns":9277,"overflow":0,"peak_rss_bytes":0}
== round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 11963 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":54109860,"operations":4000,"operations_per_second":73923,"p50_ns":11583,"p99_ns":19839,"p999_ns":25471,"p9999_ns":25828,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4639 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9197381,"operations":4000,"operations_per_second":434906,"p50_ns":2159,"p99_ns":3311,"p999_ns":13055,"p9999_ns":30191,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4532 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8967554,"operations":4000,"operations_per_second":446052,"p50_ns":2095,"p99_ns":3599,"p999_ns":17791,"p9999_ns":19607,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4522 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8945984,"operations":4000,"operations_per_second":447128,"p50_ns":2111,"p99_ns":3055,"p999_ns":13823,"p9999_ns":29029,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 15327 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":61022658,"operations":4000,"operations_per_second":65549,"p50_ns":16383,"p99_ns":19327,"p999_ns":23039,"p9999_ns":26690,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24849 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9266303,"operations":4000,"operations_per_second":431671,"p50_ns":2175,"p99_ns":4319,"p999_ns":10559,"p9999_ns":13164,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24659 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9044182,"operations":4000,"operations_per_second":442273,"p50_ns":2111,"p99_ns":5279,"p999_ns":10367,"p9999_ns":11331,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24642 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9001915,"operations":4000,"operations_per_second":444349,"p50_ns":2111,"p99_ns":3839,"p999_ns":10623,"p9999_ns":11206,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 15459 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":62857419,"operations":4000,"operations_per_second":63636,"p50_ns":16511,"p99_ns":22655,"p999_ns":43775,"p9999_ns":47179,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 60192 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35865156,"operations":4000,"operations_per_second":111528,"p50_ns":8831,"p99_ns":13183,"p999_ns":16639,"p9999_ns":23860,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 59958 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34776103,"operations":4000,"operations_per_second":115021,"p50_ns":8639,"p99_ns":10367,"p999_ns":13567,"p9999_ns":18845,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 105040 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9508040,"operations":4000,"operations_per_second":420696,"p50_ns":2127,"p99_ns":9279,"p999_ns":11519,"p9999_ns":15374,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20441 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":54769110,"operations":4000,"operations_per_second":73033,"p50_ns":14271,"p99_ns":18047,"p999_ns":21503,"p9999_ns":28248,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 60800 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":38005251,"operations":4000,"operations_per_second":105248,"p50_ns":9343,"p99_ns":12735,"p999_ns":16319,"p9999_ns":17067,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 64719 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":51536594,"operations":4000,"operations_per_second":77614,"p50_ns":12863,"p99_ns":15807,"p999_ns":17663,"p9999_ns":18063,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004842 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9659614,"operations":4000,"operations_per_second":414095,"p50_ns":2287,"p99_ns":3935,"p999_ns":9279,"p9999_ns":11136,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 30635 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":68870656,"operations":4000,"operations_per_second":58079,"p50_ns":17151,"p99_ns":20991,"p999_ns":23679,"p9999_ns":30377,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 72865 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":38075222,"operations":4000,"operations_per_second":105055,"p50_ns":9407,"p99_ns":12671,"p999_ns":16895,"p9999_ns":37741,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 72833 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":39529279,"operations":4000,"operations_per_second":101190,"p50_ns":9343,"p99_ns":13119,"p999_ns":15935,"p9999_ns":823732,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1504933 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9852895,"operations":4000,"operations_per_second":405972,"p50_ns":2319,"p99_ns":4799,"p999_ns":9727,"p9999_ns":10374,"overflow":0,"peak_rss_bytes":0}
== round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13632 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57961304,"operations":4000,"operations_per_second":69011,"p50_ns":16511,"p99_ns":18559,"p999_ns":25727,"p9999_ns":28348,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4647 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9198074,"operations":4000,"operations_per_second":434873,"p50_ns":2159,"p99_ns":3311,"p999_ns":14527,"p9999_ns":23454,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4526 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8947098,"operations":4000,"operations_per_second":447072,"p50_ns":2095,"p99_ns":3263,"p999_ns":12607,"p9999_ns":17913,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4517 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8935357,"operations":4000,"operations_per_second":447659,"p50_ns":2095,"p99_ns":3071,"p999_ns":15999,"p9999_ns":18369,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 14408 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":58916887,"operations":4000,"operations_per_second":67892,"p50_ns":16191,"p99_ns":18431,"p999_ns":24319,"p9999_ns":41092,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24822 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9262810,"operations":4000,"operations_per_second":431834,"p50_ns":2175,"p99_ns":5791,"p999_ns":10303,"p9999_ns":10615,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24617 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8955444,"operations":4000,"operations_per_second":446655,"p50_ns":2111,"p99_ns":3151,"p999_ns":9791,"p9999_ns":11266,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24656 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9052325,"operations":4000,"operations_per_second":441875,"p50_ns":2111,"p99_ns":4639,"p999_ns":10239,"p9999_ns":19652,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 12576 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57455680,"operations":4000,"operations_per_second":69618,"p50_ns":12479,"p99_ns":21887,"p999_ns":93183,"p9999_ns":192241,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 61368 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57291591,"operations":4000,"operations_per_second":69818,"p50_ns":8703,"p99_ns":97791,"p999_ns":1179647,"p9999_ns":1470361,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 59597 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35434876,"operations":4000,"operations_per_second":112883,"p50_ns":8639,"p99_ns":12543,"p999_ns":15359,"p9999_ns":648342,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 104994 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9438987,"operations":4000,"operations_per_second":423774,"p50_ns":2127,"p99_ns":8639,"p999_ns":11455,"p9999_ns":15328,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20688 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":55286929,"operations":4000,"operations_per_second":72349,"p50_ns":14335,"p99_ns":18431,"p999_ns":20863,"p9999_ns":24761,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 60874 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":41368317,"operations":4000,"operations_per_second":96692,"p50_ns":9407,"p99_ns":13503,"p999_ns":15999,"p9999_ns":1453995,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 64964 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":52129616,"operations":4000,"operations_per_second":76731,"p50_ns":13055,"p99_ns":15999,"p999_ns":18815,"p9999_ns":18985,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004874 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9711129,"operations":4000,"operations_per_second":411898,"p50_ns":2303,"p99_ns":3615,"p999_ns":9599,"p9999_ns":14322,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 30339 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":83126962,"operations":4000,"operations_per_second":48119,"p50_ns":17151,"p99_ns":21503,"p999_ns":827391,"p9999_ns":2408656,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 72972 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":39218442,"operations":4000,"operations_per_second":101992,"p50_ns":9471,"p99_ns":15231,"p999_ns":46335,"p9999_ns":56195,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 73558 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":41480433,"operations":4000,"operations_per_second":96431,"p50_ns":9727,"p99_ns":14911,"p999_ns":124415,"p9999_ns":565902,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1504926 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9755701,"operations":4000,"operations_per_second":410016,"p50_ns":2319,"p99_ns":3903,"p999_ns":9407,"p9999_ns":10194,"overflow":0,"peak_rss_bytes":0}
```

### epoll

```text
== epoll, round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 18666 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":67566253,"operations":4000,"operations_per_second":59201,"p50_ns":17663,"p99_ns":18687,"p999_ns":22143,"p9999_ns":26609,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2837 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5580687,"operations":4000,"operations_per_second":716757,"p50_ns":1255,"p99_ns":2159,"p999_ns":9791,"p9999_ns":17788,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2675 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5265728,"operations":4000,"operations_per_second":759629,"p50_ns":1215,"p99_ns":1615,"p999_ns":11647,"p9999_ns":13019,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2652 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5219446,"operations":4000,"operations_per_second":766364,"p50_ns":1215,"p99_ns":1623,"p999_ns":8319,"p9999_ns":10028,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 19430 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":68534134,"operations":4000,"operations_per_second":58365,"p50_ns":17151,"p99_ns":20991,"p999_ns":24447,"p9999_ns":39153,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 23001 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5878942,"operations":4000,"operations_per_second":680394,"p50_ns":1255,"p99_ns":2143,"p999_ns":9087,"p9999_ns":116643,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22863 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":7371255,"operations":4000,"operations_per_second":542648,"p50_ns":1215,"p99_ns":1663,"p999_ns":21759,"p9999_ns":955011,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22760 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5207800,"operations":4000,"operations_per_second":768078,"p50_ns":1215,"p99_ns":1647,"p999_ns":3071,"p9999_ns":7770,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 19751 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":70806203,"operations":4000,"operations_per_second":56492,"p50_ns":17407,"p99_ns":20479,"p999_ns":122879,"p9999_ns":279128,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 62341 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35342706,"operations":4000,"operations_per_second":113177,"p50_ns":8703,"p99_ns":12863,"p999_ns":15615,"p9999_ns":30232,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 62943 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34719040,"operations":4000,"operations_per_second":115210,"p50_ns":8703,"p99_ns":11007,"p999_ns":13439,"p9999_ns":14732,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102836 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5373448,"operations":4000,"operations_per_second":744400,"p50_ns":1223,"p99_ns":1687,"p999_ns":8511,"p9999_ns":14116,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20349 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":70754542,"operations":4000,"operations_per_second":56533,"p50_ns":17663,"p99_ns":21119,"p999_ns":24447,"p9999_ns":32576,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 64307 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":41138315,"operations":4000,"operations_per_second":97232,"p50_ns":10111,"p99_ns":13375,"p999_ns":16895,"p9999_ns":160401,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 65164 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":49841335,"operations":4000,"operations_per_second":80254,"p50_ns":9983,"p99_ns":17151,"p999_ns":192511,"p9999_ns":2715938,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1002814 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5551484,"operations":4000,"operations_per_second":720528,"p50_ns":1263,"p99_ns":1679,"p999_ns":8255,"p9999_ns":8951,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 33543 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":71093633,"operations":4000,"operations_per_second":56263,"p50_ns":17791,"p99_ns":20607,"p999_ns":23167,"p9999_ns":23554,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 77023 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":44643153,"operations":4000,"operations_per_second":89599,"p50_ns":9919,"p99_ns":14527,"p999_ns":45311,"p9999_ns":2219467,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 78673 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":40583508,"operations":4000,"operations_per_second":98562,"p50_ns":9983,"p99_ns":13631,"p999_ns":15871,"p9999_ns":189501,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1502823 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5551329,"operations":4000,"operations_per_second":720548,"p50_ns":1263,"p99_ns":1695,"p999_ns":7135,"p9999_ns":8215,"overflow":0,"peak_rss_bytes":0}
== epoll, round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 17139 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":64256524,"operations":4000,"operations_per_second":62250,"p50_ns":17279,"p99_ns":18303,"p999_ns":25471,"p9999_ns":25733,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2806 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5518682,"operations":4000,"operations_per_second":724810,"p50_ns":1255,"p99_ns":1679,"p999_ns":9279,"p9999_ns":12483,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2691 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5288616,"operations":4000,"operations_per_second":756341,"p50_ns":1207,"p99_ns":1607,"p999_ns":8831,"p9999_ns":15078,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2675 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5262088,"operations":4000,"operations_per_second":760154,"p50_ns":1215,"p99_ns":1623,"p999_ns":9791,"p9999_ns":17903,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 17028 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":63525339,"operations":4000,"operations_per_second":62966,"p50_ns":17023,"p99_ns":20223,"p999_ns":24959,"p9999_ns":27647,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 22952 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5577122,"operations":4000,"operations_per_second":717215,"p50_ns":1255,"p99_ns":1703,"p999_ns":8255,"p9999_ns":13730,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22768 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5211108,"operations":4000,"operations_per_second":767591,"p50_ns":1215,"p99_ns":1623,"p999_ns":3695,"p9999_ns":11181,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22751 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5178487,"operations":4000,"operations_per_second":772426,"p50_ns":1215,"p99_ns":1639,"p999_ns":3007,"p9999_ns":4032,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 19815 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":70055669,"operations":4000,"operations_per_second":57097,"p50_ns":17535,"p99_ns":20095,"p999_ns":22271,"p9999_ns":35757,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 62285 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35283597,"operations":4000,"operations_per_second":113367,"p50_ns":8703,"p99_ns":10751,"p999_ns":19327,"p9999_ns":153869,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 62966 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34772565,"operations":4000,"operations_per_second":115033,"p50_ns":8703,"p99_ns":11327,"p999_ns":14143,"p9999_ns":32941,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102802 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5311370,"operations":4000,"operations_per_second":753101,"p50_ns":1215,"p99_ns":1655,"p999_ns":8063,"p9999_ns":8716,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20630 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":71743038,"operations":4000,"operations_per_second":55754,"p50_ns":17791,"p99_ns":19839,"p999_ns":23679,"p9999_ns":305568,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 64343 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":40827649,"operations":4000,"operations_per_second":97972,"p50_ns":10175,"p99_ns":14207,"p999_ns":18559,"p9999_ns":43532,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 65178 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":42152650,"operations":4000,"operations_per_second":94893,"p50_ns":9983,"p99_ns":14271,"p999_ns":22271,"p9999_ns":785654,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1002831 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5556874,"operations":4000,"operations_per_second":719829,"p50_ns":1263,"p99_ns":1687,"p999_ns":7327,"p9999_ns":8816,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 33513 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":72874653,"operations":4000,"operations_per_second":54888,"p50_ns":17791,"p99_ns":20351,"p999_ns":36351,"p9999_ns":837141,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 76590 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":39201042,"operations":4000,"operations_per_second":102038,"p50_ns":9727,"p99_ns":13887,"p999_ns":15295,"p9999_ns":15664,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 78611 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":40355720,"operations":4000,"operations_per_second":99118,"p50_ns":10047,"p99_ns":13887,"p999_ns":17151,"p9999_ns":131677,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1502856 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5599817,"operations":4000,"operations_per_second":714309,"p50_ns":1279,"p99_ns":1695,"p999_ns":6943,"p9999_ns":8867,"overflow":0,"peak_rss_bytes":0}
== epoll, round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 19174 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":69440127,"operations":4000,"operations_per_second":57603,"p50_ns":17535,"p99_ns":18431,"p999_ns":19327,"p9999_ns":23248,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2821 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5539354,"operations":4000,"operations_per_second":722105,"p50_ns":1255,"p99_ns":1679,"p999_ns":9215,"p9999_ns":16806,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2681 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5267491,"operations":4000,"operations_per_second":759374,"p50_ns":1215,"p99_ns":1623,"p999_ns":9663,"p9999_ns":18835,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2655 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5220809,"operations":4000,"operations_per_second":766164,"p50_ns":1207,"p99_ns":1623,"p999_ns":8383,"p9999_ns":17898,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 18260 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":65681723,"operations":4000,"operations_per_second":60899,"p50_ns":17023,"p99_ns":19967,"p999_ns":22015,"p9999_ns":29430,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 22962 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5638399,"operations":4000,"operations_per_second":709421,"p50_ns":1255,"p99_ns":1775,"p999_ns":8703,"p9999_ns":9483,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22755 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5210232,"operations":4000,"operations_per_second":767720,"p50_ns":1215,"p99_ns":1647,"p999_ns":7935,"p9999_ns":9768,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22767 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5260655,"operations":4000,"operations_per_second":760361,"p50_ns":1215,"p99_ns":1639,"p999_ns":6911,"p9999_ns":8270,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 19713 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":69107194,"operations":4000,"operations_per_second":57881,"p50_ns":17279,"p99_ns":20351,"p999_ns":27519,"p9999_ns":51336,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 62359 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34877930,"operations":4000,"operations_per_second":114685,"p50_ns":8703,"p99_ns":9343,"p999_ns":13183,"p9999_ns":14231,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 63027 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34967994,"operations":4000,"operations_per_second":114390,"p50_ns":8703,"p99_ns":10815,"p999_ns":19967,"p9999_ns":31263,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102824 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5321193,"operations":4000,"operations_per_second":751711,"p50_ns":1223,"p99_ns":1663,"p999_ns":8639,"p9999_ns":8882,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20397 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":70764042,"operations":4000,"operations_per_second":56525,"p50_ns":17535,"p99_ns":22015,"p999_ns":47103,"p9999_ns":63449,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 63982 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":39663244,"operations":4000,"operations_per_second":100849,"p50_ns":9855,"p99_ns":12351,"p999_ns":15615,"p9999_ns":17397,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 65127 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":40786059,"operations":4000,"operations_per_second":98072,"p50_ns":10047,"p99_ns":14207,"p999_ns":16895,"p9999_ns":97638,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1002813 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5559133,"operations":4000,"operations_per_second":719536,"p50_ns":1263,"p99_ns":1695,"p999_ns":7295,"p9999_ns":7770,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 33388 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":70860463,"operations":4000,"operations_per_second":56448,"p50_ns":17791,"p99_ns":20863,"p999_ns":29567,"p9999_ns":100418,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 76832 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":44383104,"operations":4000,"operations_per_second":90124,"p50_ns":9855,"p99_ns":14079,"p999_ns":368639,"p9999_ns":1434883,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 78618 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":40536563,"operations":4000,"operations_per_second":98676,"p50_ns":9983,"p99_ns":14527,"p999_ns":38399,"p9999_ns":109781,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1502798 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5560241,"operations":4000,"operations_per_second":719393,"p50_ns":1263,"p99_ns":1687,"p999_ns":7359,"p9999_ns":10470,"overflow":0,"peak_rss_bytes":0}
```

## Run 2: AMD EPYC 9V45 96-Core Processor, CI run 36063951318

### io_uring

```text
model name	: AMD EPYC 9V45 96-Core Processor
4
6.17.0-1022-azure
MemTotal:       16373452 kB
== round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8675 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":36568084,"operations":4000,"operations_per_second":109385,"p50_ns":9343,"p99_ns":12543,"p999_ns":17023,"p9999_ns":78498,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2793 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5539691,"operations":4000,"operations_per_second":722061,"p50_ns":1311,"p99_ns":1847,"p999_ns":8383,"p9999_ns":14251,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2742 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5449002,"operations":4000,"operations_per_second":734079,"p50_ns":1279,"p99_ns":1839,"p999_ns":6175,"p9999_ns":32143,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2760 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5459988,"operations":4000,"operations_per_second":732602,"p50_ns":1287,"p99_ns":2175,"p999_ns":8031,"p9999_ns":19860,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 7615 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":32997274,"operations":4000,"operations_per_second":121222,"p50_ns":7999,"p99_ns":13503,"p999_ns":59391,"p9999_ns":80691,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 22877 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5562339,"operations":4000,"operations_per_second":719121,"p50_ns":1327,"p99_ns":1863,"p999_ns":5759,"p9999_ns":6319,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22775 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5396500,"operations":4000,"operations_per_second":741221,"p50_ns":1287,"p99_ns":1831,"p999_ns":5407,"p9999_ns":8357,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22841 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5438208,"operations":4000,"operations_per_second":735536,"p50_ns":1303,"p99_ns":1863,"p999_ns":5023,"p9999_ns":5748,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 8716 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":36187928,"operations":4000,"operations_per_second":110534,"p50_ns":9151,"p99_ns":12415,"p999_ns":15103,"p9999_ns":18347,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 55246 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":21915242,"operations":4000,"operations_per_second":182521,"p50_ns":5471,"p99_ns":6111,"p999_ns":13887,"p9999_ns":36184,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 55497 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":22430733,"operations":4000,"operations_per_second":178326,"p50_ns":5503,"p99_ns":7807,"p999_ns":11583,"p9999_ns":69965,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102930 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5647391,"operations":4000,"operations_per_second":708291,"p50_ns":1343,"p99_ns":1983,"p999_ns":6303,"p9999_ns":10716,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 9035 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":27565395,"operations":4000,"operations_per_second":145109,"p50_ns":5535,"p99_ns":10239,"p999_ns":58879,"p9999_ns":755799,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 55475 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":22368127,"operations":4000,"operations_per_second":178825,"p50_ns":5535,"p99_ns":6911,"p999_ns":10495,"p9999_ns":12754,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 57168 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24659723,"operations":4000,"operations_per_second":162207,"p50_ns":5887,"p99_ns":9023,"p999_ns":61695,"p9999_ns":91713,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1002885 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5966094,"operations":4000,"operations_per_second":670455,"p50_ns":1423,"p99_ns":2127,"p999_ns":6815,"p9999_ns":10816,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 15287 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":42178276,"operations":4000,"operations_per_second":94835,"p50_ns":9535,"p99_ns":39423,"p999_ns":108543,"p9999_ns":508100,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 61020 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":22079745,"operations":4000,"operations_per_second":181161,"p50_ns":5439,"p99_ns":6655,"p999_ns":11007,"p9999_ns":21166,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 61224 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24098372,"operations":4000,"operations_per_second":165986,"p50_ns":5439,"p99_ns":9151,"p999_ns":11391,"p9999_ns":1016477,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1503073 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":6115543,"operations":4000,"operations_per_second":654071,"p50_ns":1423,"p99_ns":2143,"p999_ns":10559,"p9999_ns":56380,"overflow":0,"peak_rss_bytes":0}
== round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8910 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35849658,"operations":4000,"operations_per_second":111577,"p50_ns":9215,"p99_ns":12287,"p999_ns":15487,"p9999_ns":17817,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2898 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5738148,"operations":4000,"operations_per_second":697089,"p50_ns":1351,"p99_ns":1951,"p999_ns":9727,"p9999_ns":14852,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2837 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5617814,"operations":4000,"operations_per_second":712020,"p50_ns":1319,"p99_ns":1919,"p999_ns":13247,"p9999_ns":19920,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2826 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5590838,"operations":4000,"operations_per_second":715456,"p50_ns":1311,"p99_ns":2319,"p999_ns":10431,"p9999_ns":14221,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 8895 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35758622,"operations":4000,"operations_per_second":111861,"p50_ns":9151,"p99_ns":11583,"p999_ns":14655,"p9999_ns":28027,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 22885 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5583078,"operations":4000,"operations_per_second":716450,"p50_ns":1327,"p99_ns":1943,"p999_ns":5407,"p9999_ns":6334,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22747 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5334177,"operations":4000,"operations_per_second":749881,"p50_ns":1279,"p99_ns":2111,"p999_ns":4479,"p9999_ns":14561,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22765 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5370080,"operations":4000,"operations_per_second":744867,"p50_ns":1287,"p99_ns":1975,"p999_ns":4607,"p9999_ns":10270,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 8824 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":36674004,"operations":4000,"operations_per_second":109069,"p50_ns":9279,"p99_ns":13503,"p999_ns":15551,"p9999_ns":17922,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 55372 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25086132,"operations":4000,"operations_per_second":159450,"p50_ns":5375,"p99_ns":9023,"p999_ns":352255,"p9999_ns":999867,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 55386 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":21094864,"operations":4000,"operations_per_second":189619,"p50_ns":5183,"p99_ns":9471,"p999_ns":10623,"p9999_ns":14687,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102947 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5659011,"operations":4000,"operations_per_second":706837,"p50_ns":1343,"p99_ns":1959,"p999_ns":5695,"p9999_ns":7250,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 8795 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24674991,"operations":4000,"operations_per_second":162107,"p50_ns":5439,"p99_ns":10111,"p999_ns":14847,"p9999_ns":20776,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 55492 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25291478,"operations":4000,"operations_per_second":158156,"p50_ns":5471,"p99_ns":45055,"p999_ns":77823,"p9999_ns":108699,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 57209 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24967129,"operations":4000,"operations_per_second":160210,"p50_ns":5983,"p99_ns":8959,"p999_ns":53247,"p9999_ns":208599,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1003007 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5975400,"operations":4000,"operations_per_second":669411,"p50_ns":1439,"p99_ns":2079,"p999_ns":6495,"p9999_ns":10361,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 15314 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":39287740,"operations":4000,"operations_per_second":101812,"p50_ns":9663,"p99_ns":14207,"p999_ns":49151,"p9999_ns":166456,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 61385 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26501950,"operations":4000,"operations_per_second":150932,"p50_ns":5567,"p99_ns":47103,"p999_ns":78847,"p9999_ns":84132,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 61503 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24656367,"operations":4000,"operations_per_second":162229,"p50_ns":5535,"p99_ns":23167,"p999_ns":81919,"p9999_ns":97662,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1503258 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":6373225,"operations":4000,"operations_per_second":627625,"p50_ns":1455,"p99_ns":2303,"p999_ns":32383,"p9999_ns":42559,"overflow":0,"peak_rss_bytes":0}
== round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8223 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":33193543,"operations":4000,"operations_per_second":120505,"p50_ns":8063,"p99_ns":9983,"p999_ns":15231,"p9999_ns":17501,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2809 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5556599,"operations":4000,"operations_per_second":719864,"p50_ns":1303,"p99_ns":1935,"p999_ns":8895,"p9999_ns":21597,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2781 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5488857,"operations":4000,"operations_per_second":728749,"p50_ns":1303,"p99_ns":1863,"p999_ns":6271,"p9999_ns":20250,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2823 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5578734,"operations":4000,"operations_per_second":717008,"p50_ns":1327,"p99_ns":1863,"p999_ns":11071,"p9999_ns":18613,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 8498 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34558422,"operations":4000,"operations_per_second":115746,"p50_ns":8511,"p99_ns":12479,"p999_ns":18431,"p9999_ns":35588,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 22913 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5643094,"operations":4000,"operations_per_second":708831,"p50_ns":1343,"p99_ns":1959,"p999_ns":5887,"p9999_ns":6555,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22822 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5476350,"operations":4000,"operations_per_second":730413,"p50_ns":1303,"p99_ns":2191,"p999_ns":5791,"p9999_ns":6319,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22890 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5577816,"operations":4000,"operations_per_second":717126,"p50_ns":1327,"p99_ns":1943,"p999_ns":6143,"p9999_ns":6465,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 8661 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35956090,"operations":4000,"operations_per_second":111246,"p50_ns":9023,"p99_ns":13567,"p999_ns":15295,"p9999_ns":24602,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 55355 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25220548,"operations":4000,"operations_per_second":158600,"p50_ns":5375,"p99_ns":56575,"p999_ns":115199,"p9999_ns":136925,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 55363 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":22074924,"operations":4000,"operations_per_second":181201,"p50_ns":5471,"p99_ns":6655,"p999_ns":11519,"p9999_ns":70470,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102866 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5486806,"operations":4000,"operations_per_second":729021,"p50_ns":1319,"p99_ns":1919,"p999_ns":3935,"p9999_ns":5433,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 8936 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25609554,"operations":4000,"operations_per_second":156191,"p50_ns":5663,"p99_ns":11007,"p999_ns":35583,"p9999_ns":67216,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 55625 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24939296,"operations":4000,"operations_per_second":160389,"p50_ns":5631,"p99_ns":8639,"p999_ns":35071,"p9999_ns":956717,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 57486 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25862376,"operations":4000,"operations_per_second":154664,"p50_ns":6079,"p99_ns":11199,"p999_ns":59135,"p9999_ns":74988,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1003138 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":6155035,"operations":4000,"operations_per_second":649874,"p50_ns":1463,"p99_ns":2431,"p999_ns":6559,"p9999_ns":10696,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 15474 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":39405625,"operations":4000,"operations_per_second":101508,"p50_ns":9727,"p99_ns":14527,"p999_ns":25599,"p9999_ns":73180,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 61301 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24406351,"operations":4000,"operations_per_second":163891,"p50_ns":5567,"p99_ns":7135,"p999_ns":13567,"p9999_ns":919446,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 61505 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":22551101,"operations":4000,"operations_per_second":177374,"p50_ns":5567,"p99_ns":7167,"p999_ns":10687,"p9999_ns":12699,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1502980 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5938057,"operations":4000,"operations_per_second":673621,"p50_ns":1415,"p99_ns":2063,"p999_ns":5375,"p9999_ns":7446,"overflow":0,"peak_rss_bytes":0}
```

### epoll

```text
== epoll, round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 10204 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":37537972,"operations":4000,"operations_per_second":106558,"p50_ns":9855,"p99_ns":12287,"p999_ns":14719,"p9999_ns":16755,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 1902 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3740662,"operations":4000,"operations_per_second":1069329,"p50_ns":811,"p99_ns":1111,"p999_ns":8639,"p9999_ns":10565,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 1818 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3568315,"operations":4000,"operations_per_second":1120977,"p50_ns":799,"p99_ns":1079,"p999_ns":4831,"p9999_ns":19464,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 1772 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3472419,"operations":4000,"operations_per_second":1151934,"p50_ns":791,"p99_ns":1079,"p999_ns":4863,"p9999_ns":8267,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 9398 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35187311,"operations":4000,"operations_per_second":113677,"p50_ns":8639,"p99_ns":10367,"p999_ns":14271,"p9999_ns":163481,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 21937 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3671236,"operations":4000,"operations_per_second":1089551,"p50_ns":811,"p99_ns":1119,"p999_ns":5279,"p9999_ns":5533,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 21846 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3473137,"operations":4000,"operations_per_second":1151696,"p50_ns":791,"p99_ns":1095,"p999_ns":5599,"p9999_ns":6379,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 21808 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3452836,"operations":4000,"operations_per_second":1158467,"p50_ns":799,"p99_ns":1087,"p999_ns":5247,"p9999_ns":5493,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 10584 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":41852551,"operations":4000,"operations_per_second":95573,"p50_ns":9919,"p99_ns":11327,"p999_ns":218111,"p9999_ns":739915,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 57015 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":22134038,"operations":4000,"operations_per_second":180717,"p50_ns":5471,"p99_ns":5983,"p999_ns":17663,"p9999_ns":93781,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 57493 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":22456570,"operations":4000,"operations_per_second":178121,"p50_ns":5535,"p99_ns":6111,"p999_ns":11007,"p9999_ns":179060,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 101937 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3628653,"operations":4000,"operations_per_second":1102337,"p50_ns":823,"p99_ns":1143,"p999_ns":5279,"p9999_ns":6104,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 10833 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":39954651,"operations":4000,"operations_per_second":100113,"p50_ns":9919,"p99_ns":12927,"p999_ns":15231,"p9999_ns":44742,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 57195 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24993245,"operations":4000,"operations_per_second":160043,"p50_ns":5599,"p99_ns":42495,"p999_ns":70143,"p9999_ns":74127,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 57712 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26234431,"operations":4000,"operations_per_second":152471,"p50_ns":5599,"p99_ns":48127,"p999_ns":75263,"p9999_ns":377478,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1001910 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3664674,"operations":4000,"operations_per_second":1091502,"p50_ns":831,"p99_ns":1143,"p999_ns":4895,"p9999_ns":5137,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 17177 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":44517901,"operations":4000,"operations_per_second":89851,"p50_ns":9983,"p99_ns":35583,"p999_ns":82431,"p9999_ns":1394242,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 63732 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":27881560,"operations":4000,"operations_per_second":143463,"p50_ns":5599,"p99_ns":56063,"p999_ns":79871,"p9999_ns":80396,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 64624 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26712385,"operations":4000,"operations_per_second":149743,"p50_ns":5663,"p99_ns":49663,"p999_ns":72703,"p9999_ns":80100,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1501855 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3632238,"operations":4000,"operations_per_second":1101249,"p50_ns":839,"p99_ns":1143,"p999_ns":2463,"p9999_ns":4607,"overflow":0,"peak_rss_bytes":0}
== epoll, round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 10355 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":38480932,"operations":4000,"operations_per_second":103947,"p50_ns":9919,"p99_ns":12415,"p999_ns":14783,"p9999_ns":15448,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2009 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3940285,"operations":4000,"operations_per_second":1015154,"p50_ns":859,"p99_ns":1159,"p999_ns":11007,"p9999_ns":19234,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 1846 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3612282,"operations":4000,"operations_per_second":1107333,"p50_ns":831,"p99_ns":1127,"p999_ns":5471,"p9999_ns":9795,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 1820 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3566569,"operations":4000,"operations_per_second":1121526,"p50_ns":827,"p99_ns":1127,"p999_ns":4671,"p9999_ns":7716,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 10680 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":39008637,"operations":4000,"operations_per_second":102541,"p50_ns":9855,"p99_ns":11199,"p999_ns":14655,"p9999_ns":14727,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 22038 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3881888,"operations":4000,"operations_per_second":1030426,"p50_ns":847,"p99_ns":1175,"p999_ns":4991,"p9999_ns":5543,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 21924 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3633482,"operations":4000,"operations_per_second":1100872,"p50_ns":823,"p99_ns":1127,"p999_ns":5343,"p9999_ns":6349,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 21916 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3606056,"operations":4000,"operations_per_second":1109245,"p50_ns":827,"p99_ns":1127,"p999_ns":4543,"p9999_ns":5028,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 11569 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":58620729,"operations":4000,"operations_per_second":68235,"p50_ns":10111,"p99_ns":67583,"p999_ns":120831,"p9999_ns":381154,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 57070 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":21932200,"operations":4000,"operations_per_second":182380,"p50_ns":5471,"p99_ns":5919,"p999_ns":6175,"p9999_ns":7937,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 57465 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":22110780,"operations":4000,"operations_per_second":180907,"p50_ns":5535,"p99_ns":5919,"p999_ns":6079,"p9999_ns":6094,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 101962 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3683751,"operations":4000,"operations_per_second":1085849,"p50_ns":831,"p99_ns":1151,"p999_ns":5247,"p9999_ns":5603,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 11205 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":43290740,"operations":4000,"operations_per_second":92398,"p50_ns":10111,"p99_ns":36607,"p999_ns":89599,"p9999_ns":245415,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 57315 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":23767661,"operations":4000,"operations_per_second":168295,"p50_ns":5663,"p99_ns":10175,"p999_ns":72191,"p9999_ns":79259,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 57589 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":23755259,"operations":4000,"operations_per_second":168383,"p50_ns":5567,"p99_ns":10111,"p999_ns":75263,"p9999_ns":77647,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1001962 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3782262,"operations":4000,"operations_per_second":1057568,"p50_ns":847,"p99_ns":1159,"p999_ns":4447,"p9999_ns":30531,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 17395 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":41618268,"operations":4000,"operations_per_second":96111,"p50_ns":10175,"p99_ns":14975,"p999_ns":63231,"p9999_ns":69575,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 63566 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":22669929,"operations":4000,"operations_per_second":176445,"p50_ns":5631,"p99_ns":6719,"p999_ns":10943,"p9999_ns":55458,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 64248 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24869382,"operations":4000,"operations_per_second":160840,"p50_ns":5567,"p99_ns":10623,"p999_ns":78335,"p9999_ns":575407,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1501879 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3689493,"operations":4000,"operations_per_second":1084159,"p50_ns":839,"p99_ns":1143,"p999_ns":5023,"p9999_ns":9194,"overflow":0,"peak_rss_bytes":0}
== epoll, round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 10077 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":37405025,"operations":4000,"operations_per_second":106937,"p50_ns":9791,"p99_ns":11135,"p999_ns":15295,"p9999_ns":20065,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 1944 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3823621,"operations":4000,"operations_per_second":1046128,"p50_ns":843,"p99_ns":1167,"p999_ns":9727,"p9999_ns":11868,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 1814 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3556097,"operations":4000,"operations_per_second":1124828,"p50_ns":819,"p99_ns":1111,"p999_ns":6879,"p9999_ns":9414,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 1804 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3538238,"operations":4000,"operations_per_second":1130506,"p50_ns":823,"p99_ns":1119,"p999_ns":4703,"p9999_ns":16304,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 9926 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":36621728,"operations":4000,"operations_per_second":109224,"p50_ns":9599,"p99_ns":10495,"p999_ns":14015,"p9999_ns":19840,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 21970 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3742801,"operations":4000,"operations_per_second":1068718,"p50_ns":819,"p99_ns":1127,"p999_ns":5343,"p9999_ns":14487,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 21848 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3496495,"operations":4000,"operations_per_second":1144002,"p50_ns":803,"p99_ns":1095,"p999_ns":5695,"p9999_ns":9414,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 21829 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3483702,"operations":4000,"operations_per_second":1148203,"p50_ns":807,"p99_ns":1103,"p999_ns":4287,"p9999_ns":5778,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 11138 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":53729507,"operations":4000,"operations_per_second":74446,"p50_ns":9983,"p99_ns":67583,"p999_ns":114175,"p9999_ns":143982,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 57023 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":21941486,"operations":4000,"operations_per_second":182303,"p50_ns":5471,"p99_ns":5887,"p999_ns":6335,"p9999_ns":43931,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 57344 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":21760053,"operations":4000,"operations_per_second":183823,"p50_ns":5439,"p99_ns":5823,"p999_ns":5983,"p9999_ns":6139,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 101895 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3590616,"operations":4000,"operations_per_second":1114014,"p50_ns":823,"p99_ns":1127,"p999_ns":4735,"p9999_ns":5608,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 10960 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":41057675,"operations":4000,"operations_per_second":97423,"p50_ns":9983,"p99_ns":13951,"p999_ns":46847,"p9999_ns":346627,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 57398 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25038722,"operations":4000,"operations_per_second":159752,"p50_ns":5663,"p99_ns":21375,"p999_ns":80895,"p9999_ns":87406,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 57554 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":22591711,"operations":4000,"operations_per_second":177056,"p50_ns":5535,"p99_ns":7167,"p999_ns":48639,"p9999_ns":54021,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1001827 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3579644,"operations":4000,"operations_per_second":1117429,"p50_ns":823,"p99_ns":1151,"p999_ns":4287,"p9999_ns":6405,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 16999 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":40660866,"operations":4000,"operations_per_second":98374,"p50_ns":9919,"p99_ns":14975,"p999_ns":58367,"p9999_ns":92910,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 63399 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":22801362,"operations":4000,"operations_per_second":175428,"p50_ns":5567,"p99_ns":7231,"p999_ns":54527,"p9999_ns":72244,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 64177 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24759970,"operations":4000,"operations_per_second":161551,"p50_ns":5535,"p99_ns":32255,"p999_ns":66047,"p9999_ns":77186,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1501824 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3628430,"operations":4000,"operations_per_second":1102405,"p50_ns":827,"p99_ns":1135,"p999_ns":5247,"p9999_ns":5328,"overflow":0,"peak_rss_bytes":0}
```

## Run 3: AMD EPYC 9V74 80-Core Processor, CI run 36063960479

### io_uring

```text
model name	: AMD EPYC 9V74 80-Core Processor
4
6.17.0-1022-azure
MemTotal:       16373444 kB
== round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 10679 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":42635899,"operations":4000,"operations_per_second":93817,"p50_ns":10815,"p99_ns":23679,"p999_ns":37631,"p9999_ns":41127,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4306 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8543070,"operations":4000,"operations_per_second":468215,"p50_ns":2007,"p99_ns":2911,"p999_ns":14719,"p9999_ns":19389,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4237 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8409043,"operations":4000,"operations_per_second":475678,"p50_ns":1975,"p99_ns":2879,"p999_ns":14335,"p9999_ns":27937,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4213 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8364699,"operations":4000,"operations_per_second":478200,"p50_ns":1959,"p99_ns":2911,"p999_ns":15935,"p9999_ns":33465,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 10888 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":39659917,"operations":4000,"operations_per_second":100857,"p50_ns":10111,"p99_ns":14335,"p999_ns":15999,"p9999_ns":16465,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24426 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8497566,"operations":4000,"operations_per_second":470723,"p50_ns":2023,"p99_ns":2991,"p999_ns":4319,"p9999_ns":21592,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24386 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8390130,"operations":4000,"operations_per_second":476750,"p50_ns":1991,"p99_ns":3359,"p999_ns":7263,"p9999_ns":7867,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24398 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8370375,"operations":4000,"operations_per_second":477875,"p50_ns":1975,"p99_ns":3503,"p999_ns":7743,"p9999_ns":12168,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 11107 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":41877195,"operations":4000,"operations_per_second":95517,"p50_ns":10559,"p99_ns":15615,"p999_ns":16767,"p9999_ns":18643,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 56107 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24325856,"operations":4000,"operations_per_second":164434,"p50_ns":5983,"p99_ns":8703,"p999_ns":24319,"p9999_ns":68498,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 56409 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24143240,"operations":4000,"operations_per_second":165677,"p50_ns":5919,"p99_ns":7647,"p999_ns":12927,"p9999_ns":23490,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 104492 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8680557,"operations":4000,"operations_per_second":460799,"p50_ns":2023,"p99_ns":3535,"p999_ns":7775,"p9999_ns":12213,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 11328 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":30570513,"operations":4000,"operations_per_second":130845,"p50_ns":7487,"p99_ns":13631,"p999_ns":21247,"p9999_ns":30115,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 56936 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":28489877,"operations":4000,"operations_per_second":140400,"p50_ns":6751,"p99_ns":9983,"p999_ns":12735,"p9999_ns":228584,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 57085 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":32305607,"operations":4000,"operations_per_second":123817,"p50_ns":7903,"p99_ns":10815,"p999_ns":30719,"p9999_ns":184858,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1005656 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10947546,"operations":4000,"operations_per_second":365378,"p50_ns":2399,"p99_ns":8639,"p999_ns":38655,"p9999_ns":49244,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 18710 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":45530818,"operations":4000,"operations_per_second":87852,"p50_ns":11199,"p99_ns":17023,"p999_ns":29055,"p9999_ns":62093,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 63512 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":29107453,"operations":4000,"operations_per_second":137421,"p50_ns":6623,"p99_ns":22271,"p999_ns":76799,"p9999_ns":85889,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 63599 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":28262577,"operations":4000,"operations_per_second":141529,"p50_ns":6687,"p99_ns":11647,"p999_ns":70655,"p9999_ns":90501,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1505334 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10655746,"operations":4000,"operations_per_second":375384,"p50_ns":2463,"p99_ns":5887,"p999_ns":11903,"p9999_ns":36625,"overflow":0,"peak_rss_bytes":0}
== round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9891 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35866951,"operations":4000,"operations_per_second":111523,"p50_ns":8447,"p99_ns":13439,"p999_ns":16895,"p9999_ns":30811,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4305 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8529540,"operations":4000,"operations_per_second":468958,"p50_ns":2007,"p99_ns":2911,"p999_ns":11071,"p9999_ns":29038,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4224 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8366646,"operations":4000,"operations_per_second":478088,"p50_ns":1967,"p99_ns":2863,"p999_ns":11775,"p9999_ns":15849,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4221 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8358398,"operations":4000,"operations_per_second":478560,"p50_ns":1967,"p99_ns":3439,"p999_ns":8127,"p9999_ns":32259,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 10250 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":37248021,"operations":4000,"operations_per_second":107388,"p50_ns":9855,"p99_ns":15039,"p999_ns":16255,"p9999_ns":20721,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24398 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8469127,"operations":4000,"operations_per_second":472303,"p50_ns":2023,"p99_ns":3407,"p999_ns":6943,"p9999_ns":7251,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24435 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8506401,"operations":4000,"operations_per_second":470234,"p50_ns":1999,"p99_ns":3199,"p999_ns":8383,"p9999_ns":36660,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24391 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8372942,"operations":4000,"operations_per_second":477729,"p50_ns":1983,"p99_ns":3455,"p999_ns":7839,"p9999_ns":8523,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 11357 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":41906875,"operations":4000,"operations_per_second":95449,"p50_ns":10495,"p99_ns":15487,"p999_ns":18303,"p9999_ns":20040,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 56118 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24396316,"operations":4000,"operations_per_second":163959,"p50_ns":5919,"p99_ns":8319,"p999_ns":15807,"p9999_ns":180672,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 56375 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24156984,"operations":4000,"operations_per_second":165583,"p50_ns":5919,"p99_ns":7775,"p999_ns":11883,"p9999_ns":11883,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 104456 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8673608,"operations":4000,"operations_per_second":461169,"p50_ns":2039,"p99_ns":3663,"p999_ns":7615,"p9999_ns":7951,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 11099 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":30203919,"operations":4000,"operations_per_second":132433,"p50_ns":6847,"p99_ns":13631,"p999_ns":23167,"p9999_ns":43215,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 56984 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":28035596,"operations":4000,"operations_per_second":142675,"p50_ns":6719,"p99_ns":10367,"p999_ns":42239,"p9999_ns":44171,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 57053 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":31998947,"operations":4000,"operations_per_second":125004,"p50_ns":7839,"p99_ns":11199,"p999_ns":46591,"p9999_ns":124187,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1005082 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10134140,"operations":4000,"operations_per_second":394705,"p50_ns":2367,"p99_ns":5055,"p999_ns":9855,"p9999_ns":13435,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 18724 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":44965809,"operations":4000,"operations_per_second":88956,"p50_ns":11071,"p99_ns":16191,"p999_ns":20735,"p9999_ns":21051,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 63417 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":28029626,"operations":4000,"operations_per_second":142706,"p50_ns":6655,"p99_ns":10239,"p999_ns":13503,"p9999_ns":323237,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 63513 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":33041461,"operations":4000,"operations_per_second":121060,"p50_ns":6591,"p99_ns":10367,"p999_ns":16191,"p9999_ns":1784740,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1505515 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10964774,"operations":4000,"operations_per_second":364804,"p50_ns":2447,"p99_ns":6591,"p999_ns":31999,"p9999_ns":55969,"overflow":0,"peak_rss_bytes":0}
== round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9824 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35667315,"operations":4000,"operations_per_second":112147,"p50_ns":8767,"p99_ns":13503,"p999_ns":16895,"p9999_ns":45719,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4294 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8517021,"operations":4000,"operations_per_second":469647,"p50_ns":2015,"p99_ns":2959,"p999_ns":15295,"p9999_ns":23525,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4217 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8365395,"operations":4000,"operations_per_second":478160,"p50_ns":1967,"p99_ns":2879,"p999_ns":15551,"p9999_ns":22449,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4216 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8411717,"operations":4000,"operations_per_second":475527,"p50_ns":1975,"p99_ns":3391,"p999_ns":9407,"p9999_ns":52644,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 9381 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35789887,"operations":4000,"operations_per_second":111763,"p50_ns":8959,"p99_ns":14783,"p999_ns":20223,"p9999_ns":183827,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24394 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8465774,"operations":4000,"operations_per_second":472490,"p50_ns":2023,"p99_ns":3023,"p999_ns":4351,"p9999_ns":6980,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 25275 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10200311,"operations":4000,"operations_per_second":392144,"p50_ns":1991,"p99_ns":14719,"p999_ns":56319,"p9999_ns":96004,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24406 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8348850,"operations":4000,"operations_per_second":479107,"p50_ns":1983,"p99_ns":3263,"p999_ns":7359,"p9999_ns":8217,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 11094 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":42472241,"operations":4000,"operations_per_second":94179,"p50_ns":10303,"p99_ns":16639,"p999_ns":70143,"p9999_ns":79324,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 56061 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":23786793,"operations":4000,"operations_per_second":168160,"p50_ns":5855,"p99_ns":7391,"p999_ns":12287,"p9999_ns":52849,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 56304 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":23921032,"operations":4000,"operations_per_second":167216,"p50_ns":5855,"p99_ns":7487,"p999_ns":12223,"p9999_ns":31352,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 104426 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8631360,"operations":4000,"operations_per_second":463426,"p50_ns":2023,"p99_ns":3503,"p999_ns":7711,"p9999_ns":10876,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 10812 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":29811268,"operations":4000,"operations_per_second":134177,"p50_ns":6751,"p99_ns":13631,"p999_ns":40959,"p9999_ns":70867,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 56865 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":27441791,"operations":4000,"operations_per_second":145763,"p50_ns":6655,"p99_ns":10495,"p999_ns":15167,"p9999_ns":16519,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 57053 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":31333216,"operations":4000,"operations_per_second":127660,"p50_ns":7775,"p99_ns":10623,"p999_ns":15551,"p9999_ns":20170,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1005089 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10134396,"operations":4000,"operations_per_second":394695,"p50_ns":2383,"p99_ns":4863,"p999_ns":7423,"p9999_ns":12328,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 18238 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":45269673,"operations":4000,"operations_per_second":88359,"p50_ns":11007,"p99_ns":16255,"p999_ns":19199,"p9999_ns":462357,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 63184 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26846271,"operations":4000,"operations_per_second":148996,"p50_ns":6527,"p99_ns":9535,"p999_ns":12287,"p9999_ns":17075,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 63442 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":29888976,"operations":4000,"operations_per_second":133828,"p50_ns":6559,"p99_ns":40703,"p999_ns":85503,"p9999_ns":135113,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1505202 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10355669,"operations":4000,"operations_per_second":386261,"p50_ns":2431,"p99_ns":4991,"p999_ns":7295,"p9999_ns":9704,"overflow":0,"peak_rss_bytes":0}
```

### epoll

```text
== epoll, round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 11753 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":40160400,"operations":4000,"operations_per_second":99600,"p50_ns":10367,"p99_ns":13503,"p999_ns":16319,"p9999_ns":22829,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2290 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4494447,"operations":4000,"operations_per_second":889987,"p50_ns":1019,"p99_ns":1359,"p999_ns":10879,"p9999_ns":16790,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2178 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4659735,"operations":4000,"operations_per_second":858417,"p50_ns":987,"p99_ns":1319,"p999_ns":7199,"p9999_ns":203286,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2175 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4273631,"operations":4000,"operations_per_second":935972,"p50_ns":987,"p99_ns":1319,"p999_ns":9983,"p9999_ns":13861,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 11894 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":40897444,"operations":4000,"operations_per_second":97805,"p50_ns":10623,"p99_ns":12287,"p999_ns":18047,"p9999_ns":33996,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 22389 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4507857,"operations":4000,"operations_per_second":887339,"p50_ns":1019,"p99_ns":1399,"p999_ns":6335,"p9999_ns":6665,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22273 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4257840,"operations":4000,"operations_per_second":939443,"p50_ns":987,"p99_ns":1327,"p999_ns":4287,"p9999_ns":18548,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22546 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4220984,"operations":4000,"operations_per_second":947646,"p50_ns":987,"p99_ns":1327,"p999_ns":2655,"p9999_ns":4081,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 12940 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":48826715,"operations":4000,"operations_per_second":81922,"p50_ns":11007,"p99_ns":16639,"p999_ns":72191,"p9999_ns":1969113,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 58292 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":23302371,"operations":4000,"operations_per_second":171656,"p50_ns":5791,"p99_ns":6847,"p999_ns":11263,"p9999_ns":11527,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 58810 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":23439621,"operations":4000,"operations_per_second":170651,"p50_ns":5823,"p99_ns":6847,"p999_ns":11583,"p9999_ns":23315,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102294 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4304372,"operations":4000,"operations_per_second":929287,"p50_ns":987,"p99_ns":1375,"p999_ns":6239,"p9999_ns":7040,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 13677 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":47082580,"operations":4000,"operations_per_second":84957,"p50_ns":11647,"p99_ns":17151,"p999_ns":19967,"p9999_ns":22463,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 58926 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":27026620,"operations":4000,"operations_per_second":148002,"p50_ns":6463,"p99_ns":8575,"p999_ns":12991,"p9999_ns":286376,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 59474 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26611663,"operations":4000,"operations_per_second":150310,"p50_ns":6527,"p99_ns":8575,"p999_ns":12415,"p9999_ns":13104,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1002391 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4678317,"operations":4000,"operations_per_second":855008,"p50_ns":1079,"p99_ns":1575,"p999_ns":5503,"p9999_ns":6870,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 20850 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":48462863,"operations":4000,"operations_per_second":82537,"p50_ns":11519,"p99_ns":25599,"p999_ns":103935,"p9999_ns":162600,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 66241 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26781608,"operations":4000,"operations_per_second":149356,"p50_ns":6399,"p99_ns":8639,"p999_ns":71679,"p9999_ns":122740,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 66839 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":33507046,"operations":4000,"operations_per_second":119377,"p50_ns":6271,"p99_ns":53247,"p999_ns":79359,"p9999_ns":2382411,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1502381 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4738948,"operations":4000,"operations_per_second":844069,"p50_ns":1103,"p99_ns":1615,"p999_ns":5183,"p9999_ns":6034,"overflow":0,"peak_rss_bytes":0}
== epoll, round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12546 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":43533903,"operations":4000,"operations_per_second":91882,"p50_ns":10943,"p99_ns":15807,"p999_ns":55295,"p9999_ns":68773,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2264 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4461978,"operations":4000,"operations_per_second":896463,"p50_ns":1019,"p99_ns":1367,"p999_ns":6527,"p9999_ns":13815,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2157 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4240689,"operations":4000,"operations_per_second":943242,"p50_ns":987,"p99_ns":1319,"p999_ns":6559,"p9999_ns":10806,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2163 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4227638,"operations":4000,"operations_per_second":946154,"p50_ns":987,"p99_ns":1319,"p999_ns":5759,"p9999_ns":8408,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 14026 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":55211593,"operations":4000,"operations_per_second":72448,"p50_ns":10495,"p99_ns":67583,"p999_ns":77823,"p9999_ns":87291,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 22328 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4454886,"operations":4000,"operations_per_second":897890,"p50_ns":1019,"p99_ns":1367,"p999_ns":5375,"p9999_ns":5994,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22239 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4246376,"operations":4000,"operations_per_second":941979,"p50_ns":987,"p99_ns":1327,"p999_ns":3359,"p9999_ns":5663,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22228 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4233010,"operations":4000,"operations_per_second":944954,"p50_ns":987,"p99_ns":1319,"p999_ns":2175,"p9999_ns":3125,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 12913 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":44260200,"operations":4000,"operations_per_second":90374,"p50_ns":11007,"p99_ns":15871,"p999_ns":17279,"p9999_ns":21657,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 58208 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":23103195,"operations":4000,"operations_per_second":173136,"p50_ns":5759,"p99_ns":6623,"p999_ns":11263,"p9999_ns":13350,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 58544 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":22674010,"operations":4000,"operations_per_second":176413,"p50_ns":5599,"p99_ns":6527,"p999_ns":10623,"p9999_ns":10731,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102294 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4303138,"operations":4000,"operations_per_second":929554,"p50_ns":987,"p99_ns":1383,"p999_ns":5919,"p9999_ns":7486,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 13568 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":47046621,"operations":4000,"operations_per_second":85022,"p50_ns":11583,"p99_ns":17023,"p999_ns":48383,"p9999_ns":73981,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 58855 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":30983984,"operations":4000,"operations_per_second":129098,"p50_ns":6367,"p99_ns":10879,"p999_ns":147455,"p9999_ns":1987396,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 59355 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26118597,"operations":4000,"operations_per_second":153147,"p50_ns":6367,"p99_ns":8511,"p999_ns":11967,"p9999_ns":63846,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1002428 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4702892,"operations":4000,"operations_per_second":850540,"p50_ns":1087,"p99_ns":1583,"p999_ns":5183,"p9999_ns":5553,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 20308 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":45004819,"operations":4000,"operations_per_second":88879,"p50_ns":11263,"p99_ns":14079,"p999_ns":17791,"p9999_ns":49945,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 65793 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25424849,"operations":4000,"operations_per_second":157326,"p50_ns":6271,"p99_ns":7967,"p999_ns":14079,"p9999_ns":24161,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 66807 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25611815,"operations":4000,"operations_per_second":156177,"p50_ns":6303,"p99_ns":8159,"p999_ns":11583,"p9999_ns":18873,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1502394 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4807388,"operations":4000,"operations_per_second":832052,"p50_ns":1103,"p99_ns":1599,"p999_ns":5951,"p9999_ns":24126,"overflow":0,"peak_rss_bytes":0}
== epoll, round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12048 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":40368725,"operations":4000,"operations_per_second":99086,"p50_ns":10751,"p99_ns":13119,"p999_ns":17279,"p9999_ns":22809,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2276 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4483620,"operations":4000,"operations_per_second":892136,"p50_ns":1019,"p99_ns":1367,"p999_ns":7327,"p9999_ns":12499,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2162 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4256110,"operations":4000,"operations_per_second":939825,"p50_ns":987,"p99_ns":1319,"p999_ns":5375,"p9999_ns":14602,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2164 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4261599,"operations":4000,"operations_per_second":938614,"p50_ns":987,"p99_ns":1319,"p999_ns":7103,"p9999_ns":14101,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 12208 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":41184059,"operations":4000,"operations_per_second":97124,"p50_ns":10559,"p99_ns":14719,"p999_ns":30847,"p9999_ns":39589,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 22403 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4577154,"operations":4000,"operations_per_second":873905,"p50_ns":1019,"p99_ns":1367,"p999_ns":6303,"p9999_ns":32539,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22248 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4217385,"operations":4000,"operations_per_second":948455,"p50_ns":987,"p99_ns":1319,"p999_ns":1951,"p9999_ns":3565,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22233 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4262134,"operations":4000,"operations_per_second":938497,"p50_ns":987,"p99_ns":1319,"p999_ns":2879,"p9999_ns":11767,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 12930 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":44608424,"operations":4000,"operations_per_second":89669,"p50_ns":10943,"p99_ns":16383,"p999_ns":61183,"p9999_ns":70346,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 58536 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":44227471,"operations":4000,"operations_per_second":90441,"p50_ns":5759,"p99_ns":93695,"p999_ns":149503,"p9999_ns":190597,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 58540 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":22620447,"operations":4000,"operations_per_second":176831,"p50_ns":5599,"p99_ns":6495,"p999_ns":10879,"p9999_ns":11722,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102288 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4307067,"operations":4000,"operations_per_second":928706,"p50_ns":991,"p99_ns":1399,"p999_ns":5535,"p9999_ns":6189,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 13526 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":46669982,"operations":4000,"operations_per_second":85708,"p50_ns":11519,"p99_ns":16639,"p999_ns":70655,"p9999_ns":78243,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 58842 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26071899,"operations":4000,"operations_per_second":153421,"p50_ns":6367,"p99_ns":8959,"p999_ns":12607,"p9999_ns":15283,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 59178 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25942606,"operations":4000,"operations_per_second":154186,"p50_ns":6335,"p99_ns":8383,"p999_ns":12415,"p9999_ns":12764,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1002402 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4672348,"operations":4000,"operations_per_second":856100,"p50_ns":1079,"p99_ns":1543,"p999_ns":4959,"p9999_ns":6324,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 20427 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":45584556,"operations":4000,"operations_per_second":87749,"p50_ns":11391,"p99_ns":15487,"p999_ns":18687,"p9999_ns":22634,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 66085 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":27922249,"operations":4000,"operations_per_second":143254,"p50_ns":6335,"p99_ns":36607,"p999_ns":62463,"p9999_ns":65138,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 66760 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25704664,"operations":4000,"operations_per_second":155613,"p50_ns":6239,"p99_ns":8511,"p999_ns":24447,"p9999_ns":66330,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1502405 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4723428,"operations":4000,"operations_per_second":846842,"p50_ns":1095,"p99_ns":1607,"p999_ns":5663,"p9999_ns":6450,"overflow":0,"peak_rss_bytes":0}
```
