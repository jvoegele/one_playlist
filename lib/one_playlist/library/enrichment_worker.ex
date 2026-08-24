defmodule OnePlaylist.Library.EnrichmentWorker do
  @moduledoc """
  The Oban job that enriches one recording.

  Thin, like `OnePlaylist.Transfers.TransferWorker`: everything worth reading is
  in `OnePlaylist.Library.Enrichment`, which is a plain function over a recording
  and testable without a queue in the way.

  ## A queue of one, because MusicBrainz asks for one request a second

  `enrichment: 1` in `config/config.exs`. Two concurrent workers would not go
  twice as fast — `OnePlaylist.MusicBrainz.Service` rate-limits to one request a
  second regardless — they would only queue behind each other inside the
  limiter, holding an Oban slot and a database connection while they waited.

  So the concurrency that matters is set once, in the limiter, and the queue is
  sized to match it rather than to fight it.

  ## Snoozing rather than retrying

  A recording that could not be enriched because MusicBrainz was unreachable is
  not a failed job in any interesting sense; nothing is wrong and nothing needs
  attention. It snoozes for a minute, which leaves the queue free for recordings
  whose lookups are working.

  Snoozing is close to unbounded — Oban raises `max_attempts` alongside the
  attempt it consumes — so it is reserved for the failure that genuinely
  resolves itself. A write that will not go through does not: a rejected
  changeset will be rejected identically in a minute, so it is cancelled rather
  than snoozed, and `max_attempts: 3` then covers the faults that are neither.

  ## Nothing here is urgent

  Enrichment is a strict improvement on data that already works. A playlist
  displays, transfers and exports perfectly well un-enriched; every field this
  fills in is one that was `nil` and would have stayed `nil`. That is why it is
  a background job at the lowest possible concurrency and why failing quietly is
  the right behaviour — there is no user waiting, and no user harmed.
  """

  use Oban.Worker,
    queue: :enrichment,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      # A recording already queued does not need queueing again — a playlist
      # imported twice names many of the same recordings, and `find_or_create/1`
      # enqueues for each. Completed jobs are excluded so a recording can be
      # re-enriched later, which is what `Enrichment.due/1` is for.
      states: Oban.Job.states() -- [:completed, :discarded, :cancelled]
    ]

  alias OnePlaylist.Library.Enrichment
  alias OnePlaylist.Library.Recording
  alias OnePlaylist.Repo

  require Logger

  import Errata, only: [is_error: 1]

  @doc """
  Queues one recording for enrichment.

  Answers `:ok` however it goes, including when the job is a duplicate of one
  already queued. Callers are creating a recording, and a recording that failed
  to be *scheduled* for enrichment is still a perfectly good recording — failing
  their write over it would trade something that matters for something that does
  not.
  """
  @spec enqueue(Ecto.UUID.t()) :: :ok
  def enqueue(recording_id) do
    case %{recording_id: recording_id} |> new() |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("could not enqueue enrichment for #{recording_id}: #{inspect(reason)}")
        :ok
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"recording_id" => recording_id}}) do
    case Repo.get(Recording, recording_id) do
      nil ->
        # Recordings are never deleted by the application — deleting a playlist
        # deliberately leaves them, because they belong to nobody. So this is
        # only reachable by hand, and no number of retries will bring the row
        # back.
        Logger.warning("recording #{recording_id} no longer exists; discarding job")
        {:cancel, :recording_deleted}

      recording ->
        enrich(recording)
    end
  end

  # The error says what to do about itself. Before this the worker branched on
  # the *shape* of what came back — a `%Ecto.Changeset{}` meant give up and
  # anything else meant retry — which worked and said nothing about why.
  #
  # `Errata.retryable?/1` **raises** on anything that is not an Errata error, so
  # it cannot be asked directly at a boundary where a changeset or a `Req` error
  # can arrive. `is_error/1` is the guard that makes it safe, and anything else
  # is not retryable: a rejected changeset will be rejected identically in a
  # minute.
  defp enrich(recording) do
    case Enrichment.enrich(recording) do
      {:ok, _enriched} ->
        :ok

      {:error, reason} when is_error(reason) ->
        if Errata.retryable?(reason) do
          {:snooze, 60}
        else
          give_up(recording, reason)
        end

      {:error, reason} ->
        give_up(recording, reason)
    end
  end

  defp give_up(recording, reason) do
    Logger.warning("enrichment of #{recording.id} gave up: #{inspect(reason)}")

    {:cancel, :not_retryable}
  end
end
