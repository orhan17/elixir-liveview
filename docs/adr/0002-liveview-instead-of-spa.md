# ADR-0002: Phoenix LiveView instead of an SPA

- **Status:** accepted
- **Date:** 2026-07-30 (decision fixed in PLAN.md from day 0)

## Context

The app is realtime-first: every interaction (card create/edit/vote/drag,
presence, typing) must reach every open tab within, ideally, a render frame.
The conventional shape is a JS SPA (React/Vue) talking to a Phoenix API over
channels — two codebases, two state models, and a client-side store that
mirrors the server.

## Decision

Server-rendered LiveView. One language, one process model end to end: a tab
is a BEAM process, the board is a BEAM process, and "sync" is those processes
messaging each other. The client holds no application state — it renders
diffs the server pushes over the websocket.

JavaScript exists only where the browser genuinely owns the interaction:
one hook (`CardSort`, drag-and-drop via vendored SortableJS) that reports
intent (`pushEvent`) and lets the server's broadcast be the truth.

## Alternatives rejected

- **SPA + Phoenix Channels API** — duplicates the state model on the client,
  adds an API contract, an auth story for the socket, and a build pipeline;
  none of it buys anything this product needs.
- **Server-rendered pages + polling** — simple, but "realtime" retro with
  1–2 s latency defeats the point, and polling per tab costs more than the
  persistent socket.

## Consequences

- No API layer, no client store, no client/server drift; the two-client tests
  assert real end-to-end behavior in milliseconds.
- Free wins from the platform: form recovery after reconnect (`phx-change`),
  presence, per-tab process isolation.
- Costs, accepted: every interaction round-trips the server (fine on a LAN or
  one region; drag feels local only because SortableJS moves the DOM
  optimistically); there is no offline story; deep JS-ecosystem needs go
  through hooks — acceptable at "one hook per app", painful at twenty.
- The team-shape argument matters as much as the technical one: this is a
  one-developer product in an unfamiliar stack, and one mental model beats
  two half-learned ones.
