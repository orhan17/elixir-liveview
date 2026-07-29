defmodule RetroWeb.BoardLive do
  use RetroWeb, :live_view

  alias Retro.Boards
  alias Retro.Boards.Card

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
        if connected?(socket), do: Boards.subscribe(board)

        socket =
          socket
          |> assign(:board, board)
          |> assign(:display_name, display_name)
          |> assign(:cards, Boards.list_cards(board))
          |> assign(:forms, empty_forms())

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

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        {@board.title}
        <:subtitle>You are {@display_name}. Not realtime yet — a second tab stays stale (Phase 3 fixes this).</:subtitle>
      </.header>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <section :for={lane <- Card.lanes()} class="bg-base-200 rounded-box p-3 space-y-3">
          <h2 class="font-semibold text-sm uppercase tracking-wide">{lane_title(lane)}</h2>

          <div :for={card <- cards_in(@cards, lane)} id={"card-#{card.id}"} class="card bg-base-100 shadow-sm">
            <div class="card-body p-3">
              <p class="whitespace-pre-wrap text-sm">{card.body}</p>
              <div class="text-xs opacity-60 flex justify-between">
                <span>{card.author_name}</span>
                <span>▲ {card.votes}</span>
              </div>
            </div>
          </div>

          <.form for={@forms[lane]} id={"card-form-#{lane}"} phx-submit="create_card">
            <div class="space-y-2">
              <.input field={@forms[lane][:lane]} type="hidden" id={"lane-#{lane}"} value={lane} />
              <.input
                field={@forms[lane][:body]}
                type="textarea"
                id={"body-#{lane}"}
                placeholder="Add a card…"
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
end
