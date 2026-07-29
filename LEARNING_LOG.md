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

## 2026-07-29 — Phase 1: card field `column` renamed to `lane` after review

- **What was written:** the first `create_cards` migration used the field name `column`,
  copied verbatim from PLAN.md.
- **Why it was wrong:** `COLUMN` is a reserved word in SQL (survivable — Ecto quotes all
  identifiers, but raw psql needs `"column"`), and worse, the term was overloaded:
  "board column" vs "table column" would collide in every conversation and ADR.
- **How it was caught:** flagged in review of the applied migration, before any schema
  code depended on the name — the cheapest possible moment to rename.
- **Fix:** `mix ecto.rollback`, renamed to `lane` (values `:went_well | :to_improve |
  :action_items`), PLAN.md wording updated to match the code.

## 2026-07-29 — Phase 1: decision-provenance slip (developer-side, logged deliberately)

- **What happened:** not a code error — an attribution one, and by the developer, not the
  AI. The developer attributed his own decisions to the assistant (float positions,
  `votes` kept out of `cast/3`, the `get_board_by_slug` / `!` pair — all proposed by the
  developer in the step 4–6 refinements, later described as "your decisions, not mine").
- **How it was caught:** the assistant checked the claim against the conversation record
  and corrected it.
- **Why it is in this log:** the README will include a decision-provenance section;
  provenance is a project artifact like code, and it must stay accurate in both
  directions — including when the error favors the AI.

## 2026-07-29 — Phase 3: AI's test fixture violated the project's own validation

- **What was written:** throwaway acceptance test used `slug: "rt"` — 2 characters.
- **Why it was wrong:** the Board changeset (written by the same AI two phases earlier)
  requires slug length 3–40; all four tests failed in setup with `valid?: false`.
- **How it was caught:** the validation did its job — `{:ok, board} = create_board(...)`
  crashed on the error tuple before any LiveView code ran.
- **Fix:** `slug: "rt-smoke"`. Small, but a fair example of the failure mode "the AI
  forgets constraints it wrote itself once they scroll out of its context".

## 2026-07-29 — Phase 2→4: a deferred unknown, closed two phases later (not an error)

- **What was said:** in the Phase 2 learning check the developer answered "I don't know"
  to whether a textarea draft survives a server restart, recalling only the name
  `phx-auto-recover`. Verification (LiveView's `view.ts`, `getFormsForRecovery`) showed
  recovery applies only to forms **with** `phx-change` — which Phase 2's forms lacked, so
  drafts were lost.
- **How it closed:** Phase 4's typing indicator added `phx-change` to the card forms and
  mirrors the draft into the form assign — form recovery switched on as a designed side
  effect. Kill the server mid-draft, restart, reconnect: the draft comes back.
- **Why it is in this log:** logged at the developer's request as the counterpart to the
  error entries — a tracked unknown that was carried openly for two phases and then
  closed by code, instead of being papered over with a guess at the moment it was asked.

## 2026-07-29 — Phase 5: new DOM id collided with an id the AI wrote two phases earlier

- **What was written:** the drag-and-drop hook container got `id={"lane-#{lane}"}` — the
  exact id the Phase 2 form already uses for its hidden lane input.
- **Why it was wrong:** duplicate DOM ids break LiveView's patching contract; morphdom
  targets nodes by id, so two `#lane-went_well` elements make patches land on the wrong
  node nondeterministically.
- **How it was caught:** LiveView 1.2's built-in duplicate-id detection failed all three
  throwaway acceptance tests at mount, before the code ever reached a browser.
- **Fix:** container renamed to `cards-#{lane}`. Same failure family as the Phase 3 slug
  entry: the AI forgetting its own earlier decisions once they scroll out of context —
  this time caught by tooling instead of by a failing changeset.

## 2026-07-29 — Phase 5: right conclusion, false cause (developer-side, logged deliberately)

- **What was said:** in the Phase 5 learning check the developer attributed DOM-node
  survival during drag patches to a `:key` attribute on the `:for` — an attribute the
  template does not contain.
- **Why it was wrong:** the real mechanism is the `id="card-#{card.id}"` written back in
  Phase 2: morphdom keys nodes on `node.id` (`getNodeKey`, dom_patch.ts:216). The
  explanation matched the observed behavior perfectly while naming a nonexistent cause —
  had someone later removed the "redundant" id and kept `:key` faith, nodes would start
  being destroyed and recreated while the explanation kept sounding convincing.
- **How it was caught:** rule 1 — verification against deps sources, not against
  behavior. This error class is invisible to behavioral testing by construction: the
  observable outcome is identical right up until someone acts on the false cause.
- **Why it is in this log:** at the developer's request, with his framing: "верный
  вывод, ложная причина — худший вид правильного ответа; ловится только чтением кода."
