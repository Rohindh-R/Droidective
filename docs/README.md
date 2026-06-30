# Droidective Engineering Docs

Process and standards for contributing to Droidective. `CONTRIBUTING.md` (repo
root) is the short on-ramp; these docs are the detail you reach for when opening
or reviewing a non-trivial change.

## Authoring a change

- **[PULL_REQUESTS.md](PULL_REQUESTS.md)** — how to scope, branch, commit, and
  open a PR. Pre-flight checklist, commit conventions, PR description standard.
- The GitHub PR template (`.github/PULL_REQUEST_TEMPLATE.md`) auto-fills the PR
  body with the checklist from that doc.

## Reviewing a change

- **[CODE_REVIEW.md](CODE_REVIEW.md)** — the review process and the order to
  apply it. Start here; it links the topic standards below.

### Topic standards (each is a review lens and an authoring guide)

| Doc | What it covers |
|-----|----------------|
| [review/ARCHITECTURE.md](review/ARCHITECTURE.md) | The two-layer rule, actor boundaries, where logic vs. UI lives |
| [review/CODE_QUALITY.md](review/CODE_QUALITY.md) | Swift style, complexity limits, naming, the zero-warning policy |
| [review/TESTING.md](review/TESTING.md) | What must be tested, how, and the mocked-process discipline |
| [review/CONCURRENCY_AND_PITFALLS.md](review/CONCURRENCY_AND_PITFALLS.md) | Process threading, CRLF, shell quoting, `.task(id:)` keys, the bug traps learned the hard way |
| [review/UI_UX.md](review/UI_UX.md) | SwiftUI layout, empty states, hotkeys, the feature/hub/notes contract |
| [review/IMPACT_ANALYSIS.md](review/IMPACT_ANALYSIS.md) | Reasoning about blast radius: persistence, registry, shared services, releases |
| [review/SECURITY.md](review/SECURITY.md) | Secrets, on-device shell input, file operations, the public-repo rule |

## A note on these docs

They describe the project as it is, not an aspirational process. If a standard
here no longer matches the code, the doc is the bug — fix it in the same PR that
changes the behavior.
