# Security policy

## How to report a vulnerability

Use GitHub's private vulnerability reporting: open the repository's
[Security tab](https://github.com/c4milo/rotor/security) and click "Report a vulnerability". The
report stays private, and the advisory, and a CVE if one is needed, come out of the same thread.

If you cannot use GitHub, email camilo.aguilar@gmail.com with the same details you would put in the
report.

Do not open a public issue for a vulnerability.

## What to expect

One maintainer runs this project. You get an answer within 7 days, and an assessment within 30:
confirmed, not a vulnerability, or more information needed. I promise to keep you informed. I do
not promise a date for the fix; that comes out of the assessment.

## Scope

In scope: the library as shipped, which is everything under `src/`. For example:

- memory a loop reads or writes outside what the program gave it;
- a buffer the loop hands back while the kernel can still write to it;
- an operation that ends with no final event, or with more than one;
- a message between loops, or between processes, that is lost or reaches the wrong loop;
- input from the network that stops a loop at an assertion. Assertions are for programming errors,
  so a peer that can reach one can stop a server.

Out of scope, so that triage stays fast:

- `bench/`, `tools/` and `examples/`, which are not part of the library.
- A program's own misuse that stops at a named assertion, such as calling a loop from a thread that
  does not own it. Stopping there is the intended behavior.
- A limit the program chose. A full loop refuses an operation with an error, by design.
- Bugs in the kernel, and attacks that need a compromised host.
- Physical side channels.

## Supported versions

The latest release only. One maintainer does not promise backports.

## Disclosure policy

Coordinated disclosure, 90 days by default. It can be shorter when the fix is easy, and longer when
a deployment needs the time. Reporters are credited in the advisory unless they decline.
