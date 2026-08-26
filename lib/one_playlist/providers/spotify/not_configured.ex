defmodule OnePlaylist.Providers.Spotify.NotConfigured do
  @moduledoc """
  Spotify application credentials are absent from the environment.

  A `:general` error rather than infrastructure: nothing is down and retrying
  changes nothing. Someone has to set `SPOTIFY_CLIENT_ID` and
  `SPOTIFY_CLIENT_SECRET`.

  Both, unlike TIDAL. Spotify is driven here as a **confidential** client, so
  the secret is not optional the way `OnePlaylist.Providers.Tidal.OAuth`'s is —
  see that module for the comparison.
  """

  use Errata.Error,
    default_message: "Spotify is not configured on this server",
    default_reason: :missing_credentials,
    reasons: [:missing_credentials],
    http_status: 501,
    code: "SPOTIFY_NOT_CONFIGURED"

  # Names the key rather than only the provider, because "Spotify is not
  # configured" sends a reader to look at all of it. The distinction is not
  # cosmetic here: this application needs *two* values where TIDAL needs one,
  # and the second is easy to leave out.
  #
  # Safe to display. `context.missing` holds the *name* of a variable, never its
  # value — and `:client_secret` is in `config :errata, redact:` regardless, so
  # a future edit that put a value here would be redacted rather than shown.
  def display_message(%{context: %{missing: name}}) when is_binary(name),
    do: "Spotify is not configured on this server: #{name} is not set"

  def display_message(error), do: error.message
end
