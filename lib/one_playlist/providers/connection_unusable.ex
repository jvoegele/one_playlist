defmodule OnePlaylist.Providers.ConnectionUnusable do
  @moduledoc """
  A connection exists but cannot currently be used to call the provider.

  These are reasons on one type rather than separate types because every caller
  does the same thing with them — stop, and ask the user to reconnect. Only the
  message shown differs, which is exactly what `display_message/1` is for.
  """

  use Errata.DomainError,
    default_message: "that music service needs to be reconnected",
    reasons: [:revoked, :expired, :reauth_required, :insufficient_scope],
    http_status: 403,
    code: "PROVIDER_CONNECTION_UNUSABLE"

  def display_message(%{reason: :insufficient_scope, context: %{provider: provider}}),
    do: "#{provider} did not grant all the permissions this action needs"

  def display_message(%{reason: :revoked, context: %{provider: provider}}),
    do: "access to #{provider} was revoked — reconnect to continue"

  def display_message(%{context: %{provider: provider}}),
    do: "your #{provider} connection has expired — reconnect to continue"

  def display_message(error), do: error.message
end
