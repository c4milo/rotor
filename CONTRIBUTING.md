# Contributing

This page is the short version of the rules for changing rotor. [`CLAUDE.md`](CLAUDE.md) holds all
of them, for people and coding agents alike: the style, the limits on function and file size, the
commit format, and how each test is shown to catch the bug it covers.

## What you need

- Zig 0.16.0.
- Docker, for the Linux gate and the race gate.
- The network, once: the first build fetches the lint tooling, pepegrillo.

Run `zig build hooks` once after you clone. It points git at `.githooks`, which checks each commit
message before a push.

## Commands

| command | what it does |
|---|---|
| `zig build test` | the lint, every module's tests, the conformance suite, the halt check, every example built and checked, and the format check |
| `zig build test-<module>` | one module's tests alone, such as `zig build test-kqueue` |
| `zig build test-linux && bash tools/linux_test.sh` | the Linux tests in Docker: io_uring with `seccomp=unconfined`, epoll under the default profile |
| `zig build test-race && bash tools/race_test.sh` | the suites that start threads, under ThreadSanitizer in Docker |
| `zig build proofs` | the Lean proofs; it needs the toolchain `proofs/lean-toolchain` names |
| `zig build bench-echo bench-crosscore bench-alternatives` | the benchmark programs and the pinned libuv and libxev; [`docs/benchmarks.md`](docs/benchmarks.md) says how to run them |
| `zig build lint-commits` | the commit messages this branch adds |

Every change passes `zig build test` before it is committed. A change to a Linux backend also
passes the Linux gate, and a change to code that another thread touches also passes the race gate.

Code in the README or the guide is an excerpt of a program under [`examples/`](examples), line for
line, and `zig build test` fails when it is not (`tools/readme_examples.zig`). To change what a page
shows, change the program, check that it still runs, and copy the lines.

## What a change needs

| change | it lands with |
|---|---|
| New operation, or a change in what one promises | A test in [`src/conformance/`](src/conformance), which runs on every backend |
| New check or test | A mutation: break the code on purpose, and report in the commit whether a test caught it (`CAUGHT` or `NOT CAUGHT`) |
| New assertion a caller's mistake can reach | A scenario in [`tools/halt/`](tools/halt), which runs in a child process and must stop at that assertion |
| New limit | A named constant in the module's `constants.zig`, with a doc comment |
| Speed claim | The harness number, the command that produced it and the machine. Runs where rotor loses are reported too. |
| Design change | A record in [`docs/decisions/`](docs/decisions). A record starts as proposed, and a proposed record does not allow building what it describes. |

## Rules that do not bend

- rotor allocates nothing. No file under `src/` names an allocator.
- Assertions stay on in production. There is no build mode that removes them.
- A loop belongs to one thread. It takes no lock and starts no thread.
- Every operation ends with exactly one final event.
- If a change would do something a decision record rejected, stop and say so. Do not reverse the
  record in code.

## Commits

- A commit message is a Conventional Commit: `type(scope): description`, with a subject of 72
  columns or less. The scopes follow the modules: `core`, `linux-shared`, `uring`, `kqueue`,
  `epoll`, `conformance`, `adapter`, `bench`, `tools`.
- The body says why, in 100 words or less and 3 paragraphs or less, with lines of 100 columns or
  less.
- A commit message carries no `Co-Authored-By` trailer.
- Prose is simple English, in the active voice, in code comments, documents and commit messages
  alike.

## Where things are

| path | what it holds |
|---|---|
| [`src/rotor/`](src/rotor) | the public module: `Loop`, `Registry`, `Remote`, and the choice of backend |
| [`src/core/`](src/core) | the types every backend shares, the slot table, the timer heap and the limits |
| [`src/uring/`](src/uring), [`src/kqueue/`](src/kqueue), [`src/epoll/`](src/epoll) | the three backends |
| [`src/conformance/`](src/conformance) | the suite every backend passes |
| [`examples/`](examples) | complete programs that use the public module, which `zig build test` runs and checks |
| [`bench/`](bench) | the harness, a server per library, the cost probes and every recorded run |
| [`docs/`](docs) | the guide, the benchmarks, the design records and the table of measured costs |
| [`proofs/`](proofs) | the Lean proofs of the timer heap and the timer lifecycle |
| [`tools/`](tools) | the lint configuration, the halt scenarios, the io_uring probe and the Docker gates |

## Security reports are not pull requests

Report a vulnerability through the private route in [`SECURITY.md`](SECURITY.md). Do not open a
public issue for it, and do not open a public pull request that fixes it and shows it at once.
