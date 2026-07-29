defmodule RetroWeb.JoinController do
  use RetroWeb, :controller

  alias Retro.Boards

  @max_name_length 60

  def new(conn, %{"slug" => slug}) do
    board = Boards.get_board_by_slug!(slug)

    render(conn, :new,
      board: board,
      display_name: get_session(conn, :display_name) || ""
    )
  end

  def create(conn, %{"slug" => slug, "display_name" => display_name}) do
    board = Boards.get_board_by_slug!(slug)
    display_name = String.trim(display_name)

    if display_name == "" or String.length(display_name) > @max_name_length do
      conn
      |> put_flash(:error, "Display name must be 1–#{@max_name_length} characters.")
      |> redirect(to: ~p"/b/#{board.slug}/join")
    else
      conn
      |> put_session(:display_name, display_name)
      |> redirect(to: ~p"/b/#{board.slug}")
    end
  end
end
