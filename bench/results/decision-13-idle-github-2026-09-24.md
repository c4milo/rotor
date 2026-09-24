# Decision 13's idle case on `github`, 2026-09-24

`rotor_post` from commit `dcc95fb`, on io_uring, in the CI job `costs`, which was started by hand
three times. Each start got its own GitHub-hosted `ubuntu-24.04` runner with a different processor.
For each gap before a ping (0, 20, 100 and 1,000 µs) the job ran the three modes in turn, 2,000 round
trips each after 200 not measured, and did that three times. Each `rotor_post:` line gives the CPU
time the answering loop used per round trip. The JSON line after it is the run's result: its
histogram holds half a round trip, so its `p50_ns` is one message. Decision 13's results section
reads them.

## Run 1: INTEL(R) XEON(R) PLATINUM 8573C, CI run 36020002652

```text
== round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 7235 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":47254349,"operations":4000,"operations_per_second":84648,"p50_ns":11519,"p99_ns":18303,"p999_ns":22527,"p9999_ns":28293,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 3004 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5936097,"operations":4000,"operations_per_second":673843,"p50_ns":1399,"p99_ns":2175,"p999_ns":8831,"p9999_ns":29639,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2698 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5312027,"operations":4000,"operations_per_second":753008,"p50_ns":1255,"p99_ns":2015,"p999_ns":6335,"p9999_ns":11624,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 6842 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":32416688,"operations":4000,"operations_per_second":123393,"p50_ns":8063,"p99_ns":11071,"p999_ns":13631,"p9999_ns":24355,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 23033 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5779646,"operations":4000,"operations_per_second":692083,"p50_ns":1391,"p99_ns":2191,"p999_ns":6463,"p9999_ns":8138,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22848 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5465114,"operations":4000,"operations_per_second":731915,"p50_ns":1287,"p99_ns":1991,"p999_ns":5887,"p9999_ns":6692,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 7702 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":38590501,"operations":4000,"operations_per_second":103652,"p50_ns":9535,"p99_ns":16383,"p999_ns":20991,"p9999_ns":21751,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 54907 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":23810594,"operations":4000,"operations_per_second":167992,"p50_ns":5855,"p99_ns":8639,"p999_ns":11967,"p9999_ns":19953,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102923 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5545521,"operations":4000,"operations_per_second":721302,"p50_ns":1287,"p99_ns":2431,"p999_ns":5791,"p9999_ns":7007,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 10284 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":29922044,"operations":4000,"operations_per_second":133680,"p50_ns":7391,"p99_ns":11967,"p999_ns":17535,"p9999_ns":21316,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 55403 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25454627,"operations":4000,"operations_per_second":157142,"p50_ns":6239,"p99_ns":9023,"p999_ns":14463,"p9999_ns":32433,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1003267 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":6239785,"operations":4000,"operations_per_second":641047,"p50_ns":1471,"p99_ns":2479,"p999_ns":5791,"p9999_ns":7031,"overflow":0,"peak_rss_bytes":0}
== round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 6405 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":31820366,"operations":4000,"operations_per_second":125705,"p50_ns":7935,"p99_ns":11327,"p999_ns":15615,"p9999_ns":74982,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2782 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5485827,"operations":4000,"operations_per_second":729151,"p50_ns":1279,"p99_ns":1911,"p999_ns":8703,"p9999_ns":16932,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2705 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5353655,"operations":4000,"operations_per_second":747153,"p50_ns":1255,"p99_ns":2047,"p999_ns":6751,"p9999_ns":14285,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 6613 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":32501247,"operations":4000,"operations_per_second":123072,"p50_ns":8095,"p99_ns":11327,"p999_ns":15807,"p9999_ns":16351,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 22997 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5712224,"operations":4000,"operations_per_second":700252,"p50_ns":1327,"p99_ns":2287,"p999_ns":6079,"p9999_ns":18418,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22893 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5523177,"operations":4000,"operations_per_second":724220,"p50_ns":1311,"p99_ns":2159,"p999_ns":5279,"p9999_ns":6739,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 7884 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":36930011,"operations":4000,"operations_per_second":108312,"p50_ns":9023,"p99_ns":14399,"p999_ns":20735,"p9999_ns":163595,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 54716 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":23622820,"operations":4000,"operations_per_second":169327,"p50_ns":5855,"p99_ns":9087,"p999_ns":12991,"p9999_ns":24732,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102935 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5546472,"operations":4000,"operations_per_second":721179,"p50_ns":1287,"p99_ns":2239,"p999_ns":6175,"p9999_ns":6549,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 10006 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":29449587,"operations":4000,"operations_per_second":135825,"p50_ns":7263,"p99_ns":12031,"p999_ns":18559,"p9999_ns":49393,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 55353 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25182075,"operations":4000,"operations_per_second":158843,"p50_ns":6207,"p99_ns":9343,"p999_ns":11903,"p9999_ns":14458,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1003348 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":6394789,"operations":4000,"operations_per_second":625509,"p50_ns":1495,"p99_ns":2703,"p999_ns":5823,"p9999_ns":6800,"overflow":0,"peak_rss_bytes":0}
== round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 6309 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":30656333,"operations":4000,"operations_per_second":130478,"p50_ns":7647,"p99_ns":10687,"p999_ns":15935,"p9999_ns":21636,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2776 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5493575,"operations":4000,"operations_per_second":728123,"p50_ns":1287,"p99_ns":1991,"p999_ns":9727,"p9999_ns":28714,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2797 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5536753,"operations":4000,"operations_per_second":722445,"p50_ns":1271,"p99_ns":1959,"p999_ns":17279,"p9999_ns":18419,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 6663 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34115548,"operations":4000,"operations_per_second":117248,"p50_ns":8191,"p99_ns":15615,"p999_ns":19071,"p9999_ns":197645,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 22858 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5484998,"operations":4000,"operations_per_second":729261,"p50_ns":1279,"p99_ns":2095,"p999_ns":7935,"p9999_ns":24769,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22766 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5310015,"operations":4000,"operations_per_second":753293,"p50_ns":1263,"p99_ns":2175,"p999_ns":4063,"p9999_ns":5206,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 7961 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":37173690,"operations":4000,"operations_per_second":107602,"p50_ns":9151,"p99_ns":15039,"p999_ns":19199,"p9999_ns":21806,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 54795 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":23626682,"operations":4000,"operations_per_second":169300,"p50_ns":5855,"p99_ns":9983,"p999_ns":15807,"p9999_ns":33955,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102911 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5718496,"operations":4000,"operations_per_second":699484,"p50_ns":1303,"p99_ns":2255,"p999_ns":6303,"p9999_ns":73973,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 10348 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":30575745,"operations":4000,"operations_per_second":130822,"p50_ns":7487,"p99_ns":11519,"p999_ns":18047,"p9999_ns":85669,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 55362 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25944190,"operations":4000,"operations_per_second":154177,"p50_ns":6175,"p99_ns":10367,"p999_ns":40959,"p9999_ns":234213,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1003310 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":6322697,"operations":4000,"operations_per_second":632641,"p50_ns":1495,"p99_ns":2543,"p999_ns":5471,"p9999_ns":5925,"overflow":0,"peak_rss_bytes":0}
```

## Run 2: AMD EPYC 7763 64-Core Processor, CI run 36020013371

```text
== round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13124 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":55900097,"operations":4000,"operations_per_second":71556,"p50_ns":12287,"p99_ns":20991,"p999_ns":28799,"p9999_ns":35612,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4577 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9060752,"operations":4000,"operations_per_second":441464,"p50_ns":2127,"p99_ns":3327,"p999_ns":12543,"p9999_ns":25688,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4435 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8740869,"operations":4000,"operations_per_second":457620,"p50_ns":2063,"p99_ns":3535,"p999_ns":13887,"p9999_ns":31915,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 14163 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":58448268,"operations":4000,"operations_per_second":68436,"p50_ns":16127,"p99_ns":19711,"p999_ns":22911,"p9999_ns":49738,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24715 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9143549,"operations":4000,"operations_per_second":437466,"p50_ns":2127,"p99_ns":8383,"p999_ns":11071,"p9999_ns":12573,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24445 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8627631,"operations":4000,"operations_per_second":463626,"p50_ns":2063,"p99_ns":3007,"p999_ns":8575,"p9999_ns":10564,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 17252 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":65330466,"operations":4000,"operations_per_second":61227,"p50_ns":16383,"p99_ns":19199,"p999_ns":26623,"p9999_ns":27146,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 59731 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34757909,"operations":4000,"operations_per_second":115081,"p50_ns":8639,"p99_ns":12287,"p999_ns":17791,"p9999_ns":45871,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 104711 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9063270,"operations":4000,"operations_per_second":441341,"p50_ns":2079,"p99_ns":8191,"p999_ns":10239,"p9999_ns":17262,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20966 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":67889059,"operations":4000,"operations_per_second":58919,"p50_ns":14335,"p99_ns":18815,"p999_ns":244735,"p9999_ns":2996511,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 60675 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":38168108,"operations":4000,"operations_per_second":104799,"p50_ns":9279,"p99_ns":13823,"p999_ns":16511,"p9999_ns":165771,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004891 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9658853,"operations":4000,"operations_per_second":414127,"p50_ns":2271,"p99_ns":4079,"p999_ns":10943,"p9999_ns":13104,"overflow":0,"peak_rss_bytes":0}
== round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 10918 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":51341927,"operations":4000,"operations_per_second":77909,"p50_ns":11263,"p99_ns":19967,"p999_ns":24703,"p9999_ns":26049,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4582 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9079823,"operations":4000,"operations_per_second":440537,"p50_ns":2127,"p99_ns":3247,"p999_ns":17023,"p9999_ns":25603,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4407 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8740340,"operations":4000,"operations_per_second":457648,"p50_ns":2047,"p99_ns":3055,"p999_ns":12991,"p9999_ns":34014,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 16871 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":63852359,"operations":4000,"operations_per_second":62644,"p50_ns":16127,"p99_ns":19199,"p999_ns":21503,"p9999_ns":23679,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24658 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9043302,"operations":4000,"operations_per_second":442316,"p50_ns":2127,"p99_ns":4031,"p999_ns":10047,"p9999_ns":11120,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24435 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8602107,"operations":4000,"operations_per_second":465002,"p50_ns":2063,"p99_ns":2927,"p999_ns":6079,"p9999_ns":11216,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 17190 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":70292004,"operations":4000,"operations_per_second":56905,"p50_ns":16383,"p99_ns":21759,"p999_ns":79359,"p9999_ns":2051813,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 59949 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35166382,"operations":4000,"operations_per_second":113744,"p50_ns":8703,"p99_ns":11903,"p999_ns":14719,"p9999_ns":16787,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 104686 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8989888,"operations":4000,"operations_per_second":444944,"p50_ns":2063,"p99_ns":8255,"p999_ns":9599,"p9999_ns":9939,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20962 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":56095412,"operations":4000,"operations_per_second":71307,"p50_ns":14399,"p99_ns":18943,"p999_ns":25471,"p9999_ns":27596,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 60686 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":38127660,"operations":4000,"operations_per_second":104910,"p50_ns":9279,"p99_ns":14399,"p999_ns":18559,"p9999_ns":78482,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004855 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9588462,"operations":4000,"operations_per_second":417168,"p50_ns":2271,"p99_ns":3583,"p999_ns":9599,"p9999_ns":9843,"overflow":0,"peak_rss_bytes":0}
== round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12894 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":55793875,"operations":4000,"operations_per_second":71692,"p50_ns":12159,"p99_ns":20095,"p999_ns":25983,"p9999_ns":36889,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4562 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9030066,"operations":4000,"operations_per_second":442964,"p50_ns":2127,"p99_ns":3119,"p999_ns":13631,"p9999_ns":37235,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4421 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8780188,"operations":4000,"operations_per_second":455571,"p50_ns":2047,"p99_ns":2975,"p999_ns":17407,"p9999_ns":46036,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 15504 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":59624851,"operations":4000,"operations_per_second":67086,"p50_ns":16127,"p99_ns":19455,"p999_ns":24575,"p9999_ns":25983,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24702 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9111390,"operations":4000,"operations_per_second":439010,"p50_ns":2127,"p99_ns":4895,"p999_ns":11327,"p9999_ns":11917,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24425 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8555392,"operations":4000,"operations_per_second":467541,"p50_ns":2063,"p99_ns":3327,"p999_ns":4607,"p9999_ns":6096,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 14081 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":59225868,"operations":4000,"operations_per_second":67538,"p50_ns":16319,"p99_ns":19967,"p999_ns":27903,"p9999_ns":125005,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 59916 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35252308,"operations":4000,"operations_per_second":113467,"p50_ns":8703,"p99_ns":11455,"p999_ns":15871,"p9999_ns":18429,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 104766 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9199573,"operations":4000,"operations_per_second":434802,"p50_ns":2079,"p99_ns":9343,"p999_ns":10559,"p9999_ns":11010,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20773 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":55983034,"operations":4000,"operations_per_second":71450,"p50_ns":14335,"p99_ns":19839,"p999_ns":36863,"p9999_ns":48236,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 60883 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":38789005,"operations":4000,"operations_per_second":103122,"p50_ns":9407,"p99_ns":13823,"p999_ns":19199,"p9999_ns":205971,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004900 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9631868,"operations":4000,"operations_per_second":415288,"p50_ns":2287,"p99_ns":3583,"p999_ns":8447,"p9999_ns":9237,"overflow":0,"peak_rss_bytes":0}
```

## Run 3: AMD EPYC 9V74 80-Core Processor, CI run 36020023420

```text
== round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13241 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":50783168,"operations":4000,"operations_per_second":78766,"p50_ns":13247,"p99_ns":18943,"p999_ns":22015,"p9999_ns":50811,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 5260 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10437415,"operations":4000,"operations_per_second":383236,"p50_ns":2463,"p99_ns":3807,"p999_ns":14015,"p9999_ns":39214,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 5211 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10309276,"operations":4000,"operations_per_second":388000,"p50_ns":2431,"p99_ns":3599,"p999_ns":11711,"p9999_ns":18753,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 14331 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":51816087,"operations":4000,"operations_per_second":77196,"p50_ns":12991,"p99_ns":19967,"p999_ns":21247,"p9999_ns":38593,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 25360 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10465825,"operations":4000,"operations_per_second":382196,"p50_ns":2431,"p99_ns":7711,"p999_ns":11839,"p9999_ns":33400,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 25460 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10540342,"operations":4000,"operations_per_second":379494,"p50_ns":2479,"p99_ns":7903,"p999_ns":10047,"p9999_ns":11212,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 14274 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":52890614,"operations":4000,"operations_per_second":75627,"p50_ns":13311,"p99_ns":19583,"p999_ns":21247,"p9999_ns":22704,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 58303 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":31146079,"operations":4000,"operations_per_second":128427,"p50_ns":7647,"p99_ns":13119,"p999_ns":15615,"p9999_ns":16660,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 105587 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10920158,"operations":4000,"operations_per_second":366295,"p50_ns":2575,"p99_ns":4191,"p999_ns":9087,"p9999_ns":28067,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 14345 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":38952116,"operations":4000,"operations_per_second":102690,"p50_ns":9151,"p99_ns":17151,"p999_ns":21759,"p9999_ns":109785,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 58915 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":37615924,"operations":4000,"operations_per_second":106337,"p50_ns":8511,"p99_ns":14655,"p999_ns":69119,"p9999_ns":774031,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1006151 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":12628644,"operations":4000,"operations_per_second":316740,"p50_ns":2975,"p99_ns":5759,"p999_ns":10687,"p9999_ns":15218,"overflow":0,"peak_rss_bytes":0}
== round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13393 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":50367996,"operations":4000,"operations_per_second":79415,"p50_ns":13247,"p99_ns":19583,"p999_ns":21247,"p9999_ns":26249,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 5161 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10241298,"operations":4000,"operations_per_second":390575,"p50_ns":2415,"p99_ns":4191,"p999_ns":10111,"p9999_ns":33194,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 5186 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10258888,"operations":4000,"operations_per_second":389905,"p50_ns":2431,"p99_ns":3487,"p999_ns":12031,"p9999_ns":17251,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 14056 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":49886919,"operations":4000,"operations_per_second":80181,"p50_ns":12799,"p99_ns":19071,"p999_ns":20607,"p9999_ns":21081,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 25328 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10349361,"operations":4000,"operations_per_second":386497,"p50_ns":2431,"p99_ns":4703,"p999_ns":10111,"p9999_ns":13225,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 25404 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10416778,"operations":4000,"operations_per_second":383995,"p50_ns":2479,"p99_ns":4575,"p999_ns":9279,"p9999_ns":11928,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 14005 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":52438721,"operations":4000,"operations_per_second":76279,"p50_ns":13311,"p99_ns":19967,"p999_ns":22271,"p9999_ns":26384,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 58105 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":31362475,"operations":4000,"operations_per_second":127540,"p50_ns":7615,"p99_ns":13119,"p999_ns":42239,"p9999_ns":58633,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 105570 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10899044,"operations":4000,"operations_per_second":367004,"p50_ns":2559,"p99_ns":4415,"p999_ns":11007,"p9999_ns":13340,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 14594 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":39100065,"operations":4000,"operations_per_second":102301,"p50_ns":9727,"p99_ns":17407,"p999_ns":20095,"p9999_ns":21527,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 58865 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35868396,"operations":4000,"operations_per_second":111518,"p50_ns":8511,"p99_ns":14335,"p999_ns":18943,"p9999_ns":331612,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1006384 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":12775283,"operations":4000,"operations_per_second":313104,"p50_ns":3007,"p99_ns":6911,"p999_ns":10559,"p9999_ns":11763,"overflow":0,"peak_rss_bytes":0}
== round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12870 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":48287260,"operations":4000,"operations_per_second":82837,"p50_ns":11903,"p99_ns":17919,"p999_ns":21759,"p9999_ns":21767,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 5416 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10761180,"operations":4000,"operations_per_second":371706,"p50_ns":2527,"p99_ns":3871,"p999_ns":11711,"p9999_ns":38437,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 5060 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10034123,"operations":4000,"operations_per_second":398639,"p50_ns":2367,"p99_ns":3423,"p999_ns":16511,"p9999_ns":31016,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 13743 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":50343084,"operations":4000,"operations_per_second":79454,"p50_ns":12927,"p99_ns":19327,"p999_ns":24191,"p9999_ns":47441,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 25287 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10316437,"operations":4000,"operations_per_second":387730,"p50_ns":2415,"p99_ns":5119,"p999_ns":9855,"p9999_ns":12724,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 25142 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10022007,"operations":4000,"operations_per_second":399121,"p50_ns":2383,"p99_ns":4223,"p999_ns":9279,"p9999_ns":11482,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 13664 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":53861965,"operations":4000,"operations_per_second":74263,"p50_ns":13247,"p99_ns":20479,"p999_ns":174079,"p9999_ns":316450,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 58261 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":30954057,"operations":4000,"operations_per_second":129223,"p50_ns":7615,"p99_ns":10111,"p999_ns":15615,"p9999_ns":27621,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 105533 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10842617,"operations":4000,"operations_per_second":368914,"p50_ns":2543,"p99_ns":4127,"p999_ns":9599,"p9999_ns":12804,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 14589 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":43864316,"operations":4000,"operations_per_second":91190,"p50_ns":9087,"p99_ns":24575,"p999_ns":89087,"p9999_ns":1547707,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 58838 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35370850,"operations":4000,"operations_per_second":113087,"p50_ns":8511,"p99_ns":14335,"p999_ns":32639,"p9999_ns":62288,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1006375 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":12722115,"operations":4000,"operations_per_second":314413,"p50_ns":2991,"p99_ns":5567,"p999_ns":9855,"p9999_ns":14952,"overflow":0,"peak_rss_bytes":0}
```
