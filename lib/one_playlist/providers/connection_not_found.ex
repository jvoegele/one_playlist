defmodule OnePlaylist.Providers.ConnectionNotFound do
  @moduledoc "The user has no connection to the requested provider."

  use Errata.DomainError,
    default_message: "no connection to that music service",
    default_reason: :not_connected,
    reasons: [:not_connected],
    http_status: 404,
    code: "PROVIDER_NOT_CONNECTED"
end
