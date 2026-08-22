defmodule OnePlaylist.Providers.TokenRefreshFailed do
  @moduledoc """
  Exchanging a refresh token for a new access token failed.

  Infrastructure rather than domain: the usual cause is the provider being
  unreachable, which is nobody's fault and worth retrying. The exception is
  `:invalid_grant`, which is the provider telling us the refresh token is dead —
  retrying that is how an integration wedges itself, so this type answers
  `retryable?/1` per instance rather than taking the infrastructure default.

  `ExternalService` reads that answer through the `:retry_on` and
  `:retry_exceptions` predicates. See `docs/reference/jv-libraries.md`.
  """

  use Errata.InfrastructureError,
    default_message: "could not refresh access to the music service",
    reasons: [:invalid_grant, :provider_unavailable, :rate_limited, :malformed_response],
    code: "PROVIDER_TOKEN_REFRESH_FAILED"

  def retryable?(%{reason: :invalid_grant}), do: false
  def retryable?(_error), do: true

  def http_status(%{reason: :rate_limited}), do: 429
  def http_status(_error), do: 503
end
