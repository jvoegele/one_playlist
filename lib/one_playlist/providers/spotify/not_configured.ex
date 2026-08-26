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
end
