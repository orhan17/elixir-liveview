defmodule Retro.BoardServer do
  @moduledoc """
  One process per live board: the single writer for that board's cards.

  Every mutation flows through this process's mailbox and is handled one
  message at a time — the ordering decisions that used to race in SQL
  (`next_position`) are now serialized by construction, with no lock anywhere.
  Postgres stays the durable copy (write-through in this phase; write-behind
  arrives in Phase 7) and the recovery source: `init/1` reloads everything.
  """

  # `use GenServer` also generates child_spec/1; restart: :transient makes the
  # supervisor restart this child only after an ABNORMAL exit (crash, kill).
  # A normal stop stays stopped — exactly what Phase 7's idle shutdown needs.
  use GenServer, restart: :transient

  import Ecto.Query, only: [from: 2]
  import Retro.Boards.Card, only: [is_lane: 1]

  alias Retro.Boards.{Board, Card}
  alias Retro.Repo

  ## Client API — this code runs in the CALLER's process (a LiveView, iex).
  ## Guards live here on purpose: garbage input crashes the caller, never the
  ## board process shared by everyone else.

  # A via tuple delegates naming to Registry: "the pid registered under this
  # slug in Retro.BoardRegistry". Slugs stay strings end to end — no atom is
  # ever created per board (atoms are never garbage collected).
  def via(slug) when is_binary(slug), do: {:via, Registry, {Retro.BoardRegistry, slug}}

  def start_link(slug) do
    GenServer.start_link(__MODULE__, slug, name: via(slug))
  end

  # Start on demand, or find the running one. Two callers racing here both ask
  # the DynamicSupervisor to start the same child; Registry's unique key makes
  # the second registration fail with {:already_started, pid} and the loser
  # adopts the winner's pid. Same single-arbiter shape as the slug unique
  # index — one level up the stack.
  def start_or_lookup(slug) when is_binary(slug) do
    case DynamicSupervisor.start_child(Retro.BoardSupervisor, {__MODULE__, slug}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_cards(slug), do: call(slug, :list_cards)

  def create_card(slug, attrs), do: call(slug, {:create_card, attrs})

  # editor_name is the caller's session identity: ownership ("edit your own
  # card") is enforced HERE, in the single writer — the UI hiding the button
  # is cosmetics, not security.
  def update_card(slug, id, attrs, editor_name) when is_integer(id) and is_binary(editor_name) do
    call(slug, {:update_card, id, attrs, editor_name})
  end

  def delete_card(slug, id) when is_integer(id), do: call(slug, {:delete_card, id})

  def reposition_card(slug, id, lane, new_index)
      when is_integer(id) and is_lane(lane) and is_integer(new_index) and new_index >= 0 do
    call(slug, {:reposition_card, id, lane, new_index})
  end

  def vote_card(slug, id) when is_integer(id), do: call(slug, {:vote_card, id})

  # Every op ensures the server exists first: after a crash-restart or (Phase
  # 7) an idle shutdown, the next touch of the board revives it transparently.
  defp call(slug, msg) do
    {:ok, pid} = start_or_lookup(slug)
    GenServer.call(pid, msg)
  end

  ## Server callbacks — run IN the board process, strictly one at a time.

  @impl true
  def init(slug) do
    board = Repo.get_by!(Board, slug: slug)
    cards = Repo.all(from c in Card, where: c.board_id == ^board.id)
    # Cards keyed by id; ordering is imposed on read via Card.sort_key/1 —
    # still the one definition of order, now applied in memory.
    {:ok, %{board: board, cards: Map.new(cards, &{&1.id, &1})}}
  end

  @impl true
  def handle_call(:list_cards, _from, state) do
    {:reply, sorted_cards(state), state}
  end

  def handle_call({:create_card, attrs}, _from, state) do
    changeset = Card.changeset(%Card{board_id: state.board.id}, attrs)

    case Ecto.Changeset.get_field(changeset, :lane) do
      nil ->
        # Invalid changeset: insert short-circuits and returns the errors.
        {:reply, Repo.insert(changeset), state}

      lane ->
        # max-in-lane is read from this process's own memory, and nothing can
        # interleave before the insert below — the check-then-act race that
        # lived in the SQL next_position is gone, not handled.
        changeset
        |> Ecto.Changeset.put_change(:position, append_position(state, lane))
        |> Repo.insert()
        |> reply_and_broadcast(:card_created, state)
    end
  end

  def handle_call({:update_card, id, attrs, editor_name}, _from, state) do
    case fetch_card(state, id) do
      {:ok, %Card{author_name: ^editor_name} = card} ->
        card |> Card.changeset(attrs) |> Repo.update() |> reply_and_broadcast(:card_updated, state)

      # A card that exists but belongs to someone else: the pin above did not
      # match, so this clause catches it as a plain authorization failure.
      {:ok, %Card{}} ->
        {:reply, {:error, :forbidden}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:delete_card, id}, _from, state) do
    with {:ok, card} <- fetch_card(state, id),
         {:ok, card} <- Repo.delete(card) do
      state = %{state | cards: Map.delete(state.cards, card.id)}
      broadcast(state, :card_deleted, card)
      {:reply, {:ok, card}, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:reposition_card, id, lane, new_index}, _from, state) do
    case fetch_card(state, id) do
      {:ok, card} ->
        {prev, next} = neighbors_at(state, card, lane, new_index)

        # Ecto.Changeset.change/2 (vs cast/3) applies trusted server-side
        # values with no casting — both values are computed here, not input.
        card
        |> Ecto.Changeset.change(lane: lane, position: position_between(prev, next))
        |> Repo.update()
        |> reply_and_broadcast(:card_updated, state)

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:vote_card, id}, _from, state) do
    case fetch_card(state, id) do
      {:ok, card} ->
        # Read-increment-write on in-memory state: safe for the same reason
        # positions are — no other write can interleave within one call.
        card
        |> Ecto.Changeset.change(votes: card.votes + 1)
        |> Repo.update()
        |> reply_and_broadcast(:card_updated, state)

      error ->
        {:reply, error, state}
    end
  end

  ## Internals

  defp fetch_card(state, id) do
    # `%{^id => card}` pins the id INSIDE a map pattern: match only if that
    # exact key is present.
    case state.cards do
      %{^id => card} -> {:ok, card}
      _ -> {:error, :not_found}
    end
  end

  defp sorted_cards(state) do
    state.cards |> Map.values() |> Enum.sort_by(&Card.sort_key/1)
  end

  defp append_position(state, lane) do
    case for {_id, c} <- state.cards, c.lane == lane, do: c.position do
      [] -> 1.0
      positions -> Enum.max(positions) + 1.0
    end
  end

  # The dragged card's future neighbors, from in-memory state — the target
  # lane without the dragged card (SortableJS reports the index in that list).
  defp neighbors_at(state, card, lane, new_index) do
    rest =
      state.cards
      |> Map.values()
      |> Enum.filter(&(&1.lane == lane and &1.id != card.id))
      |> Enum.sort_by(&Card.sort_key/1)

    # Enum.at with a negative index counts from the END — hence the guard on
    # the client API and the explicit branch here.
    prev = if new_index > 0, do: Enum.at(rest, new_index - 1)
    {prev, Enum.at(rest, new_index)}
  end

  # Fractional indexing (moved from the context, unchanged): ~45-50 drops into
  # one gap before float precision runs out — accepted, documented in ADR.
  defp position_between(nil, nil), do: 1.0
  defp position_between(nil, next), do: next.position / 2
  defp position_between(prev, nil), do: prev.position + 1.0
  defp position_between(prev, next), do: (prev.position + next.position) / 2

  defp reply_and_broadcast({:ok, %Card{} = card}, event, state) do
    state = %{state | cards: Map.put(state.cards, card.id, card)}
    broadcast(state, event, card)
    {:reply, {:ok, card}, state}
  end

  defp reply_and_broadcast({:error, _changeset} = error, _event, state) do
    {:reply, error, state}
  end

  # There is exactly one writer per board now, so "every writer broadcasts
  # the same way" holds by construction — the slug-lookup stopgap in the old
  # context broadcast is gone.
  defp broadcast(state, event, card) do
    Phoenix.PubSub.broadcast(Retro.PubSub, Retro.Boards.topic(state.board), {event, card})
  end
end
