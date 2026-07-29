# CLAUDE.md — Live Retro Board

Read PLAN.md fully. This file is the short version future sessions must obey.

## Rules of Engagement (summary)
1. Verify every framework API against the pinned versions below (`deps/` source, hexdocs) — never from memory.
2. One phase at a time; every phase ends with a STOP. Never scaffold ahead.
3. Plan + new-concepts brief before code; wait for the user's "go".
4. After each phase: 3 learning-check questions, wait for answers, correct wrong ones.
5. Small diffs — max ~150 lines per step.
6. Comment each unfamiliar Elixir idiom once (user comes from PHP/Go), then never again.
7. No new dependencies without asking.
8. User writes at least half the test assertions. Never skip/delete failing tests.
9. Log every AI mistake to LEARNING_LOG.md — it is a primary deliverable.
10. One conventional commit per phase; propose message, user approves (per-phase commits pre-authorized).

## Pinned versions (write all code against these)
- Elixir 1.20.2 / Erlang OTP 29 · Phoenix 1.8.9 · LiveView 1.2.8
- Ecto 3.14.1 / ecto_sql 3.14.0 / postgrex 0.22.3 · Bandit 1.12.4 · phoenix_pubsub 2.2.0
- Postgres 17 (Homebrew service, role postgres/postgres)

## Status
- Phases 0–6 done (schema, board UI, realtime cards, presence + typing, drag-and-drop, BoardServer/Registry/DynamicSupervisor as single writer + voting; write-through). Next: mini-step edit-own-card, then Phase 7 (write-behind; answer the UPDATE delta-vs-row question first).
