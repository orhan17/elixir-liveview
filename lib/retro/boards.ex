defmodule Retro.Boards do
  @moduledoc """
  Public API of the boards domain. The web layer calls this module only —
  schemas and Repo stay behind it.
  """

  import Ecto.Query, only: [from: 2]
  import Retro.Boards.Card, only: [is_lane: 1]

  alias Retro.Boards.{Board, Card}
  alias Retro.Repo

  # Pub/sub lives in the context so every writer — LiveView today, BoardServer
  # in Phase 6 — triggers the same notifications through one code path.
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
  # response — the LiveView route will lean on exactly this in Phase 2.
  def get_board_by_slug!(slug), do: Repo.get_by!(Board, slug: slug)

  # `%Board{} = board` in the head is pattern matching used as a guard: the
  # call crashes unless the argument is a Board struct — an assertion built
  # into the function signature instead of an instanceof check.
  def list_cards(%Board{} = board) do
    # ^ is the pin operator: interpolate this Elixir value into the query
    # (unpinned names would be read as database columns).
    # order_by is the SQL mirror of Card.sort_key/1 (id as tiebreaker makes
    # equal positions deterministic) — change them only as a pair.
    Repo.all(
      from c in Card,
        where: c.board_id == ^board.id,
        order_by: [asc: c.lane, asc: c.position, asc: c.id]
    )
  end

  def create_card(%Board{} = board, attrs) do
    changeset = Card.changeset(%Card{board_id: board.id}, attrs)

    # get_field/2 reads a field from changes falling back to data. Lane is nil
    # only when the changeset is already invalid — then insert/1 short-circuits
    # on valid?: false and returns {:error, changeset} without touching the DB.
    case Ecto.Changeset.get_field(changeset, :lane) do
      nil ->
        Repo.insert(changeset)

      lane ->
        changeset
        |> Ecto.Changeset.put_change(:position, next_position(board.id, lane))
        |> Repo.insert()
        |> broadcast_result(:card_created)
    end
  end

  def update_card(%Card{} = card, attrs) do
    card
    |> Card.changeset(attrs)
    |> Repo.update()
    |> broadcast_result(:card_updated)
  end

  def delete_card(%Card{} = card) do
    card
    |> Repo.delete()
    |> broadcast_result(:card_deleted)
  end

  # `attrs \\ %{}` declares a default argument; used by the Phase 2 form.
  def change_card(%Card{} = card, attrs \\ %{}), do: Card.changeset(card, attrs)

  # Drag-and-drop drop handler. The client sends only its INTENT (target lane +
  # index); the position arithmetic happens here, against the DB's current
  # order — the same trust boundary as create_card computing position itself.
  # Ecto.Changeset.change/2 (vs cast/3) applies trusted server-side values
  # with no casting/validation — correct here because both values are ours,
  # not user input. Concurrent drags of the same card are last-write-wins by
  # design (documented in ADR-0001); the BoardServer serializes this in Phase 6.
  def reposition_card(%Card{} = card, lane, new_index)
      when is_lane(lane) and is_integer(new_index) and new_index >= 0 do
    {prev, next} = neighbors_at(card, lane, new_index)

    card
    |> Ecto.Changeset.change(lane: lane, position: position_between(prev, next))
    |> Repo.update()
    |> broadcast_result(:card_updated)
  end

  # The dragged card's future neighbors: the target lane's cards WITHOUT the
  # dragged one (SortableJS reports the index in exactly that list), so a
  # same-lane move can't pick the card itself as its own neighbor.
  defp neighbors_at(card, lane, new_index) do
    rest =
      Repo.all(
        from c in Card,
          where: c.board_id == ^card.board_id and c.lane == ^lane and c.id != ^card.id,
          order_by: [asc: c.position, asc: c.id]
      )

    # Enum.at with a negative index counts from the END of the list — hence
    # the explicit guard, or dropping at index 0 would grab the LAST card.
    prev = if new_index > 0, do: Enum.at(rest, new_index - 1)
    {prev, Enum.at(rest, new_index)}
  end

  # Fractional indexing — the payoff of position being a float: dropping
  # between 2.0 and 3.0 yields 2.5, no renumbering of neighbours. Precision
  # degrades after ~50 halvings of the same gap; accepted and documented.
  defp position_between(nil, nil), do: 1.0
  defp position_between(nil, next), do: next.position / 2
  defp position_between(prev, nil), do: prev.position + 1.0
  defp position_between(prev, next), do: (prev.position + next.position) / 2

  # Broadcast to EVERYONE, sender included: subscribers (the sender's own
  # LiveView too) apply changes only in handle_info — one code path, so the
  # self-echo double-render bug cannot exist. The slug lookup is a stopgap
  # until Phase 6, when BoardServer owns both the slug and the broadcasting.
  defp broadcast_result({:ok, %Card{} = card}, event) do
    slug = Repo.one!(from b in Board, where: b.id == ^card.board_id, select: b.slug)
    Phoenix.PubSub.broadcast(Retro.PubSub, topic(slug), {event, card})
    {:ok, card}
  end

  defp broadcast_result({:error, _changeset} = error, _event), do: error

  # defp = private to this module. New cards append to their lane: max + 1.0
  # (`||` returns the left side unless it is nil/false — hence 0.0 for an
  # empty lane, so the first card lands on 1.0).
  defp next_position(board_id, lane) do
    max =
      Repo.one(
        from c in Card,
          where: c.board_id == ^board_id and c.lane == ^lane,
          select: max(c.position)
      )

    (max || 0.0) + 1.0
  end
end
