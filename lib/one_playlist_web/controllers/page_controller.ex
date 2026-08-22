defmodule OnePlaylistWeb.PageController do
  use OnePlaylistWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
