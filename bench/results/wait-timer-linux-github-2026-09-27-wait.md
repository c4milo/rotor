# The Linux wait timers at a 1 ms and a 10 ms wait, `github`, 2026-09-27

A GitHub-hosted x86-64 runner, started by a push to the branch `ab-wait-timer`, whose workflow
built `zig build bench-linux` four times: at `5e376b2`, which has neither Linux wait timer, and at
`674512c`, which has both, each once as it is and once with `rotor_post`'s 1 ms wait patched to
10 ms (`bench/crosscore/rotor_post_options.zig`, `wait_ns`). The rows name them `base-1`,
`base-10`, `lazy-1` and `lazy-10`. Ten rounds alternate the four builds, and each round runs
`post_epoll` and `post_uring` in `waiting` mode with no gap, 20,000 round trips after 2,000 of
warmup. A row is one run: the answering loop's CPU per round trip, then the run's JSON line.

What the runner reported:

```text
model name	: AMD EPYC 7763 64-Core Processor
cores: 4
kernel: 6.17.0-1022-azure
MemTotal:       16373452 kB
io_uring_disabled: 0
```

Its load average before and after the rounds:

```text
14:14:22 up 9 min,  0 user,  load average: 1.48, 1.46, 0.81
14:15:16 up 9 min,  0 user,  load average: 0.63, 1.23, 0.76
```

The runner is shared and not quiet, and no number from it enters `docs/costs.md`.

## The rounds

```text
1 base-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15733 ns
1 base-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":608690214,"operations":40000,"operations_per_second":65714,"p50_ns":17535,"p99_ns":19199,"p999_ns":39935,"p9999_ns":1130495,"overflow":0,"peak_rss_bytes":0}
1 base-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14627 ns
1 base-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":608413422,"operations":40000,"operations_per_second":65744,"p50_ns":17023,"p99_ns":22527,"p999_ns":28159,"p9999_ns":254975,"overflow":0,"peak_rss_bytes":0}
1 lazy-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12902 ns
1 lazy-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":483726711,"operations":40000,"operations_per_second":82691,"p50_ns":12799,"p99_ns":18943,"p999_ns":24191,"p9999_ns":35327,"overflow":0,"peak_rss_bytes":0}
1 lazy-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12860 ns
1 lazy-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":528329665,"operations":40000,"operations_per_second":75710,"p50_ns":12351,"p99_ns":20095,"p999_ns":24959,"p9999_ns":34815,"overflow":0,"peak_rss_bytes":0}
1 base-10 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 19366 ns
1 base-10 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":713705621,"operations":40000,"operations_per_second":56045,"p50_ns":18047,"p99_ns":19071,"p999_ns":23039,"p9999_ns":34047,"overflow":0,"peak_rss_bytes":0}
1 base-10 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15230 ns
1 base-10 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":626886434,"operations":40000,"operations_per_second":63807,"p50_ns":17279,"p99_ns":19071,"p999_ns":26751,"p9999_ns":43263,"overflow":0,"peak_rss_bytes":0}
1 lazy-10 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 17528 ns
1 lazy-10 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":686088818,"operations":40000,"operations_per_second":58301,"p50_ns":17791,"p99_ns":18687,"p999_ns":22655,"p9999_ns":585727,"overflow":0,"peak_rss_bytes":0}
1 lazy-10 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14638 ns
1 lazy-10 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":605455823,"operations":40000,"operations_per_second":66065,"p50_ns":16767,"p99_ns":18943,"p999_ns":25727,"p9999_ns":290815,"overflow":0,"peak_rss_bytes":0}
2 base-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 18886 ns
2 base-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":696861793,"operations":40000,"operations_per_second":57400,"p50_ns":17663,"p99_ns":18943,"p999_ns":23423,"p9999_ns":37631,"overflow":0,"peak_rss_bytes":0}
2 base-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15343 ns
2 base-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":626811005,"operations":40000,"operations_per_second":63815,"p50_ns":17151,"p99_ns":18943,"p999_ns":28415,"p9999_ns":43775,"overflow":0,"peak_rss_bytes":0}
2 lazy-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13685 ns
2 lazy-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":518219208,"operations":40000,"operations_per_second":77187,"p50_ns":12863,"p99_ns":19327,"p999_ns":24447,"p9999_ns":26751,"overflow":0,"peak_rss_bytes":0}
2 lazy-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 11716 ns
2 lazy-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":475271058,"operations":40000,"operations_per_second":84162,"p50_ns":12287,"p99_ns":19839,"p999_ns":24703,"p9999_ns":41215,"overflow":0,"peak_rss_bytes":0}
2 base-10 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 19142 ns
2 base-10 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":707418783,"operations":40000,"operations_per_second":56543,"p50_ns":17919,"p99_ns":19071,"p999_ns":23167,"p9999_ns":27775,"overflow":0,"peak_rss_bytes":0}
2 base-10 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15421 ns
2 base-10 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":627537738,"operations":40000,"operations_per_second":63741,"p50_ns":17279,"p99_ns":19071,"p999_ns":26495,"p9999_ns":41215,"overflow":0,"peak_rss_bytes":0}
2 lazy-10 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 17598 ns
2 lazy-10 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":675824353,"operations":40000,"operations_per_second":59186,"p50_ns":17791,"p99_ns":18687,"p999_ns":23039,"p9999_ns":27135,"overflow":0,"peak_rss_bytes":0}
2 lazy-10 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14413 ns
2 lazy-10 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":601628217,"operations":40000,"operations_per_second":66486,"p50_ns":16767,"p99_ns":18943,"p999_ns":27135,"p9999_ns":47615,"overflow":0,"peak_rss_bytes":0}
3 base-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 18802 ns
3 base-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":693230206,"operations":40000,"operations_per_second":57700,"p50_ns":17663,"p99_ns":18815,"p999_ns":23039,"p9999_ns":33535,"overflow":0,"peak_rss_bytes":0}
3 base-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15855 ns
3 base-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":642759500,"operations":40000,"operations_per_second":62231,"p50_ns":17279,"p99_ns":19199,"p999_ns":30207,"p9999_ns":64767,"overflow":0,"peak_rss_bytes":0}
3 lazy-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14221 ns
3 lazy-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":540367813,"operations":40000,"operations_per_second":74023,"p50_ns":12863,"p99_ns":19583,"p999_ns":24575,"p9999_ns":41215,"overflow":0,"peak_rss_bytes":0}
3 lazy-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12543 ns
3 lazy-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":520127267,"operations":40000,"operations_per_second":76904,"p50_ns":12287,"p99_ns":19711,"p999_ns":23807,"p9999_ns":33535,"overflow":0,"peak_rss_bytes":0}
3 base-10 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 18821 ns
3 base-10 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":701265921,"operations":40000,"operations_per_second":57039,"p50_ns":17919,"p99_ns":19071,"p999_ns":23807,"p9999_ns":33535,"overflow":0,"peak_rss_bytes":0}
3 base-10 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15468 ns
3 base-10 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":635683151,"operations":40000,"operations_per_second":62924,"p50_ns":17279,"p99_ns":19199,"p999_ns":25855,"p9999_ns":47871,"overflow":0,"peak_rss_bytes":0}
3 lazy-10 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 17978 ns
3 lazy-10 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":691952333,"operations":40000,"operations_per_second":57807,"p50_ns":17791,"p99_ns":18687,"p999_ns":22399,"p9999_ns":36607,"overflow":0,"peak_rss_bytes":0}
3 lazy-10 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13946 ns
3 lazy-10 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":569810428,"operations":40000,"operations_per_second":70198,"p50_ns":16767,"p99_ns":18815,"p999_ns":26495,"p9999_ns":37887,"overflow":0,"peak_rss_bytes":0}
4 base-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 19199 ns
4 base-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":704682493,"operations":40000,"operations_per_second":56763,"p50_ns":17791,"p99_ns":18815,"p999_ns":23295,"p9999_ns":28543,"overflow":0,"peak_rss_bytes":0}
4 base-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15866 ns
4 base-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":635820162,"operations":40000,"operations_per_second":62910,"p50_ns":17279,"p99_ns":18943,"p999_ns":26495,"p9999_ns":67583,"overflow":0,"peak_rss_bytes":0}
4 lazy-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13011 ns
4 lazy-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":493312137,"operations":40000,"operations_per_second":81084,"p50_ns":12863,"p99_ns":19199,"p999_ns":23807,"p9999_ns":31359,"overflow":0,"peak_rss_bytes":0}
4 lazy-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12976 ns
4 lazy-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":533193822,"operations":40000,"operations_per_second":75019,"p50_ns":12351,"p99_ns":19967,"p999_ns":24447,"p9999_ns":32255,"overflow":0,"peak_rss_bytes":0}
4 base-10 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 18285 ns
4 base-10 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":681132654,"operations":40000,"operations_per_second":58725,"p50_ns":17791,"p99_ns":19071,"p999_ns":24063,"p9999_ns":36351,"overflow":0,"peak_rss_bytes":0}
4 base-10 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15735 ns
4 base-10 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":645972592,"operations":40000,"operations_per_second":61922,"p50_ns":17279,"p99_ns":19199,"p999_ns":27391,"p9999_ns":798719,"overflow":0,"peak_rss_bytes":0}
4 lazy-10 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 17543 ns
4 lazy-10 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":675634017,"operations":40000,"operations_per_second":59203,"p50_ns":17791,"p99_ns":18815,"p999_ns":22783,"p9999_ns":50175,"overflow":0,"peak_rss_bytes":0}
4 lazy-10 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14875 ns
4 lazy-10 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":622140019,"operations":40000,"operations_per_second":64294,"p50_ns":17023,"p99_ns":19071,"p999_ns":25983,"p9999_ns":440319,"overflow":0,"peak_rss_bytes":0}
5 base-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16035 ns
5 base-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":603389955,"operations":40000,"operations_per_second":66292,"p50_ns":17535,"p99_ns":18943,"p999_ns":23167,"p9999_ns":36095,"overflow":0,"peak_rss_bytes":0}
5 base-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16411 ns
5 base-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":655585247,"operations":40000,"operations_per_second":61014,"p50_ns":17279,"p99_ns":19071,"p999_ns":26751,"p9999_ns":43007,"overflow":0,"peak_rss_bytes":0}
5 lazy-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13344 ns
5 lazy-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":507061745,"operations":40000,"operations_per_second":78885,"p50_ns":12863,"p99_ns":19199,"p999_ns":23551,"p9999_ns":26367,"overflow":0,"peak_rss_bytes":0}
5 lazy-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12657 ns
5 lazy-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":512577189,"operations":40000,"operations_per_second":78037,"p50_ns":12415,"p99_ns":20095,"p999_ns":24703,"p9999_ns":34047,"overflow":0,"peak_rss_bytes":0}
5 base-10 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 18123 ns
5 base-10 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":678859802,"operations":40000,"operations_per_second":58922,"p50_ns":18047,"p99_ns":19199,"p999_ns":23423,"p9999_ns":32767,"overflow":0,"peak_rss_bytes":0}
5 base-10 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14714 ns
5 base-10 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":608959538,"operations":40000,"operations_per_second":65685,"p50_ns":17151,"p99_ns":19455,"p999_ns":27391,"p9999_ns":85503,"overflow":0,"peak_rss_bytes":0}
5 lazy-10 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 17878 ns
5 lazy-10 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":684768058,"operations":40000,"operations_per_second":58413,"p50_ns":17663,"p99_ns":18815,"p999_ns":25727,"p9999_ns":36863,"overflow":0,"peak_rss_bytes":0}
5 lazy-10 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14059 ns
5 lazy-10 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":592346386,"operations":40000,"operations_per_second":67528,"p50_ns":16767,"p99_ns":19199,"p999_ns":26111,"p9999_ns":38143,"overflow":0,"peak_rss_bytes":0}
6 base-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 17005 ns
6 base-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":634942059,"operations":40000,"operations_per_second":62997,"p50_ns":17663,"p99_ns":18815,"p999_ns":23935,"p9999_ns":35583,"overflow":0,"peak_rss_bytes":0}
6 base-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16381 ns
6 base-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":653324135,"operations":40000,"operations_per_second":61225,"p50_ns":17279,"p99_ns":19071,"p999_ns":27263,"p9999_ns":40447,"overflow":0,"peak_rss_bytes":0}
6 lazy-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13368 ns
6 lazy-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":511411346,"operations":40000,"operations_per_second":78214,"p50_ns":12799,"p99_ns":19455,"p999_ns":24063,"p9999_ns":761855,"overflow":0,"peak_rss_bytes":0}
6 lazy-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13098 ns
6 lazy-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":531773004,"operations":40000,"operations_per_second":75220,"p50_ns":12287,"p99_ns":19839,"p999_ns":24191,"p9999_ns":34559,"overflow":0,"peak_rss_bytes":0}
6 base-10 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 18354 ns
6 base-10 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":691739095,"operations":40000,"operations_per_second":57825,"p50_ns":17919,"p99_ns":19071,"p999_ns":25087,"p9999_ns":507903,"overflow":0,"peak_rss_bytes":0}
6 base-10 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16043 ns
6 base-10 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":643091109,"operations":40000,"operations_per_second":62199,"p50_ns":17279,"p99_ns":19327,"p999_ns":25855,"p9999_ns":36863,"overflow":0,"peak_rss_bytes":0}
6 lazy-10 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 17726 ns
6 lazy-10 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":677941989,"operations":40000,"operations_per_second":59002,"p50_ns":17663,"p99_ns":18815,"p999_ns":24575,"p9999_ns":37631,"overflow":0,"peak_rss_bytes":0}
6 lazy-10 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14531 ns
6 lazy-10 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":613902996,"operations":40000,"operations_per_second":65156,"p50_ns":16895,"p99_ns":19071,"p999_ns":25215,"p9999_ns":53759,"overflow":0,"peak_rss_bytes":0}
7 base-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 18558 ns
7 base-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":689054006,"operations":40000,"operations_per_second":58050,"p50_ns":17791,"p99_ns":19071,"p999_ns":25599,"p9999_ns":29695,"overflow":0,"peak_rss_bytes":0}
7 base-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15780 ns
7 base-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":640041539,"operations":40000,"operations_per_second":62495,"p50_ns":17279,"p99_ns":19071,"p999_ns":26879,"p9999_ns":38911,"overflow":0,"peak_rss_bytes":0}
7 lazy-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14124 ns
7 lazy-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":536266972,"operations":40000,"operations_per_second":74589,"p50_ns":12863,"p99_ns":19327,"p999_ns":23295,"p9999_ns":27391,"overflow":0,"peak_rss_bytes":0}
7 lazy-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13506 ns
7 lazy-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":545317329,"operations":40000,"operations_per_second":73351,"p50_ns":12479,"p99_ns":20095,"p999_ns":24063,"p9999_ns":27519,"overflow":0,"peak_rss_bytes":0}
7 base-10 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 17930 ns
7 base-10 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":674492692,"operations":40000,"operations_per_second":59303,"p50_ns":17919,"p99_ns":18943,"p999_ns":21887,"p9999_ns":30463,"overflow":0,"peak_rss_bytes":0}
7 base-10 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15939 ns
7 base-10 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":645672059,"operations":40000,"operations_per_second":61950,"p50_ns":17407,"p99_ns":19327,"p999_ns":26111,"p9999_ns":34047,"overflow":0,"peak_rss_bytes":0}
7 lazy-10 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 17904 ns
7 lazy-10 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":684791742,"operations":40000,"operations_per_second":58411,"p50_ns":17663,"p99_ns":18815,"p999_ns":22911,"p9999_ns":28543,"overflow":0,"peak_rss_bytes":0}
7 lazy-10 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15098 ns
7 lazy-10 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":621058023,"operations":40000,"operations_per_second":64406,"p50_ns":16767,"p99_ns":18943,"p999_ns":26111,"p9999_ns":39167,"overflow":0,"peak_rss_bytes":0}
8 base-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 18559 ns
8 base-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":688377104,"operations":40000,"operations_per_second":58107,"p50_ns":17791,"p99_ns":18943,"p999_ns":22143,"p9999_ns":29183,"overflow":0,"peak_rss_bytes":0}
8 base-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16111 ns
8 base-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":652032002,"operations":40000,"operations_per_second":61346,"p50_ns":17279,"p99_ns":19455,"p999_ns":28415,"p9999_ns":175103,"overflow":0,"peak_rss_bytes":0}
8 lazy-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14099 ns
8 lazy-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":535543965,"operations":40000,"operations_per_second":74690,"p50_ns":12927,"p99_ns":19455,"p999_ns":23551,"p9999_ns":33279,"overflow":0,"peak_rss_bytes":0}
8 lazy-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12774 ns
8 lazy-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":518490246,"operations":40000,"operations_per_second":77147,"p50_ns":12287,"p99_ns":19839,"p999_ns":24063,"p9999_ns":32127,"overflow":0,"peak_rss_bytes":0}
8 base-10 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 18694 ns
8 base-10 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":696293396,"operations":40000,"operations_per_second":57447,"p50_ns":17919,"p99_ns":19071,"p999_ns":23423,"p9999_ns":41215,"overflow":0,"peak_rss_bytes":0}
8 base-10 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15817 ns
8 base-10 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":641313809,"operations":40000,"operations_per_second":62371,"p50_ns":17279,"p99_ns":20351,"p999_ns":30207,"p9999_ns":38143,"overflow":0,"peak_rss_bytes":0}
8 lazy-10 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16866 ns
8 lazy-10 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":652568634,"operations":40000,"operations_per_second":61296,"p50_ns":17535,"p99_ns":18559,"p999_ns":22527,"p9999_ns":31103,"overflow":0,"peak_rss_bytes":0}
8 lazy-10 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15360 ns
8 lazy-10 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":629602482,"operations":40000,"operations_per_second":63532,"p50_ns":16895,"p99_ns":18943,"p999_ns":26623,"p9999_ns":33791,"overflow":0,"peak_rss_bytes":0}
9 base-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 18518 ns
9 base-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":687886355,"operations":40000,"operations_per_second":58149,"p50_ns":17791,"p99_ns":19071,"p999_ns":23807,"p9999_ns":32255,"overflow":0,"peak_rss_bytes":0}
9 base-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15299 ns
9 base-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":622336638,"operations":40000,"operations_per_second":64273,"p50_ns":17279,"p99_ns":19199,"p999_ns":26495,"p9999_ns":36095,"overflow":0,"peak_rss_bytes":0}
9 lazy-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12950 ns
9 lazy-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":490098062,"operations":40000,"operations_per_second":81616,"p50_ns":12799,"p99_ns":19071,"p999_ns":24959,"p9999_ns":34303,"overflow":0,"peak_rss_bytes":0}
9 lazy-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12469 ns
9 lazy-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":517143990,"operations":40000,"operations_per_second":77347,"p50_ns":12095,"p99_ns":19839,"p999_ns":24831,"p9999_ns":36351,"overflow":0,"peak_rss_bytes":0}
9 base-10 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 18007 ns
9 base-10 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":677208063,"operations":40000,"operations_per_second":59066,"p50_ns":17919,"p99_ns":19199,"p999_ns":24575,"p9999_ns":34815,"overflow":0,"peak_rss_bytes":0}
9 base-10 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16482 ns
9 base-10 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":660290320,"operations":40000,"operations_per_second":60579,"p50_ns":17407,"p99_ns":18943,"p999_ns":25471,"p9999_ns":37887,"overflow":0,"peak_rss_bytes":0}
9 lazy-10 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 17664 ns
9 lazy-10 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":678132139,"operations":40000,"operations_per_second":58985,"p50_ns":17791,"p99_ns":18815,"p999_ns":24063,"p9999_ns":44799,"overflow":0,"peak_rss_bytes":0}
9 lazy-10 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14390 ns
9 lazy-10 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":604890458,"operations":40000,"operations_per_second":66127,"p50_ns":16895,"p99_ns":19071,"p999_ns":25471,"p9999_ns":37631,"overflow":0,"peak_rss_bytes":0}
10 base-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 18401 ns
10 base-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":683971462,"operations":40000,"operations_per_second":58481,"p50_ns":17791,"p99_ns":18943,"p999_ns":23423,"p9999_ns":41727,"overflow":0,"peak_rss_bytes":0}
10 base-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16200 ns
10 base-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":649763349,"operations":40000,"operations_per_second":61560,"p50_ns":17407,"p99_ns":19071,"p999_ns":26239,"p9999_ns":38143,"overflow":0,"peak_rss_bytes":0}
10 lazy-1 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14432 ns
10 lazy-1 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":548113429,"operations":40000,"operations_per_second":72977,"p50_ns":12927,"p99_ns":19455,"p999_ns":24575,"p9999_ns":27263,"overflow":0,"peak_rss_bytes":0}
10 lazy-1 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13328 ns
10 lazy-1 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":536279841,"operations":40000,"operations_per_second":74587,"p50_ns":12415,"p99_ns":20735,"p999_ns":24447,"p9999_ns":30335,"overflow":0,"peak_rss_bytes":0}
10 base-10 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 18492 ns
10 base-10 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":690012638,"operations":40000,"operations_per_second":57969,"p50_ns":17791,"p99_ns":19071,"p999_ns":23807,"p9999_ns":33023,"overflow":0,"peak_rss_bytes":0}
10 base-10 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16065 ns
10 base-10 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":646547959,"operations":40000,"operations_per_second":61867,"p50_ns":17279,"p99_ns":19327,"p999_ns":25215,"p9999_ns":36607,"overflow":0,"peak_rss_bytes":0}
10 lazy-10 post_epoll rotor_post: mode waiting, gap 0 us, peer CPU per round trip 17861 ns
10 lazy-10 post_epoll {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":682620822,"operations":40000,"operations_per_second":58597,"p50_ns":17663,"p99_ns":18815,"p999_ns":25087,"p9999_ns":31999,"overflow":0,"peak_rss_bytes":0}
10 lazy-10 post_uring rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13979 ns
10 lazy-10 post_uring {"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":590442850,"operations":40000,"operations_per_second":67745,"p50_ns":16767,"p99_ns":19327,"p999_ns":27135,"p9999_ns":42751,"overflow":0,"peak_rss_bytes":0}
```
