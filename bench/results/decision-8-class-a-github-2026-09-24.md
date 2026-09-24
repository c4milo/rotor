# Decision 8's class A on `github`, 2026-09-24

`zig build bench-linux` built three `nop` benchmarks, from commit `82ffed8` in runs 1 to 5 and from
`dcc95fb` in runs 6 to 8:

- `uring_nop_safe`: ReleaseSafe, the mode rotor ships in.
- `uring_nop_no_class_a`: ReleaseSafe with decision 8's class A assertions compiled out
  (`src/core/assertion_class.zig`), and every other assertion and safety check kept.
- `uring_nop_fast`: ReleaseFast, which removes every assertion and every safety check. It prints
  "class A on" because the switch is on, but ReleaseFast checks no assertion at all. Later builds
  print "no assertions" there.

The CI job `costs` ran the three in turn five times on a GitHub-hosted `ubuntu-24.04` runner. The
job was started by hand eight times, and each start got its own runner, so there are eight runs
below. The pool gave five AMD EPYC 7763 runners, one AMD EPYC 9V45, one AMD EPYC 9V74 and one
Intel Xeon Platinum 8573C.

`dcc95fb` switched 14 more class A sites, the ones an echo message passes through, and runs 6 to 8
add the echo half: `echo_runner --candidates rotor --payloads 4096` against `zig-out/bin`, the
server rotor ships, and against `zig-out/no-class-a`, the same server built with class A compiled
out, alternating, three times each. A `nop` passes none of those 14 sites, so the `nop` rounds of
all eight runs measure the same assertions. Decision 8's results section reads them.

## Run 1: AMD EPYC 7763 64-Core Processor, CI run 36008948196

```text
model name	: AMD EPYC 7763 64-Core Processor
4
6.17.0-1022-azure
MemTotal:       16373448 kB
== round 1
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 601 | 551 |
| 8 | 1323 | 1383 | 165 |
| 32 | 3847 | 3988 | 120 |
| 64 | 7243 | 8516 | 113 |
| 128 | 14307 | 22562 | 111 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 541 | 581 | 541 |
| 8 | 1272 | 1332 | 159 |
| 32 | 3687 | 4148 | 115 |
| 64 | 6903 | 8746 | 107 |
| 128 | 13585 | 21961 | 106 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 561 | 591 | 561 |
| 8 | 1323 | 1392 | 165 |
| 32 | 3797 | 4468 | 118 |
| 64 | 7133 | 9267 | 111 |
| 128 | 14076 | 22472 | 109 |
== round 2
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 611 | 551 |
| 8 | 1332 | 1393 | 166 |
| 32 | 3857 | 5550 | 120 |
| 64 | 7253 | 8135 | 113 |
| 128 | 14347 | 22782 | 112 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 531 | 591 | 531 |
| 8 | 1272 | 1422 | 159 |
| 32 | 3647 | 4218 | 113 |
| 64 | 6883 | 9648 | 107 |
| 128 | 13554 | 22181 | 105 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 561 | 631 | 561 |
| 8 | 1322 | 1382 | 165 |
| 32 | 3787 | 5199 | 118 |
| 64 | 7203 | 9167 | 112 |
| 128 | 14106 | 22472 | 110 |
== round 3
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 672 | 551 |
| 8 | 1323 | 1383 | 165 |
| 32 | 3856 | 4669 | 120 |
| 64 | 7233 | 10540 | 113 |
| 128 | 14276 | 22692 | 111 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 531 | 581 | 531 |
| 8 | 1272 | 1322 | 159 |
| 32 | 3657 | 3787 | 114 |
| 64 | 6872 | 8727 | 107 |
| 128 | 13545 | 21890 | 105 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 561 | 611 | 561 |
| 8 | 1332 | 1383 | 166 |
| 32 | 3827 | 4538 | 119 |
| 64 | 7153 | 8144 | 111 |
| 128 | 14086 | 22532 | 110 |
== round 4
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 722 | 551 |
| 8 | 1322 | 1392 | 165 |
| 32 | 3847 | 5130 | 120 |
| 64 | 7243 | 9087 | 113 |
| 128 | 14256 | 22762 | 111 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 521 | 611 | 521 |
| 8 | 1263 | 1904 | 157 |
| 32 | 3657 | 3918 | 114 |
| 64 | 6953 | 7824 | 108 |
| 128 | 13606 | 22041 | 106 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 552 | 691 | 552 |
| 8 | 1322 | 1713 | 165 |
| 32 | 3787 | 3927 | 118 |
| 64 | 7143 | 9979 | 111 |
| 128 | 14077 | 22703 | 109 |
== round 5
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 541 | 591 | 541 |
| 8 | 1323 | 1393 | 165 |
| 32 | 3877 | 5370 | 121 |
| 64 | 7434 | 10129 | 116 |
| 128 | 14377 | 22993 | 112 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 541 | 692 | 541 |
| 8 | 1272 | 1322 | 159 |
| 32 | 3657 | 3807 | 114 |
| 64 | 6893 | 8115 | 107 |
| 128 | 13565 | 21930 | 105 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 602 | 551 |
| 8 | 1313 | 1373 | 164 |
| 32 | 3797 | 5039 | 118 |
| 64 | 7143 | 9338 | 111 |
| 128 | 14046 | 22702 | 109 |
```

## Run 2: AMD EPYC 7763 64-Core Processor, CI run 36009467504

```text
model name	: AMD EPYC 7763 64-Core Processor
4
6.17.0-1022-azure
MemTotal:       16373452 kB
== round 1
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 591 | 551 |
| 8 | 1333 | 1393 | 166 |
| 32 | 3917 | 4047 | 122 |
| 64 | 7404 | 9649 | 115 |
| 128 | 14427 | 22482 | 112 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 531 | 621 | 531 |
| 8 | 1262 | 1313 | 157 |
| 32 | 3677 | 3787 | 114 |
| 64 | 6953 | 7544 | 108 |
| 128 | 13596 | 21550 | 106 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 601 | 551 |
| 8 | 1312 | 1362 | 164 |
| 32 | 3797 | 3907 | 118 |
| 64 | 7194 | 9748 | 112 |
| 128 | 14217 | 22182 | 111 |
== round 2
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 591 | 551 |
| 8 | 1323 | 1393 | 165 |
| 32 | 3888 | 4328 | 121 |
| 64 | 7354 | 8145 | 114 |
| 128 | 14447 | 22502 | 112 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 531 | 571 | 531 |
| 8 | 1272 | 1332 | 159 |
| 32 | 3687 | 3807 | 115 |
| 64 | 6943 | 7264 | 108 |
| 128 | 13615 | 21791 | 106 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 611 | 551 |
| 8 | 1332 | 1463 | 166 |
| 32 | 3888 | 5500 | 121 |
| 64 | 7304 | 9538 | 114 |
| 128 | 14236 | 22353 | 111 |
== round 3
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 582 | 551 |
| 8 | 1313 | 1403 | 164 |
| 32 | 3917 | 4138 | 122 |
| 64 | 7374 | 9427 | 115 |
| 128 | 14387 | 22513 | 112 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 531 | 571 | 531 |
| 8 | 1272 | 1322 | 159 |
| 32 | 3657 | 3777 | 114 |
| 64 | 6933 | 9147 | 108 |
| 128 | 13565 | 21591 | 105 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 552 | 652 | 552 |
| 8 | 1313 | 1402 | 164 |
| 32 | 3817 | 4578 | 119 |
| 64 | 7214 | 7775 | 112 |
| 128 | 14187 | 22172 | 110 |
== round 4
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 591 | 551 |
| 8 | 1323 | 1383 | 165 |
| 32 | 3957 | 4068 | 123 |
| 64 | 7384 | 8566 | 115 |
| 128 | 14447 | 22512 | 112 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 531 | 561 | 531 |
| 8 | 1262 | 1322 | 157 |
| 32 | 3657 | 3797 | 114 |
| 64 | 6883 | 7635 | 107 |
| 128 | 13545 | 21520 | 105 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 552 | 621 | 552 |
| 8 | 1323 | 1392 | 165 |
| 32 | 3798 | 3927 | 118 |
| 64 | 7173 | 9538 | 112 |
| 128 | 14197 | 22332 | 110 |
== round 5
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 601 | 551 |
| 8 | 1313 | 1403 | 164 |
| 32 | 3897 | 5731 | 121 |
| 64 | 7324 | 9437 | 114 |
| 128 | 14457 | 22432 | 112 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 531 | 552 | 531 |
| 8 | 1263 | 1332 | 157 |
| 32 | 3666 | 3798 | 114 |
| 64 | 6913 | 8786 | 108 |
| 128 | 13525 | 21481 | 105 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 581 | 551 |
| 8 | 1322 | 1373 | 165 |
| 32 | 3827 | 3947 | 119 |
| 64 | 7244 | 8405 | 113 |
| 128 | 14177 | 22242 | 110 |
```

## Run 3: AMD EPYC 7763 64-Core Processor, CI run 36009991809

```text
model name	: AMD EPYC 7763 64-Core Processor
4
6.17.0-1022-azure
MemTotal:       16373452 kB
== round 1
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 611 | 551 |
| 8 | 1313 | 1383 | 164 |
| 32 | 4017 | 4909 | 125 |
| 64 | 7474 | 9628 | 116 |
| 128 | 14537 | 22682 | 113 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 532 | 581 | 532 |
| 8 | 1272 | 1333 | 159 |
| 32 | 3647 | 4318 | 113 |
| 64 | 6893 | 8507 | 107 |
| 128 | 13585 | 21710 | 106 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 552 | 601 | 552 |
| 8 | 1323 | 1373 | 165 |
| 32 | 3798 | 3938 | 118 |
| 64 | 7183 | 7955 | 112 |
| 128 | 14206 | 22201 | 110 |
== round 2
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 541 | 591 | 541 |
| 8 | 1322 | 1402 | 165 |
| 32 | 3877 | 4018 | 121 |
| 64 | 7333 | 9307 | 114 |
| 128 | 14457 | 22613 | 112 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 531 | 561 | 531 |
| 8 | 1263 | 1322 | 157 |
| 32 | 3657 | 3787 | 114 |
| 64 | 6893 | 9458 | 107 |
| 128 | 13545 | 21660 | 105 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 561 | 721 | 561 |
| 8 | 1313 | 1382 | 164 |
| 32 | 3797 | 3898 | 118 |
| 64 | 7194 | 9227 | 112 |
| 128 | 14197 | 22321 | 110 |
== round 3
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 591 | 551 |
| 8 | 1323 | 1392 | 165 |
| 32 | 3887 | 4629 | 121 |
| 64 | 7294 | 8095 | 113 |
| 128 | 14357 | 22512 | 112 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 531 | 702 | 531 |
| 8 | 1272 | 1342 | 159 |
| 32 | 3646 | 3877 | 113 |
| 64 | 6903 | 7675 | 107 |
| 128 | 13575 | 21701 | 106 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 612 | 551 |
| 8 | 1313 | 1373 | 164 |
| 32 | 3787 | 3987 | 118 |
| 64 | 7164 | 9257 | 111 |
| 128 | 14117 | 22252 | 110 |
== round 4
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 662 | 551 |
| 8 | 1313 | 1393 | 164 |
| 32 | 3848 | 3978 | 120 |
| 64 | 7264 | 8877 | 113 |
| 128 | 14297 | 22502 | 111 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 531 | 551 | 531 |
| 8 | 1262 | 1312 | 157 |
| 32 | 3647 | 3777 | 113 |
| 64 | 6873 | 9708 | 107 |
| 128 | 13565 | 21611 | 105 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 631 | 551 |
| 8 | 1313 | 1372 | 164 |
| 32 | 3787 | 3917 | 118 |
| 64 | 7183 | 7965 | 112 |
| 128 | 14157 | 22211 | 110 |
== round 5
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 542 | 621 | 542 |
| 8 | 1313 | 1383 | 164 |
| 32 | 3877 | 3998 | 121 |
| 64 | 7264 | 9006 | 113 |
| 128 | 14316 | 22412 | 111 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 531 | 651 | 531 |
| 8 | 1262 | 1313 | 157 |
| 32 | 3646 | 3767 | 113 |
| 64 | 6893 | 7784 | 107 |
| 128 | 13555 | 21610 | 105 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 561 | 591 | 561 |
| 8 | 1302 | 1362 | 162 |
| 32 | 3797 | 3917 | 118 |
| 64 | 7173 | 8175 | 112 |
| 128 | 14107 | 22251 | 110 |
```

## Run 4: AMD EPYC 9V45 96-Core Processor, CI run 36010001773

```text
model name	: AMD EPYC 9V45 96-Core Processor
4
6.17.0-1022-azure
MemTotal:       16373452 kB
== round 1
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 391 | 430 | 391 |
| 8 | 1001 | 1032 | 125 |
| 32 | 3025 | 3656 | 94 |
| 64 | 5939 | 6029 | 92 |
| 128 | 11398 | 16505 | 89 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 391 | 460 | 391 |
| 8 | 991 | 1022 | 123 |
| 32 | 2975 | 3065 | 92 |
| 64 | 5919 | 6039 | 92 |
| 128 | 11497 | 16816 | 89 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 391 | 411 | 391 |
| 8 | 1012 | 1041 | 126 |
| 32 | 3135 | 3966 | 97 |
| 64 | 5999 | 6249 | 93 |
| 128 | 11627 | 17327 | 90 |
== round 2
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 410 | 461 | 410 |
| 8 | 1032 | 1062 | 129 |
| 32 | 3235 | 4838 | 101 |
| 64 | 6039 | 6479 | 94 |
| 128 | 11487 | 16545 | 89 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 390 | 410 | 390 |
| 8 | 992 | 1032 | 124 |
| 32 | 3064 | 3345 | 95 |
| 64 | 5709 | 5799 | 89 |
| 128 | 10956 | 16024 | 85 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 411 | 431 | 411 |
| 8 | 1031 | 1061 | 128 |
| 32 | 3075 | 3395 | 96 |
| 64 | 5639 | 5758 | 88 |
| 128 | 11087 | 16154 | 86 |
== round 3
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 381 | 401 | 381 |
| 8 | 992 | 1021 | 124 |
| 32 | 3155 | 3265 | 98 |
| 64 | 6069 | 6419 | 94 |
| 128 | 11627 | 16885 | 90 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 400 | 421 | 400 |
| 8 | 1011 | 1041 | 126 |
| 32 | 3055 | 3145 | 95 |
| 64 | 5939 | 8242 | 92 |
| 128 | 11477 | 16916 | 89 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 391 | 411 | 391 |
| 8 | 1002 | 1032 | 125 |
| 32 | 3084 | 3155 | 96 |
| 64 | 5768 | 7231 | 90 |
| 128 | 11247 | 16515 | 87 |
== round 4
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 391 | 411 | 391 |
| 8 | 1022 | 1052 | 127 |
| 32 | 3054 | 3105 | 95 |
| 64 | 5879 | 6610 | 91 |
| 128 | 11457 | 42274 | 89 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 410 | 480 | 410 |
| 8 | 992 | 1092 | 124 |
| 32 | 3044 | 3185 | 95 |
| 64 | 5789 | 6019 | 90 |
| 128 | 10947 | 16004 | 85 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 391 | 421 | 391 |
| 8 | 1022 | 1062 | 127 |
| 32 | 3175 | 3265 | 99 |
| 64 | 5999 | 6139 | 93 |
| 128 | 11658 | 16845 | 91 |
== round 5
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 391 | 420 | 391 |
| 8 | 1002 | 1032 | 125 |
| 32 | 3105 | 3185 | 97 |
| 64 | 5989 | 7882 | 93 |
| 128 | 11117 | 16295 | 86 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 391 | 421 | 391 |
| 8 | 1002 | 2725 | 125 |
| 32 | 2975 | 3245 | 92 |
| 64 | 5779 | 5929 | 90 |
| 128 | 11338 | 16245 | 88 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 391 | 421 | 391 |
| 8 | 1022 | 1052 | 127 |
| 32 | 3104 | 3164 | 97 |
| 64 | 5838 | 6610 | 91 |
| 128 | 11638 | 16775 | 90 |
```

## Run 5: AMD EPYC 7763 64-Core Processor, CI run 36010011574

```text
model name	: AMD EPYC 7763 64-Core Processor
4
6.17.0-1022-azure
MemTotal:       16373452 kB
== round 1
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 601 | 551 |
| 8 | 1322 | 1392 | 165 |
| 32 | 3867 | 5681 | 120 |
| 64 | 7444 | 9047 | 116 |
| 128 | 14427 | 22462 | 112 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 531 | 561 | 531 |
| 8 | 1272 | 1402 | 159 |
| 32 | 3687 | 3888 | 115 |
| 64 | 7024 | 8385 | 109 |
| 128 | 13685 | 21670 | 106 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 561 | 592 | 561 |
| 8 | 1303 | 1363 | 162 |
| 32 | 3807 | 3967 | 118 |
| 64 | 7183 | 9017 | 112 |
| 128 | 14116 | 22101 | 110 |
== round 2
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 741 | 551 |
| 8 | 1322 | 1383 | 165 |
| 32 | 3867 | 3987 | 120 |
| 64 | 7253 | 8285 | 113 |
| 128 | 14287 | 22301 | 111 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 531 | 602 | 531 |
| 8 | 1263 | 1342 | 157 |
| 32 | 3647 | 3868 | 113 |
| 64 | 6893 | 7624 | 107 |
| 128 | 13625 | 21661 | 106 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 621 | 551 |
| 8 | 1312 | 1363 | 164 |
| 32 | 3778 | 3908 | 118 |
| 64 | 7124 | 7914 | 111 |
| 128 | 14066 | 22012 | 109 |
== round 3
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 591 | 551 |
| 8 | 1322 | 1402 | 165 |
| 32 | 3857 | 3988 | 120 |
| 64 | 7244 | 9086 | 113 |
| 128 | 14277 | 22422 | 111 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 531 | 581 | 531 |
| 8 | 1272 | 1323 | 159 |
| 32 | 3656 | 4309 | 114 |
| 64 | 6893 | 10720 | 107 |
| 128 | 13555 | 21540 | 105 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 610 | 551 |
| 8 | 1323 | 2014 | 165 |
| 32 | 3808 | 3957 | 119 |
| 64 | 7224 | 7504 | 112 |
| 128 | 14197 | 22232 | 110 |
== round 4
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 631 | 551 |
| 8 | 1322 | 1392 | 165 |
| 32 | 3857 | 3977 | 120 |
| 64 | 7234 | 9508 | 113 |
| 128 | 14327 | 22472 | 111 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 531 | 711 | 531 |
| 8 | 1262 | 1322 | 157 |
| 32 | 3636 | 3757 | 113 |
| 64 | 6853 | 7173 | 107 |
| 128 | 13545 | 21510 | 105 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 581 | 551 |
| 8 | 1312 | 1362 | 164 |
| 32 | 3787 | 3897 | 118 |
| 64 | 7134 | 9007 | 111 |
| 128 | 14066 | 22082 | 109 |
== round 5
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 642 | 551 |
| 8 | 1322 | 1392 | 165 |
| 32 | 3857 | 4829 | 120 |
| 64 | 7254 | 7624 | 113 |
| 128 | 14307 | 22513 | 111 |
uring nop, ReleaseFast, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 531 | 552 | 531 |
| 8 | 1262 | 1333 | 157 |
| 32 | 3657 | 3897 | 114 |
| 64 | 6963 | 7434 | 108 |
| 128 | 13616 | 21590 | 106 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 611 | 551 |
| 8 | 1322 | 1393 | 165 |
| 32 | 3807 | 4899 | 118 |
| 64 | 7154 | 7664 | 111 |
| 128 | 14077 | 22011 | 109 |
```

## Run 6: INTEL(R) XEON(R) PLATINUM 8573C, CI run 36020002652, commit dcc95fb

The `nop` rounds, then the echo half: `echo_runner --candidates rotor --payloads 4096` against
the server rotor ships and against `zig-out/no-class-a/rotor_echo`, alternating, three times each.

```text
model name	: INTEL(R) XEON(R) PLATINUM 8573C
4
6.17.0-1022-azure
MemTotal:       16372436 kB
== round 1
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 262 | 300 | 262 |
| 8 | 736 | 826 | 92 |
| 32 | 2401 | 2801 | 75 |
| 64 | 4682 | 5468 | 73 |
| 128 | 9138 | 13422 | 71 |
uring nop, ReleaseFast, no assertions, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 289 | 426 | 289 |
| 8 | 690 | 748 | 86 |
| 32 | 2186 | 2539 | 68 |
| 64 | 4147 | 4839 | 64 |
| 128 | 8162 | 12740 | 63 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 277 | 342 | 277 |
| 8 | 742 | 807 | 92 |
| 32 | 2399 | 2662 | 74 |
| 64 | 4631 | 6722 | 72 |
| 128 | 8998 | 11655 | 70 |
== round 2
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 268 | 303 | 268 |
| 8 | 740 | 826 | 92 |
| 32 | 2428 | 2959 | 75 |
| 64 | 4683 | 5543 | 73 |
| 128 | 9261 | 13445 | 72 |
uring nop, ReleaseFast, no assertions, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 289 | 342 | 289 |
| 8 | 750 | 809 | 93 |
| 32 | 2119 | 2430 | 66 |
| 64 | 4133 | 4660 | 64 |
| 128 | 8186 | 10254 | 63 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 276 | 302 | 276 |
| 8 | 744 | 813 | 93 |
| 32 | 2383 | 2816 | 74 |
| 64 | 4625 | 5410 | 72 |
| 128 | 9102 | 13421 | 71 |
== round 3
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 267 | 337 | 267 |
| 8 | 760 | 909 | 95 |
| 32 | 2392 | 2700 | 74 |
| 64 | 4649 | 9420 | 72 |
| 128 | 9042 | 12201 | 70 |
uring nop, ReleaseFast, no assertions, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 259 | 296 | 259 |
| 8 | 803 | 913 | 100 |
| 32 | 2367 | 2697 | 73 |
| 64 | 4092 | 4325 | 63 |
| 128 | 8240 | 11310 | 64 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 301 | 339 | 301 |
| 8 | 747 | 893 | 93 |
| 32 | 2354 | 2506 | 73 |
| 64 | 4644 | 9736 | 72 |
| 128 | 9231 | 14107 | 72 |
== round 4
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 269 | 296 | 269 |
| 8 | 797 | 895 | 99 |
| 32 | 2413 | 2812 | 75 |
| 64 | 4689 | 5898 | 73 |
| 128 | 9209 | 11912 | 71 |
uring nop, ReleaseFast, no assertions, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 256 | 288 | 256 |
| 8 | 702 | 755 | 87 |
| 32 | 2149 | 2499 | 67 |
| 64 | 4142 | 4878 | 64 |
| 128 | 8065 | 9758 | 63 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 306 | 334 | 306 |
| 8 | 812 | 895 | 101 |
| 32 | 2413 | 2896 | 75 |
| 64 | 5042 | 9251 | 78 |
| 128 | 9165 | 27303 | 71 |
== round 5
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 271 | 317 | 271 |
| 8 | 807 | 919 | 100 |
| 32 | 2430 | 2840 | 75 |
| 64 | 4695 | 5443 | 73 |
| 128 | 9325 | 12066 | 72 |
uring nop, ReleaseFast, no assertions, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 261 | 295 | 261 |
| 8 | 709 | 830 | 88 |
| 32 | 2161 | 2526 | 67 |
| 64 | 4140 | 4995 | 64 |
| 128 | 8167 | 10693 | 63 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 302 | 335 | 302 |
| 8 | 733 | 965 | 91 |
| 32 | 2433 | 2816 | 76 |
| 64 | 4530 | 5148 | 70 |
| 128 | 9117 | 13852 | 71 |
-rwxr-xr-x 1 runner runner 3951936 Sep 24 15:29 zig-out/bin/rotor_echo
-rwxr-xr-x 1 runner runner 3942104 Sep 24 15:29 zig-out/no-class-a/rotor_echo
== round 1, class A on
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 208301 | 833218 | 74239 | 109055 | 121855 | 160767 | 3997696 | 4 | 3 | 1 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 214784 | 859164 | 294911 | 364543 | 442367 | 765951 | 7462912 | 0 | 0 | 0 |  |
== round 1, class A off
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 207082 | 828340 | 74751 | 110079 | 144383 | 261119 | 3993600 | 2 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 212609 | 850472 | 296959 | 339967 | 395263 | 483327 | 7462912 | 1 | 0 | 0 |  |
== round 2, class A on
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 210040 | 840172 | 74751 | 108031 | 144383 | 288767 | 3993600 | 1 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 210805 | 843237 | 299007 | 348159 | 409599 | 493567 | 7462912 | 2 | 3 | 0 |  |
== round 2, class A off
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 215304 | 861224 | 73727 | 91135 | 115199 | 134143 | 3993600 | 1 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 215576 | 862333 | 292863 | 337919 | 389119 | 464895 | 7540736 | 0 | 0 | 0 |  |
== round 3, class A on
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 213078 | 852327 | 74239 | 101375 | 109567 | 141311 | 3993600 | 1 | 7 | 2 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 217873 | 871520 | 292863 | 329727 | 380927 | 458751 | 7462912 | 7 | 0 | 0 |  |
== round 3, class A off
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 211237 | 844958 | 74751 | 105471 | 161791 | 266239 | 3997696 | 3 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 212802 | 851243 | 294911 | 372735 | 499711 | 831487 | 7462912 | 2 | 3 | 1 |  |
```

## Run 7: AMD EPYC 7763 64-Core Processor, CI run 36020013371, commit dcc95fb

The `nop` rounds, then the echo half: `echo_runner --candidates rotor --payloads 4096` against
the server rotor ships and against `zig-out/no-class-a/rotor_echo`, alternating, three times each.

```text
model name	: AMD EPYC 7763 64-Core Processor
4
6.17.0-1022-azure
MemTotal:       16373452 kB
== round 1
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 742 | 551 |
| 8 | 1323 | 1393 | 165 |
| 32 | 3877 | 4098 | 121 |
| 64 | 7294 | 7754 | 113 |
| 128 | 14377 | 22773 | 112 |
uring nop, ReleaseFast, no assertions, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 531 | 601 | 531 |
| 8 | 1272 | 1453 | 159 |
| 32 | 3647 | 3838 | 113 |
| 64 | 6873 | 7634 | 107 |
| 128 | 13556 | 21751 | 105 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 552 | 611 | 552 |
| 8 | 1303 | 1363 | 162 |
| 32 | 3788 | 3917 | 118 |
| 64 | 7154 | 7975 | 111 |
| 128 | 14066 | 22482 | 109 |
== round 2
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 582 | 551 |
| 8 | 1332 | 1403 | 166 |
| 32 | 3907 | 4137 | 122 |
| 64 | 7284 | 9608 | 113 |
| 128 | 14296 | 22482 | 111 |
uring nop, ReleaseFast, no assertions, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 531 | 552 | 531 |
| 8 | 1262 | 1332 | 157 |
| 32 | 3646 | 4298 | 113 |
| 64 | 6903 | 8847 | 107 |
| 128 | 13555 | 21771 | 105 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 582 | 551 |
| 8 | 1302 | 1363 | 162 |
| 32 | 3788 | 3958 | 118 |
| 64 | 7163 | 7795 | 111 |
| 128 | 14106 | 22543 | 110 |
== round 3
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 732 | 551 |
| 8 | 1313 | 1383 | 164 |
| 32 | 3858 | 3987 | 120 |
| 64 | 7253 | 8015 | 113 |
| 128 | 14287 | 22522 | 111 |
uring nop, ReleaseFast, no assertions, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 531 | 581 | 531 |
| 8 | 1272 | 1333 | 159 |
| 32 | 3657 | 3817 | 114 |
| 64 | 6923 | 7705 | 108 |
| 128 | 13585 | 21861 | 106 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 541 | 571 | 541 |
| 8 | 1312 | 1353 | 164 |
| 32 | 3788 | 3908 | 118 |
| 64 | 7123 | 9948 | 111 |
| 128 | 14037 | 22192 | 109 |
== round 4
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 611 | 551 |
| 8 | 1323 | 1563 | 165 |
| 32 | 3877 | 5691 | 121 |
| 64 | 7264 | 9367 | 113 |
| 128 | 14287 | 22513 | 111 |
uring nop, ReleaseFast, no assertions, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 532 | 591 | 532 |
| 8 | 1272 | 1332 | 159 |
| 32 | 3657 | 3787 | 114 |
| 64 | 6883 | 7665 | 107 |
| 128 | 13565 | 21831 | 105 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 552 | 601 | 552 |
| 8 | 1302 | 1372 | 162 |
| 32 | 3797 | 4017 | 118 |
| 64 | 7144 | 8255 | 111 |
| 128 | 14046 | 22192 | 109 |
== round 5
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 602 | 551 |
| 8 | 1323 | 1403 | 165 |
| 32 | 3848 | 4078 | 120 |
| 64 | 7234 | 9478 | 113 |
| 128 | 14256 | 22613 | 111 |
uring nop, ReleaseFast, no assertions, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 532 | 571 | 532 |
| 8 | 1263 | 1634 | 157 |
| 32 | 3657 | 3787 | 114 |
| 64 | 6893 | 9308 | 107 |
| 128 | 13555 | 21691 | 105 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 551 | 651 | 551 |
| 8 | 1302 | 1373 | 162 |
| 32 | 3778 | 3998 | 118 |
| 64 | 7133 | 9428 | 111 |
| 128 | 14027 | 22463 | 109 |
-rwxr-xr-x 1 runner runner 4021976 Sep 24 15:30 zig-out/bin/rotor_echo
-rwxr-xr-x 1 runner runner 4013944 Sep 24 15:30 zig-out/no-class-a/rotor_echo
== round 1, class A on
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 129102 | 516414 | 120831 | 154623 | 194559 | 233471 | 3997696 | 2 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 130396 | 521600 | 489471 | 536575 | 696319 | 831487 | 7454720 | 1 | 0 | 0 |  |
== round 1, class A off
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 125846 | 503392 | 123391 | 155647 | 200703 | 244735 | 4018176 | 0 | 3 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 129826 | 519320 | 491519 | 536575 | 655359 | 770047 | 7454720 | 0 | 3 | 0 |  |
== round 2, class A on
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 128963 | 515865 | 121343 | 152575 | 196607 | 232447 | 3993600 | 0 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 130770 | 523116 | 489471 | 532479 | 675839 | 819199 | 7454720 | 0 | 0 | 0 |  |
== round 2, class A off
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 128648 | 514597 | 121343 | 152575 | 188415 | 234495 | 4018176 | 2 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 130030 | 520157 | 491519 | 548863 | 761855 | 880639 | 7454720 | 0 | 0 | 0 |  |
== round 3, class A on
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 129163 | 516665 | 121343 | 150527 | 191487 | 244735 | 3993600 | 1 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 130500 | 522031 | 489471 | 532479 | 663551 | 798719 | 7454720 | 0 | 3 | 0 |  |
== round 3, class A off
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 127400 | 509613 | 122879 | 156671 | 207871 | 239615 | 4014080 | 1 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 130652 | 522622 | 489471 | 536575 | 708607 | 806911 | 7454720 | 0 | 3 | 0 |  |
```

## Run 8: AMD EPYC 9V74 80-Core Processor, CI run 36020023420, commit dcc95fb

The `nop` rounds, then the echo half: `echo_runner --candidates rotor --payloads 4096` against
the server rotor ships and against `zig-out/no-class-a/rotor_echo`, alternating, three times each.

```text
model name	: AMD EPYC 9V74 80-Core Processor
4
6.17.0-1022-azure
MemTotal:       16373452 kB
== round 1
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 761 | 831 | 761 |
| 8 | 1603 | 1673 | 200 |
| 32 | 4336 | 4547 | 135 |
| 64 | 7992 | 10205 | 124 |
| 128 | 15794 | 23606 | 123 |
uring nop, ReleaseFast, no assertions, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 751 | 771 | 751 |
| 8 | 1552 | 1592 | 194 |
| 32 | 4157 | 4357 | 129 |
| 64 | 7682 | 9414 | 120 |
| 128 | 15072 | 22694 | 117 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 651 | 862 | 651 |
| 8 | 1463 | 1612 | 182 |
| 32 | 4116 | 5479 | 128 |
| 64 | 7882 | 10005 | 123 |
| 128 | 15614 | 23465 | 121 |
== round 2
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 761 | 801 | 761 |
| 8 | 1632 | 1683 | 204 |
| 32 | 4347 | 5108 | 135 |
| 64 | 8012 | 9955 | 125 |
| 128 | 15743 | 23545 | 122 |
uring nop, ReleaseFast, no assertions, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 751 | 781 | 751 |
| 8 | 1552 | 1583 | 194 |
| 32 | 4137 | 4617 | 129 |
| 64 | 7682 | 9404 | 120 |
| 128 | 15253 | 22905 | 119 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 761 | 782 | 761 |
| 8 | 1583 | 1622 | 197 |
| 32 | 4267 | 4387 | 133 |
| 64 | 7861 | 9775 | 122 |
| 128 | 15443 | 23135 | 120 |
== round 3
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 761 | 801 | 761 |
| 8 | 1612 | 1673 | 201 |
| 32 | 4347 | 4617 | 135 |
| 64 | 7992 | 9754 | 124 |
| 128 | 15694 | 23405 | 122 |
uring nop, ReleaseFast, no assertions, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 751 | 821 | 751 |
| 8 | 1552 | 1592 | 194 |
| 32 | 4127 | 4757 | 128 |
| 64 | 7651 | 9114 | 119 |
| 128 | 15093 | 22764 | 117 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 761 | 782 | 761 |
| 8 | 1582 | 1623 | 197 |
| 32 | 4326 | 4477 | 135 |
| 64 | 7902 | 9855 | 123 |
| 128 | 15513 | 23295 | 121 |
== round 4
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 761 | 791 | 761 |
| 8 | 1603 | 1683 | 200 |
| 32 | 4427 | 4968 | 138 |
| 64 | 8112 | 9775 | 126 |
| 128 | 15974 | 23695 | 124 |
uring nop, ReleaseFast, no assertions, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 751 | 781 | 751 |
| 8 | 1552 | 1703 | 194 |
| 32 | 4137 | 4446 | 129 |
| 64 | 7652 | 9164 | 119 |
| 128 | 15083 | 22824 | 117 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 761 | 782 | 761 |
| 8 | 1582 | 1622 | 197 |
| 32 | 4256 | 4537 | 133 |
| 64 | 8002 | 10005 | 125 |
| 128 | 15603 | 23375 | 121 |
== round 5
uring nop, ReleaseSafe, class A on, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 761 | 821 | 761 |
| 8 | 1612 | 1663 | 201 |
| 32 | 4347 | 5198 | 135 |
| 64 | 7992 | 9484 | 124 |
| 128 | 15683 | 23446 | 122 |
uring nop, ReleaseFast, no assertions, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 751 | 901 | 751 |
| 8 | 1542 | 1572 | 192 |
| 32 | 4136 | 4276 | 129 |
| 64 | 7651 | 9474 | 119 |
| 128 | 15133 | 24146 | 118 |
uring nop, ReleaseSafe, class A off, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 762 | 811 | 762 |
| 8 | 1582 | 1653 | 197 |
| 32 | 4256 | 4516 | 133 |
| 64 | 7882 | 10065 | 123 |
| 128 | 15473 | 23235 | 120 |
-rwxr-xr-x 1 runner runner 4026616 Sep 24 15:30 zig-out/bin/rotor_echo
-rwxr-xr-x 1 runner runner 4018584 Sep 24 15:29 zig-out/no-class-a/rotor_echo
== round 1, class A on
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 126697 | 506800 | 123391 | 157695 | 200703 | 228351 | 3993600 | 2 | 3 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 128910 | 515655 | 495615 | 532479 | 614399 | 724991 | 7462912 | 0 | 3 | 0 |  |
== round 1, class A off
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 126550 | 506208 | 124415 | 148479 | 180223 | 220159 | 4014080 | 1 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 128231 | 512949 | 497663 | 540671 | 733183 | 897023 | 7462912 | 0 | 3 | 0 |  |
== round 2, class A on
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 127413 | 509663 | 123903 | 142335 | 173055 | 203775 | 3993600 | 0 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 128647 | 514603 | 497663 | 536575 | 716799 | 786431 | 7462912 | 0 | 3 | 0 |  |
== round 2, class A off
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 127017 | 508078 | 123903 | 153599 | 205823 | 268287 | 4018176 | 0 | 3 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 127208 | 508854 | 503807 | 548863 | 729087 | 1003519 | 7462912 | 1 | 0 | 0 |  |
== round 3, class A on
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 127359 | 509446 | 123391 | 154623 | 272383 | 366591 | 3989504 | 0 | 3 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 129138 | 516594 | 495615 | 532479 | 614399 | 733183 | 7462912 | 1 | 3 | 0 |  |
== round 3, class A off
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 127706 | 510835 | 123391 | 157695 | 230399 | 342015 | 4014080 | 1 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 128726 | 514931 | 493567 | 532479 | 675839 | 892927 | 7462912 | 0 | 3 | 0 |  |
```
