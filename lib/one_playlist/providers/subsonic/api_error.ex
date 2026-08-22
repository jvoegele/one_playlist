defmodule OnePlaylist.Providers.Subsonic.APIError do
  @moduledoc """
  A Subsonic server refused a call.

  ## Failures arrive as successes

  Subsonic answers **HTTP 200 for everything**, including authentication
  failures and missing resources, and puts the real outcome in the body:

      {"subsonic-response": {"status": "failed",
                             "error": {"code": 40, "message": "Wrong username or password"}}}

  That inverts the assumption every other error path in this application makes,
  and it is why `OnePlaylist.Providers.Subsonic.Client` classifies on the body
  rather than on the status line. A client written for TIDAL and pointed at
  Subsonic would report every failure as a success — silently, and with an
  empty result rather than an error.

  ## The codes that matter

  | Code | Meaning | Retryable |
  | --- | --- | --- |
  | 0 | generic | yes — it is the server's "something went wrong" |
  | 10 | required parameter missing | no, it is our bug |
  | 20 / 30 | client or server version too old | no |
  | 40 | wrong username or password | no |
  | 41 | token authentication not supported | no |
  | 50 | not authorized for this operation | no |
  | 70 | not found | no |

  Retrying an authentication failure is how an integration wedges itself, and
  on a self-hosted server it is also how a user gets locked out of their own
  music by their own transfer.
  """

  use Errata.DomainError,
    default_message: "the request to the music server failed",
    default_reason: :server_error,
    reasons: [
      :server_error,
      :missing_parameter,
      :incompatible_version,
      :unauthorized,
      :token_auth_unsupported,
      :forbidden,
      :not_found,
      :unexpected
    ],
    http_status: 502,
    code: "SUBSONIC_API_ERROR"

  def retryable?(%{reason: :server_error}), do: true
  def retryable?(%{reason: :unexpected}), do: true
  def retryable?(_error), do: false

  def display_message(%{reason: :unauthorized}),
    do: "your music server rejected that username or password — reconnect to continue"

  def display_message(%{reason: :token_auth_unsupported}),
    do:
      "your music server is too old for token authentication, " <>
        "which this application requires rather than sending a password in the clear"

  def display_message(%{reason: :forbidden}),
    do: "that account is not allowed to do this on your music server"

  def display_message(%{reason: :not_found}), do: "that is no longer on your music server"

  def display_message(%{context: %{detail: detail}}) when is_binary(detail), do: detail
  def display_message(error), do: error.message

  @doc """
  Maps a Subsonic error code to a reason.

  Unknown codes become `:unexpected` rather than raising: the protocol is
  implemented by several servers and a code this does not know about is their
  business, not a reason to crash a transfer.
  """
  @spec reason_for(integer()) :: atom()
  def reason_for(0), do: :server_error
  def reason_for(10), do: :missing_parameter
  def reason_for(20), do: :incompatible_version
  def reason_for(30), do: :incompatible_version
  def reason_for(40), do: :unauthorized
  def reason_for(41), do: :token_auth_unsupported
  def reason_for(50), do: :forbidden
  def reason_for(70), do: :not_found
  def reason_for(_code), do: :unexpected
end
