defmodule OnePlaylist.Providers.ProviderNotSupported do
  @moduledoc """
  No adapter is registered for this provider yet.

  `OnePlaylist.Providers.Connection` accepts every service this application
  intends to support, which is deliberately ahead of what it can actually talk
  to — the column's check constraint documents the roadmap. This is the error
  for the gap between the two.

  A `:general` error rather than a domain one: the caller did nothing wrong and
  cannot fix it by asking differently.
  """

  use Errata.Error,
    default_message: "that music service is not supported yet",
    default_reason: :no_adapter,
    reasons: [:no_adapter],
    http_status: 501,
    code: "PROVIDER_NOT_SUPPORTED"

  def display_message(%{context: %{provider: provider}}),
    do: "#{provider} is not supported yet"

  def display_message(error), do: error.message
end
