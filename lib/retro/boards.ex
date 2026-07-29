defmodule Retro.Boards do
  @moduledoc """
  Public API of the boards domain. The web layer calls this module only —
  schemas, Repo and the BoardServer stay behind it.

  Since Phase 6 every card operation routes through `Retro.BoardServer`: the
  per-board process is the single writer and the source of truth while the
  board is live. Postgres is the durable copy and the recovery source.
  """

  alias Retro.BoardServer
  alias Retro.Boards.{Board, Card}
  alias Retro.Repo

  # Subscriptions and the topic string stay here: they are the contract
  # between the single writer (BoardServer broadcasts) and the many readers.
  def subscribe(%Board{} = board) do
    Phoenix.PubSub.subscribe(Retro.PubSub, topic(board))
  end

  # Public: the web layer needs the same topic string for Presence tracking
  # and transient (non-domain) broadcasts like typing indicators.
  def topic(%Board{slug: slug}), do: topic(slug)
  def topic(slug) when is_binary(slug), do: "board:" <> slug

  def create_board(attrs) do
    %Board{}
    |> Board.changeset(attrs)
    |> Repo.insert()
  end

  def get_board_by_slug(slug), do: Repo.get_by(Board, slug: slug)

  # The ! variant raises Ecto.NoResultsError, which Phoenix maps to a 404
  # response — the LiveView route leans on exactly this.
  def get_board_by_slug!(slug), do: Repo.get_by!(Board, slug: slug)

  # Reads go through the board process too: while a board is live its memory
  # is the truth, and the DB may lag behind it (fully so after Phase 7).
  def list_cards(%Board{} = board), do: BoardServer.list_cards(board.slug)

  def create_card(%Board{} = board, attrs), do: BoardServer.create_card(board.slug, attrs)

  # Card operations are board-scoped by signature: the caller can only reach
  # cards of the board it holds — the server rejects foreign ids with
  # {:error, :not_found} because they are simply absent from its state.
  def update_card(%Board{} = board, card_id, attrs, editor_name) do
    BoardServer.update_card(board.slug, card_id, attrs, editor_name)
  end

  def delete_card(%Board{} = board, card_id) do
    BoardServer.delete_card(board.slug, card_id)
  end

  def reposition_card(%Board{} = board, card_id, lane, new_index) do
    BoardServer.reposition_card(board.slug, card_id, lane, new_index)
  end

  def vote_card(%Board{} = board, card_id), do: BoardServer.vote_card(board.slug, card_id)

  # `attrs \\ %{}` declares a default argument; used by the card forms.
  def change_card(%Card{} = card, attrs \\ %{}), do: Card.changeset(card, attrs)
end
