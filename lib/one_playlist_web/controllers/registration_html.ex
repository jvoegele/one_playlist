defmodule OnePlaylistWeb.RegistrationHTML do
  @moduledoc """
  Pages rendered by `OnePlaylistWeb.RegistrationController`.
  """
  use OnePlaylistWeb, :html

  import OnePlaylistWeb.AuthComponents

  embed_templates "registration_html/*"
end
