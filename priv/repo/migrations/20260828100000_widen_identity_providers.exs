defmodule OnePlaylist.Repo.Migrations.WidenIdentityProviders do
  use Ecto.Migration

  @moduledoc """
  Lets the identity spine hold a Spotify id.

  `create_recording_identities` wrote its provider list out by hand and said why:
  "written out rather than derived so that adding a provider is a deliberate
  migration rather than a silent widening." The intent was right and the
  enforcement was inverted — what it actually produced was a silent **narrowing**.

  Spotify arrived on 2026-08-26 and neither this constraint nor
  `OnePlaylist.Library.Identity`'s `Ecto.Enum` was widened. The enum is what made
  it silent: casting `provider: :spotify` failed validation, `Repo.insert`
  answered `{:error, changeset}` rather than raising, and `Identities.record/4`
  discards that result and answers `:ok` — deliberately, so that a spine which
  fails to learn never fails the transfer it was learning from.

  So every Spotify transfer declined to record the thing §5 calls "the asset that
  compounds", and said nothing. Measured before the fix: 6 recordings whose
  `origin_provider` is `spotify`, and **0** Spotify identities.

  Two changes stop it recurring. The enum is now derived from
  `OnePlaylist.Providers.Connection.providers/0` rather than restated, so the
  application layer cannot drift from the provider list again. And this
  constraint is deliberately kept *no wider* than that list, so if the two ever
  do diverge the failure is a raised `Ecto.ConstraintError` rather than silence.

  `file` is absent from both, and correctly: a file has no ids to remember, and
  `record/4` refuses it in a clause of its own.
  """

  @providers ~w(library spotify apple_music youtube_music tidal deezer plex jellyfin navidrome subsonic)
  @was ~w(tidal subsonic navidrome library)

  defp check(providers) do
    list = Enum.map_join(providers, ", ", &"'#{&1}'")

    """
    alter table public.recording_identities
      add constraint recording_identities_provider_check
      check (provider in (#{list}))
    """
  end

  @drop "alter table public.recording_identities drop constraint recording_identities_provider_check"

  def up do
    execute @drop
    execute check(@providers)
  end

  def down do
    execute @drop
    execute check(@was)
  end
end
