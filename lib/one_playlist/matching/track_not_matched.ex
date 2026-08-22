defmodule OnePlaylist.Matching.TrackNotMatched do
  @moduledoc """
  No candidate met the confidence threshold for this track.

  ## This is a value, not a failure

  A transfer that reaches this is working correctly. Some tracks have no
  counterpart on the destination — local files, podcasts, regional exclusives,
  recordings the other service simply does not carry — and the honest outcome
  is to say so per track and carry on.

  What must never happen is the alternative: dropping the track and reporting a
  complete transfer. So this error carries everything needed to explain the
  decision to a person and to let them fix it by hand:

    * `source` — the track that failed to match, in full.
    * `candidates_considered` — how many were looked at. Zero means the search
      found nothing; a number means nothing was good enough, which is a
      different problem with a different fix.

  The reasons are separated for the same purpose. `:all_rejected` in particular
  is worth its own line in a report: it means candidates *were* found and every
  one was disqualified as a different recording — a live take, a karaoke
  version. "We found `Yesterday (Karaoke Version)` and refused it" is a far
  better thing to tell someone than "not found", and it is the case where the
  engine most deserves credit rather than suspicion.
    * `best_score` and `best_confidence` — how close the nearest miss came.
    * `threshold` — what it needed to beat, so a user who lowers the threshold
      can see which tracks that would recover.

  A near miss at 0.74 against a 0.75 threshold and a total absence are both
  "unmatched", and telling them apart is most of what makes a transfer report
  worth reading.

  `retryable?/1` is `false` in every case. The catalogue will not have changed
  by the next attempt, and retrying spends provider quota to reach the same
  answer — an unmatched track needs a person or a different threshold, not
  another request.
  """

  use Errata.DomainError,
    default_message: "no confident match was found for this track",
    default_reason: :below_threshold,
    reasons: [:below_threshold, :all_rejected, :no_candidates, :unsearchable],
    http_status: 422,
    code: "TRACK_NOT_MATCHED"

  def retryable?(_error), do: false

  def display_message(%{reason: :no_candidates, context: context}),
    do: "#{describe(context)} was not found on the destination service"

  def display_message(%{reason: :all_rejected, context: context}),
    do:
      "#{describe(context)} — #{candidate_count(context)} found, " <>
        "but each was a different recording"

  def display_message(%{reason: :unsearchable, context: context}),
    do: "#{describe(context)} has too little information to search for"

  def display_message(%{context: %{best_confidence: :none} = context}),
    do: "nothing on the destination service resembled #{describe(context)}"

  def display_message(%{context: context}),
    do: "the closest match for #{describe(context)} was not confident enough"

  def display_message(error), do: error.message

  # Enough to identify the track in a report line without dumping the struct.
  defp describe(%{source: %{title: title, artists: [artist | _rest]}})
       when is_binary(title),
       do: "“#{title}” by #{artist}"

  defp describe(%{source: %{title: title}}) when is_binary(title), do: "“#{title}”"
  defp describe(_context), do: "this track"

  defp candidate_count(%{candidates_considered: 1}), do: "1 candidate was"
  defp candidate_count(%{candidates_considered: count}), do: "#{count} candidates were"
  defp candidate_count(_context), do: "candidates were"
end
