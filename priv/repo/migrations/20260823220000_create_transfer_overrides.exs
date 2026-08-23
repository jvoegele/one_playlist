defmodule OnePlaylist.Repo.Migrations.CreateTransferOverrides do
  @moduledoc """
  Letting a person correct a match the engine got wrong.

  ## Why an override is a separate table rather than a column on the report

  `OnePlaylist.Transfers.record_run/3` writes the report with
  `on_conflict: {:replace_all_except, [:id, :inserted_at]}` on
  `[:transfer_id, :position]`. A transfer is re-run routinely — the pipeline is
  snapshot-and-diff and resumable, and Oban retries a failure — so every row of
  `transfer_items` is rewritten by the next run.

  A correction stored *on* that row would therefore be destroyed by a retry,
  and the symptom would be the worst kind: a correction that silently did not
  stick, with nothing in the logs and a report that looks like it was never
  touched.

  So an override is an **input** to a run rather than a patch on its output.
  `Runner` consults this table before running the matching ladder, which makes
  an override behave exactly like a very high confidence match and leaves the
  dedup, the batching, the counters and the report untouched.

  ## Scoped to one transfer, on purpose, for now

  The key is `(transfer_id, position)`. The obvious wish is to remember a
  correction across transfers — "this track is that one on TIDAL" — and the
  reason not to yet is that there is no good key for it.

  `transfer_items.source_track_id` is a real provider id for a TIDAL or
  Subsonic source, and for a CSV it is the **row number**
  (`OnePlaylist.Formats.Csv` assigns `Integer.to_string(position)`). Keyed on
  that, a correction made against row 3 of one import would be applied to row 3
  of an unrelated one. ISRC is a sound key and useless here: a track with an
  ISRC almost always matched by ISRC and needed no correction. Normalized
  artist and title is the honest candidate and wants evidence before it is
  committed to.

  Widening this later is additive — a `track_corrections` table consulted
  first, this one second — so nothing here has to be undone.
  """

  use Ecto.Migration

  def up do
    # Five is enough to choose from and small enough that a report full of them
    # stays a reasonable row. See `OnePlaylist.Transfers.Candidate`.
    alter table(:transfer_items) do
      # What the winning rung considered and rejected, kept so that a person
      # deciding between them needs no provider call. Populated only for items
      # that did not match by exact identifier: nobody overrides an ISRC match,
      # and keeping candidates for every track of a 5,000 track transfer is
      # megabytes of rows nobody will open.
      add :candidates, {:array, :map}, default: []
    end

    create table(:transfer_overrides, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :transfer_id, references(:transfers, on_delete: :delete_all, type: :binary_id),
        null: false

      # Denormalized for the same reason `transfer_items.user_id` is: an RLS
      # policy comparing against auth.uid() directly, rather than an EXISTS
      # subquery evaluated per row.
      add :user_id, references(:users, on_delete: :delete_all, type: :uuid, prefix: "auth"),
        null: false

      add :position, :integer, null: false

      add :destination_track_id, :text, null: false

      # Enough to render the report row without asking the provider again. The
      # destination track is already in hand when the override is made, and a
      # correction whose display needs a network call is a correction that shows
      # a spinner where it should show an answer.
      add :destination_title, :text
      add :destination_artist, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # One correction per track. A second correction of the same track replaces
    # the first, which is what changing your mind should do.
    create unique_index(:transfer_overrides, [:transfer_id, :position])

    # --- Authorization -------------------------------------------------------
    #
    # The `auth.uid()` shape, as for `transfers` and `transfer_items`.
    execute "alter table public.transfer_overrides enable row level security",
            "alter table public.transfer_overrides disable row level security"

    execute "revoke all on table public.transfer_overrides from anon, authenticated",
            "grant all on table public.transfer_overrides to anon, authenticated"

    # Read only, like the report. An override is written by the application
    # after it has confirmed the chosen track was accepted by the destination,
    # so a client able to insert one directly could claim a track had been added
    # that never was.
    execute "grant select on table public.transfer_overrides to authenticated",
            "revoke select on table public.transfer_overrides from authenticated"

    execute """
            create policy "own transfer_overrides select" on public.transfer_overrides
              for select to authenticated using ((select auth.uid()) = user_id)
            """,
            ~s|drop policy "own transfer_overrides select" on public.transfer_overrides|
  end

  def down do
    drop table(:transfer_overrides)

    alter table(:transfer_items) do
      remove :candidates
    end
  end
end
