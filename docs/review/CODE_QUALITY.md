# Code Quality

Style and hygiene for Swift in this repo. CI enforces a warning-free build; this
doc covers the things the compiler won't flag.

## Zero warnings

The project treats compiler warnings as errors-in-waiting. `make build` must be
clean. If a warning genuinely can't be removed, silence it locally with a
comment explaining why — never leave it unaddressed and never blanket-suppress.

A PR that adds a warning is not done.

## Hard limits

Same limits the rest of the codebase holds to:

- ≤100 lines per function; cyclomatic complexity ≤8. A long function is usually
  hiding two functions.
- ≤5 positional parameters. Past that, take a struct.
- 100-char lines.
- **Absolute imports only** — no relative `..` paths.

These are review prompts, not a linter. A 120-line function that's genuinely one
flat sequence is better split for review even if it "reads fine".

## Swift idiom

- **`let...else` for early returns**; keep the happy path unindented. Pyramids of
  `if let` nesting are a refactor signal.
- **Enums for state**, not boolean-flag soups. A feature that's
  `isLoading`/`isError`/`hasData` should be one enum.
- **Value types by default.** Reach for `class` only when identity or reference
  semantics are actually needed.
- **Exhaustive `switch`** — no `default:` catch-all on an enum you own, so adding
  a case forces you to handle it. The `"\r\n" is one Character` class of bug is
  exactly what a wildcard hides.
- Newtypes over bare primitives where it prevents mix-ups (a serial, an app id,
  a pid).

## Naming

- Names say what, not how. Match the surrounding code's vocabulary — a new
  service should read like the existing services.
- No `raw_`/`parsed_` prefix pairs; shadow the variable through its
  transformation.
- Test names describe the behavior under test (`parsesCRLFLogcatOutput`), not
  the method (`testParse`).

## Comments and dead code

- Code should be self-documenting. If a comment explains *what* the code does,
  the code needs refactoring, not the comment.
- Comments that explain *why* (a non-obvious constraint, a workaround for a
  platform quirk) are valuable — keep those.
- **No commented-out code.** Delete it; git remembers.
- **Replace, don't deprecate.** When new code supersedes old, remove the old —
  no shims, no dual paths left "just in case". Dead code misleads readers.

## Error handling

- Fail fast with actionable messages: what operation, what input, what to do.
- Never swallow an error silently. `AdbClient` deliberately returns a structured
  `AdbResult` (it doesn't throw on non-zero exit) — surface the failure to the
  caller, don't `try?` it away.
- Don't `fatalError`/`assert` on input you don't control (device output, user
  input, file contents). Handle it.

## Review checklist

- [ ] Build is warning-free.
- [ ] No function over the limits without a reason that's visible in review.
- [ ] No commented-out code; no leftover dead/old implementation.
- [ ] Errors carry context and aren't silently dropped.
- [ ] Naming matches the neighborhood; no `..` imports.
