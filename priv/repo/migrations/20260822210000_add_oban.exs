defmodule OnePlaylist.Repo.Migrations.AddOban do
  use Ecto.Migration

  @moduledoc """
  Oban's job tables, in a schema of their own.

  `prefix: "oban"` rather than `public`, for the reason the migration
  convention in `CLAUDE.md` exists at all: a table in `public` starts out
  partially granted to `anon` and `authenticated`, and Oban's tables are not
  ours to write policies for. Putting them in their own schema keeps them off
  the surface PostgREST exposes without this project having to track whatever
  columns Oban adds in a future version.

  Nothing else in this application uses a non-`public` schema, so this is the
  one place that difference is stated.
  """

  def up do
    execute "create schema if not exists oban", "drop schema if exists oban cascade"

    # Neither role should see the queue at all. `anon` and `authenticated` reach
    # Postgres only through PostgREST, and a job's `args` can carry anything a
    # caller put there.
    execute "revoke all on schema oban from anon, authenticated",
            "grant usage on schema oban to anon, authenticated"

    Oban.Migration.up(version: 14, prefix: "oban")
  end

  def down do
    Oban.Migration.down(version: 1, prefix: "oban")

    execute "drop schema if exists oban cascade"
  end
end
