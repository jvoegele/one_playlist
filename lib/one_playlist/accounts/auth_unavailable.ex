defmodule OnePlaylist.Accounts.AuthUnavailable do
  @moduledoc """
  Supabase Auth could not be reached, or is not configured on this server.

  **Infrastructure**, and the counterpart to
  `OnePlaylist.Accounts.SignInFailed`: this one is never the user's fault, and
  the difference matters at the sign-in form, where "check your password" and
  "we cannot reach the authentication service" need opposite responses from the
  person reading them.

  `:not_configured` is separated from the rest because it is the fresh-checkout
  case — nobody copied `config/dev_local.example.exs` — and it is not retryable:
  no amount of waiting sets an environment variable. Everything else is
  transient by default.
  """

  use Errata.InfrastructureError,
    default_message: "the authentication service is unavailable",
    default_reason: :unreachable,
    reasons: [:not_configured, :unreachable, :unexpected_response],
    code: "AUTH_UNAVAILABLE"

  def retryable?(%{reason: :not_configured}), do: false
  def retryable?(_error), do: true

  def http_status(%{reason: :not_configured}), do: 501
  def http_status(_error), do: 503
end
