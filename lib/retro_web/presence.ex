defmodule RetroWeb.Presence do
  # Distributed presence tracking: a CRDT living on top of PubSub. We use the
  # classic pattern — diffs arrive on the tracked topic itself as
  # %Phoenix.Socket.Broadcast{event: "presence_diff"} — instead of the
  # handle_metas/4 callback, which earns its extra moving parts only for
  # app-wide aggregated presence, not a single per-board roster.
  use Phoenix.Presence,
    otp_app: :retro,
    pubsub_server: Retro.PubSub
end
