defmodule Retro.BoardServer do
  @moduledoc """
  One process per live board: the single writer for that board's cards.

  Since Phase 7 persistence is WRITE-BEHIND: mutations are applied to this
  process's memory, broadcast immediately, and flushed to Postgres in batches
  — on a timer, on idle shutdown, and in `terminate/2` when the runtime gives
  us the chance. Memory is the truth while the board is live; Postgres is the
  durable copy and the hydration source in `init/1`.

  The honest part (ADR material): `terminate/2` runs only when the exit is
  deliverable — supervisor shutdown, `{:stop, _}`, idle timeout. It does NOT
  run on `Process.exit(pid, :kill)`, a BEAM crash, or power loss. The real
  data-loss window is therefore the flush interval: up to #{5_000} ms of
  accepted-and-broadcast writes can vanish. We say so instead of pretending.
  """

  # restart: :transient — restarted after a crash/kill, but an idle shutdown
  # ({:stop, :normal}) stays down until the next touch revives it on demand.
  use GenServer, restart: :transient

  import Ecto.Query, only: [from: 2]
  import Retro.Boards.Card, only: [is_lane: 1]

  alias Retro.Boards.{Board, Card}
  alias Retro.Repo

  @flush_ms 5_000
  @idle_check_ms 60_000
  @idle_after_ms 10 * 60_000

  ## Client API — runs in the CALLER's process. Guards live here on purpose:
  ## garbage input crashes the caller, never the board process.

  def via(slug) when is_binary(slug), do: {:via, Registry, {Retro.BoardRegistry, slug}}

  def start_link(slug) do
    GenServer.start_link(__MODULE__, slug, name: via(slug))
  end

  # Two callers racing here both ask DynamicSupervisor to start the same
  # child; Registry's unique key makes the loser adopt the winner's pid.
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
  # card") is enforced in the single writer — UI hiding the button is
  # cosmetics, not security.
  def update_card(slug, id, attrs, editor_name) when is_integer(id) and is_binary(editor_name) do
    call(slug, {:update_card, id, attrs, editor_name})
  end

  def delete_card(slug, id) when is_integer(id), do: call(slug, {:delete_card, id})

  def reposition_card(slug, id, lane, new_index)
      when is_integer(id) and is_lane(lane) and is_integer(new_index) and new_index >= 0 do
    call(slug, {:reposition_card, id, lane, new_index})
  end

  def vote_card(slug, id) when is_integer(id), do: call(slug, {:vote_card, id})

  # Synchronous flush: used by tests and usable as a pre-shutdown drain.
  def flush(slug), do: call(slug, :flush)

  # Every op ensures the server exists first: after a crash-restart or an
  # idle shutdown, the next touch of the board revives it transparently.
  defp call(slug, msg) do
    {:ok, pid} = start_or_lookup(slug)
    GenServer.call(pid, msg)
  end

  ## Server callbacks — run IN the board process, strictly one at a time.

  @impl true
  def init(slug) do
    # trap_exit converts deliverable exit signals (supervisor :shutdown) into
    # messages, which is the ONLY reason terminate/2 gets a chance to flush.
    Process.flag(:trap_exit, true)

    board = Repo.get_by!(Board, slug: slug)
    cards = Repo.all(from c in Card, where: c.board_id == ^board.id)

    Process.send_after(self(), :flush_tick, @flush_ms)
    Process.send_after(self(), :idle_check, @idle_check_ms)

    {:ok,
     %{
       board: board,
       cards: Map.new(cards, &{&1.id, &1}),
       # ids whose in-memory version is newer than Postgres / ids to DELETE
       dirty: MapSet.new(),
       deleted: MapSet.new(),
       last_activity: now_ms()
     }}
  end

  @impl true
  def handle_call(:list_cards, _from, state) do
    {:reply, sorted_cards(state), touch(state)}
  end

  def handle_call({:create_card, attrs}, _from, state) do
    changeset = Card.changeset(%Card{board_id: state.board.id}, attrs)

    # apply_action/2 runs the validations WITHOUT touching the database —
    # the in-memory replacement for what Repo.insert used to short-circuit.
    with lane when not is_nil(lane) <- Ecto.Changeset.get_field(changeset, :lane),
         {:ok, card} <-
           changeset
           |> Ecto.Changeset.put_change(:position, append_position(state, lane))
           |> Ecto.Changeset.apply_action(:insert) do
      # The id still comes from Postgres — the sequence stays the single
      # arbiter of identity — but the INSERT itself is deferred to the flush.
      now = now_utc()
      card = %{card | id: next_id(), inserted_at: now, updated_at: now}
      commit({:ok, card}, :card_created, state)
    else
      nil -> {:reply, Ecto.Changeset.apply_action(changeset, :insert), state}
      {:error, changeset} -> {:reply, {:error, changeset}, state}
    end
  end

  def handle_call({:update_card, id, attrs, editor_name}, _from, state) do
    case fetch_card(state, id) do
      {:ok, %Card{author_name: ^editor_name} = card} ->
        card
        |> Card.changeset(attrs)
        |> Ecto.Changeset.apply_action(:update)
        |> commit(:card_updated, state)

      # Exists but belongs to someone else: the pin above did not match.
      {:ok, %Card{}} ->
        {:reply, {:error, :forbidden}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:delete_card, id}, _from, state) do
    case fetch_card(state, id) do
      {:ok, card} ->
        state =
          %{
            state
            | cards: Map.delete(state.cards, id),
              dirty: MapSet.delete(state.dirty, id),
              deleted: MapSet.put(state.deleted, id)
          }
          |> touch()

        broadcast(state, :card_deleted, card)
        {:reply, {:ok, card}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:reposition_card, id, lane, new_index}, _from, state) do
    case fetch_card(state, id) do
      {:ok, card} ->
        {prev, next} = neighbors_at(state, card, lane, new_index)

        card
        |> Ecto.Changeset.change(lane: lane, position: position_between(prev, next))
        |> Ecto.Changeset.apply_action(:update)
        |> commit(:card_updated, state)

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:vote_card, id}, _from, state) do
    case fetch_card(state, id) do
      {:ok, card} ->
        card
        |> Ecto.Changeset.change(votes: card.votes + 1)
        |> Ecto.Changeset.apply_action(:update)
        |> commit(:card_updated, state)

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:flush, _from, state) do
    {:reply, :ok, do_flush(state)}
  end

  @impl true
  def handle_info(:flush_tick, state) do
    Process.send_after(self(), :flush_tick, @flush_ms)
    {:noreply, do_flush(state)}
  end

  def handle_info(:idle_check, state) do
    if now_ms() - state.last_activity >= @idle_after_ms do
      # {:stop, :normal, _} triggers terminate/2 (flush) and, being a normal
      # exit under restart: :transient, stays down until the next touch.
      {:stop, :normal, state}
    else
      Process.send_after(self(), :idle_check, @idle_check_ms)
      {:noreply, state}
    end
  end

  # trap_exit means deliverable exits arrive here as messages; letting the
  # supervisor's :shutdown stop us goes through terminate/2 below.
  def handle_info({:EXIT, _pid, reason}, state) do
    {:stop, reason, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Best effort, not a guarantee: never runs on :kill, BEAM death or power
    # loss. The flush interval is the real loss window.
    do_flush(state)
    :ok
  end

  ## Internals

  defp fetch_card(state, id) do
    case state.cards do
      %{^id => card} -> {:ok, card}
      _ -> {:error, :not_found}
    end
  end

  # Apply a successful in-memory mutation: stamp, store, mark dirty,
  # broadcast. All writes funnel through here.
  defp commit({:ok, %Card{} = card}, event, state) do
    card = %{card | updated_at: now_utc()}

    state =
      %{state | cards: Map.put(state.cards, card.id, card), dirty: MapSet.put(state.dirty, card.id)}
      |> touch()

    broadcast(state, event, card)
    {:reply, {:ok, card}, state}
  end

  defp commit({:error, _changeset} = error, _event, state) do
    {:reply, error, touch(state)}
  end

  defp do_flush(%{dirty: dirty, deleted: deleted} = state) do
    rows =
      dirty
      |> Enum.map(&state.cards[&1])
      # a card can be dirty and then deleted before the flush — skip holes
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&card_row/1)

    if rows != [] do
      # Upsert whole rows: Ecto CAN send deltas (an UPDATE carries only
      # changes), but delta-flushing would require keeping a second,
      # as-persisted snapshot to diff against. Deliberate trade, see ADR.
      Repo.insert_all(Card, rows,
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: [:id]
      )
    end

    if MapSet.size(deleted) > 0 do
      ids = MapSet.to_list(deleted)
      Repo.delete_all(from c in Card, where: c.id in ^ids)
    end

    %{state | dirty: MapSet.new(), deleted: MapSet.new()}
  end

  defp card_row(%Card{} = card) do
    Map.take(card, [:id, :board_id, :lane, :body, :author_name, :position, :votes, :inserted_at, :updated_at])
  end

  # Postgres' sequence keeps generating ids even though the INSERT happens
  # later: identity has exactly one arbiter, before and after write-behind.
  defp next_id do
    %{rows: [[id]]} = Repo.query!("SELECT nextval('cards_id_seq')")
    id
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

  defp neighbors_at(state, card, lane, new_index) do
    rest =
      state.cards
      |> Map.values()
      |> Enum.filter(&(&1.lane == lane and &1.id != card.id))
      |> Enum.sort_by(&Card.sort_key/1)

    prev = if new_index > 0, do: Enum.at(rest, new_index - 1)
    {prev, Enum.at(rest, new_index)}
  end

  # Fractional indexing: ~45-50 drops into one gap before float precision
  # runs out — accepted, documented in ADR.
  defp position_between(nil, nil), do: 1.0
  defp position_between(nil, next), do: next.position / 2
  defp position_between(prev, nil), do: prev.position + 1.0
  defp position_between(prev, next), do: (prev.position + next.position) / 2

  defp broadcast(state, event, card) do
    Phoenix.PubSub.broadcast(Retro.PubSub, Retro.Boards.topic(state.board), {event, card})
  end

  defp touch(state), do: %{state | last_activity: now_ms()}

  defp now_ms, do: System.monotonic_time(:millisecond)

  # timestamps(type: :utc_datetime) stores second precision — truncate to match.
  defp now_utc, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
