# The Linux wait timers against periodic wakeups, `github`, 2026-09-27

A GitHub-hosted x86-64 runner, started by a push to the branch `ab-wait-timer`, whose workflow
built `zig build bench-linux` at `5e376b2`, which has neither Linux wait timer, at `674512c`, which
has both, and at `bec041c`, a draft since dropped that moved a busy loop's timer out before it
fired. The rows name them `base-1`, `lazy-1` and `move-1`, all at `rotor_post`'s 1 ms wait.
`ticker-1` is `base-1` run beside a helper process whose two threads, pinned to the two cores the
benchmark pins to (0 and 1), do nothing but sleep 1 ms at a time. Ten rounds alternate the four,
and each round runs `post_epoll` and `post_uring` in `waiting` mode with no gap, 20,000 round
trips after 2,000 of warmup. A row is one run: the answering loop's CPU per round trip, then the
run's JSON line.

What the runner reported:

```text
model name	: INTEL(R) XEON(R) PLATINUM 8573C
cores: 4
kernel: 6.17.0-1022-azure
MemTotal:       16372432 kB
cpuidle driver: none
cpuidle governor: menu
CONFIG_HZ=1000
```

Its load average before and after the rounds:

```text
14:23:34 up 8 min,  0 user,  load average: 1.50, 1.27, 0.64
14:24:08 up 8 min,  0 user,  load average: 1.35, 1.25, 0.65
```

The runner is shared and not quiet, and no number from it enters `docs/costs.md`.

## The rounds

```text
1 base-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9549 ns
1 base-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":372082943,"operations":40000,"operations_per_second":107502,"p50_ns":10111,"p99_ns":25343,"p999_ns":29823,"p9999_ns":36863,"overflow":0,"peak_rss_bytes":0}
1 base-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8724 ns
1 base-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":368657928,"operations":40000,"operations_per_second":108501,"p50_ns":9343,"p99_ns":13887,"p999_ns":26239,"p9999_ns":189439,"overflow":0,"peak_rss_bytes":0}
1 ticker-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9346 ns
1 ticker-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":364784931,"operations":40000,"operations_per_second":109653,"p50_ns":9215,"p99_ns":18687,"p999_ns":26239,"p9999_ns":32255,"overflow":0,"peak_rss_bytes":0}
1 ticker-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8249 ns
1 ticker-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":353140813,"operations":40000,"operations_per_second":113269,"p50_ns":8831,"p99_ns":13247,"p999_ns":17535,"p9999_ns":30079,"overflow":0,"peak_rss_bytes":0}
1 lazy-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8534 ns
1 lazy-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":337527664,"operations":40000,"operations_per_second":118508,"p50_ns":8959,"p99_ns":12671,"p999_ns":16383,"p9999_ns":31359,"overflow":0,"peak_rss_bytes":0}
1 lazy-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8270 ns
1 lazy-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":354614347,"operations":40000,"operations_per_second":112798,"p50_ns":8703,"p99_ns":12799,"p999_ns":17023,"p9999_ns":23551,"overflow":0,"peak_rss_bytes":0}
1 move-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9454 ns
1 move-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":377165059,"operations":40000,"operations_per_second":106054,"p50_ns":9663,"p99_ns":12031,"p999_ns":16191,"p9999_ns":22655,"overflow":0,"peak_rss_bytes":0}
1 move-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8346 ns
1 move-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":360032877,"operations":40000,"operations_per_second":111100,"p50_ns":8895,"p99_ns":12735,"p999_ns":17151,"p9999_ns":32639,"overflow":0,"peak_rss_bytes":0}
2 base-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 10535 ns
2 base-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":404890970,"operations":40000,"operations_per_second":98792,"p50_ns":10111,"p99_ns":12863,"p999_ns":16639,"p9999_ns":40447,"overflow":0,"peak_rss_bytes":0}
2 base-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8795 ns
2 base-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":372752297,"operations":40000,"operations_per_second":107309,"p50_ns":9535,"p99_ns":13631,"p999_ns":20095,"p9999_ns":63743,"overflow":0,"peak_rss_bytes":0}
2 ticker-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8326 ns
2 ticker-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":318120405,"operations":40000,"operations_per_second":125738,"p50_ns":8895,"p99_ns":14975,"p999_ns":18047,"p9999_ns":21759,"overflow":0,"peak_rss_bytes":0}
2 ticker-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8138 ns
2 ticker-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":348855078,"operations":40000,"operations_per_second":114660,"p50_ns":8703,"p99_ns":13311,"p999_ns":19583,"p9999_ns":46079,"overflow":0,"peak_rss_bytes":0}
2 lazy-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8020 ns
2 lazy-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":319412604,"operations":40000,"operations_per_second":125229,"p50_ns":9023,"p99_ns":12735,"p999_ns":15999,"p9999_ns":17919,"overflow":0,"peak_rss_bytes":0}
2 lazy-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8318 ns
2 lazy-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":359065456,"operations":40000,"operations_per_second":111400,"p50_ns":8831,"p99_ns":12927,"p999_ns":17023,"p9999_ns":21631,"overflow":0,"peak_rss_bytes":0}
2 move-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9425 ns
2 move-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":376299620,"operations":40000,"operations_per_second":106298,"p50_ns":9535,"p99_ns":12671,"p999_ns":15743,"p9999_ns":27775,"overflow":0,"peak_rss_bytes":0}
2 move-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8370 ns
2 move-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":360190111,"operations":40000,"operations_per_second":111052,"p50_ns":8895,"p99_ns":12607,"p999_ns":16639,"p9999_ns":21887,"overflow":0,"peak_rss_bytes":0}
3 base-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 10482 ns
3 base-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":410325152,"operations":40000,"operations_per_second":97483,"p50_ns":10239,"p99_ns":13695,"p999_ns":16511,"p9999_ns":22655,"overflow":0,"peak_rss_bytes":0}
3 base-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9106 ns
3 base-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":381406419,"operations":40000,"operations_per_second":104875,"p50_ns":9727,"p99_ns":13055,"p999_ns":17151,"p9999_ns":26495,"overflow":0,"peak_rss_bytes":0}
3 ticker-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9225 ns
3 ticker-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":361910737,"operations":40000,"operations_per_second":110524,"p50_ns":9215,"p99_ns":20735,"p999_ns":28671,"p9999_ns":34815,"overflow":0,"peak_rss_bytes":0}
3 ticker-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8335 ns
3 ticker-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":354595653,"operations":40000,"operations_per_second":112804,"p50_ns":8703,"p99_ns":13311,"p999_ns":16639,"p9999_ns":34047,"overflow":0,"peak_rss_bytes":0}
3 lazy-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8519 ns
3 lazy-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":338467777,"operations":40000,"operations_per_second":118179,"p50_ns":9023,"p99_ns":12927,"p999_ns":15743,"p9999_ns":27519,"overflow":0,"peak_rss_bytes":0}
3 lazy-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8275 ns
3 lazy-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":358112830,"operations":40000,"operations_per_second":111696,"p50_ns":8639,"p99_ns":12415,"p999_ns":17023,"p9999_ns":700415,"overflow":0,"peak_rss_bytes":0}
3 move-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9378 ns
3 move-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":373579567,"operations":40000,"operations_per_second":107072,"p50_ns":9471,"p99_ns":12031,"p999_ns":15807,"p9999_ns":21759,"overflow":0,"peak_rss_bytes":0}
3 move-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8348 ns
3 move-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":362013680,"operations":40000,"operations_per_second":110493,"p50_ns":8959,"p99_ns":12735,"p999_ns":16639,"p9999_ns":46591,"overflow":0,"peak_rss_bytes":0}
4 base-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 10534 ns
4 base-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":406560534,"operations":40000,"operations_per_second":98386,"p50_ns":10175,"p99_ns":13183,"p999_ns":16063,"p9999_ns":23807,"overflow":0,"peak_rss_bytes":0}
4 base-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9014 ns
4 base-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":378429141,"operations":40000,"operations_per_second":105700,"p50_ns":9663,"p99_ns":13311,"p999_ns":17407,"p9999_ns":28031,"overflow":0,"peak_rss_bytes":0}
4 ticker-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9035 ns
4 ticker-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":345244603,"operations":40000,"operations_per_second":115859,"p50_ns":9087,"p99_ns":20991,"p999_ns":27775,"p9999_ns":34815,"overflow":0,"peak_rss_bytes":0}
4 ticker-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8044 ns
4 ticker-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":345648860,"operations":40000,"operations_per_second":115724,"p50_ns":8703,"p99_ns":13055,"p999_ns":17535,"p9999_ns":33279,"overflow":0,"peak_rss_bytes":0}
4 lazy-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8135 ns
4 lazy-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":321388743,"operations":40000,"operations_per_second":124459,"p50_ns":8959,"p99_ns":12671,"p999_ns":15999,"p9999_ns":17791,"overflow":0,"peak_rss_bytes":0}
4 lazy-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8084 ns
4 lazy-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":350166674,"operations":40000,"operations_per_second":114231,"p50_ns":8639,"p99_ns":12607,"p999_ns":19199,"p9999_ns":86527,"overflow":0,"peak_rss_bytes":0}
4 move-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9427 ns
4 move-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":371851453,"operations":40000,"operations_per_second":107569,"p50_ns":9535,"p99_ns":12351,"p999_ns":15551,"p9999_ns":23807,"overflow":0,"peak_rss_bytes":0}
4 move-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8321 ns
4 move-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":356267270,"operations":40000,"operations_per_second":112275,"p50_ns":8895,"p99_ns":12095,"p999_ns":16063,"p9999_ns":29439,"overflow":0,"peak_rss_bytes":0}
5 base-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 10507 ns
5 base-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":404280236,"operations":40000,"operations_per_second":98941,"p50_ns":10175,"p99_ns":13119,"p999_ns":15935,"p9999_ns":28927,"overflow":0,"peak_rss_bytes":0}
5 base-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8708 ns
5 base-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":364783671,"operations":40000,"operations_per_second":109654,"p50_ns":9407,"p99_ns":13247,"p999_ns":18047,"p9999_ns":30719,"overflow":0,"peak_rss_bytes":0}
5 ticker-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8567 ns
5 ticker-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":336227994,"operations":40000,"operations_per_second":118966,"p50_ns":9023,"p99_ns":20735,"p999_ns":26367,"p9999_ns":34047,"overflow":0,"peak_rss_bytes":0}
5 ticker-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8253 ns
5 ticker-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":351951485,"operations":40000,"operations_per_second":113652,"p50_ns":8767,"p99_ns":13311,"p999_ns":17279,"p9999_ns":27391,"overflow":0,"peak_rss_bytes":0}
5 lazy-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8209 ns
5 lazy-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":322785810,"operations":40000,"operations_per_second":123921,"p50_ns":9023,"p99_ns":12671,"p999_ns":15743,"p9999_ns":19583,"overflow":0,"peak_rss_bytes":0}
5 lazy-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8201 ns
5 lazy-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":354858359,"operations":40000,"operations_per_second":112721,"p50_ns":8767,"p99_ns":12799,"p999_ns":16639,"p9999_ns":28159,"overflow":0,"peak_rss_bytes":0}
5 move-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9381 ns
5 move-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":369751299,"operations":40000,"operations_per_second":108180,"p50_ns":9407,"p99_ns":11775,"p999_ns":15743,"p9999_ns":18815,"overflow":0,"peak_rss_bytes":0}
5 move-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8367 ns
5 move-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":359382888,"operations":40000,"operations_per_second":111301,"p50_ns":8959,"p99_ns":12671,"p999_ns":16767,"p9999_ns":45055,"overflow":0,"peak_rss_bytes":0}
6 base-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 10438 ns
6 base-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":402087471,"operations":40000,"operations_per_second":99480,"p50_ns":10111,"p99_ns":12927,"p999_ns":16127,"p9999_ns":36863,"overflow":0,"peak_rss_bytes":0}
6 base-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8999 ns
6 base-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":370162088,"operations":40000,"operations_per_second":108060,"p50_ns":9599,"p99_ns":13183,"p999_ns":17791,"p9999_ns":33023,"overflow":0,"peak_rss_bytes":0}
6 ticker-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8135 ns
6 ticker-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":316815680,"operations":40000,"operations_per_second":126256,"p50_ns":8895,"p99_ns":23039,"p999_ns":31743,"p9999_ns":35839,"overflow":0,"peak_rss_bytes":0}
6 ticker-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8323 ns
6 ticker-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":354085032,"operations":40000,"operations_per_second":112967,"p50_ns":8767,"p99_ns":13311,"p999_ns":17535,"p9999_ns":23935,"overflow":0,"peak_rss_bytes":0}
6 lazy-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 7705 ns
6 lazy-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":304864710,"operations":40000,"operations_per_second":131205,"p50_ns":8831,"p99_ns":12799,"p999_ns":16063,"p9999_ns":30207,"overflow":0,"peak_rss_bytes":0}
6 lazy-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8272 ns
6 lazy-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":355340981,"operations":40000,"operations_per_second":112567,"p50_ns":8767,"p99_ns":12607,"p999_ns":16895,"p9999_ns":25855,"overflow":0,"peak_rss_bytes":0}
6 move-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9408 ns
6 move-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":376729706,"operations":40000,"operations_per_second":106176,"p50_ns":9471,"p99_ns":12095,"p999_ns":15743,"p9999_ns":19327,"overflow":0,"peak_rss_bytes":0}
6 move-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8380 ns
6 move-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":361247384,"operations":40000,"operations_per_second":110727,"p50_ns":8959,"p99_ns":13119,"p999_ns":19327,"p9999_ns":42751,"overflow":0,"peak_rss_bytes":0}
7 base-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 10589 ns
7 base-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":407090598,"operations":40000,"operations_per_second":98258,"p50_ns":10175,"p99_ns":13375,"p999_ns":16383,"p9999_ns":19839,"overflow":0,"peak_rss_bytes":0}
7 base-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9115 ns
7 base-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":380846779,"operations":40000,"operations_per_second":105029,"p50_ns":9727,"p99_ns":13119,"p999_ns":17535,"p9999_ns":38143,"overflow":0,"peak_rss_bytes":0}
7 ticker-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8864 ns
7 ticker-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":345146674,"operations":40000,"operations_per_second":115892,"p50_ns":9151,"p99_ns":17151,"p999_ns":25087,"p9999_ns":30975,"overflow":0,"peak_rss_bytes":0}
7 ticker-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8406 ns
7 ticker-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":355403169,"operations":40000,"operations_per_second":112548,"p50_ns":8831,"p99_ns":13247,"p999_ns":17279,"p9999_ns":28159,"overflow":0,"peak_rss_bytes":0}
7 lazy-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8341 ns
7 lazy-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":329367335,"operations":40000,"operations_per_second":121444,"p50_ns":8959,"p99_ns":12607,"p999_ns":15807,"p9999_ns":17279,"overflow":0,"peak_rss_bytes":0}
7 lazy-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8183 ns
7 lazy-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":353580098,"operations":40000,"operations_per_second":113128,"p50_ns":8703,"p99_ns":12415,"p999_ns":16383,"p9999_ns":22015,"overflow":0,"peak_rss_bytes":0}
7 move-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9412 ns
7 move-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":378917074,"operations":40000,"operations_per_second":105563,"p50_ns":9471,"p99_ns":12607,"p999_ns":16255,"p9999_ns":40703,"overflow":0,"peak_rss_bytes":0}
7 move-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8400 ns
7 move-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":359681728,"operations":40000,"operations_per_second":111209,"p50_ns":8959,"p99_ns":12991,"p999_ns":17279,"p9999_ns":35071,"overflow":0,"peak_rss_bytes":0}
8 base-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 10550 ns
8 base-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":405836856,"operations":40000,"operations_per_second":98561,"p50_ns":10175,"p99_ns":13375,"p999_ns":16639,"p9999_ns":22783,"overflow":0,"peak_rss_bytes":0}
8 base-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9040 ns
8 base-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":376719030,"operations":40000,"operations_per_second":106179,"p50_ns":9663,"p99_ns":13567,"p999_ns":18431,"p9999_ns":55039,"overflow":0,"peak_rss_bytes":0}
8 ticker-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8784 ns
8 ticker-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":344263229,"operations":40000,"operations_per_second":116190,"p50_ns":9087,"p99_ns":16383,"p999_ns":24703,"p9999_ns":30847,"overflow":0,"peak_rss_bytes":0}
8 ticker-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8183 ns
8 ticker-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":354429983,"operations":40000,"operations_per_second":112857,"p50_ns":8831,"p99_ns":13375,"p999_ns":17151,"p9999_ns":32511,"overflow":0,"peak_rss_bytes":0}
8 lazy-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8915 ns
8 lazy-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":354339151,"operations":40000,"operations_per_second":112886,"p50_ns":8959,"p99_ns":13695,"p999_ns":15999,"p9999_ns":20863,"overflow":0,"peak_rss_bytes":0}
8 lazy-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8227 ns
8 lazy-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":355727083,"operations":40000,"operations_per_second":112445,"p50_ns":8703,"p99_ns":13119,"p999_ns":17279,"p9999_ns":35839,"overflow":0,"peak_rss_bytes":0}
8 move-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9190 ns
8 move-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":366555361,"operations":40000,"operations_per_second":109124,"p50_ns":9407,"p99_ns":12543,"p999_ns":15871,"p9999_ns":40191,"overflow":0,"peak_rss_bytes":0}
8 move-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8311 ns
8 move-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":361452887,"operations":40000,"operations_per_second":110664,"p50_ns":8959,"p99_ns":12863,"p999_ns":16895,"p9999_ns":24319,"overflow":0,"peak_rss_bytes":0}
9 base-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 10471 ns
9 base-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":403537006,"operations":40000,"operations_per_second":99123,"p50_ns":10175,"p99_ns":13439,"p999_ns":16511,"p9999_ns":26879,"overflow":0,"peak_rss_bytes":0}
9 base-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8948 ns
9 base-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":375731410,"operations":40000,"operations_per_second":106459,"p50_ns":9663,"p99_ns":13247,"p999_ns":17919,"p9999_ns":28543,"overflow":0,"peak_rss_bytes":0}
9 ticker-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8227 ns
9 ticker-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":324423096,"operations":40000,"operations_per_second":123295,"p50_ns":8831,"p99_ns":24703,"p999_ns":31743,"p9999_ns":36351,"overflow":0,"peak_rss_bytes":0}
9 ticker-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8201 ns
9 ticker-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":354073370,"operations":40000,"operations_per_second":112970,"p50_ns":8895,"p99_ns":13567,"p999_ns":18815,"p9999_ns":39423,"overflow":0,"peak_rss_bytes":0}
9 lazy-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8163 ns
9 lazy-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":321479611,"operations":40000,"operations_per_second":124424,"p50_ns":8959,"p99_ns":13375,"p999_ns":15935,"p9999_ns":23679,"overflow":0,"peak_rss_bytes":0}
9 lazy-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8232 ns
9 lazy-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":355905587,"operations":40000,"operations_per_second":112389,"p50_ns":8767,"p99_ns":12671,"p999_ns":17023,"p9999_ns":34559,"overflow":0,"peak_rss_bytes":0}
9 move-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9394 ns
9 move-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":375945403,"operations":40000,"operations_per_second":106398,"p50_ns":9471,"p99_ns":12223,"p999_ns":15615,"p9999_ns":25343,"overflow":0,"peak_rss_bytes":0}
9 move-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8388 ns
9 move-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":358991675,"operations":40000,"operations_per_second":111423,"p50_ns":8831,"p99_ns":12607,"p999_ns":17279,"p9999_ns":23295,"overflow":0,"peak_rss_bytes":0}
10 base-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 10547 ns
10 base-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":406294401,"operations":40000,"operations_per_second":98450,"p50_ns":10175,"p99_ns":13183,"p999_ns":15935,"p9999_ns":20607,"overflow":0,"peak_rss_bytes":0}
10 base-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9001 ns
10 base-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":378879139,"operations":40000,"operations_per_second":105574,"p50_ns":9663,"p99_ns":13503,"p999_ns":18047,"p9999_ns":31871,"overflow":0,"peak_rss_bytes":0}
10 ticker-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9423 ns
10 ticker-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":367302172,"operations":40000,"operations_per_second":108902,"p50_ns":9215,"p99_ns":24063,"p999_ns":29567,"p9999_ns":33791,"overflow":0,"peak_rss_bytes":0}
10 ticker-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8146 ns
10 ticker-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":347311173,"operations":40000,"operations_per_second":115170,"p50_ns":8703,"p99_ns":13055,"p999_ns":17407,"p9999_ns":36351,"overflow":0,"peak_rss_bytes":0}
10 lazy-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8885 ns
10 lazy-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":352767751,"operations":40000,"operations_per_second":113389,"p50_ns":9087,"p99_ns":13247,"p999_ns":15871,"p9999_ns":27263,"overflow":0,"peak_rss_bytes":0}
10 lazy-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8192 ns
10 lazy-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":357709361,"operations":40000,"operations_per_second":111822,"p50_ns":8831,"p99_ns":12863,"p999_ns":17023,"p9999_ns":29183,"overflow":0,"peak_rss_bytes":0}
10 move-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 9456 ns
10 move-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":379621994,"operations":40000,"operations_per_second":105367,"p50_ns":9727,"p99_ns":12863,"p999_ns":15999,"p9999_ns":27135,"overflow":0,"peak_rss_bytes":0}
10 move-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 8371 ns
10 move-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":360257731,"operations":40000,"operations_per_second":111031,"p50_ns":8895,"p99_ns":12671,"p999_ns":17023,"p9999_ns":35839,"overflow":0,"peak_rss_bytes":0}
```
