# Decision 13's built spin budget on `github`, 2026-09-24

`rotor_post` on io_uring, in the CI job `costs`, started by hand nine times in three sets of three.
Each start got its own GitHub-hosted `ubuntu-24.04` runner. For each gap before a ping the job ran
four modes in turn, 2,000 round trips each after 200 not measured, three rounds:

- `waiting`: the loop blocks at once.
- `spin_then_wait`: the program ticks without waiting for 50 µs before it blocks.
- `spin_budget`: the loop is given a 50 µs `spin_budget_ns` in its options and blocks as `waiting`
  does, so the loop spins by itself.
- `spinning`: the loop never blocks.

Each `rotor_post:` line gives the CPU time the answering loop used per round trip. The JSON line
after it is the run's result; its histogram holds half a round trip, so its `p50_ns` is one
message. The three sets are:

1. Commit `a31f1a4`, the first build, which spun at the start of every tick given a wait.
2. Commit `dfebaa5`, which runs the spin window from the loop's last event.
3. Commit `5b441cc`, the same loop as `dfebaa5`, with a 1,500 µs gap added to the job.

Decision 13's section "Built" reads them.

## Set 1, run 1: AMD EPYC 7763 64-Core Processor, CI run 36028154840, commit a31f1a4

```text
== round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14429 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57083809,"operations":4000,"operations_per_second":70072,"p50_ns":12351,"p99_ns":21375,"p999_ns":27647,"p9999_ns":33512,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4676 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9270986,"operations":4000,"operations_per_second":431453,"p50_ns":2143,"p99_ns":3807,"p999_ns":19967,"p9999_ns":32615,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4478 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8882172,"operations":4000,"operations_per_second":450340,"p50_ns":2079,"p99_ns":3071,"p999_ns":13439,"p9999_ns":20573,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4471 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8848026,"operations":4000,"operations_per_second":452078,"p50_ns":2079,"p99_ns":3327,"p999_ns":14335,"p9999_ns":18309,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 16238 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":60589744,"operations":4000,"operations_per_second":66017,"p50_ns":16255,"p99_ns":20607,"p999_ns":28415,"p9999_ns":36368,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24848 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9595582,"operations":4000,"operations_per_second":416858,"p50_ns":2159,"p99_ns":5023,"p999_ns":11839,"p9999_ns":181151,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24587 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8874407,"operations":4000,"operations_per_second":450734,"p50_ns":2095,"p99_ns":3743,"p999_ns":9087,"p9999_ns":10960,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24686 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9066484,"operations":4000,"operations_per_second":441185,"p50_ns":2095,"p99_ns":3983,"p999_ns":12351,"p9999_ns":27195,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 14306 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":60851974,"operations":4000,"operations_per_second":65733,"p50_ns":16511,"p99_ns":21247,"p999_ns":31103,"p9999_ns":425565,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 60122 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":36374657,"operations":4000,"operations_per_second":109966,"p50_ns":9023,"p99_ns":13247,"p999_ns":17663,"p9999_ns":20518,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 60925 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34517845,"operations":4000,"operations_per_second":115882,"p50_ns":8831,"p99_ns":12351,"p999_ns":18687,"p9999_ns":55538,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 104933 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9471563,"operations":4000,"operations_per_second":422316,"p50_ns":2111,"p99_ns":9023,"p999_ns":10495,"p9999_ns":11170,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20337 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":55115115,"operations":4000,"operations_per_second":72575,"p50_ns":14527,"p99_ns":19327,"p999_ns":27519,"p9999_ns":33843,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 61017 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":41558769,"operations":4000,"operations_per_second":96249,"p50_ns":9663,"p99_ns":14143,"p999_ns":47359,"p9999_ns":934014,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 66713 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":55788421,"operations":4000,"operations_per_second":71699,"p50_ns":13375,"p99_ns":17151,"p999_ns":24831,"p9999_ns":1136746,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004947 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9781797,"operations":4000,"operations_per_second":408922,"p50_ns":2303,"p99_ns":4319,"p999_ns":9599,"p9999_ns":11291,"overflow":0,"peak_rss_bytes":0}
== round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13972 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57344666,"operations":4000,"operations_per_second":69753,"p50_ns":15231,"p99_ns":19839,"p999_ns":24063,"p9999_ns":25357,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4622 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9156013,"operations":4000,"operations_per_second":436871,"p50_ns":2143,"p99_ns":3183,"p999_ns":11519,"p9999_ns":32189,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4506 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8914319,"operations":4000,"operations_per_second":448716,"p50_ns":2079,"p99_ns":3087,"p999_ns":11967,"p9999_ns":40671,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4472 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8858641,"operations":4000,"operations_per_second":451536,"p50_ns":2079,"p99_ns":3071,"p999_ns":11391,"p9999_ns":29059,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 16468 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":63492724,"operations":4000,"operations_per_second":62999,"p50_ns":16639,"p99_ns":18303,"p999_ns":24447,"p9999_ns":27751,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24839 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9291089,"operations":4000,"operations_per_second":430520,"p50_ns":2159,"p99_ns":8511,"p999_ns":10943,"p9999_ns":11611,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24567 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8873008,"operations":4000,"operations_per_second":450805,"p50_ns":2095,"p99_ns":3519,"p999_ns":9919,"p9999_ns":10514,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24573 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8889755,"operations":4000,"operations_per_second":449956,"p50_ns":2095,"p99_ns":3599,"p999_ns":10495,"p9999_ns":11401,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 17172 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":66132400,"operations":4000,"operations_per_second":60484,"p50_ns":16639,"p99_ns":19583,"p999_ns":25599,"p9999_ns":26183,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 60101 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":36489819,"operations":4000,"operations_per_second":109619,"p50_ns":9023,"p99_ns":14143,"p999_ns":18047,"p9999_ns":18805,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 61330 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":36114650,"operations":4000,"operations_per_second":110758,"p50_ns":8959,"p99_ns":14015,"p999_ns":42239,"p9999_ns":71993,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 104951 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9490068,"operations":4000,"operations_per_second":421493,"p50_ns":2111,"p99_ns":9151,"p999_ns":11071,"p9999_ns":16355,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20989 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57219539,"operations":4000,"operations_per_second":69906,"p50_ns":14719,"p99_ns":22143,"p999_ns":44031,"p9999_ns":72540,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 61246 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":39958915,"operations":4000,"operations_per_second":100102,"p50_ns":9791,"p99_ns":14271,"p999_ns":17407,"p9999_ns":18860,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 66693 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":53670956,"operations":4000,"operations_per_second":74528,"p50_ns":13375,"p99_ns":17407,"p999_ns":23935,"p9999_ns":52417,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004977 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9834436,"operations":4000,"operations_per_second":406734,"p50_ns":2303,"p99_ns":3983,"p999_ns":9791,"p9999_ns":11120,"overflow":0,"peak_rss_bytes":0}
== round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 11837 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":54777670,"operations":4000,"operations_per_second":73022,"p50_ns":11903,"p99_ns":20607,"p999_ns":25599,"p9999_ns":38336,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4603 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9144852,"operations":4000,"operations_per_second":437404,"p50_ns":2143,"p99_ns":3183,"p999_ns":13119,"p9999_ns":44713,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4460 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8839063,"operations":4000,"operations_per_second":452536,"p50_ns":2079,"p99_ns":3087,"p999_ns":12415,"p9999_ns":33702,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4478 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8874027,"operations":4000,"operations_per_second":450753,"p50_ns":2079,"p99_ns":3439,"p999_ns":15295,"p9999_ns":19636,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 14456 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":59214759,"operations":4000,"operations_per_second":67550,"p50_ns":16383,"p99_ns":18303,"p999_ns":24191,"p9999_ns":28703,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24791 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9256580,"operations":4000,"operations_per_second":432125,"p50_ns":2143,"p99_ns":8383,"p999_ns":11007,"p9999_ns":12283,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24599 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8933749,"operations":4000,"operations_per_second":447740,"p50_ns":2095,"p99_ns":3263,"p999_ns":10303,"p9999_ns":11621,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24641 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8960934,"operations":4000,"operations_per_second":446382,"p50_ns":2095,"p99_ns":3711,"p999_ns":10815,"p9999_ns":11220,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 14869 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":61721447,"operations":4000,"operations_per_second":64807,"p50_ns":16639,"p99_ns":20351,"p999_ns":25855,"p9999_ns":26880,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 59371 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34749228,"operations":4000,"operations_per_second":115110,"p50_ns":8831,"p99_ns":14271,"p999_ns":38655,"p9999_ns":76767,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 61417 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":36216638,"operations":4000,"operations_per_second":110446,"p50_ns":8959,"p99_ns":12671,"p999_ns":17151,"p9999_ns":24570,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 105053 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9525187,"operations":4000,"operations_per_second":419939,"p50_ns":2127,"p99_ns":8959,"p999_ns":10687,"p9999_ns":17312,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20329 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57916586,"operations":4000,"operations_per_second":69064,"p50_ns":14463,"p99_ns":19327,"p999_ns":21247,"p9999_ns":1461304,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 61101 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":42438517,"operations":4000,"operations_per_second":94254,"p50_ns":9663,"p99_ns":14975,"p999_ns":303103,"p9999_ns":611159,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 67032 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":55700483,"operations":4000,"operations_per_second":71812,"p50_ns":13631,"p99_ns":16511,"p999_ns":20223,"p9999_ns":382425,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1005052 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9914522,"operations":4000,"operations_per_second":403448,"p50_ns":2319,"p99_ns":4255,"p999_ns":10111,"p9999_ns":11261,"overflow":0,"peak_rss_bytes":0}
```

## Set 1, run 2: AMD EPYC 7763 64-Core Processor, CI run 36028374469, commit a31f1a4

```text
== round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12606 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":56105476,"operations":4000,"operations_per_second":71294,"p50_ns":12351,"p99_ns":21375,"p999_ns":28415,"p9999_ns":37705,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4612 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9156887,"operations":4000,"operations_per_second":436829,"p50_ns":2143,"p99_ns":3263,"p999_ns":13247,"p9999_ns":30136,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4481 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8871493,"operations":4000,"operations_per_second":450882,"p50_ns":2079,"p99_ns":3055,"p999_ns":17919,"p9999_ns":18935,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4489 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8869725,"operations":4000,"operations_per_second":450972,"p50_ns":2079,"p99_ns":3039,"p999_ns":13183,"p9999_ns":22001,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 13927 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":59551079,"operations":4000,"operations_per_second":67169,"p50_ns":16639,"p99_ns":20735,"p999_ns":27647,"p9999_ns":35691,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24894 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9333407,"operations":4000,"operations_per_second":428568,"p50_ns":2159,"p99_ns":8447,"p999_ns":11647,"p9999_ns":12488,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24643 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9008622,"operations":4000,"operations_per_second":444019,"p50_ns":2095,"p99_ns":4287,"p999_ns":10687,"p9999_ns":12062,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24649 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8946857,"operations":4000,"operations_per_second":447084,"p50_ns":2095,"p99_ns":3471,"p999_ns":11071,"p9999_ns":16320,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 17591 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":69431949,"operations":4000,"operations_per_second":57610,"p50_ns":17279,"p99_ns":20991,"p999_ns":33023,"p9999_ns":193901,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 60218 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":37189235,"operations":4000,"operations_per_second":107558,"p50_ns":9151,"p99_ns":13631,"p999_ns":18047,"p9999_ns":18960,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 61382 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":36376789,"operations":4000,"operations_per_second":109960,"p50_ns":8959,"p99_ns":14143,"p999_ns":18815,"p9999_ns":21345,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 104981 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9544814,"operations":4000,"operations_per_second":419075,"p50_ns":2111,"p99_ns":9535,"p999_ns":11583,"p9999_ns":13695,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 21063 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":58266034,"operations":4000,"operations_per_second":68650,"p50_ns":15103,"p99_ns":21503,"p999_ns":35327,"p9999_ns":178718,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 61302 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":43520070,"operations":4000,"operations_per_second":91911,"p50_ns":10111,"p99_ns":14783,"p999_ns":158719,"p9999_ns":479974,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 67505 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57201790,"operations":4000,"operations_per_second":69927,"p50_ns":14207,"p99_ns":18303,"p999_ns":26239,"p9999_ns":126455,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004920 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9977237,"operations":4000,"operations_per_second":400912,"p50_ns":2303,"p99_ns":4575,"p999_ns":9343,"p9999_ns":9923,"overflow":0,"peak_rss_bytes":0}
== round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13487 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":56451736,"operations":4000,"operations_per_second":70856,"p50_ns":12223,"p99_ns":22527,"p999_ns":28927,"p9999_ns":33632,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4636 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9194782,"operations":4000,"operations_per_second":435029,"p50_ns":2159,"p99_ns":3279,"p999_ns":20479,"p9999_ns":21234,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4506 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8860130,"operations":4000,"operations_per_second":451460,"p50_ns":2079,"p99_ns":3263,"p999_ns":11007,"p9999_ns":17087,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4464 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8818480,"operations":4000,"operations_per_second":453592,"p50_ns":2079,"p99_ns":3151,"p999_ns":11327,"p9999_ns":19847,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 16762 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":66311459,"operations":4000,"operations_per_second":60321,"p50_ns":17023,"p99_ns":20095,"p999_ns":24447,"p9999_ns":25768,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24806 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9218759,"operations":4000,"operations_per_second":433897,"p50_ns":2159,"p99_ns":3551,"p999_ns":11007,"p9999_ns":11897,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24655 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9013261,"operations":4000,"operations_per_second":443790,"p50_ns":2095,"p99_ns":3599,"p999_ns":11007,"p9999_ns":11551,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24631 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8962910,"operations":4000,"operations_per_second":446283,"p50_ns":2095,"p99_ns":4479,"p999_ns":10367,"p9999_ns":12528,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 17576 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":68866825,"operations":4000,"operations_per_second":58083,"p50_ns":17279,"p99_ns":21375,"p999_ns":32383,"p9999_ns":72981,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 60274 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":37456791,"operations":4000,"operations_per_second":106789,"p50_ns":9215,"p99_ns":13119,"p999_ns":16063,"p9999_ns":16972,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 61263 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":36173399,"operations":4000,"operations_per_second":110578,"p50_ns":8959,"p99_ns":13503,"p999_ns":18047,"p9999_ns":92156,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 105066 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9326966,"operations":4000,"operations_per_second":428864,"p50_ns":2111,"p99_ns":8639,"p999_ns":11007,"p9999_ns":12939,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20904 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":58242376,"operations":4000,"operations_per_second":68678,"p50_ns":15039,"p99_ns":21503,"p999_ns":61183,"p9999_ns":217425,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 61114 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":43568484,"operations":4000,"operations_per_second":91809,"p50_ns":9983,"p99_ns":17535,"p999_ns":47359,"p9999_ns":876738,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 66742 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":56880557,"operations":4000,"operations_per_second":70322,"p50_ns":13759,"p99_ns":18303,"p999_ns":25215,"p9999_ns":918586,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1005043 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9948446,"operations":4000,"operations_per_second":402072,"p50_ns":2303,"p99_ns":4511,"p999_ns":10751,"p9999_ns":11521,"overflow":0,"peak_rss_bytes":0}
== round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13413 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":56578246,"operations":4000,"operations_per_second":70698,"p50_ns":12223,"p99_ns":21119,"p999_ns":28799,"p9999_ns":36608,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4586 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9065577,"operations":4000,"operations_per_second":441229,"p50_ns":2143,"p99_ns":3167,"p999_ns":11391,"p9999_ns":19005,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4481 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8852377,"operations":4000,"operations_per_second":451856,"p50_ns":2079,"p99_ns":3055,"p999_ns":12607,"p9999_ns":23879,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4467 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8827638,"operations":4000,"operations_per_second":453122,"p50_ns":2079,"p99_ns":3039,"p999_ns":12479,"p9999_ns":24921,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 12817 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57291675,"operations":4000,"operations_per_second":69818,"p50_ns":12607,"p99_ns":22015,"p999_ns":28415,"p9999_ns":32425,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24911 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9469544,"operations":4000,"operations_per_second":422406,"p50_ns":2159,"p99_ns":9343,"p999_ns":11199,"p9999_ns":12032,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24593 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8934304,"operations":4000,"operations_per_second":447712,"p50_ns":2095,"p99_ns":3327,"p999_ns":10111,"p9999_ns":10725,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24719 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9082705,"operations":4000,"operations_per_second":440397,"p50_ns":2095,"p99_ns":5439,"p999_ns":12287,"p9999_ns":16806,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 15937 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":65391076,"operations":4000,"operations_per_second":61170,"p50_ns":17151,"p99_ns":20479,"p999_ns":27391,"p9999_ns":47212,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 60116 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":37018473,"operations":4000,"operations_per_second":108054,"p50_ns":9151,"p99_ns":13631,"p999_ns":17407,"p9999_ns":19631,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 61186 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35900483,"operations":4000,"operations_per_second":111419,"p50_ns":8959,"p99_ns":13119,"p999_ns":17151,"p9999_ns":18464,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 105067 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9601566,"operations":4000,"operations_per_second":416598,"p50_ns":2127,"p99_ns":9727,"p999_ns":11583,"p9999_ns":16887,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 21120 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57393930,"operations":4000,"operations_per_second":69693,"p50_ns":14975,"p99_ns":20095,"p999_ns":28287,"p9999_ns":40726,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 60937 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":42623699,"operations":4000,"operations_per_second":93844,"p50_ns":9791,"p99_ns":14975,"p999_ns":19839,"p9999_ns":1138707,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 66622 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":54581382,"operations":4000,"operations_per_second":73285,"p50_ns":13631,"p99_ns":18047,"p999_ns":21119,"p9999_ns":27416,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1005116 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10028511,"operations":4000,"operations_per_second":398862,"p50_ns":2351,"p99_ns":4223,"p999_ns":10047,"p9999_ns":16861,"overflow":0,"peak_rss_bytes":0}
```

## Set 1, run 3: AMD EPYC 7763 64-Core Processor, CI run 36028385210, commit a31f1a4

```text
== round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12908 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":59291902,"operations":4000,"operations_per_second":67462,"p50_ns":12863,"p99_ns":21887,"p999_ns":28415,"p9999_ns":48170,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4654 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9207174,"operations":4000,"operations_per_second":434443,"p50_ns":2159,"p99_ns":3167,"p999_ns":14847,"p9999_ns":49247,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4464 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8858774,"operations":4000,"operations_per_second":451529,"p50_ns":2079,"p99_ns":3023,"p999_ns":11839,"p9999_ns":40425,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4479 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8873803,"operations":4000,"operations_per_second":450765,"p50_ns":2079,"p99_ns":3391,"p999_ns":12415,"p9999_ns":30722,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 16596 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":65990660,"operations":4000,"operations_per_second":60614,"p50_ns":17151,"p99_ns":22015,"p999_ns":34815,"p9999_ns":41527,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24909 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9308909,"operations":4000,"operations_per_second":429695,"p50_ns":2159,"p99_ns":5087,"p999_ns":14015,"p9999_ns":17357,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24549 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8834665,"operations":4000,"operations_per_second":452761,"p50_ns":2095,"p99_ns":3375,"p999_ns":9791,"p9999_ns":11356,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24538 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8919128,"operations":4000,"operations_per_second":448474,"p50_ns":2079,"p99_ns":3263,"p999_ns":9919,"p9999_ns":59065,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 14100 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":62850931,"operations":4000,"operations_per_second":63642,"p50_ns":17023,"p99_ns":21503,"p999_ns":29951,"p9999_ns":775354,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 60159 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":37344819,"operations":4000,"operations_per_second":107109,"p50_ns":9151,"p99_ns":12927,"p999_ns":17535,"p9999_ns":181599,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 61362 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":36289129,"operations":4000,"operations_per_second":110225,"p50_ns":8959,"p99_ns":13183,"p999_ns":16767,"p9999_ns":18740,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 104938 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9690888,"operations":4000,"operations_per_second":412758,"p50_ns":2111,"p99_ns":9343,"p999_ns":14143,"p9999_ns":131526,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20446 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":56707218,"operations":4000,"operations_per_second":70537,"p50_ns":14975,"p99_ns":20223,"p999_ns":27647,"p9999_ns":269378,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 61197 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":40657631,"operations":4000,"operations_per_second":98382,"p50_ns":9919,"p99_ns":14335,"p999_ns":19839,"p9999_ns":117464,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 66908 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":55622250,"operations":4000,"operations_per_second":71913,"p50_ns":13759,"p99_ns":18815,"p999_ns":23679,"p9999_ns":75601,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004859 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9726816,"operations":4000,"operations_per_second":411234,"p50_ns":2303,"p99_ns":3663,"p999_ns":9599,"p9999_ns":10945,"overflow":0,"peak_rss_bytes":0}
== round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15402 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":63902792,"operations":4000,"operations_per_second":62595,"p50_ns":17407,"p99_ns":19071,"p999_ns":23935,"p9999_ns":27526,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4617 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9175946,"operations":4000,"operations_per_second":435922,"p50_ns":2143,"p99_ns":3247,"p999_ns":13055,"p9999_ns":31063,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4492 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8900084,"operations":4000,"operations_per_second":449433,"p50_ns":2079,"p99_ns":3135,"p999_ns":12031,"p9999_ns":36543,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4470 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8892944,"operations":4000,"operations_per_second":449794,"p50_ns":2079,"p99_ns":3551,"p999_ns":14399,"p9999_ns":25988,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 16531 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":63556043,"operations":4000,"operations_per_second":62936,"p50_ns":17023,"p99_ns":19199,"p999_ns":26367,"p9999_ns":28979,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24754 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9108672,"operations":4000,"operations_per_second":439141,"p50_ns":2159,"p99_ns":3647,"p999_ns":10367,"p9999_ns":11481,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24570 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8890308,"operations":4000,"operations_per_second":449928,"p50_ns":2095,"p99_ns":3535,"p999_ns":9855,"p9999_ns":10785,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24607 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8957008,"operations":4000,"operations_per_second":446577,"p50_ns":2095,"p99_ns":3775,"p999_ns":10943,"p9999_ns":25718,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 17709 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":69360086,"operations":4000,"operations_per_second":57670,"p50_ns":17279,"p99_ns":20223,"p999_ns":27647,"p9999_ns":64511,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 59346 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35280591,"operations":4000,"operations_per_second":113376,"p50_ns":9087,"p99_ns":13375,"p999_ns":15871,"p9999_ns":17833,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 61355 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":36324436,"operations":4000,"operations_per_second":110118,"p50_ns":8959,"p99_ns":13183,"p999_ns":15423,"p9999_ns":16050,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 104816 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9271366,"operations":4000,"operations_per_second":431435,"p50_ns":2095,"p99_ns":8511,"p999_ns":10751,"p9999_ns":11211,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20419 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":56099328,"operations":4000,"operations_per_second":71302,"p50_ns":15039,"p99_ns":19967,"p999_ns":25343,"p9999_ns":38016,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 61190 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":40319914,"operations":4000,"operations_per_second":99206,"p50_ns":9919,"p99_ns":13759,"p999_ns":17407,"p9999_ns":20734,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 66729 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":54942757,"operations":4000,"operations_per_second":72803,"p50_ns":13695,"p99_ns":17279,"p999_ns":20479,"p9999_ns":27035,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004877 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9661653,"operations":4000,"operations_per_second":414007,"p50_ns":2287,"p99_ns":3631,"p999_ns":9919,"p9999_ns":10745,"overflow":0,"peak_rss_bytes":0}
== round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13851 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57414624,"operations":4000,"operations_per_second":69668,"p50_ns":12351,"p99_ns":20095,"p999_ns":24063,"p9999_ns":28488,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4619 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9158241,"operations":4000,"operations_per_second":436765,"p50_ns":2143,"p99_ns":3135,"p999_ns":13951,"p9999_ns":26023,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4439 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8811606,"operations":4000,"operations_per_second":453946,"p50_ns":2079,"p99_ns":3103,"p999_ns":12223,"p9999_ns":36267,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4466 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8853416,"operations":4000,"operations_per_second":451803,"p50_ns":2079,"p99_ns":3071,"p999_ns":17919,"p9999_ns":28528,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 14039 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":59955440,"operations":4000,"operations_per_second":66716,"p50_ns":16895,"p99_ns":21887,"p999_ns":26367,"p9999_ns":31554,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24829 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9281568,"operations":4000,"operations_per_second":430961,"p50_ns":2159,"p99_ns":8703,"p999_ns":10879,"p9999_ns":11481,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24696 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9031171,"operations":4000,"operations_per_second":442910,"p50_ns":2095,"p99_ns":4703,"p999_ns":13951,"p9999_ns":28188,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24577 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8860477,"operations":4000,"operations_per_second":451442,"p50_ns":2079,"p99_ns":3919,"p999_ns":9535,"p9999_ns":10078,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 13326 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":59703755,"operations":4000,"operations_per_second":66997,"p50_ns":16767,"p99_ns":20735,"p999_ns":27135,"p9999_ns":31318,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 60076 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":36868890,"operations":4000,"operations_per_second":108492,"p50_ns":9151,"p99_ns":13119,"p999_ns":15423,"p9999_ns":18124,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 61381 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":36702125,"operations":4000,"operations_per_second":108985,"p50_ns":9023,"p99_ns":13951,"p999_ns":16639,"p9999_ns":18679,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 104868 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9343409,"operations":4000,"operations_per_second":428109,"p50_ns":2095,"p99_ns":9407,"p999_ns":10751,"p9999_ns":11657,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20001 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57976410,"operations":4000,"operations_per_second":68993,"p50_ns":14783,"p99_ns":21119,"p999_ns":44543,"p9999_ns":1246090,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 61279 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":41427740,"operations":4000,"operations_per_second":96553,"p50_ns":9919,"p99_ns":16063,"p999_ns":51455,"p9999_ns":82830,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 67195 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":56039347,"operations":4000,"operations_per_second":71378,"p50_ns":13951,"p99_ns":18559,"p999_ns":20991,"p9999_ns":50284,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004894 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9672770,"operations":4000,"operations_per_second":413532,"p50_ns":2287,"p99_ns":3855,"p999_ns":9087,"p9999_ns":9843,"overflow":0,"peak_rss_bytes":0}
```

## Set 2, run 1: AMD EPYC 9V45 96-Core Processor, CI run 36030640675, commit dfebaa5

```text
== round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9459 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":38024109,"operations":4000,"operations_per_second":105196,"p50_ns":9599,"p99_ns":13631,"p999_ns":16191,"p9999_ns":108603,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2920 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5833182,"operations":4000,"operations_per_second":685732,"p50_ns":1359,"p99_ns":2079,"p999_ns":9151,"p9999_ns":24587,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2882 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5789009,"operations":4000,"operations_per_second":690964,"p50_ns":1327,"p99_ns":1935,"p999_ns":14463,"p9999_ns":38944,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2898 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5730604,"operations":4000,"operations_per_second":698006,"p50_ns":1343,"p99_ns":2303,"p999_ns":10175,"p9999_ns":17771,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 8866 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":36093731,"operations":4000,"operations_per_second":110822,"p50_ns":9279,"p99_ns":13375,"p999_ns":18047,"p9999_ns":22088,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 23021 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5795596,"operations":4000,"operations_per_second":690179,"p50_ns":1383,"p99_ns":1975,"p999_ns":6495,"p9999_ns":10315,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22980 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5732725,"operations":4000,"operations_per_second":697748,"p50_ns":1359,"p99_ns":2015,"p999_ns":6143,"p9999_ns":6845,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 22989 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5756875,"operations":4000,"operations_per_second":694821,"p50_ns":1359,"p99_ns":2031,"p999_ns":7135,"p9999_ns":10275,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 9722 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":39400125,"operations":4000,"operations_per_second":101522,"p50_ns":9919,"p99_ns":11647,"p999_ns":15615,"p9999_ns":16294,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 55340 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":22718708,"operations":4000,"operations_per_second":176066,"p50_ns":5567,"p99_ns":6431,"p999_ns":53759,"p9999_ns":72920,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 55511 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":22840533,"operations":4000,"operations_per_second":175127,"p50_ns":5567,"p99_ns":6271,"p999_ns":42495,"p9999_ns":204774,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102963 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5715827,"operations":4000,"operations_per_second":699811,"p50_ns":1359,"p99_ns":1991,"p999_ns":5919,"p9999_ns":6424,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 9356 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":27626183,"operations":4000,"operations_per_second":144790,"p50_ns":5535,"p99_ns":13695,"p999_ns":107519,"p9999_ns":138589,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 55907 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26911440,"operations":4000,"operations_per_second":148635,"p50_ns":5695,"p99_ns":50943,"p999_ns":82943,"p9999_ns":118829,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 57344 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24951076,"operations":4000,"operations_per_second":160313,"p50_ns":6079,"p99_ns":7743,"p999_ns":11455,"p9999_ns":78528,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1003116 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":6172156,"operations":4000,"operations_per_second":648071,"p50_ns":1471,"p99_ns":2223,"p999_ns":6047,"p9999_ns":10936,"overflow":0,"peak_rss_bytes":0}
== round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8985 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35242477,"operations":4000,"operations_per_second":113499,"p50_ns":8703,"p99_ns":11455,"p999_ns":15295,"p9999_ns":30355,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2958 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5840704,"operations":4000,"operations_per_second":684848,"p50_ns":1383,"p99_ns":1975,"p999_ns":6367,"p9999_ns":22554,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2947 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5941608,"operations":4000,"operations_per_second":673218,"p50_ns":1359,"p99_ns":2111,"p999_ns":19839,"p9999_ns":55994,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2933 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5804834,"operations":4000,"operations_per_second":689080,"p50_ns":1367,"p99_ns":2223,"p999_ns":7743,"p9999_ns":19314,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 8709 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35841002,"operations":4000,"operations_per_second":111604,"p50_ns":8831,"p99_ns":10751,"p999_ns":17791,"p9999_ns":34512,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 23034 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5840705,"operations":4000,"operations_per_second":684848,"p50_ns":1399,"p99_ns":2015,"p999_ns":6335,"p9999_ns":9820,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22991 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5754723,"operations":4000,"operations_per_second":695081,"p50_ns":1367,"p99_ns":1983,"p999_ns":6079,"p9999_ns":18057,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 23020 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5793628,"operations":4000,"operations_per_second":690413,"p50_ns":1367,"p99_ns":1959,"p999_ns":6367,"p9999_ns":23721,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 8759 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":38153736,"operations":4000,"operations_per_second":104839,"p50_ns":9087,"p99_ns":22399,"p999_ns":63231,"p9999_ns":72349,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 55390 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":23681497,"operations":4000,"operations_per_second":168908,"p50_ns":5535,"p99_ns":7615,"p999_ns":73727,"p9999_ns":84417,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 55393 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":21922990,"operations":4000,"operations_per_second":182456,"p50_ns":5471,"p99_ns":6303,"p999_ns":15167,"p9999_ns":24337,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102976 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5764129,"operations":4000,"operations_per_second":693946,"p50_ns":1367,"p99_ns":2287,"p999_ns":5119,"p9999_ns":8042,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 9194 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":29213432,"operations":4000,"operations_per_second":136923,"p50_ns":5535,"p99_ns":48127,"p999_ns":99839,"p9999_ns":120607,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 55908 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26407497,"operations":4000,"operations_per_second":151472,"p50_ns":5599,"p99_ns":53503,"p999_ns":92159,"p9999_ns":109785,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 57237 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26003201,"operations":4000,"operations_per_second":153827,"p50_ns":6015,"p99_ns":9791,"p999_ns":67071,"p9999_ns":379993,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1003150 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":6185427,"operations":4000,"operations_per_second":646681,"p50_ns":1463,"p99_ns":2159,"p999_ns":9023,"p9999_ns":22073,"overflow":0,"peak_rss_bytes":0}
== round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8126 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":32855890,"operations":4000,"operations_per_second":121743,"p50_ns":8255,"p99_ns":11647,"p999_ns":21247,"p9999_ns":26305,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2921 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5774675,"operations":4000,"operations_per_second":692679,"p50_ns":1375,"p99_ns":2399,"p999_ns":5855,"p9999_ns":10300,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2867 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5688965,"operations":4000,"operations_per_second":703115,"p50_ns":1343,"p99_ns":1919,"p999_ns":10943,"p9999_ns":29579,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2914 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5772740,"operations":4000,"operations_per_second":692911,"p50_ns":1367,"p99_ns":1919,"p999_ns":6271,"p9999_ns":19319,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 8224 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":33829802,"operations":4000,"operations_per_second":118238,"p50_ns":8383,"p99_ns":11775,"p999_ns":15295,"p9999_ns":21007,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 22990 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5764030,"operations":4000,"operations_per_second":693958,"p50_ns":1367,"p99_ns":2239,"p999_ns":5727,"p9999_ns":16780,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 23000 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5758927,"operations":4000,"operations_per_second":694573,"p50_ns":1351,"p99_ns":2159,"p999_ns":6655,"p9999_ns":9980,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 23036 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5801946,"operations":4000,"operations_per_second":689423,"p50_ns":1367,"p99_ns":2351,"p999_ns":7103,"p9999_ns":7937,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 9581 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":38908571,"operations":4000,"operations_per_second":102805,"p50_ns":9727,"p99_ns":13375,"p999_ns":15487,"p9999_ns":26871,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 55214 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":22067384,"operations":4000,"operations_per_second":181262,"p50_ns":5535,"p99_ns":6239,"p999_ns":10495,"p9999_ns":11597,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 55235 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":22009837,"operations":4000,"operations_per_second":181736,"p50_ns":5535,"p99_ns":6335,"p999_ns":14655,"p9999_ns":29589,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102984 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5759469,"operations":4000,"operations_per_second":694508,"p50_ns":1367,"p99_ns":2303,"p999_ns":6559,"p9999_ns":6875,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 9326 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":32707238,"operations":4000,"operations_per_second":122297,"p50_ns":5695,"p99_ns":57599,"p999_ns":113663,"p9999_ns":174828,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 55738 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26854096,"operations":4000,"operations_per_second":148953,"p50_ns":5599,"p99_ns":45311,"p999_ns":61695,"p9999_ns":198509,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 57352 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34373319,"operations":4000,"operations_per_second":116369,"p50_ns":6111,"p99_ns":10495,"p999_ns":1056767,"p9999_ns":1654060,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1003114 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":6138738,"operations":4000,"operations_per_second":651599,"p50_ns":1455,"p99_ns":2191,"p999_ns":9407,"p9999_ns":10856,"overflow":0,"peak_rss_bytes":0}
```

## Set 2, run 2: AMD EPYC 7763 64-Core Processor, CI run 36030652152, commit dfebaa5

```text
== round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13112 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":53800069,"operations":4000,"operations_per_second":74349,"p50_ns":12287,"p99_ns":21631,"p999_ns":27647,"p9999_ns":47664,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4668 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9244328,"operations":4000,"operations_per_second":432697,"p50_ns":2159,"p99_ns":3343,"p999_ns":14015,"p9999_ns":18064,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4530 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8969393,"operations":4000,"operations_per_second":445961,"p50_ns":2111,"p99_ns":3071,"p999_ns":11263,"p9999_ns":35381,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4563 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9031764,"operations":4000,"operations_per_second":442881,"p50_ns":2111,"p99_ns":3311,"p999_ns":14847,"p9999_ns":23895,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 16892 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":63372905,"operations":4000,"operations_per_second":63118,"p50_ns":16319,"p99_ns":18815,"p999_ns":24063,"p9999_ns":31008,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24934 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9359733,"operations":4000,"operations_per_second":427362,"p50_ns":2175,"p99_ns":5983,"p999_ns":10495,"p9999_ns":11186,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24701 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9114191,"operations":4000,"operations_per_second":438876,"p50_ns":2127,"p99_ns":6975,"p999_ns":11007,"p9999_ns":11887,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24672 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9046752,"operations":4000,"operations_per_second":442147,"p50_ns":2111,"p99_ns":3487,"p999_ns":11007,"p9999_ns":13405,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 16915 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":65236574,"operations":4000,"operations_per_second":61315,"p50_ns":16639,"p99_ns":19327,"p999_ns":25983,"p9999_ns":26830,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 59722 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35384393,"operations":4000,"operations_per_second":113044,"p50_ns":8767,"p99_ns":12287,"p999_ns":20863,"p9999_ns":80876,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 59679 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34389068,"operations":4000,"operations_per_second":116316,"p50_ns":8639,"p99_ns":10431,"p999_ns":15231,"p9999_ns":18084,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 105084 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9818608,"operations":4000,"operations_per_second":407389,"p50_ns":2127,"p99_ns":9471,"p999_ns":11647,"p9999_ns":183559,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20493 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":88722828,"operations":4000,"operations_per_second":45084,"p50_ns":14463,"p99_ns":21759,"p999_ns":1515519,"p9999_ns":2997240,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 61223 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":42344995,"operations":4000,"operations_per_second":94462,"p50_ns":9663,"p99_ns":14463,"p999_ns":21631,"p9999_ns":1374855,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 65352 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":53922237,"operations":4000,"operations_per_second":74180,"p50_ns":13439,"p99_ns":18047,"p999_ns":38911,"p9999_ns":63564,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004993 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9871884,"operations":4000,"operations_per_second":405191,"p50_ns":2319,"p99_ns":4255,"p999_ns":9599,"p9999_ns":9733,"overflow":0,"peak_rss_bytes":0}
== round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14098 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57137540,"operations":4000,"operations_per_second":70006,"p50_ns":16319,"p99_ns":20095,"p999_ns":24831,"p9999_ns":27246,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4659 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9262685,"operations":4000,"operations_per_second":431840,"p50_ns":2159,"p99_ns":3391,"p999_ns":16063,"p9999_ns":36132,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4531 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8977529,"operations":4000,"operations_per_second":445556,"p50_ns":2111,"p99_ns":3391,"p999_ns":17919,"p9999_ns":37245,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4588 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9110984,"operations":4000,"operations_per_second":439030,"p50_ns":2111,"p99_ns":3279,"p999_ns":19839,"p9999_ns":65177,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 16977 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":62117168,"operations":4000,"operations_per_second":64394,"p50_ns":16319,"p99_ns":19327,"p999_ns":27007,"p9999_ns":30051,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24942 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9403887,"operations":4000,"operations_per_second":425356,"p50_ns":2175,"p99_ns":8703,"p999_ns":10879,"p9999_ns":11546,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24693 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9133645,"operations":4000,"operations_per_second":437941,"p50_ns":2111,"p99_ns":8447,"p999_ns":10559,"p9999_ns":12293,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24692 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9088396,"operations":4000,"operations_per_second":440121,"p50_ns":2111,"p99_ns":6015,"p999_ns":10239,"p9999_ns":11226,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 17331 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":66295656,"operations":4000,"operations_per_second":60335,"p50_ns":16639,"p99_ns":20991,"p999_ns":25855,"p9999_ns":43331,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 59967 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35547651,"operations":4000,"operations_per_second":112525,"p50_ns":8767,"p99_ns":11775,"p999_ns":16767,"p9999_ns":19767,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 59376 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":33777594,"operations":4000,"operations_per_second":118421,"p50_ns":8639,"p99_ns":10751,"p999_ns":16511,"p9999_ns":26008,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 105113 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9694179,"operations":4000,"operations_per_second":412618,"p50_ns":2143,"p99_ns":9535,"p999_ns":12479,"p9999_ns":18023,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20422 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":55068627,"operations":4000,"operations_per_second":72636,"p50_ns":14463,"p99_ns":19455,"p999_ns":22911,"p9999_ns":31589,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 60915 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":38578336,"operations":4000,"operations_per_second":103685,"p50_ns":9407,"p99_ns":13631,"p999_ns":16063,"p9999_ns":115430,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 65265 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":55281438,"operations":4000,"operations_per_second":72357,"p50_ns":13311,"p99_ns":16511,"p999_ns":19839,"p9999_ns":1051675,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004990 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9841877,"operations":4000,"operations_per_second":406426,"p50_ns":2319,"p99_ns":4159,"p999_ns":9919,"p9999_ns":10204,"overflow":0,"peak_rss_bytes":0}
== round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12848 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":53555888,"operations":4000,"operations_per_second":74688,"p50_ns":11711,"p99_ns":19199,"p999_ns":27775,"p9999_ns":34128,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4696 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9283290,"operations":4000,"operations_per_second":430881,"p50_ns":2191,"p99_ns":3231,"p999_ns":12927,"p9999_ns":17918,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4510 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8946025,"operations":4000,"operations_per_second":447125,"p50_ns":2111,"p99_ns":3599,"p999_ns":11455,"p9999_ns":22487,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4525 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8941440,"operations":4000,"operations_per_second":447355,"p50_ns":2111,"p99_ns":3103,"p999_ns":13183,"p9999_ns":28663,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 13971 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57173533,"operations":4000,"operations_per_second":69962,"p50_ns":16063,"p99_ns":19839,"p999_ns":27135,"p9999_ns":28769,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24880 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9421147,"operations":4000,"operations_per_second":424576,"p50_ns":2175,"p99_ns":8575,"p999_ns":12031,"p9999_ns":18865,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24705 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9105312,"operations":4000,"operations_per_second":439304,"p50_ns":2127,"p99_ns":4895,"p999_ns":10943,"p9999_ns":11371,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24712 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9056191,"operations":4000,"operations_per_second":441686,"p50_ns":2127,"p99_ns":3935,"p999_ns":10047,"p9999_ns":17332,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 17016 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":65498775,"operations":4000,"operations_per_second":61069,"p50_ns":16639,"p99_ns":19711,"p999_ns":27263,"p9999_ns":30131,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 59864 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35497526,"operations":4000,"operations_per_second":112683,"p50_ns":8703,"p99_ns":11327,"p999_ns":15679,"p9999_ns":188988,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 59544 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34046169,"operations":4000,"operations_per_second":117487,"p50_ns":8575,"p99_ns":11711,"p999_ns":15743,"p9999_ns":17828,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 105076 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9427254,"operations":4000,"operations_per_second":424301,"p50_ns":2143,"p99_ns":8575,"p999_ns":9855,"p9999_ns":10284,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20452 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":59960856,"operations":4000,"operations_per_second":66710,"p50_ns":14463,"p99_ns":19583,"p999_ns":22911,"p9999_ns":1242938,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 61147 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":42329981,"operations":4000,"operations_per_second":94495,"p50_ns":9599,"p99_ns":14271,"p999_ns":73215,"p9999_ns":1386231,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 65547 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":53885512,"operations":4000,"operations_per_second":74231,"p50_ns":13439,"p99_ns":16895,"p999_ns":23039,"p9999_ns":80280,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004960 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9785660,"operations":4000,"operations_per_second":408761,"p50_ns":2319,"p99_ns":3903,"p999_ns":9663,"p9999_ns":9973,"overflow":0,"peak_rss_bytes":0}
```

## Set 2, run 3: AMD EPYC 9V45 96-Core Processor, CI run 36030664713, commit dfebaa5

```text
== round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8971 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":36919784,"operations":4000,"operations_per_second":108342,"p50_ns":8895,"p99_ns":15167,"p999_ns":22143,"p9999_ns":27206,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2940 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5807248,"operations":4000,"operations_per_second":688794,"p50_ns":1359,"p99_ns":2335,"p999_ns":15423,"p9999_ns":24502,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2888 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5705373,"operations":4000,"operations_per_second":701093,"p50_ns":1343,"p99_ns":1903,"p999_ns":12479,"p9999_ns":20561,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2892 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5734867,"operations":4000,"operations_per_second":697487,"p50_ns":1359,"p99_ns":1919,"p999_ns":6559,"p9999_ns":27446,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 9093 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35908860,"operations":4000,"operations_per_second":111393,"p50_ns":9215,"p99_ns":13311,"p999_ns":15615,"p9999_ns":29069,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 23027 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5792832,"operations":4000,"operations_per_second":690508,"p50_ns":1383,"p99_ns":2015,"p999_ns":5279,"p9999_ns":6475,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 22987 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5785164,"operations":4000,"operations_per_second":691423,"p50_ns":1343,"p99_ns":1983,"p999_ns":7231,"p9999_ns":53060,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 23359 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":6226966,"operations":4000,"operations_per_second":642367,"p50_ns":1327,"p99_ns":3151,"p999_ns":44543,"p9999_ns":67957,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 9968 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57011505,"operations":4000,"operations_per_second":70161,"p50_ns":9535,"p99_ns":83967,"p999_ns":173055,"p9999_ns":187152,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 55345 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":21989914,"operations":4000,"operations_per_second":181901,"p50_ns":5471,"p99_ns":6239,"p999_ns":8575,"p9999_ns":10926,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 55345 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":21803531,"operations":4000,"operations_per_second":183456,"p50_ns":5439,"p99_ns":6303,"p999_ns":10751,"p9999_ns":14407,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 102962 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5739161,"operations":4000,"operations_per_second":696965,"p50_ns":1367,"p99_ns":1999,"p999_ns":3423,"p9999_ns":6319,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 9435 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":30215472,"operations":4000,"operations_per_second":132382,"p50_ns":5663,"p99_ns":54271,"p999_ns":96255,"p9999_ns":140592,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 55858 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25795663,"operations":4000,"operations_per_second":155064,"p50_ns":5695,"p99_ns":33535,"p999_ns":106495,"p9999_ns":135534,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 57379 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25603376,"operations":4000,"operations_per_second":156229,"p50_ns":6111,"p99_ns":9727,"p999_ns":73215,"p9999_ns":125193,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1003053 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":6346861,"operations":4000,"operations_per_second":630232,"p50_ns":1495,"p99_ns":2527,"p999_ns":6911,"p9999_ns":11497,"overflow":0,"peak_rss_bytes":0}
== round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9140 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35258989,"operations":4000,"operations_per_second":113446,"p50_ns":8639,"p99_ns":12799,"p999_ns":16511,"p9999_ns":28007,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 3014 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5991457,"operations":4000,"operations_per_second":667617,"p50_ns":1399,"p99_ns":2063,"p999_ns":8575,"p9999_ns":29544,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2935 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5801878,"operations":4000,"operations_per_second":689431,"p50_ns":1367,"p99_ns":1967,"p999_ns":7135,"p9999_ns":21873,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2929 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5781764,"operations":4000,"operations_per_second":691830,"p50_ns":1367,"p99_ns":1975,"p999_ns":10559,"p9999_ns":15228,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 9083 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":36707456,"operations":4000,"operations_per_second":108969,"p50_ns":9279,"p99_ns":12863,"p999_ns":15231,"p9999_ns":156986,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 23143 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":6057818,"operations":4000,"operations_per_second":660303,"p50_ns":1399,"p99_ns":2255,"p999_ns":6815,"p9999_ns":61893,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 23064 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5869704,"operations":4000,"operations_per_second":681465,"p50_ns":1359,"p99_ns":2447,"p999_ns":7359,"p9999_ns":36349,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 23037 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5821176,"operations":4000,"operations_per_second":687146,"p50_ns":1375,"p99_ns":2063,"p999_ns":5791,"p9999_ns":17556,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 9223 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":37698523,"operations":4000,"operations_per_second":106104,"p50_ns":9599,"p99_ns":12287,"p999_ns":15807,"p9999_ns":17186,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 55365 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":21830692,"operations":4000,"operations_per_second":183228,"p50_ns":5471,"p99_ns":6335,"p999_ns":11391,"p9999_ns":17351,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 55419 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":22130241,"operations":4000,"operations_per_second":180748,"p50_ns":5471,"p99_ns":6207,"p999_ns":10431,"p9999_ns":89960,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 103083 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5962944,"operations":4000,"operations_per_second":670809,"p50_ns":1391,"p99_ns":2143,"p999_ns":6399,"p9999_ns":45128,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 9028 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26083628,"operations":4000,"operations_per_second":153352,"p50_ns":5759,"p99_ns":11967,"p999_ns":52735,"p9999_ns":156510,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 55715 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24619308,"operations":4000,"operations_per_second":162474,"p50_ns":5631,"p99_ns":7775,"p999_ns":178175,"p9999_ns":350538,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 57488 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":26578190,"operations":4000,"operations_per_second":150499,"p50_ns":6175,"p99_ns":10495,"p999_ns":92671,"p9999_ns":136646,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1003146 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":6268895,"operations":4000,"operations_per_second":638070,"p50_ns":1487,"p99_ns":2415,"p999_ns":6879,"p9999_ns":10962,"overflow":0,"peak_rss_bytes":0}
== round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8140 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":33702079,"operations":4000,"operations_per_second":118687,"p50_ns":8511,"p99_ns":12735,"p999_ns":15359,"p9999_ns":23841,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 2974 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5881951,"operations":4000,"operations_per_second":680046,"p50_ns":1383,"p99_ns":2063,"p999_ns":13439,"p9999_ns":18152,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 2909 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5756440,"operations":4000,"operations_per_second":694873,"p50_ns":1359,"p99_ns":2063,"p999_ns":7743,"p9999_ns":10651,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2909 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5745134,"operations":4000,"operations_per_second":696241,"p50_ns":1359,"p99_ns":1975,"p999_ns":8895,"p9999_ns":13230,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 9351 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":36873410,"operations":4000,"operations_per_second":108479,"p50_ns":9215,"p99_ns":11391,"p999_ns":15359,"p9999_ns":19334,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 23133 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":6018804,"operations":4000,"operations_per_second":664583,"p50_ns":1407,"p99_ns":2223,"p999_ns":7103,"p9999_ns":9664,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 23063 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5780617,"operations":4000,"operations_per_second":691967,"p50_ns":1367,"p99_ns":2047,"p999_ns":6783,"p9999_ns":7531,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 23014 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5805668,"operations":4000,"operations_per_second":688981,"p50_ns":1367,"p99_ns":2063,"p999_ns":6111,"p9999_ns":13440,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 9201 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":37483918,"operations":4000,"operations_per_second":106712,"p50_ns":9279,"p99_ns":11327,"p999_ns":16639,"p9999_ns":185059,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 55413 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":21882959,"operations":4000,"operations_per_second":182790,"p50_ns":5439,"p99_ns":6399,"p999_ns":12927,"p9999_ns":19965,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 55329 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":22052853,"operations":4000,"operations_per_second":181382,"p50_ns":5375,"p99_ns":6431,"p999_ns":16767,"p9999_ns":180587,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 103001 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5816336,"operations":4000,"operations_per_second":687718,"p50_ns":1383,"p99_ns":1999,"p999_ns":5919,"p9999_ns":6600,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 9020 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":25678179,"operations":4000,"operations_per_second":155774,"p50_ns":5695,"p99_ns":11199,"p999_ns":29183,"p9999_ns":111373,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 55811 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":24044322,"operations":4000,"operations_per_second":166359,"p50_ns":5727,"p99_ns":9727,"p999_ns":75775,"p9999_ns":128594,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 58252 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":41218842,"operations":4000,"operations_per_second":97042,"p50_ns":6303,"p99_ns":75775,"p999_ns":108543,"p9999_ns":376372,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1003301 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":6526896,"operations":4000,"operations_per_second":612848,"p50_ns":1487,"p99_ns":2687,"p999_ns":16127,"p9999_ns":50676,"overflow":0,"peak_rss_bytes":0}
```

## Set 3, run 1: AMD EPYC 7763 64-Core Processor, CI run 36032363409, commit 5b441cc

```text
== round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12789 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":54107239,"operations":4000,"operations_per_second":73927,"p50_ns":14719,"p99_ns":19071,"p999_ns":24831,"p9999_ns":26449,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4630 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9160392,"operations":4000,"operations_per_second":436662,"p50_ns":2159,"p99_ns":3231,"p999_ns":12287,"p9999_ns":31268,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4496 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8892724,"operations":4000,"operations_per_second":449805,"p50_ns":2095,"p99_ns":3311,"p999_ns":11711,"p9999_ns":26830,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4502 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8903913,"operations":4000,"operations_per_second":449240,"p50_ns":2095,"p99_ns":3023,"p999_ns":11519,"p9999_ns":29049,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 13631 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":55996147,"operations":4000,"operations_per_second":71433,"p50_ns":14591,"p99_ns":17023,"p999_ns":20991,"p9999_ns":40646,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24785 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9181611,"operations":4000,"operations_per_second":435653,"p50_ns":2159,"p99_ns":3247,"p999_ns":10815,"p9999_ns":12212,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24579 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8903657,"operations":4000,"operations_per_second":449253,"p50_ns":2095,"p99_ns":3631,"p999_ns":10623,"p9999_ns":13991,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24559 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8871723,"operations":4000,"operations_per_second":450870,"p50_ns":2095,"p99_ns":3055,"p999_ns":10111,"p9999_ns":11151,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 13067 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":56450934,"operations":4000,"operations_per_second":70857,"p50_ns":14719,"p99_ns":17919,"p999_ns":25215,"p9999_ns":34409,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 59492 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":32865438,"operations":4000,"operations_per_second":121708,"p50_ns":8095,"p99_ns":12159,"p999_ns":14591,"p9999_ns":14993,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 59467 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":32452506,"operations":4000,"operations_per_second":123257,"p50_ns":7967,"p99_ns":12031,"p999_ns":15295,"p9999_ns":16420,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 104837 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9322400,"operations":4000,"operations_per_second":429074,"p50_ns":2127,"p99_ns":8383,"p999_ns":10303,"p9999_ns":10825,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 16767 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":46251660,"operations":4000,"operations_per_second":86483,"p50_ns":10431,"p99_ns":17023,"p999_ns":20223,"p9999_ns":25016,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 60097 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35315521,"operations":4000,"operations_per_second":113264,"p50_ns":8575,"p99_ns":12159,"p999_ns":16127,"p9999_ns":150487,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 63905 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":50990215,"operations":4000,"operations_per_second":78446,"p50_ns":12223,"p99_ns":15999,"p999_ns":32639,"p9999_ns":962136,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004898 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9620514,"operations":4000,"operations_per_second":415778,"p50_ns":2287,"p99_ns":3759,"p999_ns":9343,"p9999_ns":12553,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 26735 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":63983780,"operations":4000,"operations_per_second":62515,"p50_ns":15423,"p99_ns":17663,"p999_ns":23039,"p9999_ns":714197,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 71504 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35192949,"operations":4000,"operations_per_second":113659,"p50_ns":8639,"p99_ns":12735,"p999_ns":14335,"p9999_ns":16721,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 71338 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34322710,"operations":4000,"operations_per_second":116540,"p50_ns":8447,"p99_ns":11263,"p999_ns":14463,"p9999_ns":15349,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1505010 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9763161,"operations":4000,"operations_per_second":409703,"p50_ns":2319,"p99_ns":3743,"p999_ns":9215,"p9999_ns":9939,"overflow":0,"peak_rss_bytes":0}
== round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 11414 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":50285540,"operations":4000,"operations_per_second":79545,"p50_ns":14271,"p99_ns":16191,"p999_ns":21631,"p9999_ns":24325,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4600 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9138664,"operations":4000,"operations_per_second":437700,"p50_ns":2143,"p99_ns":3247,"p999_ns":13567,"p9999_ns":17718,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4469 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8842421,"operations":4000,"operations_per_second":452364,"p50_ns":2095,"p99_ns":3007,"p999_ns":10943,"p9999_ns":30376,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4490 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8883173,"operations":4000,"operations_per_second":450289,"p50_ns":2095,"p99_ns":2991,"p999_ns":11391,"p9999_ns":28623,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 13664 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":56721095,"operations":4000,"operations_per_second":70520,"p50_ns":14655,"p99_ns":16639,"p999_ns":22911,"p9999_ns":27050,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24783 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9267544,"operations":4000,"operations_per_second":431613,"p50_ns":2159,"p99_ns":8191,"p999_ns":10879,"p9999_ns":13545,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24555 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8860130,"operations":4000,"operations_per_second":451460,"p50_ns":2095,"p99_ns":3007,"p999_ns":10495,"p9999_ns":11336,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24592 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8890536,"operations":4000,"operations_per_second":449916,"p50_ns":2095,"p99_ns":3455,"p999_ns":9919,"p9999_ns":10524,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 12212 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":53684228,"operations":4000,"operations_per_second":74509,"p50_ns":14719,"p99_ns":18687,"p999_ns":23551,"p9999_ns":27997,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 59363 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":32492873,"operations":4000,"operations_per_second":123103,"p50_ns":8063,"p99_ns":12607,"p999_ns":15935,"p9999_ns":18740,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 59474 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":32512142,"operations":4000,"operations_per_second":123030,"p50_ns":7999,"p99_ns":12223,"p999_ns":15295,"p9999_ns":16125,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 104873 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9370031,"operations":4000,"operations_per_second":426892,"p50_ns":2111,"p99_ns":9023,"p999_ns":11007,"p9999_ns":16405,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 16773 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":46283774,"operations":4000,"operations_per_second":86423,"p50_ns":10431,"p99_ns":17791,"p999_ns":23807,"p9999_ns":186354,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 60040 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34690494,"operations":4000,"operations_per_second":115305,"p50_ns":8511,"p99_ns":11647,"p999_ns":14655,"p9999_ns":23975,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 63716 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":48718326,"operations":4000,"operations_per_second":82104,"p50_ns":12223,"p99_ns":15231,"p999_ns":17151,"p9999_ns":39734,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004898 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9641394,"operations":4000,"operations_per_second":414877,"p50_ns":2287,"p99_ns":3535,"p999_ns":9407,"p9999_ns":9743,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 26612 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":62127728,"operations":4000,"operations_per_second":64383,"p50_ns":15551,"p99_ns":17663,"p999_ns":20735,"p9999_ns":28097,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 71327 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34932528,"operations":4000,"operations_per_second":114506,"p50_ns":8639,"p99_ns":11199,"p999_ns":14527,"p9999_ns":15128,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 71565 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":42125857,"operations":4000,"operations_per_second":94953,"p50_ns":8575,"p99_ns":12991,"p999_ns":532479,"p9999_ns":2025162,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1504939 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9626134,"operations":4000,"operations_per_second":415535,"p50_ns":2287,"p99_ns":3727,"p999_ns":9023,"p9999_ns":9217,"overflow":0,"peak_rss_bytes":0}
== round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12443 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":53854484,"operations":4000,"operations_per_second":74274,"p50_ns":14591,"p99_ns":16639,"p999_ns":23679,"p9999_ns":25668,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4610 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9179986,"operations":4000,"operations_per_second":435730,"p50_ns":2159,"p99_ns":3215,"p999_ns":13375,"p9999_ns":39358,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4489 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8909850,"operations":4000,"operations_per_second":448941,"p50_ns":2095,"p99_ns":3039,"p999_ns":10879,"p9999_ns":39749,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4479 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8862785,"operations":4000,"operations_per_second":451325,"p50_ns":2095,"p99_ns":3103,"p999_ns":15615,"p9999_ns":21345,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 11567 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":51274553,"operations":4000,"operations_per_second":78011,"p50_ns":14463,"p99_ns":17151,"p999_ns":23039,"p9999_ns":23308,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24791 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9173367,"operations":4000,"operations_per_second":436044,"p50_ns":2159,"p99_ns":3567,"p999_ns":10687,"p9999_ns":11126,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24566 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8819164,"operations":4000,"operations_per_second":453557,"p50_ns":2095,"p99_ns":3071,"p999_ns":8511,"p9999_ns":11616,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24584 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8926939,"operations":4000,"operations_per_second":448081,"p50_ns":2111,"p99_ns":3615,"p999_ns":10175,"p9999_ns":10204,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 14234 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":59933638,"operations":4000,"operations_per_second":66740,"p50_ns":14911,"p99_ns":17023,"p999_ns":23935,"p9999_ns":151433,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 59602 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":33081167,"operations":4000,"operations_per_second":120914,"p50_ns":8159,"p99_ns":11007,"p999_ns":14079,"p9999_ns":14772,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 59351 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":32056037,"operations":4000,"operations_per_second":124781,"p50_ns":8031,"p99_ns":10303,"p999_ns":14271,"p9999_ns":35676,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 104867 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9367308,"operations":4000,"operations_per_second":427017,"p50_ns":2127,"p99_ns":8895,"p999_ns":10687,"p9999_ns":10995,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 16784 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":45939179,"operations":4000,"operations_per_second":87071,"p50_ns":10431,"p99_ns":15871,"p999_ns":22015,"p9999_ns":23183,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 60108 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35054495,"operations":4000,"operations_per_second":114108,"p50_ns":8639,"p99_ns":11903,"p999_ns":13439,"p9999_ns":14902,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 63872 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":48987726,"operations":4000,"operations_per_second":81653,"p50_ns":12223,"p99_ns":14463,"p999_ns":17535,"p9999_ns":18199,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004841 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9486684,"operations":4000,"operations_per_second":421643,"p50_ns":2271,"p99_ns":3343,"p999_ns":8255,"p9999_ns":10394,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 26335 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":61442709,"operations":4000,"operations_per_second":65101,"p50_ns":15359,"p99_ns":17791,"p999_ns":21503,"p9999_ns":37575,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 71268 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34833591,"operations":4000,"operations_per_second":114831,"p50_ns":8575,"p99_ns":12223,"p999_ns":15231,"p9999_ns":102332,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 71528 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34886502,"operations":4000,"operations_per_second":114657,"p50_ns":8575,"p99_ns":12863,"p999_ns":14975,"p9999_ns":19962,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1504978 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9694237,"operations":4000,"operations_per_second":412616,"p50_ns":2303,"p99_ns":3679,"p999_ns":9151,"p9999_ns":9392,"overflow":0,"peak_rss_bytes":0}
```

## Set 3, run 2: AMD EPYC 7763 64-Core Processor, CI run 36032373559, commit 5b441cc

```text
== round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 10041 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":48491814,"operations":4000,"operations_per_second":82488,"p50_ns":11455,"p99_ns":21887,"p999_ns":26111,"p9999_ns":38792,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4628 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9174983,"operations":4000,"operations_per_second":435968,"p50_ns":2159,"p99_ns":3167,"p999_ns":12863,"p9999_ns":34725,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4509 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8931869,"operations":4000,"operations_per_second":447834,"p50_ns":2095,"p99_ns":3071,"p999_ns":19327,"p9999_ns":20178,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4486 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8865053,"operations":4000,"operations_per_second":451209,"p50_ns":2095,"p99_ns":3071,"p999_ns":11455,"p9999_ns":29700,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 14601 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":58351108,"operations":4000,"operations_per_second":68550,"p50_ns":15935,"p99_ns":19071,"p999_ns":26367,"p9999_ns":27466,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24839 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9294610,"operations":4000,"operations_per_second":430356,"p50_ns":2175,"p99_ns":8095,"p999_ns":10175,"p9999_ns":11606,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24637 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9033638,"operations":4000,"operations_per_second":442789,"p50_ns":2111,"p99_ns":6143,"p999_ns":10751,"p9999_ns":11792,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24633 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9027344,"operations":4000,"operations_per_second":443098,"p50_ns":2111,"p99_ns":3727,"p999_ns":10495,"p9999_ns":11526,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 16987 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":64513640,"operations":4000,"operations_per_second":62002,"p50_ns":16319,"p99_ns":18431,"p999_ns":26239,"p9999_ns":26725,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 59749 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34596034,"operations":4000,"operations_per_second":115620,"p50_ns":8575,"p99_ns":10239,"p999_ns":13503,"p9999_ns":38422,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 59689 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34257933,"operations":4000,"operations_per_second":116761,"p50_ns":8511,"p99_ns":10239,"p999_ns":14207,"p9999_ns":17703,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 104890 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9433526,"operations":4000,"operations_per_second":424019,"p50_ns":2127,"p99_ns":8767,"p999_ns":9791,"p9999_ns":10013,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20419 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":55289968,"operations":4000,"operations_per_second":72345,"p50_ns":14335,"p99_ns":18687,"p999_ns":21631,"p9999_ns":22797,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 60384 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":38582121,"operations":4000,"operations_per_second":103674,"p50_ns":9151,"p99_ns":13503,"p999_ns":156671,"p9999_ns":254957,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 64134 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":51396064,"operations":4000,"operations_per_second":77826,"p50_ns":12543,"p99_ns":16127,"p999_ns":24063,"p9999_ns":538171,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004930 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9732435,"operations":4000,"operations_per_second":410996,"p50_ns":2319,"p99_ns":3455,"p999_ns":9215,"p9999_ns":9548,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 29996 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":68237508,"operations":4000,"operations_per_second":58618,"p50_ns":16895,"p99_ns":19839,"p999_ns":24063,"p9999_ns":431206,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 72105 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":37142858,"operations":4000,"operations_per_second":107692,"p50_ns":9151,"p99_ns":13311,"p999_ns":18815,"p9999_ns":31544,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 71998 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":36687221,"operations":4000,"operations_per_second":109029,"p50_ns":9087,"p99_ns":11903,"p999_ns":16895,"p9999_ns":24165,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1504987 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9767379,"operations":4000,"operations_per_second":409526,"p50_ns":2319,"p99_ns":3999,"p999_ns":9855,"p9999_ns":10986,"overflow":0,"peak_rss_bytes":0}
== round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15738 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":62242690,"operations":4000,"operations_per_second":64264,"p50_ns":16255,"p99_ns":17791,"p999_ns":24575,"p9999_ns":25853,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4630 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9154020,"operations":4000,"operations_per_second":436966,"p50_ns":2159,"p99_ns":3247,"p999_ns":12863,"p9999_ns":22412,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4497 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8897810,"operations":4000,"operations_per_second":449548,"p50_ns":2095,"p99_ns":3615,"p999_ns":15231,"p9999_ns":23769,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4465 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8850430,"operations":4000,"operations_per_second":451955,"p50_ns":2095,"p99_ns":2991,"p999_ns":11007,"p9999_ns":28533,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 15657 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":61139789,"operations":4000,"operations_per_second":65423,"p50_ns":15999,"p99_ns":19327,"p999_ns":27647,"p9999_ns":156257,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24801 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9211410,"operations":4000,"operations_per_second":434244,"p50_ns":2159,"p99_ns":4831,"p999_ns":9791,"p9999_ns":10294,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24600 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8904689,"operations":4000,"operations_per_second":449201,"p50_ns":2111,"p99_ns":3407,"p999_ns":9343,"p9999_ns":12072,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24594 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8933543,"operations":4000,"operations_per_second":447750,"p50_ns":2095,"p99_ns":3247,"p999_ns":10751,"p9999_ns":11291,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 16983 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":64624595,"operations":4000,"operations_per_second":61895,"p50_ns":16255,"p99_ns":18559,"p999_ns":21631,"p9999_ns":24756,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 59754 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34640963,"operations":4000,"operations_per_second":115470,"p50_ns":8575,"p99_ns":10047,"p999_ns":13695,"p9999_ns":14707,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 59653 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34643683,"operations":4000,"operations_per_second":115461,"p50_ns":8447,"p99_ns":13951,"p999_ns":16383,"p9999_ns":90028,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 104984 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9378002,"operations":4000,"operations_per_second":426530,"p50_ns":2127,"p99_ns":9023,"p999_ns":11135,"p9999_ns":14938,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20648 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":55671114,"operations":4000,"operations_per_second":71850,"p50_ns":14335,"p99_ns":17791,"p999_ns":20479,"p9999_ns":21630,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 60376 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":37835749,"operations":4000,"operations_per_second":105720,"p50_ns":9151,"p99_ns":13759,"p999_ns":16511,"p9999_ns":350801,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 64104 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":51637005,"operations":4000,"operations_per_second":77463,"p50_ns":12671,"p99_ns":15359,"p999_ns":17919,"p9999_ns":563268,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004913 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9704791,"operations":4000,"operations_per_second":412167,"p50_ns":2319,"p99_ns":3807,"p999_ns":9343,"p9999_ns":14847,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 29923 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":67389336,"operations":4000,"operations_per_second":59356,"p50_ns":16895,"p99_ns":18815,"p999_ns":21631,"p9999_ns":24395,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 72046 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":37226702,"operations":4000,"operations_per_second":107449,"p50_ns":9151,"p99_ns":12735,"p999_ns":16639,"p9999_ns":108633,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 72111 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":38798993,"operations":4000,"operations_per_second":103095,"p50_ns":9087,"p99_ns":12031,"p999_ns":15679,"p9999_ns":1028568,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1504958 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9794056,"operations":4000,"operations_per_second":408410,"p50_ns":2319,"p99_ns":3759,"p999_ns":9151,"p9999_ns":10580,"overflow":0,"peak_rss_bytes":0}
== round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14848 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":60243885,"operations":4000,"operations_per_second":66396,"p50_ns":16511,"p99_ns":18303,"p999_ns":25855,"p9999_ns":30597,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4589 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9135174,"operations":4000,"operations_per_second":437867,"p50_ns":2143,"p99_ns":3087,"p999_ns":14655,"p9999_ns":42184,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4477 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8853474,"operations":4000,"operations_per_second":451800,"p50_ns":2095,"p99_ns":2975,"p999_ns":13119,"p9999_ns":31734,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4507 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8918097,"operations":4000,"operations_per_second":448526,"p50_ns":2095,"p99_ns":3103,"p999_ns":14591,"p9999_ns":23289,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 15124 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":59785589,"operations":4000,"operations_per_second":66905,"p50_ns":15935,"p99_ns":18559,"p999_ns":24575,"p9999_ns":27091,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24866 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9375591,"operations":4000,"operations_per_second":426639,"p50_ns":2175,"p99_ns":8511,"p999_ns":11455,"p9999_ns":22827,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24655 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9022879,"operations":4000,"operations_per_second":443317,"p50_ns":2111,"p99_ns":4671,"p999_ns":9983,"p9999_ns":12604,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24645 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8985893,"operations":4000,"operations_per_second":445142,"p50_ns":2127,"p99_ns":3327,"p999_ns":10431,"p9999_ns":11431,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 17048 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":64776481,"operations":4000,"operations_per_second":61750,"p50_ns":16319,"p99_ns":18687,"p999_ns":21247,"p9999_ns":27231,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 59591 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34425178,"operations":4000,"operations_per_second":116194,"p50_ns":8447,"p99_ns":13311,"p999_ns":16383,"p9999_ns":18349,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 59441 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":33843003,"operations":4000,"operations_per_second":118192,"p50_ns":8383,"p99_ns":13887,"p999_ns":15295,"p9999_ns":18023,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 104994 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9520987,"operations":4000,"operations_per_second":420124,"p50_ns":2127,"p99_ns":9407,"p999_ns":10879,"p9999_ns":11031,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20437 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57666650,"operations":4000,"operations_per_second":69364,"p50_ns":14207,"p99_ns":18687,"p999_ns":50175,"p9999_ns":1009613,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 60496 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":38615751,"operations":4000,"operations_per_second":103584,"p50_ns":9279,"p99_ns":14463,"p999_ns":45311,"p9999_ns":53304,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 64216 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":51992546,"operations":4000,"operations_per_second":76934,"p50_ns":12671,"p99_ns":23551,"p999_ns":52479,"p9999_ns":60072,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004919 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9721165,"operations":4000,"operations_per_second":411473,"p50_ns":2319,"p99_ns":3967,"p999_ns":9215,"p9999_ns":9553,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 29638 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":67328487,"operations":4000,"operations_per_second":59410,"p50_ns":16895,"p99_ns":20223,"p999_ns":23551,"p9999_ns":24135,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 71964 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":38263373,"operations":4000,"operations_per_second":104538,"p50_ns":9151,"p99_ns":18175,"p999_ns":71167,"p9999_ns":76538,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 72092 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":37789154,"operations":4000,"operations_per_second":105850,"p50_ns":9087,"p99_ns":14079,"p999_ns":63231,"p9999_ns":66765,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1504955 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9765787,"operations":4000,"operations_per_second":409593,"p50_ns":2303,"p99_ns":3695,"p999_ns":9599,"p9999_ns":9728,"overflow":0,"peak_rss_bytes":0}
```

## Set 3, run 3: AMD EPYC 7763 64-Core Processor, CI run 36032383576, commit 5b441cc

```text
== round 1
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14243 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":56840213,"operations":4000,"operations_per_second":70372,"p50_ns":12607,"p99_ns":20095,"p999_ns":25471,"p9999_ns":26765,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4684 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9287139,"operations":4000,"operations_per_second":430703,"p50_ns":2175,"p99_ns":3391,"p999_ns":13055,"p9999_ns":31764,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4512 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8960725,"operations":4000,"operations_per_second":446392,"p50_ns":2111,"p99_ns":3407,"p999_ns":11903,"p9999_ns":42349,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4508 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8927752,"operations":4000,"operations_per_second":448041,"p50_ns":2111,"p99_ns":3071,"p999_ns":10943,"p9999_ns":35887,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 16229 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":62349593,"operations":4000,"operations_per_second":64154,"p50_ns":16191,"p99_ns":19455,"p999_ns":24703,"p9999_ns":27331,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24854 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9334551,"operations":4000,"operations_per_second":428515,"p50_ns":2175,"p99_ns":8191,"p999_ns":10367,"p9999_ns":11706,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24673 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9034829,"operations":4000,"operations_per_second":442731,"p50_ns":2111,"p99_ns":3791,"p999_ns":10431,"p9999_ns":10925,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24691 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9067835,"operations":4000,"operations_per_second":441119,"p50_ns":2111,"p99_ns":5087,"p999_ns":11071,"p9999_ns":11291,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 17125 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":65241261,"operations":4000,"operations_per_second":61310,"p50_ns":16511,"p99_ns":19071,"p999_ns":25343,"p9999_ns":26775,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 59840 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35625709,"operations":4000,"operations_per_second":112278,"p50_ns":8639,"p99_ns":13695,"p999_ns":52991,"p9999_ns":185495,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 59708 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34131895,"operations":4000,"operations_per_second":117192,"p50_ns":8447,"p99_ns":12607,"p999_ns":15487,"p9999_ns":16140,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 105064 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9607688,"operations":4000,"operations_per_second":416333,"p50_ns":2127,"p99_ns":9279,"p999_ns":10431,"p9999_ns":12062,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20396 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":56044197,"operations":4000,"operations_per_second":71372,"p50_ns":14271,"p99_ns":19455,"p999_ns":99839,"p9999_ns":207291,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 60660 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":37834191,"operations":4000,"operations_per_second":105724,"p50_ns":9215,"p99_ns":13439,"p999_ns":17023,"p9999_ns":175712,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 64371 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":50660803,"operations":4000,"operations_per_second":78956,"p50_ns":12671,"p99_ns":16767,"p999_ns":20351,"p9999_ns":81862,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004802 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9765074,"operations":4000,"operations_per_second":409623,"p50_ns":2303,"p99_ns":3919,"p999_ns":10175,"p9999_ns":14156,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 30172 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":68740041,"operations":4000,"operations_per_second":58190,"p50_ns":17151,"p99_ns":20991,"p999_ns":34815,"p9999_ns":160844,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 72472 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":38951446,"operations":4000,"operations_per_second":102691,"p50_ns":9215,"p99_ns":14207,"p999_ns":222207,"p9999_ns":252009,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 72634 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":39829178,"operations":4000,"operations_per_second":100428,"p50_ns":9215,"p99_ns":13311,"p999_ns":45055,"p9999_ns":1052891,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1505017 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9907455,"operations":4000,"operations_per_second":403736,"p50_ns":2319,"p99_ns":4063,"p999_ns":9407,"p9999_ns":10599,"overflow":0,"peak_rss_bytes":0}
== round 2
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12653 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":50960671,"operations":4000,"operations_per_second":78491,"p50_ns":11263,"p99_ns":20863,"p999_ns":24447,"p9999_ns":28598,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4636 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9172208,"operations":4000,"operations_per_second":436100,"p50_ns":2159,"p99_ns":3263,"p999_ns":11455,"p9999_ns":23448,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4519 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8942765,"operations":4000,"operations_per_second":447288,"p50_ns":2111,"p99_ns":3183,"p999_ns":13887,"p9999_ns":18294,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4501 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8923961,"operations":4000,"operations_per_second":448231,"p50_ns":2111,"p99_ns":3167,"p999_ns":12223,"p9999_ns":24936,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 14334 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":55401823,"operations":4000,"operations_per_second":72199,"p50_ns":15871,"p99_ns":19711,"p999_ns":23935,"p9999_ns":25913,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24862 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9334911,"operations":4000,"operations_per_second":428498,"p50_ns":2175,"p99_ns":8255,"p999_ns":10175,"p9999_ns":10694,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24651 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9054931,"operations":4000,"operations_per_second":441748,"p50_ns":2111,"p99_ns":4543,"p999_ns":10879,"p9999_ns":11196,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24677 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9051549,"operations":4000,"operations_per_second":441913,"p50_ns":2111,"p99_ns":5855,"p999_ns":10623,"p9999_ns":11065,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 16589 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":63800458,"operations":4000,"operations_per_second":62695,"p50_ns":16191,"p99_ns":18815,"p999_ns":26239,"p9999_ns":187078,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 59656 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34123334,"operations":4000,"operations_per_second":117221,"p50_ns":8575,"p99_ns":10495,"p999_ns":13439,"p9999_ns":15929,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 59423 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":33821793,"operations":4000,"operations_per_second":118266,"p50_ns":8447,"p99_ns":13823,"p999_ns":15615,"p9999_ns":15789,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 104982 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9452423,"operations":4000,"operations_per_second":423171,"p50_ns":2127,"p99_ns":9023,"p999_ns":10431,"p9999_ns":10900,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20623 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":55784202,"operations":4000,"operations_per_second":71704,"p50_ns":14271,"p99_ns":18943,"p999_ns":25087,"p9999_ns":125368,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 60699 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":37972491,"operations":4000,"operations_per_second":105339,"p50_ns":9215,"p99_ns":13759,"p999_ns":31487,"p9999_ns":159582,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 64775 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":51746358,"operations":4000,"operations_per_second":77300,"p50_ns":12863,"p99_ns":16383,"p999_ns":19583,"p9999_ns":175036,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004957 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9821712,"operations":4000,"operations_per_second":407260,"p50_ns":2303,"p99_ns":4079,"p999_ns":10239,"p9999_ns":13044,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 30495 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":68418732,"operations":4000,"operations_per_second":58463,"p50_ns":17023,"p99_ns":20223,"p999_ns":24319,"p9999_ns":25622,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 72779 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":42654684,"operations":4000,"operations_per_second":93776,"p50_ns":9279,"p99_ns":14527,"p999_ns":45823,"p9999_ns":2141138,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 72680 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":40278826,"operations":4000,"operations_per_second":99307,"p50_ns":9279,"p99_ns":12735,"p999_ns":18175,"p9999_ns":1315555,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1505073 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10028238,"operations":4000,"operations_per_second":398873,"p50_ns":2335,"p99_ns":4415,"p999_ns":9983,"p9999_ns":43882,"overflow":0,"peak_rss_bytes":0}
== round 3
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14333 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":58104300,"operations":4000,"operations_per_second":68841,"p50_ns":16383,"p99_ns":18943,"p999_ns":25087,"p9999_ns":27451,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 0 us, peer CPU per round trip 4629 ns
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9182778,"operations":4000,"operations_per_second":435598,"p50_ns":2159,"p99_ns":3263,"p999_ns":11327,"p9999_ns":30767,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 0 us, peer CPU per round trip 4518 ns
{"workload":"cross-core","candidate":"rotor (spin budget, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8940476,"operations":4000,"operations_per_second":447403,"p50_ns":2111,"p99_ns":3087,"p999_ns":15871,"p9999_ns":18003,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 4517 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":8953979,"operations":4000,"operations_per_second":446728,"p50_ns":2111,"p99_ns":3519,"p999_ns":13375,"p9999_ns":35737,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 20 us, peer CPU per round trip 15954 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":61735702,"operations":4000,"operations_per_second":64792,"p50_ns":16127,"p99_ns":18943,"p999_ns":23935,"p9999_ns":27250,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 20 us, peer CPU per round trip 24854 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9372673,"operations":4000,"operations_per_second":426772,"p50_ns":2175,"p99_ns":8447,"p999_ns":10431,"p9999_ns":11281,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 20 us, peer CPU per round trip 24715 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9067705,"operations":4000,"operations_per_second":441125,"p50_ns":2111,"p99_ns":4015,"p999_ns":10815,"p9999_ns":11466,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 20 us, peer CPU per round trip 24711 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9052709,"operations":4000,"operations_per_second":441856,"p50_ns":2111,"p99_ns":3887,"p999_ns":10879,"p9999_ns":23493,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 100 us, peer CPU per round trip 15738 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":62037433,"operations":4000,"operations_per_second":64477,"p50_ns":16255,"p99_ns":18943,"p999_ns":25855,"p9999_ns":28794,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 100 us, peer CPU per round trip 59887 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35034109,"operations":4000,"operations_per_second":114174,"p50_ns":8575,"p99_ns":10815,"p999_ns":17791,"p9999_ns":175927,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 100 us, peer CPU per round trip 59844 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":34600143,"operations":4000,"operations_per_second":115606,"p50_ns":8447,"p99_ns":13823,"p999_ns":18687,"p9999_ns":25763,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 100 us, peer CPU per round trip 105195 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9708919,"operations":4000,"operations_per_second":411992,"p50_ns":2127,"p99_ns":9599,"p999_ns":11327,"p9999_ns":20618,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1000 us, peer CPU per round trip 20311 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":54746069,"operations":4000,"operations_per_second":73064,"p50_ns":14271,"p99_ns":18815,"p999_ns":22015,"p9999_ns":26349,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1000 us, peer CPU per round trip 60657 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":37286492,"operations":4000,"operations_per_second":107277,"p50_ns":9151,"p99_ns":12479,"p999_ns":14719,"p9999_ns":15379,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1000 us, peer CPU per round trip 64639 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":51177669,"operations":4000,"operations_per_second":78159,"p50_ns":12735,"p99_ns":15999,"p999_ns":18943,"p9999_ns":97306,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1000 us, peer CPU per round trip 1004949 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9776500,"operations":4000,"operations_per_second":409144,"p50_ns":2303,"p99_ns":4223,"p999_ns":9343,"p9999_ns":11927,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode waiting, gap 1500 us, peer CPU per round trip 30584 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":70522466,"operations":4000,"operations_per_second":56719,"p50_ns":17023,"p99_ns":20223,"p999_ns":23423,"p9999_ns":1041189,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_then_wait, gap 1500 us, peer CPU per round trip 72539 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":38704435,"operations":4000,"operations_per_second":103347,"p50_ns":9215,"p99_ns":15039,"p999_ns":65023,"p9999_ns":73452,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spin_budget, gap 1500 us, peer CPU per round trip 72519 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":37096583,"operations":4000,"operations_per_second":107826,"p50_ns":9087,"p99_ns":12031,"p999_ns":14655,"p9999_ns":48119,"overflow":0,"peak_rss_bytes":0}
rotor_post: mode spinning, gap 1500 us, peer CPU per round trip 1504961 ns
{"workload":"cross-core","candidate":"rotor (idle gap, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":9785468,"operations":4000,"operations_per_second":408769,"p50_ns":2319,"p99_ns":3775,"p999_ns":9407,"p9999_ns":11431,"overflow":0,"peak_rss_bytes":0}
```
