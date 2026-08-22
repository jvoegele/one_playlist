defmodule OnePlaylist.Providers.Tidal.APIError do
  @moduledoc """
  A TIDAL API call returned an error.

  TIDAL replies in JSON:API's error shape, verified against the live service:

      {"errors": [{"code": "UNAUTHORIZED",
                   "detail": "Invalid or missing Authorization Header",
                   "meta": {"category": "AUTHENTICATION_ERROR"}}]}

  The `:reason` mirrors the useful part of that. Retryability is answered per
  instance rather than taking the infrastructure default, because the difference
  between "TIDAL is unwell" and "this request was wrong" is the difference
  between retrying and wasting the user's time.
  """

  use Errata.InfrastructureError,
    default_message: "the request to TIDAL failed",
    reasons: [:unauthorized, :forbidden, :not_found, :rate_limited, :server_error, :unexpected],
    code: "TIDAL_API_ERROR"

  def retryable?(%{reason: reason}) when reason in [:rate_limited, :server_error], do: true
  def retryable?(_error), do: false

  def http_status(%{reason: :unauthorized}), do: 401
  def http_status(%{reason: :forbidden}), do: 403
  def http_status(%{reason: :not_found}), do: 404
  def http_status(%{reason: :rate_limited}), do: 429
  def http_status(_error), do: 502

  def display_message(%{reason: :unauthorized}),
    do: "your TIDAL connection is no longer valid — reconnect to continue"

  def display_message(%{reason: :rate_limited}),
    do: "TIDAL is asking us to slow down; this will retry shortly"

  def display_message(%{reason: :not_found}), do: "that item no longer exists on TIDAL"
  def display_message(error), do: error.message
end
