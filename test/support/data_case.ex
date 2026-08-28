defmodule OnePlaylist.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use OnePlaylist.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias OnePlaylist.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import OnePlaylist.DataCase
    end
  end

  setup tags do
    OnePlaylist.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(OnePlaylist.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  The enrichment attempt on a recording, or `nil` if it has never been asked
  about.

  Since `docs/reference/domain.md` §6 split enrichment's bookkeeping off the
  recording, "never looked at" is the **absence of a row** rather than a null
  column — so `refute attempt(recording)` is the assertion that used to be
  written `refute recording.enriched_at`.

  Takes a recording or its id, and always re-reads, because most callers are
  checking what a background job did to a struct they are still holding.
  """
  def attempt(%OnePlaylist.Library.Recording{id: id}), do: attempt(id)

  def attempt(id) when is_binary(id) do
    OnePlaylist.Repo.get_by(OnePlaylist.Library.RecordingEnrichment, recording_id: id)
  end

  @doc """
  Marks every recording already in the database as looked at just now.

  Recordings belong to nobody, so a test of `Enrichment.due/1` has no user to
  scope to and the dev rows sharing the `postgres` database would otherwise fill
  the answer. Settling them inside the sandbox *is* the scoping — it rolls back
  with the rest of the test.

  One statement rather than a row at a time: the dev library is several hundred
  recordings and this runs in three tests.
  """
  def settle_existing_enrichment do
    import Ecto.Query

    now = DateTime.utc_now()
    engine = OnePlaylist.Library.Enrichment.engine()

    {_count, _returned} =
      OnePlaylist.Repo.insert_all(
        OnePlaylist.Library.RecordingEnrichment,
        from(r in OnePlaylist.Library.Recording,
          select: %{
            id: fragment("gen_random_uuid()"),
            recording_id: r.id,
            attempted_at: ^now,
            engine: ^engine
          }
        ),
        on_conflict: {:replace, [:attempted_at, :engine]},
        conflict_target: [:recording_id]
      )

    :ok
  end

  @doc """
  Records that a recording has been looked at, and answers the recording.

  The fixture counterpart to `attempt/1`, for the tests that need a recording
  which `Enrichment.due/1` should or should not offer. `attempted_at` defaults to
  now and `engine` to the current fingerprint, which between them make the
  common case — "this one has already been done" — a call with no options.
  """
  def attempted(recording, attrs \\ %{})

  def attempted(%OnePlaylist.Library.Recording{} = recording, attrs) do
    attrs =
      Map.merge(
        %{
          recording_id: recording.id,
          attempted_at: DateTime.utc_now(),
          engine: OnePlaylist.Library.Enrichment.engine()
        },
        Map.new(attrs)
      )

    {:ok, attempt} =
      %OnePlaylist.Library.RecordingEnrichment{}
      |> OnePlaylist.Library.RecordingEnrichment.changeset(attrs)
      |> OnePlaylist.Repo.insert(
        on_conflict: {:replace, [:attempted_at, :outcome, :candidates, :engine]},
        conflict_target: [:recording_id]
      )

    # Attached, the way `Enrichment.enrich/1` attaches it. A test that broadcasts
    # this recording is then sending what the real pipeline sends, rather than a
    # struct whose association would raise on the first read.
    %OnePlaylist.Library.Recording{recording | enrichment: attempt}
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
