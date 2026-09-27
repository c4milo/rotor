# The Linux wait timers against the tree before them, `github`, 2026-09-27

A GitHub-hosted x86-64 runner, started by a push to the branch `ab-wait-timer`, whose workflow
(`.github/workflows/ab-wait-timer.yml` on that branch) built `zig build bench-linux` twice: at
`5e376b2`, which has neither wait timer, and at `f1570c3`, which has both: epoll's timerfd (decision
20, "The wait timer") and io_uring's armed timeout (decision 6, "The wait timer"). The rows name them
`base` and `change`. Fifteen rounds alternate the two builds, and each round runs `post_epoll` and
`post_uring` in `waiting` mode with no gap, 20,000 round trips after 2,000 of warmup. A row is one
run: the answering loop's CPU per round trip, then the run's JSON line.

What the runner reported: its processor, cores, kernel, memory, and `io_uring_disabled`, where 0
allows io_uring:

```text
model name	: AMD EPYC 7763 64-Core Processor
4
6.17.0-1022-azure
MemTotal:       16373448 kB
0
```

Its load average before and after the rounds:

```text
13:56:16 up 5 min,  0 user,  load average: 1.93, 1.24, 0.56
13:56:53 up 6 min,  0 user,  load average: 1.13, 1.12, 0.54
```

The runner is shared and not quiet, and no number from it enters `docs/costs.md`.

## The rounds

```text
1 base post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15931 ns
1 base post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":592592220,"operations":40000,"operations_per_second":67500,"p50_ns":15871,"p99_ns":18303,"p999_ns":32511,"p9999_ns":327679,"overflow":0,"peak_rss_bytes":0}
1 base post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15479 ns
1 base post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":618302426,"operations":40000,"operations_per_second":64693,"p50_ns":16767,"p99_ns":18687,"p999_ns":26367,"p9999_ns":35327,"overflow":0,"peak_rss_bytes":0}
1 change post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14044 ns
1 change post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":515734987,"operations":40000,"operations_per_second":77559,"p50_ns":12223,"p99_ns":18687,"p999_ns":23295,"p9999_ns":25855,"overflow":0,"peak_rss_bytes":0}
1 change post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12947 ns
1 change post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":512121824,"operations":40000,"operations_per_second":78106,"p50_ns":11839,"p99_ns":19071,"p999_ns":23295,"p9999_ns":46079,"overflow":0,"peak_rss_bytes":0}
2 base post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16671 ns
2 base post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":609812004,"operations":40000,"operations_per_second":65593,"p50_ns":15871,"p99_ns":17663,"p999_ns":19455,"p9999_ns":54271,"overflow":0,"peak_rss_bytes":0}
2 base post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14567 ns
2 base post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":587327649,"operations":40000,"operations_per_second":68105,"p50_ns":16639,"p99_ns":18559,"p999_ns":25599,"p9999_ns":41983,"overflow":0,"peak_rss_bytes":0}
2 change post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12900 ns
2 change post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":478359852,"operations":40000,"operations_per_second":83619,"p50_ns":12095,"p99_ns":18303,"p999_ns":24063,"p9999_ns":30207,"overflow":0,"peak_rss_bytes":0}
2 change post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13004 ns
2 change post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":515151957,"operations":40000,"operations_per_second":77646,"p50_ns":11711,"p99_ns":19199,"p999_ns":23423,"p9999_ns":34815,"overflow":0,"peak_rss_bytes":0}
3 base post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16746 ns
3 base post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":613771923,"operations":40000,"operations_per_second":65170,"p50_ns":15935,"p99_ns":17791,"p999_ns":21119,"p9999_ns":77311,"overflow":0,"peak_rss_bytes":0}
3 base post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15847 ns
3 base post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":626358539,"operations":40000,"operations_per_second":63861,"p50_ns":16767,"p99_ns":18431,"p999_ns":24703,"p9999_ns":32255,"overflow":0,"peak_rss_bytes":0}
3 change post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12893 ns
3 change post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":473771589,"operations":40000,"operations_per_second":84428,"p50_ns":12159,"p99_ns":18175,"p999_ns":23551,"p9999_ns":27007,"overflow":0,"peak_rss_bytes":0}
3 change post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12781 ns
3 change post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":515551976,"operations":40000,"operations_per_second":77586,"p50_ns":11775,"p99_ns":18559,"p999_ns":23039,"p9999_ns":39679,"overflow":0,"peak_rss_bytes":0}
4 base post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 17058 ns
4 base post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":619582195,"operations":40000,"operations_per_second":64559,"p50_ns":15999,"p99_ns":18175,"p999_ns":19455,"p9999_ns":24191,"overflow":0,"peak_rss_bytes":0}
4 base post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15410 ns
4 base post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":614714361,"operations":40000,"operations_per_second":65070,"p50_ns":16767,"p99_ns":18559,"p999_ns":26111,"p9999_ns":39167,"overflow":0,"peak_rss_bytes":0}
4 change post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13338 ns
4 change post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":493710088,"operations":40000,"operations_per_second":81019,"p50_ns":12223,"p99_ns":18559,"p999_ns":22271,"p9999_ns":29567,"overflow":0,"peak_rss_bytes":0}
4 change post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13324 ns
4 change post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":521967429,"operations":40000,"operations_per_second":76633,"p50_ns":11839,"p99_ns":19199,"p999_ns":23167,"p9999_ns":28415,"overflow":0,"peak_rss_bytes":0}
5 base post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16150 ns
5 base post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":599748676,"operations":40000,"operations_per_second":66694,"p50_ns":15935,"p99_ns":18047,"p999_ns":27263,"p9999_ns":35327,"overflow":0,"peak_rss_bytes":0}
5 base post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16134 ns
5 base post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":634484372,"operations":40000,"operations_per_second":63043,"p50_ns":16895,"p99_ns":18559,"p999_ns":25599,"p9999_ns":30847,"overflow":0,"peak_rss_bytes":0}
5 change post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13122 ns
5 change post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":482455843,"operations":40000,"operations_per_second":82909,"p50_ns":12223,"p99_ns":18559,"p999_ns":22911,"p9999_ns":26367,"overflow":0,"peak_rss_bytes":0}
5 change post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13143 ns
5 change post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":522908064,"operations":40000,"operations_per_second":76495,"p50_ns":11967,"p99_ns":19199,"p999_ns":23551,"p9999_ns":34303,"overflow":0,"peak_rss_bytes":0}
6 base post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16511 ns
6 base post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":606686167,"operations":40000,"operations_per_second":65931,"p50_ns":15999,"p99_ns":17919,"p999_ns":20863,"p9999_ns":313343,"overflow":0,"peak_rss_bytes":0}
6 base post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15818 ns
6 base post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":628524084,"operations":40000,"operations_per_second":63641,"p50_ns":16895,"p99_ns":18815,"p999_ns":28159,"p9999_ns":419839,"overflow":0,"peak_rss_bytes":0}
6 change post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13386 ns
6 change post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":493133393,"operations":40000,"operations_per_second":81113,"p50_ns":12095,"p99_ns":18303,"p999_ns":23167,"p9999_ns":27775,"overflow":0,"peak_rss_bytes":0}
6 change post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13272 ns
6 change post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":523363238,"operations":40000,"operations_per_second":76428,"p50_ns":11903,"p99_ns":19327,"p999_ns":23295,"p9999_ns":35839,"overflow":0,"peak_rss_bytes":0}
7 base post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16293 ns
7 base post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":597066106,"operations":40000,"operations_per_second":66994,"p50_ns":15935,"p99_ns":18047,"p999_ns":23039,"p9999_ns":35327,"overflow":0,"peak_rss_bytes":0}
7 base post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16106 ns
7 base post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":635280409,"operations":40000,"operations_per_second":62964,"p50_ns":16895,"p99_ns":18431,"p999_ns":25727,"p9999_ns":46847,"overflow":0,"peak_rss_bytes":0}
7 change post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13903 ns
7 change post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":513904022,"operations":40000,"operations_per_second":77835,"p50_ns":12223,"p99_ns":18687,"p999_ns":23167,"p9999_ns":26367,"overflow":0,"peak_rss_bytes":0}
7 change post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12586 ns
7 change post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":505858246,"operations":40000,"operations_per_second":79073,"p50_ns":11711,"p99_ns":18559,"p999_ns":23807,"p9999_ns":32511,"overflow":0,"peak_rss_bytes":0}
8 base post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16796 ns
8 base post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":615805291,"operations":40000,"operations_per_second":64955,"p50_ns":16063,"p99_ns":18431,"p999_ns":32639,"p9999_ns":37375,"overflow":0,"peak_rss_bytes":0}
8 base post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15477 ns
8 base post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":616860671,"operations":40000,"operations_per_second":64844,"p50_ns":16767,"p99_ns":18943,"p999_ns":26367,"p9999_ns":37375,"overflow":0,"peak_rss_bytes":0}
8 change post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13861 ns
8 change post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":514127336,"operations":40000,"operations_per_second":77801,"p50_ns":12223,"p99_ns":18687,"p999_ns":23935,"p9999_ns":35327,"overflow":0,"peak_rss_bytes":0}
8 change post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13142 ns
8 change post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":520189451,"operations":40000,"operations_per_second":76895,"p50_ns":11903,"p99_ns":19327,"p999_ns":23423,"p9999_ns":30591,"overflow":0,"peak_rss_bytes":0}
9 base post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16175 ns
9 base post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":588551910,"operations":40000,"operations_per_second":67963,"p50_ns":15935,"p99_ns":17663,"p999_ns":23551,"p9999_ns":35071,"overflow":0,"peak_rss_bytes":0}
9 base post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15927 ns
9 base post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":631033216,"operations":40000,"operations_per_second":63388,"p50_ns":16895,"p99_ns":18687,"p999_ns":25983,"p9999_ns":34559,"overflow":0,"peak_rss_bytes":0}
9 change post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 11678 ns
9 change post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":439487787,"operations":40000,"operations_per_second":91015,"p50_ns":12031,"p99_ns":17919,"p999_ns":21375,"p9999_ns":32511,"overflow":0,"peak_rss_bytes":0}
9 change post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13131 ns
9 change post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":516824516,"operations":40000,"operations_per_second":77395,"p50_ns":11775,"p99_ns":19199,"p999_ns":23039,"p9999_ns":27135,"overflow":0,"peak_rss_bytes":0}
10 base post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16064 ns
10 base post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":597031057,"operations":40000,"operations_per_second":66998,"p50_ns":15935,"p99_ns":18047,"p999_ns":20735,"p9999_ns":32639,"overflow":0,"peak_rss_bytes":0}
10 base post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15829 ns
10 base post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":625393732,"operations":40000,"operations_per_second":63959,"p50_ns":16767,"p99_ns":18559,"p999_ns":25215,"p9999_ns":35071,"overflow":0,"peak_rss_bytes":0}
10 change post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13439 ns
10 change post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":497562591,"operations":40000,"operations_per_second":80391,"p50_ns":12159,"p99_ns":18175,"p999_ns":23551,"p9999_ns":37119,"overflow":0,"peak_rss_bytes":0}
10 change post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13156 ns
10 change post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":519939209,"operations":40000,"operations_per_second":76932,"p50_ns":11903,"p99_ns":19455,"p999_ns":23679,"p9999_ns":28671,"overflow":0,"peak_rss_bytes":0}
11 base post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16635 ns
11 base post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":608702396,"operations":40000,"operations_per_second":65713,"p50_ns":15999,"p99_ns":18047,"p999_ns":19967,"p9999_ns":27519,"overflow":0,"peak_rss_bytes":0}
11 base post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16183 ns
11 base post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":637009230,"operations":40000,"operations_per_second":62793,"p50_ns":16895,"p99_ns":18687,"p999_ns":26111,"p9999_ns":38143,"overflow":0,"peak_rss_bytes":0}
11 change post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13205 ns
11 change post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":498472839,"operations":40000,"operations_per_second":80245,"p50_ns":12031,"p99_ns":18175,"p999_ns":22783,"p9999_ns":235519,"overflow":0,"peak_rss_bytes":0}
11 change post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12745 ns
11 change post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":510305362,"operations":40000,"operations_per_second":78384,"p50_ns":11711,"p99_ns":19071,"p999_ns":23551,"p9999_ns":28927,"overflow":0,"peak_rss_bytes":0}
12 base post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16240 ns
12 base post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":604007488,"operations":40000,"operations_per_second":66224,"p50_ns":15935,"p99_ns":18047,"p999_ns":20735,"p9999_ns":33791,"overflow":0,"peak_rss_bytes":0}
12 base post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16001 ns
12 base post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":629791653,"operations":40000,"operations_per_second":63513,"p50_ns":16895,"p99_ns":18559,"p999_ns":24575,"p9999_ns":29567,"overflow":0,"peak_rss_bytes":0}
12 change post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13422 ns
12 change post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":497109938,"operations":40000,"operations_per_second":80465,"p50_ns":12159,"p99_ns":18431,"p999_ns":23807,"p9999_ns":36095,"overflow":0,"peak_rss_bytes":0}
12 change post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13160 ns
12 change post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":520064446,"operations":40000,"operations_per_second":76913,"p50_ns":11839,"p99_ns":18943,"p999_ns":22783,"p9999_ns":27263,"overflow":0,"peak_rss_bytes":0}
13 base post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16535 ns
13 base post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":606182292,"operations":40000,"operations_per_second":65986,"p50_ns":15935,"p99_ns":18047,"p999_ns":20607,"p9999_ns":29439,"overflow":0,"peak_rss_bytes":0}
13 base post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15127 ns
13 base post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":612983817,"operations":40000,"operations_per_second":65254,"p50_ns":16767,"p99_ns":21247,"p999_ns":31103,"p9999_ns":182271,"overflow":0,"peak_rss_bytes":0}
13 change post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13243 ns
13 change post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":485029758,"operations":40000,"operations_per_second":82469,"p50_ns":12159,"p99_ns":18431,"p999_ns":23679,"p9999_ns":25727,"overflow":0,"peak_rss_bytes":0}
13 change post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12932 ns
13 change post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":527373549,"operations":40000,"operations_per_second":75847,"p50_ns":11903,"p99_ns":18815,"p999_ns":24703,"p9999_ns":970751,"overflow":0,"peak_rss_bytes":0}
14 base post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16761 ns
14 base post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":609133376,"operations":40000,"operations_per_second":65667,"p50_ns":15999,"p99_ns":17919,"p999_ns":21375,"p9999_ns":376831,"overflow":0,"peak_rss_bytes":0}
14 base post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15581 ns
14 base post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":618521931,"operations":40000,"operations_per_second":64670,"p50_ns":16895,"p99_ns":18559,"p999_ns":25855,"p9999_ns":29823,"overflow":0,"peak_rss_bytes":0}
14 change post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12884 ns
14 change post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":472952117,"operations":40000,"operations_per_second":84575,"p50_ns":12159,"p99_ns":18431,"p999_ns":23039,"p9999_ns":32127,"overflow":0,"peak_rss_bytes":0}
14 change post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13180 ns
14 change post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":520014425,"operations":40000,"operations_per_second":76920,"p50_ns":11903,"p99_ns":19071,"p999_ns":23167,"p9999_ns":29567,"overflow":0,"peak_rss_bytes":0}
15 base post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 17679 ns
15 base post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":634038297,"operations":40000,"operations_per_second":63087,"p50_ns":16063,"p99_ns":18047,"p999_ns":21247,"p9999_ns":32127,"overflow":0,"peak_rss_bytes":0}
15 base post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15016 ns
15 base post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":607434683,"operations":40000,"operations_per_second":65850,"p50_ns":16767,"p99_ns":18431,"p999_ns":25983,"p9999_ns":38655,"overflow":0,"peak_rss_bytes":0}
15 change post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12886 ns
15 change post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":471910869,"operations":40000,"operations_per_second":84761,"p50_ns":12159,"p99_ns":18047,"p999_ns":22783,"p9999_ns":29311,"overflow":0,"peak_rss_bytes":0}
15 change post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13120 ns
15 change post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":520379708,"operations":40000,"operations_per_second":76866,"p50_ns":11839,"p99_ns":19071,"p999_ns":23167,"p9999_ns":39167,"overflow":0,"peak_rss_bytes":0}
```
