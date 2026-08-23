defmodule OnePlaylist.Storage.Unavailable do
  @moduledoc """
  A playlist file could not be stored or fetched.

  **Infrastructure**, and the counterpart to
  `OnePlaylist.Formats.UnreadablePlaylist`: that one means the user's file is
  wrong, this one means we could not get at it. They need opposite responses
  from the person reading them.

  `:not_found` covers a file that does not exist *and* one belonging to somebody
  else, deliberately conflated — see `OnePlaylist.Storage`. Answering
  differently would confirm that a path names a real file.

  `:forbidden` is kept separate and means something narrower: a *write* the
  storage policies refused. A user cannot cause one, because paths are built
  from their own id — so it means this application built a path wrongly, and
  disguising it as a missing file would hide a bug in `path_for/3`.
  """

  use Errata.InfrastructureError,
    default_message: "that file could not be reached",
    default_reason: :unreachable,
    reasons: [:forbidden, :not_configured, :not_found, :too_large, :unreachable],
    code: "STORAGE_UNAVAILABLE"

  def retryable?(%{reason: reason})
      when reason in [:forbidden, :not_configured, :not_found, :too_large],
      do: false

  def retryable?(_error), do: true

  def http_status(%{reason: :forbidden}), do: 403
  def http_status(%{reason: :not_found}), do: 404
  def http_status(%{reason: :too_large}), do: 413
  def http_status(%{reason: :not_configured}), do: 501
  def http_status(_error), do: 503
end
