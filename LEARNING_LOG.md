# LEARNING_LOG.md

Every AI mistake, stale API, or wrong assumption made during this project — what was
written, why it was wrong, how it was caught, and the fix. Newest entries at the bottom.

---

## 2026-07-29 — Phase 0: `mix phx.new retro --live` no longer exists

- **What was written:** PLAN.md (and the AI's initial instinct) called for
  `mix phx.new retro --live`.
- **Why it was wrong:** since Phoenix 1.6 LiveView is part of the default stack; in the
  installed `phx_new 1.8.9` there is no `--live` flag at all — only `--no-live` to opt
  *out*. Passing `--live` would have errored.
- **How it was caught:** Rule 1 ("verify before you write") — reading `mix help phx.new`
  output before running the generator, instead of trusting memory/the plan.
- **Fix:** ran `mix phx.new . --app retro --module Retro` (defaults already include
  LiveView, Postgres, Bandit).
