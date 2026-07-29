# ADR-0001: A per-board GenServer is the source of truth, not Postgres

- **Status:** accepted
- **Date:** 2026-07-30 (decision fixed in PLAN.md from day 0; consequences refined through Phases 6–7)

## Context

A retro board is a small, short-lived, high-write workload with many concurrent
writers per board: several people create, edit, vote and drag cards at once,
and every change must appear in every open tab immediately. Two problems
dominate:

1. **Ordering.** Card positions are computed from current state ("append after
   the last card", "drop between these two"). Computed in SQL, that is a
   check-then-act race: Phase 1 shipped with a deliberate, documented race in
   `next_position/2` where two concurrent inserts could read the same max and
   produce duplicate positions.
2. **Fan-out.** Every mutation must be broadcast. With plain CRUD each writer
   broadcasts after commit, and "who broadcasts what, when" is smeared across
   every call site.

## Decision

One `Retro.BoardServer` GenServer per live board — registered by slug in a
`Registry`, started on demand by a `DynamicSupervisor` — owns the board's full
state in memory and is its **single writer**. LiveView processes never touch
the Repo; they call the board process and render what it broadcasts.

While a board is live, **its process is the source of truth and Postgres is a
write-behind copy**: mutations apply to memory, broadcast immediately, and are
flushed in batches (5-second timer, graceful shutdown, idle stop after 10
minutes). On restart the process rehydrates from the last flush. Card ids
still come from the Postgres sequence (`nextval`) even though inserts are
deferred.

The mailbox is the concurrency control. There is no lock, no transaction, no
optimistic locking anywhere in the write path — not because we handle races
well, but because interleaving is impossible by construction: a GenServer
processes one message at a time.

### The single-arbiter symmetry

Every consistency problem in this system is solved the same way — by finding
its one natural arbiter and refusing to duplicate the decision anywhere else:

| Concern | Arbiter | Direction |
|---|---|---|
| Slug uniqueness | Postgres unique index (`unique_constraint` after INSERT, no pre-SELECT) | pushed **down** |
| Card ordering | the board process mailbox | pushed **up** |
| Card identity | the Postgres sequence (`nextval`, insert deferred) | stays **down** |

The Phase 1 ordering race was not fixed; it was **deleted** in Phase 6 together
with the SQL query that contained it.

## Alternatives rejected

**Plain CRUD on Postgres.** Every write becomes a transaction; ordering needs
either `SERIALIZABLE` + retry loops or explicit locking; position computation
stays a check-then-act race unless locked; every writer must remember to
broadcast. Correct-but-effortful in exactly the places the mailbox makes free.
It is how we would build this in PHP or Go — the contrast is the point of the
project.

**One global GenServer for all boards.** Same serialization benefits, but every
board queues behind every other board's writes, and one crash (or one slow
flush) is a full-system event. Per-board processes give per-board failure
domains and per-board mailbox latency for free.

**ETS-only state.** ETS gives fast shared reads but no serialization: ordered
writes need an owning process anyway, at which point ETS is an optimization of
the GenServer design, not an alternative to it. It also provides no lifecycle
— no place for the flush timer, idle shutdown, or terminate flush to live.

## The data-loss trade-off (explicit)

Write-behind means accepting a loss window. Precisely:

- `terminate/2` flushes on every **deliverable** exit: supervisor shutdown,
  idle stop, deploy. It never runs on `kill -9`, a BEAM crash, or power loss —
  `trap_exit` cannot convert an unconditional kill into a message.
- Therefore up to **one flush interval (5 s) of accepted and already broadcast
  writes** can vanish. A user can watch their card appear on every screen and
  still lose it.

This is acceptable *for this domain*: retro cards are low-value-per-write,
short-lived, and socially recoverable ("re-add your card") — the product is
the conversation, not the record. The same design would be wrong for orders or
payments, and the honest statement of that boundary is part of the decision.

Concurrent edits are **last-write-wins** through the mailbox — two people
dragging the same card do not conflict; the later message simply wins. No
merge, no CRDT: for cards this is what users expect anyway.

## Consequences

- No locks and no lock bugs; every ordering property is testable by
  construction (the suite proves 10 concurrent creates get 10 distinct
  positions).
- Reads and writes are memory-speed; Postgres sees batched upserts
  (whole rows via `insert_all` — Ecto can send deltas, but delta flushing
  would need a second as-persisted snapshot to diff against; not worth it).
- Restart recovery is trivial: rehydrate from the last flush. The failure
  story is one sentence.
- **Single-node boundary:** `Registry` is node-local, so a second node means a
  second writer per board and the ordering guarantees are gone. Multi-node
  needs a distributed registry or board affinity (see README). Slug uniqueness
  survives clustering because its arbiter (Postgres) is already global.
- Known cosmetic limits, accepted and documented: float positions exhaust
  after ~45–50 drops into the same gap (renumbering belongs to the single
  writer when it becomes real); a server-rejected drag leaves the dragging
  tab's DOM locally reordered until a diff touches that lane (fix direction:
  a monotonic board revision in assigns, natural once BoardServer existed).

## Related observation: coupled death as a consistency mechanism

The same "let it die and be rebuilt" philosophy appears one layer down, in
Phoenix's own Presence: the tracker **links** (not monitors) every tracked
LiveView. If the tracker shard crashes, the exit signal kills every tracked
process; clients auto-rejoin, remount, and re-track into the fresh shard. The
roster converges by mass rebirth, not by repair. Our recovery path is built on
the same bet: state that can be rebuilt cheaply does not need to be protected,
it needs to be easy to rebuild.
