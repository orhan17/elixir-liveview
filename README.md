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

## Architecture in one paragraph

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

## Provenance: who wrote what

This repository was built by a developer working with Claude Code under the
contract in [PLAN.md](PLAN.md). Phases 0–6 followed the full contract: per-phase
plans, the developer's "go", and mandatory learning checks after every phase.
From Phase 7 on, by the developer's explicit decision
([PLAN.md §1a](PLAN.md)), the AI implemented autonomously and **the Phase 8
test suite is entirely AI-authored** — the original plan had the developer
writing most tests, and that did not happen. [LEARNING_LOG.md](LEARNING_LOG.md)
records the AI's mistakes (stale APIs, wrong assumptions, self-inflicted test
failures) and is a primary deliverable, not an appendix. ADRs and the full
"Where the AI got it wrong" write-up land in Phase 10.
