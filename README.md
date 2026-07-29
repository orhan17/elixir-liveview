# Live Retro Board

Realtime retrospective boards on Phoenix LiveView. A board lives at `/b/:slug`;
there is no signup — on first visit you pick a display name, stored in the
session. Cards sync across every open tab instantly: creating, editing your own
cards, voting, drag-and-drop between lanes, plus a presence roster and typing
indicators.

Built as a **learning project with a contract**: [PLAN.md](PLAN.md) defines the
rules the code was written under, and [LEARNING_LOG.md](LEARNING_LOG.md)
records every mistake the AI made along the way. See
[Provenance](#provenance-who-wrote-what) below.

## Run it with Docker (recommended for reviewers)

Prerequisites: Docker with Compose.

```bash
git clone <this repo> && cd elixir-liveview
docker compose up --build
```

First build takes a few minutes. When the log says the server is running:

1. Open <http://localhost:4000/b/demo> — you'll be asked for a display name.
2. Open the same URL in a **second browser or an incognito window** (the name
   lives in a per-browser session cookie) and join under a different name.
3. Add cards, vote, edit your own cards, drag cards between lanes — both
   windows stay in sync; the header shows who's online and who's typing.

Create more boards from the running container:

```bash
docker compose exec app /app/bin/retro remote
iex> Retro.Boards.create_board(%{slug: "my-retro", title: "My Retro"})
```

…then open `http://localhost:4000/b/my-retro`.

## Run it natively

Prerequisites: Elixir 1.20.2 / Erlang OTP 29, PostgreSQL 17 with a
`postgres/postgres` superuser (versions are pinned — see PLAN.md).

```bash
mix setup            # deps, database, migrations, seeds (creates /b/demo)
mix phx.server       # or: iex -S mix phx.server
```

Then open <http://localhost:4000/b/demo>.

Run the test suite (48 tests):

```bash
mix test
```

## Architecture

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

Why it is shaped this way — including the alternatives that were rejected and
the data-loss trade-off — is written up in two ADRs:

- [ADR-0001 — a per-board GenServer is the source of truth, not Postgres](docs/adr/0001-board-server-as-source-of-truth.md)
- [ADR-0002 — LiveView instead of an SPA](docs/adr/0002-liveview-instead-of-spa.md)

Each live board is owned by one `Retro.BoardServer` GenServer — a **single
writer**: every mutation goes through its mailbox, one message at a time, which
is why there are no locks and no ordering races anywhere. LiveView processes
(one per tab) never touch the database; they call the board process and render
what it broadcasts over PubSub. Persistence is **write-behind**: mutations are
applied in memory and broadcast immediately, then flushed to Postgres in
batches (every 5 s, on graceful shutdown, and when an idle board stops itself
after 10 minutes). Postgres remains the durable copy and the recovery source:
a restarted board process rehydrates from it. Card ids still come from the
Postgres sequence, so identity has exactly one arbiter even though inserts are
deferred.

Two honest consequences, by design and not by accident:

- **Data-loss window.** `terminate/2` flushes on graceful shutdown, but nothing
  flushes on `kill -9`, a BEAM crash, or power loss — up to the last 5-second
  flush window of accepted (and already broadcast) writes can be lost.
- **Last write wins.** Two people dragging the same card at once do not
  conflict — the second write through the mailbox simply wins.

## Single-node boundary (what multi-node would take)

This app is deliberately single-node. The parts that would have to change for
a cluster — noted, not implemented:

- **`Registry` is node-local.** On two nodes, each node happily starts its own
  `BoardServer` for the same slug: two writers, and the ordering guarantees
  above are gone. A cluster needs a distributed registry (e.g. `:global`,
  Horde) or board affinity — routing every request for a board to the node
  that owns it.
- **PubSub across nodes** works out of the box over distributed Erlang (the
  default `pg` adapter), but only once nodes are actually connected — which
  this deployment never does.
- **Reproducible experiment:** start the server, then start a second BEAM with
  `iex -S mix` (no server) and create a card from there. The card lands in
  Postgres but no browser tab updates — the second BEAM has its own PubSub and
  its own Registry, and nothing bridges them. That is the single-node boundary
  made visible.

## Where the AI got it wrong

The full record is [LEARNING_LOG.md](LEARNING_LOG.md) — every stale API, wrong
assumption and self-inflicted failure, logged as it happened. Five entries that
show the failure modes best:

1. **A flag that no longer exists (Phase 0).** The plan — and the AI's first
   instinct — called for `mix phx.new retro --live`. Since Phoenix 1.6 LiveView
   is the default and `phx_new 1.8.9` has no `--live` flag; the command would
   have errored. Caught by reading `mix help phx.new` before running anything
   (the project's rule 1: verify, don't remember). Fixed in `e7a997f`.

2. **A reserved word as a field name (Phase 1).** The cards table shipped with
   a `column` field — a SQL reserved word that also made "board column" vs
   "table column" ambiguous in every later conversation. Caught reviewing the
   applied migration before any code depended on it; rolled back and renamed
   to `lane` inside `b616cb4`.

3. **The AI collided with its own two-phase-old code (Phase 5).** The
   drag-and-drop container got `id="lane-#{lane}"` — the exact DOM id the same
   AI gave a hidden form input in Phase 2. LiveView 1.2's duplicate-id
   detection failed all three acceptance tests at mount, before a browser ever
   saw it. Fixed within `9c7218b`. Same failure family as forgetting its own
   slug-length validation in Phase 3: earlier decisions scroll out of context.

4. **Right conclusion, false cause (Phase 5 review — a developer error this
   time).** Explaining why dragged DOM nodes survive patches, the developer
   credited a `:key` attribute the template doesn't contain; the real
   mechanism is morphdom keying on the `id` attribute (`getNodeKey`,
   `dom_patch.ts`). Behavior could never catch this — the explanation matched
   what the screen showed — only reading the framework source did. Logged in
   `37eb22c`, provenance recorded in both directions.

5. **Five test-suite mistakes in one `mix test` cycle (Phase 8).** Highlights:
   passing the *database* representation (`"went_well"`) where `insert_all`
   dumping expects the *runtime* atom, and asserting card order by searching
   the HTML for "first" — which matched Tailwind's `first:ml-0` class in the
   header, thousands of bytes before any card. All caught by the suite while
   it was being written; fixed within `2e9fa0a`.

## Provenance: who wrote what

This repository was built by a developer working with Claude Code under the
contract in [PLAN.md](PLAN.md). Phases 0–6 followed the full contract: per-phase
plans, the developer's "go", and mandatory learning checks after every phase.
From Phase 7 on, by the developer's explicit decision
([PLAN.md §1a](PLAN.md)), the AI implemented autonomously and **the Phase 8
test suite is entirely AI-authored** — the original plan had the developer
writing most tests, and that did not happen. [LEARNING_LOG.md](LEARNING_LOG.md)
records the AI's mistakes (stale APIs, wrong assumptions, self-inflicted test
failures) and is a primary deliverable, not an appendix. Provenance errors were
corrected in both directions — including once when the developer attributed his
own decisions to the AI, and once when he credited a real behavior to a
nonexistent cause (entry 4 above).
