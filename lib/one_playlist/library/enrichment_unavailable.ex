defmodule OnePlaylist.Library.EnrichmentUnavailable do
  @moduledoc """
  A source enrichment needed could not be asked.

  Not "there is nothing to find" — that is an *outcome* and is recorded on the
  recording itself as `enrichment_outcome`. This is the other thing entirely: the
  question could not be put, so nothing was learned and nothing should be
  concluded.

  ## Why this is an error type rather than an atom

  Because something has to decide what to do about it, and that decision is the
  error's own business rather than the caller's. `retryable?/1` answers it:
  `OnePlaylist.Library.EnrichmentWorker` snoozes and tries again instead of
  branching on the *shape* of whatever came back, which is what it did before —
  a `%Ecto.Changeset{}` meant give up and anything else meant retry. That worked
  and said nothing about why.

  The `reason` also survives the boundary. An Oban job that discards carries its
  last error into a queue dashboard, and `:archive_unreachable` there is worth
  the whole of this module.

  Infrastructure rather than domain: nothing about the user's music is wrong,
  and there is nothing they could do differently.
  """

  use Errata.InfrastructureError,
    default_message: "a source enrichment needs could not be reached",
    default_reason: :archive_unreachable,
    reasons: [
      # Cover Art Archive could not be asked whether an album has a cover. The
      # first version of enrichment treated this as "no cover" and stamped the
      # recording as fully looked at, which made an outage permanent — see
      # `OnePlaylist.Library.Enrichment`.
      :archive_unreachable,
      # MusicBrainz could not be searched. Distinct from a search that returned
      # nothing, which is a fact about the catalogue and is recorded as one.
      :search_unavailable
    ],
    http_status: 503,
    code: "ENRICHMENT_UNAVAILABLE"
end
