# Code Review

How to review a Droidective PR. The job is not to prove the code is perfect —
it's to catch the things CI can't: wrong behavior, the architecture eroding,
hidden blast radius, and UX that only shows up when you run the app.

CI already proves `swift test` passes and the build is warning-free. Don't spend
review time re-checking those; spend it on what a machine can't see.

## Order of review

Review in this order — a problem at an earlier level makes later levels moot.

1. **Architecture** — is the change in the right layer, the right service, the
   right shape? A correct feature in the wrong place still gets sent back.
   → [review/ARCHITECTURE.md](review/ARCHITECTURE.md)
2. **Correctness & pitfalls** — does it do what it claims, including the edges?
   Does it step on one of the known traps (threading, CRLF, shell quoting,
   `.task(id:)`)? → [review/CONCURRENCY_AND_PITFALLS.md](review/CONCURRENCY_AND_PITFALLS.md)
3. **Impact area** — what else does this touch? Shared services, persisted
   state, the registry, the release path.
   → [review/IMPACT_ANALYSIS.md](review/IMPACT_ANALYSIS.md)
4. **Tests** — do they test behavior and edges, not implementation? Would they
   actually fail if the code broke? → [review/TESTING.md](review/TESTING.md)
5. **Code quality** — style, complexity, naming, dead code.
   → [review/CODE_QUALITY.md](review/CODE_QUALITY.md)
6. **UI/UX** — for anything user-facing, run it. → [review/UI_UX.md](review/UI_UX.md)
7. **Security** — secrets, on-device input, file operations.
   → [review/SECURITY.md](review/SECURITY.md)
8. **Performance** — only where it's load-bearing (polling loops, large pulls,
   the per-process performance graphs). Don't ask for micro-optimization without
   a measurement.

## Before you start

```sh
git fetch origin          # review against the latest main, not a stale base
```

Pull the branch and, for anything user-facing or device-touching, **run it**
(`make run`). The architecture exists so most logic is testable without a
device, but rendering and real adb output are not in the test suite — a review
that never ran the app can't sign off on UI or live behavior.

## Writing review comments

For each issue:

- Anchor it: `file:line`, concrete.
- State the failure, not just the smell: *what input produces what wrong
  result*. "This crashes on CRLF logcat output" beats "consider newline
  handling".
- When the fix isn't obvious, give options with trade-offs and recommend one.
- Separate **blocking** (correctness, architecture, security, missing tests for
  new logic) from **non-blocking** (nits, preferences) — say which.

## When to approve

Approve when: it's in the right layer, it does what it says including the edges
you can think of, the new logic is tested, it's warning-free, and — if it's
user-facing — you ran it and it behaves. Nits alone don't block.

## Self-review

Author and reviewer can be the same person here (solo project). The discipline
still applies: re-read your own diff against these lenses before you open the PR,
and run the app. Reviewing your own change a few hours later catches more than
re-reading it the moment you wrote it.

There are repo skills for this: `/code-review` for a correctness+cleanup pass on
the working diff, `/review` for a GitHub PR, `/security-review` for the security
lens. Use them as a first pass, not a substitute for running the app.
