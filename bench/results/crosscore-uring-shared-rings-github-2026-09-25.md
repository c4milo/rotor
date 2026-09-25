# One cross-core message after io_uring posts moved to the mailbox rings, `github`, 2026-09-25

`rotor_post` from commit `1ccbd4e`, on io_uring (`zig-out/bin/rotor_post`) and on epoll
(`zig-out/linux-bench/post_epoll`) on the same runner, in the CI job `costs`, started by hand three
times. For each gap before a ping, 0, 20, 100, 1,000 and 1,500 µs, each ran the four modes in turn,
2,000 round trips each after 200 not measured, three rounds. Each `rotor_post:` line gives the CPU
time the answering loop used per round trip; the JSON line after it is the run's result, whose
`p50_ns` is one message, half a round trip. Decision 4 reads them.

## Run 1: INTEL(R) XEON(R) PLATINUM 8573C, CI run 36103203911

### io_uring

```text
model name	: INTEL(R) XEON(R) PLATINUM 8573C
4
6.17.0-1022-azure
MemTotal:       16372440 kB
== round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8179 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":53583680,"operations":4000,"operations_per_second":74649,"p50_ns":13247,"p99_ns":20735,"p999_ns":28031,"p9999_ns":49371,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 1861 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3628322,"operations":4000,"operations_per_second":1102437,"p50_ns":891,"p99_ns":935,"p999_ns":5727,"p9999_ns":20638,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 1823 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3544177,"operations":4000,"operations_per_second":1128611,"p50_ns":855,"p99_ns":903,"p999_ns":12415,"p9999_ns":22317,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 1799 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3506338,"operations":4000,"operations_per_second":1140791,"p50_ns":863,"p99_ns":911,"p999_ns":5439,"p9999_ns":8225,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 8065 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":36506565,"operations":4000,"operations_per_second":109569,"p50_ns":9087,"p99_ns":11199,"p999_ns":15935,"p9999_ns":16211,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 21886 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3511511,"operations":4000,"operations_per_second":1139110,"p50_ns":847,"p99_ns":947,"p999_ns":5983,"p9999_ns":25394,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 21928 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3561387,"operations":4000,"operations_per_second":1123157,"p50_ns":863,"p99_ns":991,"p999_ns":6399,"p9999_ns":7390,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 21955 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3597021,"operations":4000,"operations_per_second":1112031,"p50_ns":871,"p99_ns":975,"p999_ns":6367,"p9999_ns":7592,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 9323 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":41375522,"operations":4000,"operations_per_second":96675,"p50_ns":10239,"p99_ns":16127,"p999_ns":22527,"p9999_ns":24388,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 56015 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24860453,"operations":4000,"operations_per_second":160898,"p50_ns":6111,"p99_ns":8319,"p999_ns":12799,"p9999_ns":37247,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 56173 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24682801,"operations":4000,"operations_per_second":162056,"p50_ns":6047,"p99_ns":9535,"p999_ns":18175,"p9999_ns":32686,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102032 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3611704,"operations":4000,"operations_per_second":1107510,"p50_ns":883,"p99_ns":1003,"p999_ns":5855,"p9999_ns":6167,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 11859 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34576075,"operations":4000,"operations_per_second":115686,"p50_ns":8319,"p99_ns":14591,"p999_ns":36863,"p9999_ns":216614,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 56830 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":27642957,"operations":4000,"operations_per_second":144702,"p50_ns":6719,"p99_ns":10239,"p999_ns":13183,"p9999_ns":155322,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 59039 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":29065978,"operations":4000,"operations_per_second":137617,"p50_ns":7135,"p99_ns":11775,"p999_ns":14975,"p9999_ns":21209,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1001990 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3792956,"operations":4000,"operations_per_second":1054586,"p50_ns":939,"p99_ns":1015,"p999_ns":4575,"p9999_ns":5646,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 16208 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":45708422,"operations":4000,"operations_per_second":87511,"p50_ns":10495,"p99_ns":16511,"p999_ns":103935,"p9999_ns":1292660,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 62900 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":27431671,"operations":4000,"operations_per_second":145816,"p50_ns":6463,"p99_ns":8447,"p999_ns":12479,"p9999_ns":662811,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 63153 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26275860,"operations":4000,"operations_per_second":152230,"p50_ns":6463,"p99_ns":9343,"p999_ns":15103,"p9999_ns":65181,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1502066 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3905811,"operations":4000,"operations_per_second":1024115,"p50_ns":943,"p99_ns":1047,"p999_ns":5919,"p9999_ns":33361,"overflow":0,"peak_rss_bytes":0}
== round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8012 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35885686,"operations":4000,"operations_per_second":111465,"p50_ns":9087,"p99_ns":11647,"p999_ns":15359,"p9999_ns":16479,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 1771 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3441614,"operations":4000,"operations_per_second":1162245,"p50_ns":851,"p99_ns":879,"p999_ns":6847,"p9999_ns":21081,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 1735 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3377119,"operations":4000,"operations_per_second":1184441,"p50_ns":831,"p99_ns":883,"p999_ns":4927,"p9999_ns":10792,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 1819 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3533573,"operations":4000,"operations_per_second":1131998,"p50_ns":867,"p99_ns":915,"p999_ns":5727,"p9999_ns":16377,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 7516 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35130200,"operations":4000,"operations_per_second":113862,"p50_ns":8831,"p99_ns":10687,"p999_ns":18431,"p9999_ns":21666,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 21981 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3597589,"operations":4000,"operations_per_second":1111855,"p50_ns":867,"p99_ns":979,"p999_ns":5407,"p9999_ns":9191,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 21924 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3531261,"operations":4000,"operations_per_second":1132739,"p50_ns":863,"p99_ns":959,"p999_ns":5983,"p9999_ns":10943,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 21914 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3532873,"operations":4000,"operations_per_second":1132222,"p50_ns":867,"p99_ns":955,"p999_ns":5151,"p9999_ns":8138,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 9342 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":45873326,"operations":4000,"operations_per_second":87196,"p50_ns":10175,"p99_ns":16063,"p999_ns":452607,"p9999_ns":1151653,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 55921 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24452314,"operations":4000,"operations_per_second":163583,"p50_ns":6015,"p99_ns":9087,"p999_ns":12927,"p9999_ns":14047,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 56083 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24914454,"operations":4000,"operations_per_second":160549,"p50_ns":6047,"p99_ns":10303,"p999_ns":13503,"p9999_ns":207280,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 101924 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3569936,"operations":4000,"operations_per_second":1120468,"p50_ns":871,"p99_ns":991,"p999_ns":4959,"p9999_ns":5906,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 11748 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":45321670,"operations":4000,"operations_per_second":88258,"p50_ns":8383,"p99_ns":13375,"p999_ns":770047,"p9999_ns":2301550,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 56904 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":28323981,"operations":4000,"operations_per_second":141223,"p50_ns":6719,"p99_ns":10047,"p999_ns":48383,"p9999_ns":324210,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 59045 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":29094132,"operations":4000,"operations_per_second":137484,"p50_ns":7135,"p99_ns":10239,"p999_ns":14591,"p9999_ns":15622,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1002044 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3844732,"operations":4000,"operations_per_second":1040384,"p50_ns":943,"p99_ns":1135,"p999_ns":5727,"p9999_ns":7398,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 16514 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":42568704,"operations":4000,"operations_per_second":93965,"p50_ns":10495,"p99_ns":15935,"p999_ns":18943,"p9999_ns":22617,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 63115 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26425775,"operations":4000,"operations_per_second":151367,"p50_ns":6495,"p99_ns":8831,"p999_ns":13055,"p9999_ns":36488,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 63135 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25987540,"operations":4000,"operations_per_second":153919,"p50_ns":6431,"p99_ns":8095,"p999_ns":11903,"p9999_ns":22515,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1502026 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3803123,"operations":4000,"operations_per_second":1051767,"p50_ns":943,"p99_ns":1019,"p999_ns":4319,"p9999_ns":5484,"overflow":0,"peak_rss_bytes":0}
== round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8082 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35377943,"operations":4000,"operations_per_second":113064,"p50_ns":8959,"p99_ns":13183,"p999_ns":15679,"p9999_ns":17738,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 1844 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3603555,"operations":4000,"operations_per_second":1110014,"p50_ns":871,"p99_ns":911,"p999_ns":13055,"p9999_ns":33208,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 1808 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3512934,"operations":4000,"operations_per_second":1138649,"p50_ns":851,"p99_ns":899,"p999_ns":6207,"p9999_ns":17951,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 1824 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3585626,"operations":4000,"operations_per_second":1115565,"p50_ns":867,"p99_ns":927,"p999_ns":5279,"p9999_ns":35253,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 7600 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34675503,"operations":4000,"operations_per_second":115355,"p50_ns":8831,"p99_ns":10943,"p999_ns":17279,"p9999_ns":39131,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 21879 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3482685,"operations":4000,"operations_per_second":1148539,"p50_ns":851,"p99_ns":963,"p999_ns":5023,"p9999_ns":6266,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 21756 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3280038,"operations":4000,"operations_per_second":1219498,"p50_ns":823,"p99_ns":907,"p999_ns":951,"p9999_ns":2413,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 21819 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3404060,"operations":4000,"operations_per_second":1175067,"p50_ns":831,"p99_ns":931,"p999_ns":4863,"p9999_ns":5988,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 9310 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":40787021,"operations":4000,"operations_per_second":98070,"p50_ns":10111,"p99_ns":15743,"p999_ns":23935,"p9999_ns":29522,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 55916 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25165846,"operations":4000,"operations_per_second":158945,"p50_ns":6047,"p99_ns":7807,"p999_ns":14207,"p9999_ns":376324,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 56167 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24552485,"operations":4000,"operations_per_second":162916,"p50_ns":6047,"p99_ns":8255,"p999_ns":12671,"p9999_ns":26310,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 101975 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3617715,"operations":4000,"operations_per_second":1105670,"p50_ns":875,"p99_ns":1015,"p999_ns":4927,"p9999_ns":5917,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 11657 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":33677514,"operations":4000,"operations_per_second":118773,"p50_ns":8255,"p99_ns":14591,"p999_ns":18943,"p9999_ns":48791,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 56675 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26800561,"operations":4000,"operations_per_second":149250,"p50_ns":6623,"p99_ns":9023,"p999_ns":13631,"p9999_ns":14714,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 58947 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":28741032,"operations":4000,"operations_per_second":139173,"p50_ns":7071,"p99_ns":9855,"p999_ns":14271,"p9999_ns":19798,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1002021 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3804727,"operations":4000,"operations_per_second":1051323,"p50_ns":943,"p99_ns":1019,"p999_ns":4799,"p9999_ns":5642,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 16492 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":42651990,"operations":4000,"operations_per_second":93782,"p50_ns":10559,"p99_ns":14975,"p999_ns":22399,"p9999_ns":22860,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 62937 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26049910,"operations":4000,"operations_per_second":153551,"p50_ns":6463,"p99_ns":8095,"p999_ns":11967,"p9999_ns":12170,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 63237 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26189000,"operations":4000,"operations_per_second":152735,"p50_ns":6527,"p99_ns":7999,"p999_ns":12223,"p9999_ns":15395,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1502021 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3818429,"operations":4000,"operations_per_second":1047551,"p50_ns":943,"p99_ns":1015,"p999_ns":4927,"p9999_ns":5777,"overflow":0,"peak_rss_bytes":0}
```

### epoll

```text
== epoll, round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 10726 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":55164298,"operations":4000,"operations_per_second":72510,"p50_ns":7391,"p99_ns":28671,"p999_ns":655359,"p9999_ns":1742532,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2736 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5367938,"operations":4000,"operations_per_second":745165,"p50_ns":1175,"p99_ns":1599,"p999_ns":13247,"p9999_ns":25622,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2581 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5093739,"operations":4000,"operations_per_second":785277,"p50_ns":1151,"p99_ns":1551,"p999_ns":6751,"p9999_ns":33420,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2572 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5047639,"operations":4000,"operations_per_second":792449,"p50_ns":1151,"p99_ns":1559,"p999_ns":7583,"p9999_ns":15378,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 9713 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":40411956,"operations":4000,"operations_per_second":98980,"p50_ns":9663,"p99_ns":14399,"p999_ns":161791,"p9999_ns":545161,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 22808 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5424744,"operations":4000,"operations_per_second":737361,"p50_ns":1183,"p99_ns":1623,"p999_ns":6879,"p9999_ns":39113,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22756 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5141346,"operations":4000,"operations_per_second":778006,"p50_ns":1159,"p99_ns":1607,"p999_ns":9791,"p9999_ns":34501,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22852 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5284082,"operations":4000,"operations_per_second":756990,"p50_ns":1167,"p99_ns":2175,"p999_ns":17919,"p9999_ns":18377,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 10999 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":44109347,"operations":4000,"operations_per_second":90683,"p50_ns":10815,"p99_ns":17791,"p999_ns":51199,"p9999_ns":150942,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 57523 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26927480,"operations":4000,"operations_per_second":148547,"p50_ns":6655,"p99_ns":9343,"p999_ns":12607,"p9999_ns":36544,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 57880 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26626585,"operations":4000,"operations_per_second":150225,"p50_ns":6559,"p99_ns":11135,"p999_ns":13695,"p9999_ns":14849,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102676 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5121279,"operations":4000,"operations_per_second":781054,"p50_ns":1167,"p99_ns":1607,"p999_ns":6111,"p9999_ns":6477,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 11534 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":45067326,"operations":4000,"operations_per_second":88756,"p50_ns":11199,"p99_ns":16511,"p999_ns":22655,"p9999_ns":30284,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 58199 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":29172639,"operations":4000,"operations_per_second":137114,"p50_ns":7231,"p99_ns":9279,"p999_ns":12735,"p9999_ns":20120,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 58516 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":28845984,"operations":4000,"operations_per_second":138667,"p50_ns":7071,"p99_ns":9983,"p999_ns":13247,"p9999_ns":84912,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1002801 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5369077,"operations":4000,"operations_per_second":745007,"p50_ns":1215,"p99_ns":1663,"p999_ns":5087,"p9999_ns":7729,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 18776 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":44549117,"operations":4000,"operations_per_second":89788,"p50_ns":11007,"p99_ns":16383,"p999_ns":22399,"p9999_ns":23175,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 65303 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":29051939,"operations":4000,"operations_per_second":137684,"p50_ns":6975,"p99_ns":11391,"p999_ns":73727,"p9999_ns":153700,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 66231 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":28025675,"operations":4000,"operations_per_second":142726,"p50_ns":6911,"p99_ns":8639,"p999_ns":12863,"p9999_ns":19152,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1502839 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5397055,"operations":4000,"operations_per_second":741144,"p50_ns":1223,"p99_ns":1671,"p999_ns":4895,"p9999_ns":5063,"overflow":0,"peak_rss_bytes":0}
== epoll, round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9523 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":36858435,"operations":4000,"operations_per_second":108523,"p50_ns":9215,"p99_ns":11711,"p999_ns":15295,"p9999_ns":17026,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2713 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5349358,"operations":4000,"operations_per_second":747753,"p50_ns":1175,"p99_ns":1599,"p999_ns":7487,"p9999_ns":23165,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2583 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5079265,"operations":4000,"operations_per_second":787515,"p50_ns":1151,"p99_ns":1551,"p999_ns":8063,"p9999_ns":18513,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2685 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5291225,"operations":4000,"operations_per_second":755968,"p50_ns":1223,"p99_ns":1655,"p999_ns":9087,"p9999_ns":19918,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 9963 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":38540499,"operations":4000,"operations_per_second":103786,"p50_ns":9663,"p99_ns":13503,"p999_ns":14527,"p9999_ns":15641,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 22817 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5389392,"operations":4000,"operations_per_second":742198,"p50_ns":1207,"p99_ns":1687,"p999_ns":6399,"p9999_ns":7914,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22692 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5056898,"operations":4000,"operations_per_second":790998,"p50_ns":1151,"p99_ns":1631,"p999_ns":6655,"p9999_ns":15582,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22728 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5091129,"operations":4000,"operations_per_second":785680,"p50_ns":1167,"p99_ns":1615,"p999_ns":5215,"p9999_ns":5367,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 11110 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":43774840,"operations":4000,"operations_per_second":91376,"p50_ns":10815,"p99_ns":16767,"p999_ns":22783,"p9999_ns":24543,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 57955 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":29172620,"operations":4000,"operations_per_second":137114,"p50_ns":6879,"p99_ns":16639,"p999_ns":22655,"p9999_ns":74996,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 57954 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26877439,"operations":4000,"operations_per_second":148823,"p50_ns":6655,"p99_ns":8447,"p999_ns":13183,"p9999_ns":41573,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102656 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5066667,"operations":4000,"operations_per_second":789473,"p50_ns":1175,"p99_ns":1631,"p999_ns":5247,"p9999_ns":6900,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 11632 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":45587452,"operations":4000,"operations_per_second":87743,"p50_ns":11199,"p99_ns":15935,"p999_ns":27519,"p9999_ns":203565,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 58151 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":29308487,"operations":4000,"operations_per_second":136479,"p50_ns":7135,"p99_ns":10879,"p999_ns":18303,"p9999_ns":47027,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 58739 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":29233379,"operations":4000,"operations_per_second":136829,"p50_ns":7135,"p99_ns":11711,"p999_ns":17279,"p9999_ns":34317,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1002824 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5414380,"operations":4000,"operations_per_second":738773,"p50_ns":1223,"p99_ns":1671,"p999_ns":6847,"p9999_ns":15969,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 18965 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":45131009,"operations":4000,"operations_per_second":88630,"p50_ns":11199,"p99_ns":15807,"p999_ns":19839,"p9999_ns":54408,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 65248 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":28428200,"operations":4000,"operations_per_second":140705,"p50_ns":6975,"p99_ns":9599,"p999_ns":13631,"p9999_ns":99188,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 66181 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":28172656,"operations":4000,"operations_per_second":141981,"p50_ns":6975,"p99_ns":8703,"p999_ns":12543,"p9999_ns":13599,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1502855 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5448483,"operations":4000,"operations_per_second":734149,"p50_ns":1231,"p99_ns":1679,"p999_ns":2559,"p9999_ns":4815,"overflow":0,"peak_rss_bytes":0}
== epoll, round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 10111 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":39131983,"operations":4000,"operations_per_second":102218,"p50_ns":9855,"p99_ns":12351,"p999_ns":15487,"p9999_ns":16941,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2690 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5301815,"operations":4000,"operations_per_second":754458,"p50_ns":1175,"p99_ns":1599,"p999_ns":7103,"p9999_ns":21433,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2573 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5070678,"operations":4000,"operations_per_second":788849,"p50_ns":1151,"p99_ns":1551,"p999_ns":7071,"p9999_ns":20492,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2551 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5017999,"operations":4000,"operations_per_second":797130,"p50_ns":1159,"p99_ns":1559,"p999_ns":6047,"p9999_ns":16276,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 10232 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":39399152,"operations":4000,"operations_per_second":101525,"p50_ns":9791,"p99_ns":12287,"p999_ns":17663,"p9999_ns":31634,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 22750 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5310058,"operations":4000,"operations_per_second":753287,"p50_ns":1183,"p99_ns":1615,"p999_ns":2975,"p9999_ns":11921,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22737 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5068413,"operations":4000,"operations_per_second":789201,"p50_ns":1159,"p99_ns":1607,"p999_ns":6559,"p9999_ns":10189,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22727 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5090379,"operations":4000,"operations_per_second":785796,"p50_ns":1151,"p99_ns":1623,"p999_ns":6879,"p9999_ns":8922,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 11069 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":43635412,"operations":4000,"operations_per_second":91668,"p50_ns":10879,"p99_ns":15679,"p999_ns":22015,"p9999_ns":40412,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 57628 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":27105351,"operations":4000,"operations_per_second":147572,"p50_ns":6719,"p99_ns":8895,"p999_ns":14079,"p9999_ns":33550,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 58007 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26899518,"operations":4000,"operations_per_second":148701,"p50_ns":6687,"p99_ns":8703,"p999_ns":12735,"p9999_ns":13580,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102723 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5100951,"operations":4000,"operations_per_second":784167,"p50_ns":1167,"p99_ns":1615,"p999_ns":6271,"p9999_ns":18606,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 11611 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":45102281,"operations":4000,"operations_per_second":88687,"p50_ns":11135,"p99_ns":16127,"p999_ns":22527,"p9999_ns":48008,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 58030 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":29172363,"operations":4000,"operations_per_second":137116,"p50_ns":7103,"p99_ns":9983,"p999_ns":14015,"p9999_ns":137778,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 58671 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35831075,"operations":4000,"operations_per_second":111634,"p50_ns":7103,"p99_ns":9855,"p999_ns":14783,"p9999_ns":2524281,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1002822 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5390178,"operations":4000,"operations_per_second":742090,"p50_ns":1223,"p99_ns":1671,"p999_ns":5375,"p9999_ns":6694,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 18807 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":44917380,"operations":4000,"operations_per_second":89052,"p50_ns":11135,"p99_ns":15295,"p999_ns":22399,"p9999_ns":50512,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 65141 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":28201453,"operations":4000,"operations_per_second":141836,"p50_ns":6975,"p99_ns":8895,"p999_ns":12991,"p9999_ns":14759,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 66196 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":28162417,"operations":4000,"operations_per_second":142033,"p50_ns":6943,"p99_ns":8703,"p999_ns":13887,"p9999_ns":33242,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1502832 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5386368,"operations":4000,"operations_per_second":742615,"p50_ns":1223,"p99_ns":1679,"p999_ns":4831,"p9999_ns":6683,"overflow":0,"peak_rss_bytes":0}
```

## Run 2: AMD EPYC 7763 64-Core Processor, CI run 36103210871

### io_uring

```text
model name	: AMD EPYC 7763 64-Core Processor
4
6.17.0-1022-azure
MemTotal:       16373448 kB
== round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13154 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57625354,"operations":4000,"operations_per_second":69413,"p50_ns":12735,"p99_ns":21759,"p999_ns":29695,"p9999_ns":35351,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2060 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4020748,"operations":4000,"operations_per_second":994839,"p50_ns":987,"p99_ns":1047,"p999_ns":12031,"p9999_ns":22182,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 1925 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3749196,"operations":4000,"operations_per_second":1066895,"p50_ns":903,"p99_ns":963,"p999_ns":14975,"p9999_ns":17297,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 1925 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3749120,"operations":4000,"operations_per_second":1066917,"p50_ns":919,"p99_ns":963,"p999_ns":15231,"p9999_ns":16996,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 15985 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":63047787,"operations":4000,"operations_per_second":63443,"p50_ns":16639,"p99_ns":19839,"p999_ns":26623,"p9999_ns":35126,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 22225 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3955770,"operations":4000,"operations_per_second":1011181,"p50_ns":983,"p99_ns":1143,"p999_ns":5791,"p9999_ns":8591,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22101 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3790337,"operations":4000,"operations_per_second":1055315,"p50_ns":903,"p99_ns":1311,"p999_ns":8159,"p9999_ns":10149,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22149 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3859011,"operations":4000,"operations_per_second":1036535,"p50_ns":919,"p99_ns":1775,"p999_ns":8639,"p9999_ns":12869,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 17702 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":70362727,"operations":4000,"operations_per_second":56848,"p50_ns":17663,"p99_ns":22527,"p999_ns":40191,"p9999_ns":237846,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 60562 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34161582,"operations":4000,"operations_per_second":117090,"p50_ns":8447,"p99_ns":13183,"p999_ns":14463,"p9999_ns":18690,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 60229 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":32833385,"operations":4000,"operations_per_second":121827,"p50_ns":8063,"p99_ns":13055,"p999_ns":14783,"p9999_ns":16461,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102049 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3669441,"operations":4000,"operations_per_second":1090084,"p50_ns":919,"p99_ns":1019,"p999_ns":1951,"p9999_ns":4238,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 21762 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":58849098,"operations":4000,"operations_per_second":67970,"p50_ns":15295,"p99_ns":21759,"p999_ns":28927,"p9999_ns":76097,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 63199 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":49238179,"operations":4000,"operations_per_second":81237,"p50_ns":10303,"p99_ns":15039,"p999_ns":1007615,"p9999_ns":1170804,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 69064 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":58863979,"operations":4000,"operations_per_second":67953,"p50_ns":14783,"p99_ns":19071,"p999_ns":21887,"p9999_ns":25062,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1002067 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3983970,"operations":4000,"operations_per_second":1004023,"p50_ns":979,"p99_ns":1143,"p999_ns":6815,"p9999_ns":7289,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 33331 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":76153867,"operations":4000,"operations_per_second":52525,"p50_ns":19071,"p99_ns":22911,"p999_ns":29439,"p9999_ns":35812,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 76002 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":47914333,"operations":4000,"operations_per_second":83482,"p50_ns":10303,"p99_ns":15999,"p999_ns":148479,"p9999_ns":1863473,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 76909 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":42026545,"operations":4000,"operations_per_second":95177,"p50_ns":10495,"p99_ns":15103,"p999_ns":21631,"p9999_ns":62412,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1502056 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4001858,"operations":4000,"operations_per_second":999535,"p50_ns":979,"p99_ns":1199,"p999_ns":3151,"p9999_ns":6883,"overflow":0,"peak_rss_bytes":0}
== round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 11931 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":53532344,"operations":4000,"operations_per_second":74721,"p50_ns":11583,"p99_ns":21503,"p999_ns":25855,"p9999_ns":33317,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2071 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4080597,"operations":4000,"operations_per_second":980248,"p50_ns":987,"p99_ns":1063,"p999_ns":9087,"p9999_ns":39834,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 1923 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3794756,"operations":4000,"operations_per_second":1054086,"p50_ns":907,"p99_ns":959,"p999_ns":9727,"p9999_ns":35777,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 1919 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3755705,"operations":4000,"operations_per_second":1065046,"p50_ns":919,"p99_ns":959,"p999_ns":10815,"p9999_ns":28012,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 15974 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":62701962,"operations":4000,"operations_per_second":63793,"p50_ns":16511,"p99_ns":18943,"p999_ns":25087,"p9999_ns":28669,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 22239 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3935847,"operations":4000,"operations_per_second":1016299,"p50_ns":983,"p99_ns":1071,"p999_ns":2175,"p9999_ns":3967,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22163 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3765268,"operations":4000,"operations_per_second":1062341,"p50_ns":903,"p99_ns":1287,"p999_ns":8319,"p9999_ns":8486,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22089 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3752326,"operations":4000,"operations_per_second":1066005,"p50_ns":907,"p99_ns":1003,"p999_ns":7359,"p9999_ns":8631,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 16500 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":66790590,"operations":4000,"operations_per_second":59888,"p50_ns":17791,"p99_ns":23167,"p999_ns":31359,"p9999_ns":66940,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 60739 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34783253,"operations":4000,"operations_per_second":114997,"p50_ns":8447,"p99_ns":13887,"p999_ns":18047,"p9999_ns":227045,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 60249 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":32733538,"operations":4000,"operations_per_second":122198,"p50_ns":8063,"p99_ns":13055,"p999_ns":14335,"p9999_ns":16972,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102049 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3683557,"operations":4000,"operations_per_second":1085906,"p50_ns":919,"p99_ns":1023,"p999_ns":2063,"p9999_ns":2269,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 22332 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":59963084,"operations":4000,"operations_per_second":66707,"p50_ns":15295,"p99_ns":20735,"p999_ns":25727,"p9999_ns":108308,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 63423 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":41931245,"operations":4000,"operations_per_second":95394,"p50_ns":10431,"p99_ns":15743,"p999_ns":23807,"p9999_ns":48170,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 68465 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57807050,"operations":4000,"operations_per_second":69195,"p50_ns":14463,"p99_ns":17535,"p999_ns":24191,"p9999_ns":155261,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1002040 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3975063,"operations":4000,"operations_per_second":1006273,"p50_ns":979,"p99_ns":1135,"p999_ns":6527,"p9999_ns":8135,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 33156 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":75753303,"operations":4000,"operations_per_second":52802,"p50_ns":18943,"p99_ns":23167,"p999_ns":30591,"p9999_ns":38567,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 76327 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":42153848,"operations":4000,"operations_per_second":94890,"p50_ns":10431,"p99_ns":14847,"p999_ns":40191,"p9999_ns":93690,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 76325 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":43262228,"operations":4000,"operations_per_second":92459,"p50_ns":10495,"p99_ns":15551,"p999_ns":111103,"p9999_ns":303734,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1501974 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4015221,"operations":4000,"operations_per_second":996209,"p50_ns":975,"p99_ns":1231,"p999_ns":8095,"p9999_ns":8130,"overflow":0,"peak_rss_bytes":0}
== round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13912 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":59127577,"operations":4000,"operations_per_second":67650,"p50_ns":16639,"p99_ns":19711,"p999_ns":28031,"p9999_ns":29500,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2061 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4021439,"operations":4000,"operations_per_second":994668,"p50_ns":983,"p99_ns":1047,"p999_ns":10175,"p9999_ns":24275,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 1923 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3771565,"operations":4000,"operations_per_second":1060567,"p50_ns":903,"p99_ns":963,"p999_ns":7295,"p9999_ns":45194,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 1909 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3714065,"operations":4000,"operations_per_second":1076987,"p50_ns":919,"p99_ns":955,"p999_ns":7071,"p9999_ns":22597,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 15441 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":59663652,"operations":4000,"operations_per_second":67042,"p50_ns":16639,"p99_ns":19455,"p999_ns":26623,"p9999_ns":29315,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 22262 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4014140,"operations":4000,"operations_per_second":996477,"p50_ns":983,"p99_ns":1063,"p999_ns":8959,"p9999_ns":25027,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22100 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3780861,"operations":4000,"operations_per_second":1057960,"p50_ns":903,"p99_ns":1279,"p999_ns":7999,"p9999_ns":8465,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22075 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3756047,"operations":4000,"operations_per_second":1064949,"p50_ns":907,"p99_ns":979,"p999_ns":8159,"p9999_ns":9347,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 18126 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":70562846,"operations":4000,"operations_per_second":56687,"p50_ns":18303,"p99_ns":21375,"p999_ns":29311,"p9999_ns":44889,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 60304 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":33304116,"operations":4000,"operations_per_second":120105,"p50_ns":8255,"p99_ns":12159,"p999_ns":16895,"p9999_ns":20143,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 60328 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":32884185,"operations":4000,"operations_per_second":121639,"p50_ns":8095,"p99_ns":12607,"p999_ns":15359,"p9999_ns":17893,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102021 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3677439,"operations":4000,"operations_per_second":1087713,"p50_ns":919,"p99_ns":1015,"p999_ns":1855,"p9999_ns":2635,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 21411 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57703344,"operations":4000,"operations_per_second":69320,"p50_ns":14719,"p99_ns":20735,"p999_ns":23039,"p9999_ns":26013,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 63059 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":41148766,"operations":4000,"operations_per_second":97208,"p50_ns":10303,"p99_ns":14591,"p999_ns":32767,"p9999_ns":96475,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 67823 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":55882024,"operations":4000,"operations_per_second":71579,"p50_ns":13951,"p99_ns":17663,"p999_ns":21375,"p9999_ns":22632,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1002050 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4024071,"operations":4000,"operations_per_second":994018,"p50_ns":983,"p99_ns":1199,"p999_ns":6783,"p9999_ns":8501,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 32632 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":77765317,"operations":4000,"operations_per_second":51436,"p50_ns":18815,"p99_ns":25215,"p999_ns":90111,"p9999_ns":717214,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 75486 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":40521419,"operations":4000,"operations_per_second":98713,"p50_ns":10047,"p99_ns":14847,"p999_ns":20479,"p9999_ns":42850,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 76349 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":43126412,"operations":4000,"operations_per_second":92750,"p50_ns":10367,"p99_ns":14847,"p999_ns":25727,"p9999_ns":713302,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1501994 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3991139,"operations":4000,"operations_per_second":1002220,"p50_ns":971,"p99_ns":1151,"p999_ns":7007,"p9999_ns":7979,"overflow":0,"peak_rss_bytes":0}
```

### epoll

```text
== epoll, round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14803 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":58771298,"operations":4000,"operations_per_second":68060,"p50_ns":14207,"p99_ns":20479,"p999_ns":28799,"p9999_ns":30903,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2931 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5757442,"operations":4000,"operations_per_second":694752,"p50_ns":1263,"p99_ns":2111,"p999_ns":8511,"p9999_ns":15754,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2690 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5277161,"operations":4000,"operations_per_second":757983,"p50_ns":1223,"p99_ns":1623,"p999_ns":9983,"p9999_ns":30497,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2693 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5293591,"operations":4000,"operations_per_second":755630,"p50_ns":1207,"p99_ns":1615,"p999_ns":12223,"p9999_ns":17553,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 18030 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":75787975,"operations":4000,"operations_per_second":52778,"p50_ns":16063,"p99_ns":23295,"p999_ns":1187839,"p9999_ns":1633176,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 23179 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9101191,"operations":4000,"operations_per_second":439502,"p50_ns":1359,"p99_ns":2127,"p999_ns":8703,"p9999_ns":1020768,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22794 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5325341,"operations":4000,"operations_per_second":751125,"p50_ns":1223,"p99_ns":1735,"p999_ns":8063,"p9999_ns":13866,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22790 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5278752,"operations":4000,"operations_per_second":757754,"p50_ns":1223,"p99_ns":1655,"p999_ns":5759,"p9999_ns":26514,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 20263 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":70627663,"operations":4000,"operations_per_second":56635,"p50_ns":17663,"p99_ns":20223,"p999_ns":22399,"p9999_ns":25843,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 62348 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34915724,"operations":4000,"operations_per_second":114561,"p50_ns":8703,"p99_ns":9663,"p999_ns":14911,"p9999_ns":24455,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 63834 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":37165787,"operations":4000,"operations_per_second":107625,"p50_ns":9087,"p99_ns":13183,"p999_ns":15103,"p9999_ns":224455,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102852 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5437289,"operations":4000,"operations_per_second":735660,"p50_ns":1239,"p99_ns":1775,"p999_ns":8447,"p9999_ns":8541,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 21929 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":89931121,"operations":4000,"operations_per_second":44478,"p50_ns":18431,"p99_ns":22655,"p999_ns":1982463,"p9999_ns":2180176,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 66552 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":45662478,"operations":4000,"operations_per_second":87599,"p50_ns":11007,"p99_ns":15679,"p999_ns":19839,"p9999_ns":43807,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 68010 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":46182024,"operations":4000,"operations_per_second":86613,"p50_ns":11775,"p99_ns":15999,"p999_ns":19583,"p9999_ns":36047,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1002835 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5563270,"operations":4000,"operations_per_second":719001,"p50_ns":1279,"p99_ns":1831,"p999_ns":7231,"p9999_ns":8731,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 36703 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":77912973,"operations":4000,"operations_per_second":51339,"p50_ns":19455,"p99_ns":23423,"p999_ns":41471,"p9999_ns":354058,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 81183 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":46524154,"operations":4000,"operations_per_second":85976,"p50_ns":11711,"p99_ns":15359,"p999_ns":23167,"p9999_ns":25337,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 82473 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":52827457,"operations":4000,"operations_per_second":75718,"p50_ns":11391,"p99_ns":15935,"p999_ns":520191,"p9999_ns":1822751,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1502850 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5599382,"operations":4000,"operations_per_second":714364,"p50_ns":1279,"p99_ns":1855,"p999_ns":7295,"p9999_ns":7439,"overflow":0,"peak_rss_bytes":0}
== epoll, round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15383 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57169634,"operations":4000,"operations_per_second":69967,"p50_ns":12415,"p99_ns":18559,"p999_ns":21503,"p9999_ns":24776,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 3186 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":6263252,"operations":4000,"operations_per_second":638645,"p50_ns":1455,"p99_ns":2335,"p999_ns":9663,"p9999_ns":16004,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2727 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5363930,"operations":4000,"operations_per_second":745721,"p50_ns":1223,"p99_ns":1767,"p999_ns":12159,"p9999_ns":17252,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2705 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5325769,"operations":4000,"operations_per_second":751065,"p50_ns":1215,"p99_ns":1623,"p999_ns":11967,"p9999_ns":30112,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 18508 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":66311992,"operations":4000,"operations_per_second":60320,"p50_ns":17023,"p99_ns":20607,"p999_ns":26111,"p9999_ns":35201,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 22954 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5567019,"operations":4000,"operations_per_second":718517,"p50_ns":1255,"p99_ns":1695,"p999_ns":7519,"p9999_ns":8861,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22759 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5178448,"operations":4000,"operations_per_second":772432,"p50_ns":1215,"p99_ns":1639,"p999_ns":3599,"p9999_ns":7028,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22748 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5196589,"operations":4000,"operations_per_second":769735,"p50_ns":1215,"p99_ns":1631,"p999_ns":2415,"p9999_ns":4688,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 20829 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":72846418,"operations":4000,"operations_per_second":54910,"p50_ns":18175,"p99_ns":21503,"p999_ns":28543,"p9999_ns":33653,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 62616 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35789527,"operations":4000,"operations_per_second":111764,"p50_ns":8895,"p99_ns":11071,"p999_ns":15615,"p9999_ns":21235,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 63857 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":37272983,"operations":4000,"operations_per_second":107316,"p50_ns":9279,"p99_ns":13503,"p999_ns":18943,"p9999_ns":123080,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102864 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5414183,"operations":4000,"operations_per_second":738800,"p50_ns":1255,"p99_ns":1799,"p999_ns":7839,"p9999_ns":9392,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 22624 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":77325497,"operations":4000,"operations_per_second":51729,"p50_ns":19583,"p99_ns":22655,"p999_ns":28543,"p9999_ns":34063,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 66150 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":44712496,"operations":4000,"operations_per_second":89460,"p50_ns":10815,"p99_ns":15103,"p999_ns":19327,"p9999_ns":35722,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 68646 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":48789515,"operations":4000,"operations_per_second":81984,"p50_ns":11967,"p99_ns":16767,"p999_ns":21887,"p9999_ns":705883,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1002873 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5628752,"operations":4000,"operations_per_second":710637,"p50_ns":1295,"p99_ns":1839,"p999_ns":8095,"p9999_ns":8851,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 37159 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":77765740,"operations":4000,"operations_per_second":51436,"p50_ns":19455,"p99_ns":23423,"p999_ns":28543,"p9999_ns":31639,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 80986 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":50978104,"operations":4000,"operations_per_second":78465,"p50_ns":11583,"p99_ns":17535,"p999_ns":46847,"p9999_ns":2238781,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 83002 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":46188111,"operations":4000,"operations_per_second":86602,"p50_ns":11391,"p99_ns":15359,"p999_ns":21631,"p9999_ns":24886,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1502847 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5568905,"operations":4000,"operations_per_second":718274,"p50_ns":1287,"p99_ns":1863,"p999_ns":3007,"p9999_ns":7649,"overflow":0,"peak_rss_bytes":0}
== epoll, round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 18912 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":68480015,"operations":4000,"operations_per_second":58411,"p50_ns":17407,"p99_ns":18559,"p999_ns":23679,"p9999_ns":25302,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2868 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5631463,"operations":4000,"operations_per_second":710294,"p50_ns":1263,"p99_ns":1783,"p999_ns":11071,"p9999_ns":15078,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2673 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5258820,"operations":4000,"operations_per_second":760626,"p50_ns":1215,"p99_ns":1623,"p999_ns":10751,"p9999_ns":21871,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2684 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5266155,"operations":4000,"operations_per_second":759567,"p50_ns":1215,"p99_ns":1615,"p999_ns":11519,"p9999_ns":16451,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 19343 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":67795862,"operations":4000,"operations_per_second":59000,"p50_ns":17151,"p99_ns":19583,"p999_ns":24959,"p9999_ns":37806,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 22990 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5675130,"operations":4000,"operations_per_second":704829,"p50_ns":1255,"p99_ns":1751,"p999_ns":9087,"p9999_ns":13385,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22762 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5248575,"operations":4000,"operations_per_second":762111,"p50_ns":1215,"p99_ns":1631,"p999_ns":7647,"p9999_ns":9603,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22770 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5248032,"operations":4000,"operations_per_second":762190,"p50_ns":1215,"p99_ns":1631,"p999_ns":4767,"p9999_ns":23674,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 20569 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":71672147,"operations":4000,"operations_per_second":55809,"p50_ns":17919,"p99_ns":20479,"p999_ns":27263,"p9999_ns":37160,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 62403 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35164453,"operations":4000,"operations_per_second":113751,"p50_ns":8767,"p99_ns":10623,"p999_ns":15871,"p9999_ns":18635,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 63351 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35818721,"operations":4000,"operations_per_second":111673,"p50_ns":8831,"p99_ns":12415,"p999_ns":18559,"p9999_ns":66369,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102792 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5258220,"operations":4000,"operations_per_second":760713,"p50_ns":1215,"p99_ns":1735,"p999_ns":7295,"p9999_ns":8431,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 22836 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":77721600,"operations":4000,"operations_per_second":51465,"p50_ns":19583,"p99_ns":22911,"p999_ns":28543,"p9999_ns":46282,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 67412 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":47793631,"operations":4000,"operations_per_second":83693,"p50_ns":11775,"p99_ns":16639,"p999_ns":26751,"p9999_ns":160075,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 68562 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":47767526,"operations":4000,"operations_per_second":83738,"p50_ns":11903,"p99_ns":16767,"p999_ns":24703,"p9999_ns":132863,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1002872 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5617721,"operations":4000,"operations_per_second":712032,"p50_ns":1287,"p99_ns":1903,"p999_ns":8383,"p9999_ns":9031,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 37104 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":79526516,"operations":4000,"operations_per_second":50297,"p50_ns":19327,"p99_ns":23039,"p999_ns":34303,"p9999_ns":988302,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 81402 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":49849529,"operations":4000,"operations_per_second":80241,"p50_ns":11647,"p99_ns":17791,"p999_ns":280575,"p9999_ns":522780,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 83739 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":47446006,"operations":4000,"operations_per_second":84306,"p50_ns":11839,"p99_ns":16255,"p999_ns":26623,"p9999_ns":41012,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1502876 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5638786,"operations":4000,"operations_per_second":709372,"p50_ns":1319,"p99_ns":1847,"p999_ns":7423,"p9999_ns":8481,"overflow":0,"peak_rss_bytes":0}
```

## Run 3: AMD EPYC 9V74 80-Core Processor, CI run 36103217522

### io_uring

```text
model name	: AMD EPYC 9V74 80-Core Processor
4
6.17.0-1022-azure
MemTotal:       16373452 kB
== round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9849 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":38525099,"operations":4000,"operations_per_second":103828,"p50_ns":9535,"p99_ns":13055,"p999_ns":17023,"p9999_ns":17706,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 1688 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3299338,"operations":4000,"operations_per_second":1212364,"p50_ns":803,"p99_ns":863,"p999_ns":7231,"p9999_ns":14836,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 1604 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3135927,"operations":4000,"operations_per_second":1275539,"p50_ns":763,"p99_ns":799,"p999_ns":6911,"p9999_ns":17891,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 1590 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3103118,"operations":4000,"operations_per_second":1289026,"p50_ns":767,"p99_ns":787,"p999_ns":7167,"p9999_ns":12864,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 10749 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":39109701,"operations":4000,"operations_per_second":102276,"p50_ns":10047,"p99_ns":14655,"p999_ns":16767,"p9999_ns":18172,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 21759 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3829018,"operations":4000,"operations_per_second":1044654,"p50_ns":803,"p99_ns":967,"p999_ns":2815,"p9999_ns":284428,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 21735 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3066794,"operations":4000,"operations_per_second":1304293,"p50_ns":763,"p99_ns":839,"p999_ns":1871,"p9999_ns":3164,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 21748 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3089320,"operations":4000,"operations_per_second":1294783,"p50_ns":767,"p99_ns":839,"p999_ns":2271,"p9999_ns":3180,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 10550 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":41359565,"operations":4000,"operations_per_second":96712,"p50_ns":10431,"p99_ns":15871,"p999_ns":58111,"p9999_ns":164352,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 56428 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":21432164,"operations":4000,"operations_per_second":186635,"p50_ns":5311,"p99_ns":6271,"p999_ns":12671,"p9999_ns":14426,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 56601 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":21477883,"operations":4000,"operations_per_second":186238,"p50_ns":5311,"p99_ns":6303,"p999_ns":14335,"p9999_ns":45497,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 101802 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3074250,"operations":4000,"operations_per_second":1301130,"p50_ns":759,"p99_ns":927,"p999_ns":1431,"p9999_ns":2193,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 11530 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":31464653,"operations":4000,"operations_per_second":127126,"p50_ns":8031,"p99_ns":12927,"p999_ns":16639,"p9999_ns":90924,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 57257 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25575674,"operations":4000,"operations_per_second":156398,"p50_ns":6175,"p99_ns":9791,"p999_ns":17279,"p9999_ns":34010,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 58577 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":29900207,"operations":4000,"operations_per_second":133778,"p50_ns":7455,"p99_ns":10175,"p999_ns":13247,"p9999_ns":17175,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1001829 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3608159,"operations":4000,"operations_per_second":1108598,"p50_ns":867,"p99_ns":1263,"p999_ns":4895,"p9999_ns":5628,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 18806 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":45614983,"operations":4000,"operations_per_second":87690,"p50_ns":11263,"p99_ns":16255,"p999_ns":18815,"p9999_ns":56503,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 63737 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":28864666,"operations":4000,"operations_per_second":138577,"p50_ns":6047,"p99_ns":8511,"p999_ns":58367,"p9999_ns":1326056,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 64012 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24790311,"operations":4000,"operations_per_second":161353,"p50_ns":6015,"p99_ns":8767,"p999_ns":12543,"p9999_ns":13204,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1501999 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3712502,"operations":4000,"operations_per_second":1077440,"p50_ns":883,"p99_ns":1351,"p999_ns":5343,"p9999_ns":5583,"overflow":0,"peak_rss_bytes":0}
== round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 10313 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":39070700,"operations":4000,"operations_per_second":102378,"p50_ns":10367,"p99_ns":15551,"p999_ns":20863,"p9999_ns":22473,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 1662 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3238997,"operations":4000,"operations_per_second":1234950,"p50_ns":803,"p99_ns":859,"p999_ns":1479,"p9999_ns":7426,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 1611 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3149089,"operations":4000,"operations_per_second":1270208,"p50_ns":763,"p99_ns":1599,"p999_ns":6079,"p9999_ns":14105,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 1611 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3145708,"operations":4000,"operations_per_second":1271573,"p50_ns":767,"p99_ns":807,"p999_ns":5343,"p9999_ns":14651,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 10219 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":38610420,"operations":4000,"operations_per_second":103598,"p50_ns":10047,"p99_ns":17279,"p999_ns":23551,"p9999_ns":25202,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 21751 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3250493,"operations":4000,"operations_per_second":1230582,"p50_ns":803,"p99_ns":887,"p999_ns":2447,"p9999_ns":7476,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 21736 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3069268,"operations":4000,"operations_per_second":1303242,"p50_ns":763,"p99_ns":867,"p999_ns":1527,"p9999_ns":2448,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 21752 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3095191,"operations":4000,"operations_per_second":1292327,"p50_ns":767,"p99_ns":843,"p999_ns":2511,"p9999_ns":7411,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 11310 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":42503594,"operations":4000,"operations_per_second":94109,"p50_ns":10559,"p99_ns":15615,"p999_ns":16895,"p9999_ns":17370,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 56438 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":21541561,"operations":4000,"operations_per_second":185687,"p50_ns":5343,"p99_ns":6335,"p999_ns":10559,"p9999_ns":41346,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 56564 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":21378115,"operations":4000,"operations_per_second":187107,"p50_ns":5279,"p99_ns":6335,"p999_ns":6975,"p9999_ns":20875,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 101708 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3125285,"operations":4000,"operations_per_second":1279883,"p50_ns":763,"p99_ns":971,"p999_ns":2143,"p9999_ns":9884,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 11227 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":31194967,"operations":4000,"operations_per_second":128225,"p50_ns":7199,"p99_ns":14399,"p999_ns":58367,"p9999_ns":61645,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 58782 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":43183370,"operations":4000,"operations_per_second":92628,"p50_ns":6175,"p99_ns":78335,"p999_ns":1036287,"p9999_ns":1612333,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 58489 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":29849255,"operations":4000,"operations_per_second":134006,"p50_ns":7423,"p99_ns":10175,"p999_ns":13119,"p9999_ns":19774,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1001918 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3612502,"operations":4000,"operations_per_second":1107265,"p50_ns":871,"p99_ns":1295,"p999_ns":4991,"p9999_ns":5788,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 18777 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":47934367,"operations":4000,"operations_per_second":83447,"p50_ns":11263,"p99_ns":40959,"p999_ns":65023,"p9999_ns":74474,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 63803 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":29650534,"operations":4000,"operations_per_second":134904,"p50_ns":6079,"p99_ns":11711,"p999_ns":136191,"p9999_ns":1297294,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 64015 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25022163,"operations":4000,"operations_per_second":159858,"p50_ns":6079,"p99_ns":8831,"p999_ns":14335,"p9999_ns":20670,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1501917 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3700901,"operations":4000,"operations_per_second":1080817,"p50_ns":883,"p99_ns":1303,"p999_ns":6303,"p9999_ns":7125,"overflow":0,"peak_rss_bytes":0}
== round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 10692 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":39896615,"operations":4000,"operations_per_second":100259,"p50_ns":10367,"p99_ns":15039,"p999_ns":17151,"p9999_ns":20405,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 1686 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3306669,"operations":4000,"operations_per_second":1209676,"p50_ns":807,"p99_ns":863,"p999_ns":5663,"p9999_ns":21982,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 1583 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3090390,"operations":4000,"operations_per_second":1294335,"p50_ns":763,"p99_ns":799,"p999_ns":5311,"p9999_ns":7295,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 1598 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3119319,"operations":4000,"operations_per_second":1282331,"p50_ns":767,"p99_ns":799,"p999_ns":7231,"p9999_ns":11577,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 11021 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":39763854,"operations":4000,"operations_per_second":100593,"p50_ns":10047,"p99_ns":14527,"p999_ns":16767,"p9999_ns":182253,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 21745 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3228889,"operations":4000,"operations_per_second":1238816,"p50_ns":803,"p99_ns":891,"p999_ns":1407,"p9999_ns":2088,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 21735 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3056119,"operations":4000,"operations_per_second":1308849,"p50_ns":763,"p99_ns":811,"p999_ns":1519,"p9999_ns":1872,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 21733 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3090172,"operations":4000,"operations_per_second":1294426,"p50_ns":767,"p99_ns":871,"p999_ns":2335,"p9999_ns":4026,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 11366 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":42554179,"operations":4000,"operations_per_second":93997,"p50_ns":10559,"p99_ns":15679,"p999_ns":16895,"p9999_ns":17245,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 56399 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":21642681,"operations":4000,"operations_per_second":184819,"p50_ns":5343,"p99_ns":6527,"p999_ns":12863,"p9999_ns":15668,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 56543 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":21561490,"operations":4000,"operations_per_second":185515,"p50_ns":5343,"p99_ns":6399,"p999_ns":12287,"p9999_ns":17240,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 101697 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3119847,"operations":4000,"operations_per_second":1282114,"p50_ns":771,"p99_ns":971,"p999_ns":2095,"p9999_ns":2398,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 11293 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":31773663,"operations":4000,"operations_per_second":125890,"p50_ns":7135,"p99_ns":13375,"p999_ns":62719,"p9999_ns":242567,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 57244 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25429757,"operations":4000,"operations_per_second":157296,"p50_ns":6175,"p99_ns":9023,"p999_ns":14463,"p9999_ns":16759,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 58396 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":29620946,"operations":4000,"operations_per_second":135039,"p50_ns":7423,"p99_ns":9599,"p999_ns":13439,"p9999_ns":25647,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1001927 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3605285,"operations":4000,"operations_per_second":1109482,"p50_ns":867,"p99_ns":1223,"p999_ns":5055,"p9999_ns":5783,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 18762 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":45366289,"operations":4000,"operations_per_second":88171,"p50_ns":11199,"p99_ns":15103,"p999_ns":20095,"p9999_ns":29864,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 63829 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":28677113,"operations":4000,"operations_per_second":139484,"p50_ns":6047,"p99_ns":9919,"p999_ns":101887,"p9999_ns":1007102,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 63935 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24743257,"operations":4000,"operations_per_second":161660,"p50_ns":6015,"p99_ns":8639,"p999_ns":12031,"p9999_ns":12263,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1501983 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3701157,"operations":4000,"operations_per_second":1080743,"p50_ns":883,"p99_ns":1279,"p999_ns":6079,"p9999_ns":6920,"overflow":0,"peak_rss_bytes":0}
```

### epoll

```text
== epoll, round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 11845 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":39683881,"operations":4000,"operations_per_second":100796,"p50_ns":9727,"p99_ns":14719,"p999_ns":17535,"p9999_ns":89982,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2284 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4518474,"operations":4000,"operations_per_second":885254,"p50_ns":1019,"p99_ns":1367,"p999_ns":7711,"p9999_ns":19073,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2165 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4257888,"operations":4000,"operations_per_second":939432,"p50_ns":987,"p99_ns":1319,"p999_ns":6719,"p9999_ns":15367,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2154 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4239043,"operations":4000,"operations_per_second":943609,"p50_ns":987,"p99_ns":1319,"p999_ns":6943,"p9999_ns":10645,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 12493 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":41607988,"operations":4000,"operations_per_second":96135,"p50_ns":10751,"p99_ns":14463,"p999_ns":25855,"p9999_ns":39638,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 22457 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":6411096,"operations":4000,"operations_per_second":623918,"p50_ns":1019,"p99_ns":1391,"p999_ns":17023,"p9999_ns":767324,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22256 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4252545,"operations":4000,"operations_per_second":940613,"p50_ns":987,"p99_ns":1327,"p999_ns":5343,"p9999_ns":7030,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22269 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4304509,"operations":4000,"operations_per_second":929258,"p50_ns":987,"p99_ns":1327,"p999_ns":6015,"p9999_ns":6489,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 12988 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":48357908,"operations":4000,"operations_per_second":82716,"p50_ns":11135,"p99_ns":16767,"p999_ns":248831,"p9999_ns":1210852,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 58303 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":23200120,"operations":4000,"operations_per_second":172412,"p50_ns":5791,"p99_ns":6815,"p999_ns":11199,"p9999_ns":11386,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 58822 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":23257151,"operations":4000,"operations_per_second":171990,"p50_ns":5823,"p99_ns":6751,"p999_ns":11455,"p9999_ns":18697,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102293 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4286193,"operations":4000,"operations_per_second":933229,"p50_ns":987,"p99_ns":1383,"p999_ns":6079,"p9999_ns":7536,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 13491 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":46024836,"operations":4000,"operations_per_second":86909,"p50_ns":11455,"p99_ns":14463,"p999_ns":18175,"p9999_ns":19779,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 59048 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26700483,"operations":4000,"operations_per_second":149810,"p50_ns":6527,"p99_ns":8895,"p999_ns":12415,"p9999_ns":13529,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 59487 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26533433,"operations":4000,"operations_per_second":150753,"p50_ns":6495,"p99_ns":8895,"p999_ns":11839,"p9999_ns":13976,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1002419 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4666075,"operations":4000,"operations_per_second":857251,"p50_ns":1063,"p99_ns":1519,"p999_ns":6687,"p9999_ns":17405,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 20776 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":45911028,"operations":4000,"operations_per_second":87125,"p50_ns":11455,"p99_ns":16319,"p999_ns":18175,"p9999_ns":23084,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 66287 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25819887,"operations":4000,"operations_per_second":154919,"p50_ns":6335,"p99_ns":8063,"p999_ns":12543,"p9999_ns":14181,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 67243 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26946456,"operations":4000,"operations_per_second":148442,"p50_ns":6335,"p99_ns":12799,"p999_ns":50431,"p9999_ns":66242,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1502474 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4720263,"operations":4000,"operations_per_second":847410,"p50_ns":1087,"p99_ns":1583,"p999_ns":5823,"p9999_ns":6029,"overflow":0,"peak_rss_bytes":0}
== epoll, round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 11179 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":39552458,"operations":4000,"operations_per_second":101131,"p50_ns":10943,"p99_ns":12799,"p999_ns":16319,"p9999_ns":25597,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2284 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4489086,"operations":4000,"operations_per_second":891049,"p50_ns":1019,"p99_ns":1359,"p999_ns":9151,"p9999_ns":13214,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2152 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4238282,"operations":4000,"operations_per_second":943778,"p50_ns":987,"p99_ns":1319,"p999_ns":6047,"p9999_ns":12914,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2156 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4237061,"operations":4000,"operations_per_second":944050,"p50_ns":987,"p99_ns":1319,"p999_ns":6719,"p9999_ns":9013,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 13099 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":43261882,"operations":4000,"operations_per_second":92460,"p50_ns":10751,"p99_ns":15423,"p999_ns":20479,"p9999_ns":36203,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 22348 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4490192,"operations":4000,"operations_per_second":890830,"p50_ns":1019,"p99_ns":1367,"p999_ns":6143,"p9999_ns":6665,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22233 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4178241,"operations":4000,"operations_per_second":957340,"p50_ns":983,"p99_ns":1327,"p999_ns":2671,"p9999_ns":2959,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22232 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4246030,"operations":4000,"operations_per_second":942056,"p50_ns":987,"p99_ns":1319,"p999_ns":1975,"p9999_ns":3089,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 12924 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":43909064,"operations":4000,"operations_per_second":91097,"p50_ns":10879,"p99_ns":14911,"p999_ns":17919,"p9999_ns":164206,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 58299 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":23258327,"operations":4000,"operations_per_second":171981,"p50_ns":5759,"p99_ns":7199,"p999_ns":12671,"p9999_ns":21496,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 58701 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":22915315,"operations":4000,"operations_per_second":174555,"p50_ns":5599,"p99_ns":6559,"p999_ns":10943,"p9999_ns":157051,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102296 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4339031,"operations":4000,"operations_per_second":921864,"p50_ns":987,"p99_ns":1383,"p999_ns":6591,"p9999_ns":7456,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 13768 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":47167900,"operations":4000,"operations_per_second":84803,"p50_ns":11647,"p99_ns":16767,"p999_ns":21759,"p9999_ns":50183,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 59128 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":27287349,"operations":4000,"operations_per_second":146588,"p50_ns":6559,"p99_ns":10303,"p999_ns":18687,"p9999_ns":129701,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 59460 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":30115862,"operations":4000,"operations_per_second":132820,"p50_ns":6495,"p99_ns":9151,"p999_ns":12415,"p9999_ns":1345435,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1002426 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4645572,"operations":4000,"operations_per_second":861034,"p50_ns":1063,"p99_ns":1551,"p999_ns":5631,"p9999_ns":6935,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 20763 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":45644736,"operations":4000,"operations_per_second":87633,"p50_ns":11455,"p99_ns":13503,"p999_ns":19199,"p9999_ns":19448,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 66374 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26213069,"operations":4000,"operations_per_second":152595,"p50_ns":6463,"p99_ns":8447,"p999_ns":13055,"p9999_ns":14085,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 67312 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25985807,"operations":4000,"operations_per_second":153930,"p50_ns":6303,"p99_ns":8191,"p999_ns":20607,"p9999_ns":121559,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1502457 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4675069,"operations":4000,"operations_per_second":855602,"p50_ns":1087,"p99_ns":1567,"p999_ns":3743,"p9999_ns":5458,"overflow":0,"peak_rss_bytes":0}
== epoll, round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12223 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":40598035,"operations":4000,"operations_per_second":98526,"p50_ns":10943,"p99_ns":12735,"p999_ns":16383,"p9999_ns":17150,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2270 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4474392,"operations":4000,"operations_per_second":893976,"p50_ns":1019,"p99_ns":1359,"p999_ns":8703,"p9999_ns":12854,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2153 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4230340,"operations":4000,"operations_per_second":945550,"p50_ns":987,"p99_ns":1319,"p999_ns":6303,"p9999_ns":10711,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2175 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4283955,"operations":4000,"operations_per_second":933716,"p50_ns":987,"p99_ns":1319,"p999_ns":8383,"p9999_ns":17861,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 12818 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":42520867,"operations":4000,"operations_per_second":94071,"p50_ns":10687,"p99_ns":11391,"p999_ns":15743,"p9999_ns":17310,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 22365 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4530853,"operations":4000,"operations_per_second":882835,"p50_ns":1019,"p99_ns":1367,"p999_ns":7103,"p9999_ns":7706,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22235 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4238302,"operations":4000,"operations_per_second":943774,"p50_ns":987,"p99_ns":1319,"p999_ns":3631,"p9999_ns":10485,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22238 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4258784,"operations":4000,"operations_per_second":939235,"p50_ns":987,"p99_ns":1319,"p999_ns":3199,"p9999_ns":8698,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 13165 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":44745430,"operations":4000,"operations_per_second":89394,"p50_ns":11071,"p99_ns":16511,"p999_ns":17919,"p9999_ns":29143,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 58338 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":23516188,"operations":4000,"operations_per_second":170095,"p50_ns":5759,"p99_ns":6847,"p999_ns":11071,"p9999_ns":155849,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 58699 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":22915371,"operations":4000,"operations_per_second":174555,"p50_ns":5663,"p99_ns":6719,"p999_ns":10879,"p9999_ns":11261,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102273 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4266161,"operations":4000,"operations_per_second":937611,"p50_ns":987,"p99_ns":1375,"p999_ns":2335,"p9999_ns":6209,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 13761 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":47882755,"operations":4000,"operations_per_second":83537,"p50_ns":11647,"p99_ns":14975,"p999_ns":42495,"p9999_ns":347877,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 59006 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26524477,"operations":4000,"operations_per_second":150804,"p50_ns":6463,"p99_ns":8511,"p999_ns":13183,"p9999_ns":13354,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 59457 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26582396,"operations":4000,"operations_per_second":150475,"p50_ns":6527,"p99_ns":8575,"p999_ns":12095,"p9999_ns":14186,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1002395 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4583263,"operations":4000,"operations_per_second":872740,"p50_ns":1063,"p99_ns":1527,"p999_ns":5311,"p9999_ns":5964,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 20931 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":46884903,"operations":4000,"operations_per_second":85315,"p50_ns":11519,"p99_ns":17151,"p999_ns":47871,"p9999_ns":57815,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 66408 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26464669,"operations":4000,"operations_per_second":151144,"p50_ns":6463,"p99_ns":10559,"p999_ns":18047,"p9999_ns":67204,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 67227 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25986425,"operations":4000,"operations_per_second":153926,"p50_ns":6367,"p99_ns":8447,"p999_ns":13055,"p9999_ns":54350,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1502462 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4695596,"operations":4000,"operations_per_second":851862,"p50_ns":1079,"p99_ns":1599,"p999_ns":6623,"p9999_ns":7471,"overflow":0,"peak_rss_bytes":0}
```
