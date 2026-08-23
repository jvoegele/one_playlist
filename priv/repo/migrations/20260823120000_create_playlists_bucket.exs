defmodule OnePlaylist.Repo.Migrations.CreatePlaylistsBucket do
  @moduledoc """
  A private Supabase Storage bucket for playlist files, with policies.

  ## Why this is an Ecto migration rather than a `supabase/migrations` one

  `storage.buckets` and `storage.objects` are Supabase's tables, so the bucket
  could reasonably be created either side of that line. It lives here because
  this is the schema *this application* depends on: `mix ecto.reset` runs
  `supabase db reset` and then these, so a bucket created here survives a reset
  while one created by hand in Studio does not.

  ## The path convention is the security model

  Every object is stored at `<user_id>/<kind>/<name>`, and the policies below
  compare `auth.uid()` against the **first folder** of that path. There is no
  ownership column on `storage.objects` to key on — Supabase's own convention is
  exactly this, and it means the path is not a naming nicety but the thing that
  decides who can read a file.

  `OnePlaylist.Storage` is the only module that builds these paths, for that
  reason.
  """

  use Ecto.Migration

  @bucket "playlists"

  # Generous for the job: a 58-track CSV is 3 KB, and a hundred thousand tracks
  # would be about five megabytes. Enforced by Storage before any bytes are
  # persisted, which is what makes it worth setting here rather than in the
  # application.
  @size_limit 5 * 1024 * 1024

  def up do
    # `allowed_mime_types` is deliberately left null. A browser reports whatever
    # it likes for a `.csv` — `text/csv`, `text/plain`,
    # `application/vnd.ms-excel`, or `application/octet-stream` depending on
    # what the operating system has registered — so a restriction here rejects
    # legitimate uploads and stops nothing, the value being client-supplied.
    # `OnePlaylist.Formats.Csv.parse/2` is the real gate, and it reads the bytes.
    execute """
            insert into storage.buckets (id, name, public, file_size_limit)
            values ('#{@bucket}', '#{@bucket}', false, #{@size_limit})
            on conflict (id) do nothing
            """,
            "delete from storage.buckets where id = '#{@bucket}'"

    # `storage.objects` already has row level security enabled and — until now —
    # no policies at all, which is deny-by-default and the right starting point.
    # `authenticated` also already holds every grant on it, Supabase having
    # granted them: so these policies are the *only* thing standing between one
    # user's uploads and another's.
    for {action, clause} <- [
          {"select", "using"},
          {"insert", "with check"},
          {"update", "using"},
          {"delete", "using"}
        ] do
      execute """
              create policy "own playlist files #{action}" on storage.objects
                for #{action} to authenticated
                #{clause} (
                  bucket_id = '#{@bucket}'
                  and (select auth.uid())::text = (storage.foldername(name))[1]
                )
              """,
              ~s|drop policy "own playlist files #{action}" on storage.objects|
    end

    # `update` needs both halves: `using` decides which rows may be touched, and
    # without a `with check` a user could move their own object *into* somebody
    # else's folder — passing the read test on the way in and landing where they
    # should not be able to write.
    execute """
            alter policy "own playlist files update" on storage.objects
              with check (
                bucket_id = '#{@bucket}'
                and (select auth.uid())::text = (storage.foldername(name))[1]
              )
            """,
            ~s|select 1|
  end

  def down do
    for action <- ~w(select insert update delete) do
      execute ~s|drop policy if exists "own playlist files #{action}" on storage.objects|
    end

    execute "delete from storage.objects where bucket_id = '#{@bucket}'"
    execute "delete from storage.buckets where id = '#{@bucket}'"
  end
end
