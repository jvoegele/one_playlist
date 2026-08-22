defmodule OnePlaylist.Transfers.WriteNotConfirmed do
  @moduledoc """
  Tracks were written to the destination, and are not there.

  ## Why this exists

  Every `add_tracks/4` implementation reports how many tracks it was *given*,
  because that is all a provider tells it: TIDAL answers an append with `200`
  and an empty body, and Subsonic answers `ok`. Neither says what it stored.

  So "added 6" means "asked to add 6 and was not refused", and the gap between
  that and "6 are there" is exactly the failure this application is organised
  against — a transfer that finishes, reports success, and is wrong.

  It is not hypothetical. A six-track append to a Subsonic server arrived as a
  one-track append, because Req merges same-named query parameters and Subsonic
  expresses a collection as a repeated one. The server answered `ok`, the
  adapter reported six, and five tracks were gone. Nothing in the suite could
  have caught it, because every layer was faithfully reporting what the layer
  below told it.

  So the runner re-reads the destination after writing and compares. One extra
  request per transfer, and it converts a silent lie into a visible failure.

  ## Retryable, deliberately

  The runner's writes are a diff against the destination, so a retry adds
  exactly what is still missing. If the cause was transient the retry fixes it;
  if it is structural the transfer fails visibly after its attempts are spent,
  which is the correct outcome and the one a user can act on.
  """

  use Errata.InfrastructureError,
    default_message: "some tracks did not reach the destination playlist",
    default_reason: :missing_after_write,
    reasons: [:missing_after_write],
    http_status: 502,
    code: "TRANSFER_WRITE_NOT_CONFIRMED"

  def retryable?(_error), do: true

  def display_message(%{context: %{missing: missing}}) when is_list(missing) do
    "#{length(missing)} track(s) were written to the destination but are not there — " <>
      "the transfer will be retried"
  end

  def display_message(error), do: error.message
end
