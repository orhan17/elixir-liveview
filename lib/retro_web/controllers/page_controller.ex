defmodule RetroWeb.PageController do
  use RetroWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
