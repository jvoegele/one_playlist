defmodule OnePlaylistWeb.SessionHTML do
  @moduledoc """
  Pages rendered by `OnePlaylistWeb.SessionController`.
  """
  use OnePlaylistWeb, :html

  import OnePlaylistWeb.AuthComponents

  embed_templates "session_html/*"
end
