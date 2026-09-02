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

  `:method_disabled` is the same shape one layer further in: the application is
  configured, but the Supabase project has the requested sign-in method switched
  off — Google without a client id, or email OTP disabled. GoTrue reports it as
  `provider_disabled`, `email_provider_disabled` or `otp_disabled`. It is the
  project's configuration and not the user's, so it is this error rather than
  `SignInFailed`, and like `:not_configured` no retry will fix it.
  """

  use Errata.InfrastructureError,
    default_message: "the authentication service is unavailable",
    default_reason: :unreachable,
    reasons: [:not_configured, :method_disabled, :unreachable, :unexpected_response],
    code: "AUTH_UNAVAILABLE"

  def retryable?(%{reason: reason}) when reason in [:not_configured, :method_disabled], do: false
  def retryable?(_error), do: true

  def http_status(%{reason: reason}) when reason in [:not_configured, :method_disabled], do: 501
  def http_status(_error), do: 503
end
