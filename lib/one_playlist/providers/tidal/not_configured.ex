defmodule OnePlaylist.Providers.Tidal.NotConfigured do
  @moduledoc """
  TIDAL application credentials are absent from the environment.

  A `:general` error rather than infrastructure: nothing is down and retrying
  changes nothing. Someone has to set `TIDAL_CLIENT_ID`.
  """

  use Errata.Error,
    default_message: "TIDAL is not configured on this server",
    default_reason: :missing_credentials,
    reasons: [:missing_credentials],
    http_status: 501,
    code: "TIDAL_NOT_CONFIGURED"
end
