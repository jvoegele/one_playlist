defmodule OnePlaylist.Transfers.SourceMissing do
  @moduledoc """
  A file-backed transfer has no parsed source to run.

  **Infrastructure**, not domain: the user did nothing wrong, and the only way
  to reach it is a transfer created without its
  `OnePlaylist.Transfers.Source` row. The two are written in one transaction, so
  that should be impossible — which is exactly why it is worth naming rather
  than letting the worker crash on a `nil`.

  Not retryable. No number of attempts writes a row that was never inserted.
  """

  use Errata.InfrastructureError,
    default_message: "that upload has no parsed tracks to transfer",
    default_reason: :not_parsed,
    reasons: [:not_parsed],
    code: "TRANSFER_SOURCE_MISSING",
    http_status: 500

  def retryable?(_error), do: false
end
