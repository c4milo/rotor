# 16. A C ABI for C consumers

Status: declined as asked, by the owner on 2026-09-24. It records a request from chapulin, the
investigation that followed, and the ruling: rotor adds no C ABI and no static library target for
this request. Nothing in rotor changes.

## Context

chapulin is a TLS 1.3 library in C11. Its server role has unit vectors and no end-to-end test
of its own: nothing in its suite starts a chapulin server and points a real client at it. Its
client legs are tested against `openssl s_client` and a Go peer, as separate processes.

The request was whether chapulin's tests could link rotor as a static library, so the server
role is exercised under a real event loop rather than a blocking socket. The appeal is real:
a blocking test delivers whole records nearly every time, so partial reads, write backpressure
and many concurrent connections go untested, and those are what break first in production.

Two facts settle the shape of the answer.

**rotor exposes no C ABI today.** No file under `src/` contains `export fn` or `callconv(.C)`,
and `build.zig` declares no static library target. Serving this request means adding both: a C
surface and a library artifact, each with its own maintenance and its own error mapping from
Zig to C.

**The dependency points the wrong way.** chapulin already publishes a C ABI — its packaged
object exports between nine and sixteen symbols depending on the build axes, and colibri
already links it. A test that drives chapulin's server under rotor's loop can therefore be
written on the Zig side, linking chapulin, with no new surface anywhere. Written the other way
round it needs a new C surface in rotor that exists only for tests.

## Decision

Declined as asked, by the owner on 2026-09-24. rotor adds no C ABI and no static library target
for this.

The need splits into two, and neither half wants a C ABI in rotor.

| need | where it belongs | cost |
|---|---|---|
| chapulin proves its own server works | chapulin's own suite, a server binary with `openssl s_client` as the peer, mirroring its existing client legs in reverse | no new dependency for anyone |
| the server is exercised under a real event loop | the Zig side, a harness that links chapulin's packaged object the way colibri already does | no new surface; reuses an ABI that exists |

### Alternatives

**Add the C surface anyway.** A completion-based loop maps to C cleanly enough — submit an
operation with a callback and a context pointer, run the loop until stopped. The cost is not
the shape, it is that the surface would exist for one caller's tests, would have to keep
TigerStyle's caller-supplied-memory contract across the boundary, and would have to answer what
a Zig error becomes in C. Reconsider if a C consumer appears that is not a test.

**Do nothing and accept the gap.** Rejected: partial reads and backpressure are exactly the
class of defect a blocking test cannot produce, and leaving them untested until production is
the opposite of what both trees are for.

## Open questions

1. rotor's README says "No kernel backend exists yet", while `src/kqueue/` and `src/uring/`
   both exist and reference `accept` and `connect`. One of the two is stale. This record
   assumes the README is behind the code and does not rely on either being finished; the
   recommendation holds regardless, because it asks nothing new of rotor. **Settled by
   2026-09-24:** the README was behind. It now describes the three backends, and rotor has
   released through v0.4.0.
2. If a Zig-side harness is written, it belongs to whichever tree owns the loop it drives.
   colibri already links both chapulin roles and runs them against Go, so the cheapest version
   of this may be a leg in colibri rather than a new harness anywhere. **Partly done by
   2026-09-24:** colibri's decision 58 made rotor the loop of its test-only UDP endpoints, and its
   hq-interop server runs chapulin's QUIC mode over one rotor socket (`src/testing/quic_udp.zig`
   in colibri). So chapulin's server role now runs under rotor's loop over QUIC. Its TCP role
   does not yet, and that harness would also live in colibri's tree or chapulin's, not in rotor.
