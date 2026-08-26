defmodule OnePlaylist.Providers.Spotify.APIError do
  @moduledoc """
  A Spotify Web API call returned an error.

  Spotify replies with a single error object rather than JSON:API's array:

      {"error": {"status": 401, "message": "The access token expired"}}

  Two reasons exist here that TIDAL's equivalent has no use for, and both come
  from Spotify's Development Mode:

    * `:not_allowlisted` — a 403 whose message names the user rather than the
      request. An app in Development Mode serves only the accounts added to it
      in the dashboard, and everybody else gets a 403 that is indistinguishable
      from a scope problem unless the message is read. Telling them apart
      matters because the fixes are opposite: one is "reconnect and grant more",
      the other is "you cannot use this at all until an owner adds you".

    * `:quota_exceeded` — the daily/rolling application quota, as opposed to the
      per-request `:rate_limited`. Retrying does not help within the window.

  Retryability is answered per instance rather than taking the infrastructure
  default, because the difference between "Spotify is unwell" and "this request
  was wrong" is the difference between retrying and wasting the user's time.
  """

  use Errata.InfrastructureError,
    default_message: "the request to Spotify failed",
    reasons: [
      :unauthorized,
      :forbidden,
      :not_allowlisted,
      :not_found,
      :rate_limited,
      :quota_exceeded,
      :server_error,
      :unexpected
    ],
    code: "SPOTIFY_API_ERROR"

  # `:quota_exceeded` is deliberately **not** retryable. A 429 asks us to wait a
  # few seconds; a quota refusal means the application's window is spent, and
  # retrying inside it burns the circuit breaker on a request that cannot
  # succeed no matter how long the backoff.
  def retryable?(%{reason: reason}) when reason in [:rate_limited, :server_error], do: true
  def retryable?(_error), do: false

  def http_status(%{reason: :unauthorized}), do: 401
  def http_status(%{reason: reason}) when reason in [:forbidden, :not_allowlisted], do: 403
  def http_status(%{reason: :not_found}), do: 404
  def http_status(%{reason: reason}) when reason in [:rate_limited, :quota_exceeded], do: 429
  def http_status(_error), do: 502

  def display_message(%{reason: :unauthorized}),
    do: "your Spotify connection is no longer valid — reconnect to continue"

  def display_message(%{reason: :not_allowlisted}),
    do:
      "this Spotify app is in development mode and your account has not been " <>
        "added to it — the app's owner has to allowlist you"

  def display_message(%{reason: :rate_limited}),
    do: "Spotify is asking us to slow down; this will retry shortly"

  def display_message(%{reason: :quota_exceeded}),
    do: "this Spotify app has used its quota for now; try again later"

  def display_message(%{reason: :not_found}), do: "that item no longer exists on Spotify"
  def display_message(error), do: error.message
end
