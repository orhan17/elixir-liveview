defmodule Retro.BoardFixtures do
  @moduledoc """
  Test fixtures for boards and cards.

  `board_fixture/1` also registers an `on_exit` that terminates the board's
  BoardServer: servers are registered globally by slug and would otherwise
  outlive the test (and its DB sandbox) holding stale state.
  """

  alias Retro.Boards

  def unique_slug, do: "brd-#{System.unique_integer([:positive])}"

  def board_fixture(attrs \\ %{}) do
    slug = Map.get(attrs, :slug, unique_slug())

    {:ok, board} =
      attrs
      |> Enum.into(%{slug: slug, title: "Board #{slug}"})
      |> Boards.create_board()

    ExUnit.Callbacks.on_exit(fn ->
      case Registry.lookup(Retro.BoardRegistry, slug) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(Retro.BoardSupervisor, pid)
        [] -> :ok
      end
    end)

    board
  end

  def card_fixture(board, attrs \\ %{}) do
    {:ok, card} =
      Boards.create_card(
        board,
        Enum.into(attrs, %{
          "lane" => "went_well",
          "body" => "a card",
          "author_name" => "Fixture"
        })
      )

    card
  end
end
