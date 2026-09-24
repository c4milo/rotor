# Decision 8's class A on `github`, 2026-09-24

`zig build bench-linux` built three `nop` benchmarks from commit `82ffed8`:

- `uring_nop_safe`: ReleaseSafe, the mode rotor ships in.
- `uring_nop_no_class_a`: ReleaseSafe with decision 8's class A assertions compiled out
  (`src/core/assertion_class.zig`), and every other assertion and safety check kept.
- `uring_nop_fast`: ReleaseFast, which removes every assertion and every safety check. It prints
  "class A on" because the switch is on, but ReleaseFast checks no assertion at all. Later builds
  print "no assertions" there.

The CI job `costs` ran the three in turn five times on a GitHub-hosted `ubuntu-24.04` runner. The
job was started by hand five times, and each start got its own runner, so there are five runs
below. The pool gave four AMD EPYC 7763 runners and one AMD EPYC 9V45. Decision 8's results
section reads them.

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
