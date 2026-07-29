defmodule RetroWeb.BoardLive do
  use RetroWeb, :live_view

  alias Retro.Boards
  alias Retro.Boards.Card
  alias RetroWeb.Presence

  @typing_timeout_ms 3000

  # mount/3 runs TWICE per visit: once for the plain HTTP render (disconnected),
  # then again in a fresh process when the browser's websocket connects. That
  # second process is this tab's server-side state for as long as the tab lives.
  def mount(%{"slug" => slug}, session, socket) do
    case session["display_name"] do
      nil ->
        {:ok, redirect(socket, to: ~p"/b/#{slug}/join")}

      display_name ->
        # Unknown slug raises Ecto.NoResultsError, which Phoenix renders as 404.
        board = Boards.get_board_by_slug!(slug)

        # Subscribe only in the connected mount: the disconnected one runs in a
        # short-lived HTTP process that dies right after rendering — it will
        # never be around to receive a message. Subscribe BEFORE list_cards:
        # an event landing in the gap then shows up twice (once in the list,
        # once as a message), which upsert_card below absorbs; the reverse
        # order would LOSE the event instead.
        if connected?(socket) do
          Boards.subscribe(board)
          # Track AFTER subscribing, so our own join diff also reaches us and
          # the roster updates through the same single path as everyone else's.
          {:ok, _ref} = Presence.track(self(), Boards.topic(board), display_name, %{})
        end

        socket =
          socket
          |> assign(:board, board)
          |> assign(:display_name, display_name)
          |> assign(:cards, Boards.list_cards(board))
          |> assign(:forms, empty_forms())
          |> assign(:online, online_names(board))
          |> assign(:typing, %{})

        {:ok, socket}
    end
  end

  # handle_event/3 = a message from THIS tab's browser (phx-submit over the
  # websocket). Contrast with handle_info/2 (messages from other processes),
  # which arrives in Phase 3.
  def handle_event("create_card", %{"card" => params}, socket) do
    # author_name comes from the session-backed assign, never from the form —
    # the client does not get to claim someone else's name.
    params = Map.put(params, "author_name", socket.assigns.display_name)

    case Boards.create_card(socket.assigns.board, params) do
      {:ok, _card} ->
        # Deliberately NOT touching :cards here — our own card comes back via
        # the broadcast into handle_info, same as everyone else's. One path.
        {:noreply, assign(socket, :forms, empty_forms())}

      {:error, changeset} ->
        lane = Ecto.Changeset.get_field(changeset, :lane)

        forms =
          if lane in Card.lanes() do
            Map.put(socket.assigns.forms, lane, to_form(changeset))
          else
            socket.assigns.forms
          end

        {:noreply, assign(socket, :forms, forms)}
    end
  end

  # Drop reported by the CardSort hook (pushEvent, not a form). Everything in
  # the payload is client-controlled, so each piece is re-validated: lane must
  # parse into a known atom, the card must exist on THIS board (assigns, not a
  # trusting Repo.get by id — a forged id targeting another board dies here).
  # On :ok assigns stay untouched: the new order arrives via the broadcast,
  # same single path as everyone else's.
  def handle_event("reposition", %{"id" => id, "lane" => lane_param, "new_index" => new_index}, socket) do
    lane = Enum.find(Card.lanes(), &(Atom.to_string(&1) == lane_param))
    card = Enum.find(socket.assigns.cards, &(to_string(&1.id) == to_string(id)))

    if lane && card && is_integer(new_index) && new_index >= 0 do
      # Delete-vs-reposition now serializes in the BoardServer mailbox: a
      # concurrently deleted card comes back as a clean {:error, :not_found}
      # (the StaleEntryError crash of the pre-Phase-6 design is gone).
      _ = Boards.reposition_card(socket.assigns.board, card.id, lane, new_index)
    end

    {:noreply, socket}
  end

  # ▲ click. Result deliberately ignored: the incremented card arrives via
  # the broadcast, and a vanished card is a benign {:error, :not_found}.
  def handle_event("vote", %{"id" => id}, socket) do
    card = Enum.find(socket.assigns.cards, &(to_string(&1.id) == to_string(id)))
    if card, do: Boards.vote_card(socket.assigns.board, card.id)
    {:noreply, socket}
  end

  # Throttled phx-change from a compose box. Two jobs: tell the room someone
  # is typing, and mirror the draft into this lane's form assign — which is
  # exactly what makes LiveView's form recovery restore it after a reconnect.
  def handle_event("typing", %{"card" => params}, socket) do
    Phoenix.PubSub.broadcast(
      Retro.PubSub,
      Boards.topic(socket.assigns.board),
      {:typing, socket.assigns.display_name}
    )

    lane = Enum.find(Card.lanes(), &(Atom.to_string(&1) == params["lane"]))

    forms =
      if lane do
        Map.put(socket.assigns.forms, lane, to_form(Boards.change_card(%Card{}, params)))
      else
        socket.assigns.forms
      end

    {:noreply, assign(socket, :forms, forms)}
  end

  # handle_info/2 = a message from ANOTHER process (here: PubSub delivering a
  # broadcast into this process's mailbox). The browser is never the sender.
  def handle_info({:card_created, %Card{} = card}, socket) do
    {:noreply, update(socket, :cards, &upsert_card(&1, card))}
  end

  def handle_info({:card_updated, %Card{} = card}, socket) do
    {:noreply, update(socket, :cards, &upsert_card(&1, card))}
  end

  def handle_info({:card_deleted, %Card{} = card}, socket) do
    {:noreply, update(socket, :cards, &Enum.reject(&1, fn c -> c.id == card.id end))}
  end

  # Presence broadcasts its diffs on the same board topic. Re-reading the full
  # list on every diff is deliberate: applying joins/leaves incrementally is an
  # optimization we don't need at a retro board's roster size.
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, :online, online_names(socket.assigns.board))}
  end

  def handle_info({:typing, name}, socket) do
    if name == socket.assigns.display_name do
      {:noreply, socket}
    else
      # Re-arm the expiry timer: cancel the old one, start a fresh one. A timer
      # that fired in the cancel race removes the name at most one throttle
      # interval early — cosmetic, so not worth guarding against.
      if old = socket.assigns.typing[name], do: Process.cancel_timer(old)
      ref = Process.send_after(self(), {:typing_expired, name}, @typing_timeout_ms)
      {:noreply, update(socket, :typing, &Map.put(&1, name, ref))}
    end
  end

  def handle_info({:typing_expired, name}, socket) do
    {:noreply, update(socket, :typing, &Map.delete(&1, name))}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        {@board.title}
        <:subtitle>You are {@display_name}.</:subtitle>
        <:actions>
          <div class="flex items-center">
            <div
              :for={name <- @online}
              class="avatar avatar-placeholder -ml-1 first:ml-0"
              title={name}
            >
              <div class="bg-primary text-primary-content w-8 rounded-full ring-2 ring-base-100">
                <span class="text-xs">{initials(name)}</span>
              </div>
            </div>
            <span class="text-xs opacity-60 ml-2">{length(@online)} online</span>
          </div>
        </:actions>
      </.header>

      <p class="text-xs italic opacity-70 min-h-4">{typing_line(@typing)}</p>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <section :for={lane <- Card.lanes()} class="bg-base-200 rounded-box p-3 space-y-3">
          <h2 class="font-semibold text-sm uppercase tracking-wide">{lane_title(lane)}</h2>

          <%!-- The hook element must hold ONLY cards: SortableJS treats every
               child as draggable, and the reported index counts them all.
               min-h keeps an empty lane a droppable target. --%>
          <div
            id={"cards-#{lane}"}
            phx-hook="CardSort"
            data-lane={lane}
            class="space-y-3 min-h-8"
          >
            <div
              :for={card <- cards_in(@cards, lane)}
              id={"card-#{card.id}"}
              data-id={card.id}
              class="card bg-base-100 shadow-sm cursor-grab"
            >
              <div class="card-body p-3">
                <p class="whitespace-pre-wrap text-sm">{card.body}</p>
                <div class="text-xs opacity-60 flex justify-between">
                  <span>{card.author_name}</span>
                  <button
                    type="button"
                    class="cursor-pointer hover:text-primary"
                    phx-click="vote"
                    phx-value-id={card.id}
                  >
                    ▲ {card.votes}
                  </button>
                </div>
              </div>
            </div>
          </div>

          <.form
            for={@forms[lane]}
            id={"card-form-#{lane}"}
            phx-submit="create_card"
            phx-change="typing"
          >
            <div class="space-y-2">
              <.input field={@forms[lane][:lane]} type="hidden" id={"lane-#{lane}"} value={lane} />
              <.input
                field={@forms[lane][:body]}
                type="textarea"
                id={"body-#{lane}"}
                placeholder="Add a card…"
                phx-throttle="1500"
              />
              <.button class="btn-sm">Add</.button>
            </div>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # One form per lane, keyed by lane. DOM ids must be unique per form, hence
  # the explicit id= overrides in the template above.
  defp empty_forms do
    Map.new(Card.lanes(), fn lane -> {lane, to_form(Boards.change_card(%Card{}))} end)
  end

  defp cards_in(cards, lane), do: Enum.filter(cards, &(&1.lane == lane))

  # Idempotent by id (drop-then-insert), so a create delivered twice — e.g. an
  # event landing between subscribe and list_cards — cannot duplicate a card.
  # In-memory ordering reuses Card.sort_key/1, the same rule as the SQL query.
  defp upsert_card(cards, card) do
    [card | Enum.reject(cards, &(&1.id == card.id))]
    |> Enum.sort_by(&Card.sort_key/1)
  end

  # Multiple function clauses: pattern matching picks the clause by argument —
  # this replaces a case/switch and is the idiomatic Elixir dispatch.
  defp lane_title(:went_well), do: "Went well"
  defp lane_title(:to_improve), do: "To improve"
  defp lane_title(:action_items), do: "Action items"

  defp online_names(board) do
    board |> Boards.topic() |> Presence.list() |> Map.keys() |> Enum.sort()
  end

  defp initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  defp typing_line(typing) when typing == %{}, do: ""

  defp typing_line(typing) do
    names = typing |> Map.keys() |> Enum.sort()
    verb = if length(names) == 1, do: "is", else: "are"
    Enum.join(names, ", ") <> " #{verb} typing…"
  end
end
