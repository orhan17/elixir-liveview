# PLAN.md — Live Retro Board (Elixir / Phoenix LiveView)

> This file is the contract between me (the developer) and Claude Code.
> Read it fully before writing any code. Re-read the **Rules of Engagement**
> at the start of every session.

---

## 0. Context you must understand before doing anything

I am a senior backend developer with 7+ years in **PHP (Laravel, Symfony, Zend)** and **Go**.
I have **never written Elixir**. I do not know the BEAM, OTP, Ecto, or LiveView.

This project has two goals, and the second one matters more than the first:

1. Ship a working realtime app.
2. **Prove that I understand the code I ship.** This repository will be reviewed by a
   prospective employer specifically to judge whether I can use AI tools to work in an
   unfamiliar stack *competently* — not whether I can generate code I can't explain.

Therefore: **optimizing for speed is a failure mode here.** A repo that appears in one
giant commit, with no tests I wrote, and idioms I can't defend in an interview, is worse
than no repo at all. Slow down. Teach. Stop often.

---

## 1. Rules of Engagement (non-negotiable)

1. **Verify before you write.** Phoenix and LiveView changed significantly across recent
   major versions. Before writing code that touches a framework API, check the docs for the
   **exact versions pinned in `mix.exs`** (`mix hex.docs`, hexdocs, or `deps/` source). Do
   not write framework code from memory. If you cannot verify an API, say so explicitly
   instead of guessing.
2. **One phase at a time.** Each phase below ends with a `STOP`. When you reach it, stop
   and wait for me. Do not start the next phase, do not "helpfully" scaffold ahead.
3. **Plan before code.** At the start of each phase, output (a) a 5–10 line plan, and
   (b) the *new concepts* this phase introduces that I need to understand, in plain
   language, max 10 lines. Then wait for my "go".
4. **Learning check after each phase.** After the code is working, ask me **3 questions**
   about what we just built (why this abstraction, what happens on failure, what would
   break under load). Wait for my answers. If an answer is wrong, correct it before moving
   on. This is not optional — it is the point of the project.
5. **Small diffs.** Never generate more than ~150 lines in one step. If a task is bigger,
   split it and stop between parts.
6. **Comment the idioms, once.** The first time the code uses a pattern I won't know from
   PHP/Go — pattern matching in function heads, the pipe operator, `with`, multiple
   function clauses, `@impl`, sigils, immutable rebinding, `{:noreply, socket}` returns —
   add a one-line comment explaining it. Do not comment it again afterwards.
7. **No new dependency without asking.** Default to what `mix phx.new` gives us.
8. **Tests are not optional and not yours alone.** In test phases, you write the harness
   and *I* write at least half the assertions. Never use `--no-verify`, never skip or
   delete a failing test to make a phase "done".
9. **Log every mistake to `LEARNING_LOG.md`.** Every time you produce something wrong —
   stale API, wrong OTP assumption, compile error, wrong behaviour — append an entry:
   what you wrote, why it was wrong, how it was caught, what the fix was. This file is a
   primary deliverable of the project, not an afterthought.
10. **One commit per phase**, conventional-commit style (`feat:`, `test:`, `docs:`,
    `refactor:`). Propose the message; I approve. Commit history must read as a learning
    process over several days, not a code dump.

---

## 1a. Amendment — 2026-07-30, after Phase 6 (developer's decision)

The process above was followed in full for Phases 0–6. For the remaining implementation
work (mini-step 6.5, Phases 7–8) the developer explicitly chose speed over the learning
ritual, so:

- **Rules 2, 3, 4 are suspended.** No per-phase "go" gates, no plan approval waits, and
  no learning checks from here on. The Phase 6 learning check was posed and left
  unanswered — the checks stop exactly there. The AI implements autonomously; the
  developer reviews diffs and re-runs acceptance manually after the fact.
- **Rule 8 is amended: the Phase 8 test suite is authored entirely by the AI.** The
  original intent — the developer writes the setup, the first test in each file, and
  most assertions — was **not** carried out. This attribution is part of the project's
  provenance and must be restated in the README's provenance section.
- **Rule 5 is relaxed** to "working increments, one commit per phase".
- **Rules 1, 6, 7, 9, 10 remain in force** (verify against pinned versions; comment
  idioms once; no new deps without asking; LEARNING_LOG; conventional commits).

This amendment exists so the repository never claims a process that did not happen.

---

## 2. The product

**Live Retro Board** — realtime retrospective boards.

- A board lives at `/b/:slug`. No signup: on first visit the user picks a display name,
  stored in the session.
- Board has fixed lanes (`Went well`, `To improve`, `Action items`) — "lane", not
  "column", to avoid the SQL reserved word and the board-column/table-column ambiguity.
- Anyone on the board can add a card, edit their own card, vote on any card, and drag
  cards between lanes.
- Every change appears for all connected users instantly.
- Connected users are visible (avatar strip); "N is typing…" appears while someone drafts
  a card.
- Zero custom JavaScript beyond one LiveView JS hook for drag-and-drop.

**Explicitly out of scope:** authentication, authorization, board deletion, exports,
mobile layout polish, i18n. If I ask for one of these, remind me it's out of scope.

---

## 3. Architecture (this is the decision, not a suggestion)

The interesting part of this project — and the reason a reviewer will take it seriously —
is that **Postgres is not the source of truth while a board is live**.

```
Browser tab ──ws──> LiveView process (one per tab)
                          │
                          │ calls / subscribes
                          ▼
                  BoardServer (GenServer, one per board)
                    ├─ registered in Registry by slug
                    ├─ started on demand by DynamicSupervisor
                    ├─ holds authoritative board state in memory
                    ├─ broadcasts changes via Phoenix.PubSub
                    └─ write-behind flush to Postgres (interval + terminate)
                          │
                          ▼
                       Ecto / Postgres  (persistence, hydration on boot)
```

Rationale to be captured in the ADR:

- A retro board is a small, short-lived, high-write, single-writer-per-entity workload.
  Serializing all writes through one process per board removes the need for transactions,
  optimistic locking, or mutexes entirely — ordering is guaranteed by the process mailbox.
- The failure story is explicit and cheap: if a `BoardServer` crashes, the supervisor
  restarts it and it rehydrates from the last flush. We lose at most one flush interval of
  cards. That is an accepted trade-off, and I must be able to defend it.
- This is idiomatic BEAM design and deliberately *not* how I would build it in Go or PHP.
  The contrast is the point.

---

## 4. Phases

Each phase: plan → my "go" → code → acceptance criteria pass → learning check → commit → `STOP`.

### Phase 0 — Bootstrap and orientation

- Confirm toolchain: Erlang/OTP + Elixir versions, `mix phx.new` availability.
- Generate the app: `mix phx.new retro --live`, Postgres configured, `mix phx.server` runs.
- Pin and report the exact Phoenix / LiveView / Ecto versions from `mix.exs`. **Every later
  phase must be written against these versions.**
- Write `CLAUDE.md` at the repo root: a 20-line summary of the Rules of Engagement above,
  plus the pinned versions, so future sessions inherit them.
- Walk me through the generated directory layout in ~15 lines: what `lib/retro/` vs
  `lib/retro_web/` means, what `application.ex` and the supervision tree are, where the
  router lives.

**Acceptance:** app boots, I can explain what a supervision tree is in one sentence.
`STOP`

### Phase 1 — Domain and persistence, no realtime

- Ecto schemas: `Board` (slug, title), `Card` (board_id, lane, body, author_name,
  position, votes). Migrations only, no business logic in schemas.
- Context module `Retro.Boards` with `create_board/1`, `get_board_by_slug/1`,
  `list_cards/1`, `create_card/2`, `update_card/2`, `delete_card/1`.
- Changesets with real validation (body length, lane must be one of
  `:went_well | :to_improve | :action_items`).
- Explain: what a *context* is in Phoenix and why the schema is not the model. I come from
  Eloquent/Doctrine — name the difference directly.

**Acceptance:** I can create a board and cards from `iex -S mix` and read them back.
`STOP`

### Phase 2 — First LiveView, single user

- Route `/b/:slug` → `RetroWeb.BoardLive`.
- `mount/3` loads the board, `render/1` shows three lanes with cards.
- Lane order: the template MUST iterate `Card.lanes/0` (UI order: went_well, to_improve,
  action_items) and filter cards per lane — never render query order. `list_cards/1`
  returns lanes alphabetically (SQL mirror of `Card.sort_key/1`), which is grouping
  order, not display order; rendering it directly would silently reverse the columns.
- Name prompt on first visit, stored in session, no auth.
- Add a card via `phx-submit`. Nothing realtime yet — a second tab stays stale on purpose,
  and I want to *see* that before we fix it.
- Explain the LiveView lifecycle explicitly: the double `mount` (static render, then
  websocket connect), `assigns`, why `socket` is returned rather than mutated, and why
  the process is per-tab rather than per-user.

**Acceptance:** cards persist across reload; I can trace exactly which callback runs when.
`STOP`

### Phase 3 — Realtime sync

- Subscribe to `Phoenix.PubSub` topic `board:<slug>` in `mount/3` (connected case only —
  explain why the disconnected mount must not subscribe).
- Broadcast card create/update/delete; handle inbound broadcasts in `handle_info/2`.
- Make the distinction explicit in comments: `handle_event/3` = message from *my* browser,
  `handle_info/2` = message from *another process*.
- Avoid the self-echo double-render bug; if it happens, that is a `LEARNING_LOG.md` entry.

**Acceptance:** two browser tabs stay in sync in both directions.
`STOP`

### Phase 4 — Presence and typing indicators

- `Phoenix.Presence` tracking display names on the board topic; avatar strip in the header.
- Typing indicator: broadcast a throttled `:typing` event while the compose box has focus,
  expire it client-side after a short timeout.
- Explain how Presence handles CRDT-style merges and what happens on a disconnect —
  including what a tab closing looks like to the server (process exit, not an HTTP call).

**Acceptance:** opening/closing a tab updates the roster within a second for everyone else.
`STOP`

### Phase 5 — Drag and drop

- One LiveView JS hook (Sortable-style, hand-rolled or a small vendored lib — ask before
  adding a dependency) for reordering within and between lanes.
- Persist `lane` + `position` on drop; broadcast to everyone.
- Handle the conflict case: two users drag the same card at once. Define and document the
  resolution (last write wins is acceptable — say so out loud in the ADR).

**Acceptance:** drag in tab A moves the card in tab B; positions survive reload.
`STOP`

### Phase 6 — The OTP layer (the centrepiece)

This is the phase I care about most. Go slower here, not faster.

- `Retro.BoardServer` — a `GenServer` holding one board's full state in memory.
- `Retro.BoardRegistry` (`Registry`) for slug → pid lookup.
- `Retro.BoardSupervisor` (`DynamicSupervisor`) starting servers on demand.
- `Retro.BoardServer.via/1` + a `start_or_lookup/1` helper. Explain the race between two
  simultaneous lookups and how `Registry` resolves it.
- LiveViews now read and write through the `BoardServer`, never the repo directly.
- Explain, with the code in front of us: `handle_call` vs `handle_cast` vs `handle_info`,
  why we chose which for each operation, and why there is no lock anywhere in this design.
- Explain the chosen supervision strategy (`:one_for_one`) and why not `:one_for_all`.

**Acceptance:** in `iex`, I can `Process.exit(pid, :kill)` a board server, and the board
keeps working in the browser after an automatic restart.
`STOP`

### Phase 7 — Write-behind persistence

- Dirty-state tracking in `BoardServer`; flush to Postgres on a timer
  (`Process.send_after/3`, not a library scheduler — I want to see the primitive) and in
  `terminate/2`.
- Hydration from Postgres on `init/1`.
- **Be honest about `terminate/2`:** state the exact conditions under which it is *not*
  called, and therefore what data loss is possible. Do not pretend it is a guarantee.
- Idle boards shut down after N minutes of inactivity, flushing on the way out.

**Acceptance:** kill the server mid-session, restart, and at most the last unflushed
window of cards is missing — and I can say precisely what that window is.
`STOP`

### Phase 8 — Tests

- `ExUnit` for the context module: changeset validation, card CRUD.
- `BoardServer` tests: state transitions, hydration, flush-on-terminate, restart behaviour.
- `Phoenix.LiveViewTest`: mount, add a card via `render_submit`, and a **two-client test**
  asserting that a broadcast from client A is rendered by client B.
- You write the setup and the first test in each file. **I write the rest.** Give me a list
  of the assertions I should write and let me attempt them before you fill gaps.
- `mix test` green, no skipped tests.

**Acceptance:** the suite fails if I intentionally break the PubSub broadcast.
`STOP`

### Phase 9 — Deploy

> **Amended 2026-07-30 (developer's decision):** no cloud deploy. Reviewers will clone
> from GitHub and run the app themselves, so the deliverables become: the generated
> Docker release, a `docker-compose.yml` that boots app + Postgres + demo board in one
> command, and a README that documents both the Docker and the native path.
> Acceptance replaced accordingly: `docker compose up --build` on a fresh clone serves
> a working board at `http://localhost:4000/b/demo`. The multi-node README notes and
> the interview dry-run below remain in force.

- `mix phx.gen.release --docker`, deploy to Fly.io, single region, attached Postgres.
- Confirm websockets work through the proxy and that two devices on different networks
  stay in sync.
- Note in the README what would change with more than one node (PubSub adapter, Registry
  scope, board affinity) — **without implementing it**. Knowing the limit is the point.
- Interview dry-run, the day before: answer the section-7 self-check list aloud, from
  memory, repo closed. Whatever does not come out goes back into work. "I understood the
  explanation" and "I can explain" are different things — this is where the gap shows.

**Acceptance:** a public URL I can open on a phone during a call.
`STOP`

### Phase 10 — The documentation deliverables

These are graded as heavily as the code. Do not rush them.

- **`README.md`** — what it is, quick start under 5 minutes, architecture diagram
  (the ASCII one above is fine), and a prominent section:
  **"Where the AI got it wrong"** — 3–5 real entries pulled from `LEARNING_LOG.md`, each
  with the wrong output, how it was caught, and the fixing commit hash.
- **`docs/adr/0001-board-server-as-source-of-truth.md`** — context, decision, alternatives
  rejected (plain CRUD on Postgres; a single global GenServer; ETS-only), consequences,
  and the explicit data-loss trade-off.
- **`docs/adr/0002-liveview-instead-of-spa.md`** — short.
- Rewrite the git history *only* if it is misleading; otherwise leave it honest.

**Acceptance:** a reviewer who reads only the README understands the design and believes
a human made the decisions.
`STOP`

---

## 5. Known hallucination hotspots — check these against the pinned docs

Do not write any of the following from memory. Verify each the first time it comes up, and
log it if the first attempt was stale:

- Route helpers vs verified routes (`~p` sigil) — which one this Phoenix version uses.
- `live_redirect` / `live_patch` vs `push_navigate` / `push_patch`.
- `Phoenix.Component` function components vs the older `live_component` style, and the
  current `~H` / `:let` / slot syntax.
- `assign_async` / `start_async` availability and signature.
- The generated `core_components.ex` API — it differs between generator versions; read the
  file in *this* repo rather than assuming.
- `Phoenix.Presence` setup (module definition, `track/4` arity, `handle_metas`).
- `DynamicSupervisor.start_child/2` child-spec shape and `Registry` `:via` tuple syntax.
- Ecto changeset function names and `Ecto.Multi` usage.
- Tailwind/esbuild config, which Phoenix manages itself — don't introduce a Node toolchain.

---

## 6. Session protocol

Start every session with:

> Read PLAN.md and CLAUDE.md. Tell me which phase we are on, what is left in it, and your
> plan for this session. Then STOP.

End every session with:

> Update LEARNING_LOG.md with anything from this session. Summarize in 5 lines what I
> should be able to explain now that I couldn't this morning. Then STOP.

---

## 7. Definition of done for the whole project

- [ ] Public URL, works on two devices simultaneously.
- [ ] `mix test` green, with tests I wrote myself.
- [ ] `LEARNING_LOG.md` with real entries, not retrofitted ones.
- [ ] Two ADRs.
- [ ] Commit history spread over several sessions, one phase per commit.
- [ ] A 2-minute screencast: two tabs syncing, then killing a `BoardServer` in `iex` and
  watching it recover.
- [ ] I can answer all of these without notes:
    - What happens to my LiveView process if a user closes their laptop for ten minutes?
    - Why `:one_for_one` and not `:one_for_all`?
    - What is lost when a `BoardServer` crashes, and why is that acceptable here?
    - `handle_call` vs `handle_cast` — where did I use each, and why?
    - Why is there no mutex or transaction around the in-memory board state?
    - What breaks the moment I add a second node?