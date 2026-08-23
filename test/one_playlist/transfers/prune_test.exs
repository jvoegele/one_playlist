defmodule OnePlaylist.Transfers.PruneTest do
  @moduledoc """
  `public.prune_transfer_sources/1`, the nightly tidy-up behind finished imports.

  Tested through SQL rather than through a context function, because that is
  what it is: `pg_cron` calls it, and no Elixir code does. A test that went
  through a wrapper would be testing the wrapper.
  """

  use OnePlaylist.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias OnePlaylist.AuthFixtures
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Transfers.Source
  alias OnePlaylist.Transfers.Transfer

  defp transfer_with_source(user_id, status, finished_ago_days) do
    {:ok, transfer} =
      %Transfer{}
      |> Transfer.create_changeset(%{
        user_id: user_id,
        source_provider: :file,
        source_playlist_id: "#{user_id}/imports/x.csv",
        source_playlist_name: "x.csv",
        destination_provider: :tidal,
        threshold: 0.75
      })
      |> Repo.insert()

    {:ok, _source} =
      transfer.id
      |> Source.changeset(user_id, [%Track{provider: :file, provider_id: "1", title: "A"}], :csv)
      |> Repo.insert()

    # Set status and age directly: `updated_at` is what the function keys on,
    # and the changesets will not let a test claim a transfer finished last week.
    _ =
      SQL.query!(
        Repo,
        "update public.transfers set status = $1, updated_at = now() - ($2 || ' days')::interval where id = $3",
        [to_string(status), to_string(finished_ago_days), Ecto.UUID.dump!(transfer.id)]
      )

    transfer
  end

  defp prune(days) do
    %{rows: [[removed]]} =
      SQL.query!(Repo, "select public.prune_transfer_sources(($1 || ' days')::interval)", [
        to_string(days)
      ])

    removed
  end

  defp source_exists?(transfer), do: Repo.get(Source, transfer.id) != nil

  setup do
    %{user_id: AuthFixtures.user_id_fixture()}
  end

  test "removes the parsed tracks of a transfer that finished long ago", %{user_id: user} do
    old = transfer_with_source(user, :completed, 30)

    assert prune(7) >= 1
    refute source_exists?(old)
  end

  test "leaves a transfer that finished recently", %{user_id: user} do
    recent = transfer_with_source(user, :completed, 1)

    _ = prune(7)

    assert source_exists?(recent)
  end

  test "leaves an unfinished transfer however old it is" do
    # A job stuck for a month still needs its tracks. Pruning them would turn a
    # stalled transfer into one that fails with SourceMissing.
    user = AuthFixtures.user_id_fixture()
    stuck = transfer_with_source(user, :running, 90)
    queued = transfer_with_source(user, :pending, 90)

    _ = prune(7)

    assert source_exists?(stuck)
    assert source_exists?(queued)
  end

  test "a failed transfer is finished too", %{user_id: user} do
    # `failed` is as final as `completed` for this purpose: the run is over and
    # the report has been written.
    failed = transfer_with_source(user, :failed, 30)

    _ = prune(7)

    refute source_exists?(failed)
  end

  test "the transfer itself survives, and so does its file", %{user_id: user} do
    # The row is a cache of a parse. The record is the file in Storage, named by
    # source_playlist_id, and pruning must not touch either.
    old = transfer_with_source(user, :completed, 30)

    _ = prune(7)

    assert %Transfer{} = kept = Repo.get(Transfer, old.id)
    assert kept.source_playlist_id == old.source_playlist_id
  end

  test "reports how many rows it removed", %{user_id: user} do
    _ = transfer_with_source(user, :completed, 30)
    _ = transfer_with_source(user, :completed, 30)
    _ = transfer_with_source(user, :completed, 1)

    # A delta rather than an absolute. The sandbox rolls back other tests' rows,
    # but `dev` and `test` share this database, so an absolute count would break
    # the first time somebody's own import aged past the threshold.
    before = Repo.aggregate(Source, :count)
    removed = prune(7)

    assert removed == before - Repo.aggregate(Source, :count)
    assert removed >= 2
  end
end
