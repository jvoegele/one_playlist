defmodule OnePlaylist.Library.EnrichmentWorkerTest do
  @moduledoc """
  Queueing enrichment, and the sweep that keeps queueing it.

  What matters here is not that the job runs — `OnePlaylist.Library.Enrichment`
  is tested directly — but that the right recordings reach the queue and the
  wrong ones do not. Enrichment costs one request a second, so a duplicate job
  is a real waste and a missing one is a recording nobody ever identifies.
  """

  use OnePlaylist.DataCase, async: false
  use Oban.Testing, repo: OnePlaylist.Repo, prefix: "oban"

  alias OnePlaylist.Library
  alias OnePlaylist.Library.EnrichmentSweeper
  alias OnePlaylist.Library.EnrichmentWorker
  alias OnePlaylist.Library.Recording
  alias OnePlaylist.Music.Track

  # `ZZ` is an unassigned ISRC country code, so a fixture cannot collide with
  # music somebody imported into the dev database this shares. See
  # `OnePlaylist.LibraryTest` for why that is a live concern here and nowhere
  # else.
  defp unique_isrc do
    "ZZZ9925" <>
      String.pad_leading(to_string(rem(System.unique_integer([:positive]), 100_000)), 5, "0")
  end

  defp track(attrs \\ %{}) do
    struct!(
      %Track{
        provider: :tidal,
        provider_id: "t-#{System.unique_integer([:positive])}",
        title: "Corduroy",
        artists: ["Pearl Jam"],
        isrc: unique_isrc()
      },
      attrs
    )
  end

  describe "enqueueing on arrival" do
    test "a newly stored recording is queued" do
      stored = Library.find_or_create(track())

      assert_enqueued(worker: EnrichmentWorker, args: %{recording_id: stored.id})
    end

    test "a recording it already held is not queued again" do
      # A playlist imported twice names mostly the same recordings. Re-queueing
      # each arrival would spend the enrichment budget re-asking about music the
      # application has already looked up.
      isrc = unique_isrc()
      stored = Library.find_or_create(track(%{isrc: isrc}))

      Oban.Job
      |> Ecto.Query.where([j], j.worker == "OnePlaylist.Library.EnrichmentWorker")
      |> Repo.delete_all(prefix: "oban")

      assert Library.find_or_create(track(%{isrc: isrc})).id == stored.id

      refute_enqueued(worker: EnrichmentWorker, args: %{recording_id: stored.id})
    end
  end

  describe "the worker" do
    test "cancels rather than retries when the recording is gone" do
      # Recordings are never deleted by the application — deleting a playlist
      # deliberately leaves them — so this is only reachable by hand, and no
      # number of attempts brings the row back.
      assert {:cancel, :recording_deleted} =
               perform_job(EnrichmentWorker, %{recording_id: Ecto.UUID.generate()})
    end
  end

  describe "deciding whether to try again" do
    test "an unreachable source snoozes rather than giving up" do
      # The error says what to do about itself. Before this the worker branched
      # on the *shape* of what came back, which worked and said nothing about
      # why — and a queue dashboard showing `:archive_unreachable` is worth the
      # error type on its own.
      error = OnePlaylist.Library.EnrichmentUnavailable.new(reason: :archive_unreachable)

      assert Errata.retryable?(error)
    end

    test "asking a non-Errata error whether it is retryable raises" do
      # Worth pinning, because it is the whole reason the worker guards with
      # `is_error/1`. `Errata.retryable?/1` is documented as *the* decision
      # function — `if Errata.retryable?(error), do: retry()` — and it cannot be
      # used that way at a boundary where a changeset or a `Req` error can
      # arrive, which at an Oban worker is always.
      assert_raise ArgumentError, fn -> Errata.retryable?(%Ecto.Changeset{}) end
    end
  end

  describe "the nightly sweep" do
    test "queues the never-enriched and leaves the freshly asked alone" do
      Repo.update_all(Recording, set: [enriched_at: DateTime.utc_now()])

      never = Library.find_or_create(track())
      asked = Library.find_or_create(track())
      {:ok, _asked} = Repo.update(Ecto.Changeset.change(asked, enriched_at: DateTime.utc_now()))

      Oban.Job
      |> Ecto.Query.where([j], j.worker == "OnePlaylist.Library.EnrichmentWorker")
      |> Repo.delete_all(prefix: "oban")

      assert :ok = perform_job(EnrichmentSweeper, %{})

      assert_enqueued(worker: EnrichmentWorker, args: %{recording_id: never.id})
      refute_enqueued(worker: EnrichmentWorker, args: %{recording_id: asked.id})
    end
  end
end
