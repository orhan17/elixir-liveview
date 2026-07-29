# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Idempotent: creates the /b/demo board once so a fresh checkout has
# something to open. `mix ecto.setup` runs this automatically; the Docker
# image gets the same board via Retro.Release.setup/0.

alias Retro.Boards

unless Boards.get_board_by_slug("demo") do
  {:ok, _board} = Boards.create_board(%{slug: "demo", title: "Demo Retro"})
end
