defmodule OnePlaylist.Library do
  @moduledoc """
  Playlists One Playlist holds itself.

  The context behind `OnePlaylist.Providers.Library`, which is the adapter that
  makes all of this reachable as an ordinary transfer endpoint. See
  `docs/reference/domain.md` §5 for why the application became a place playlists
  live rather than only a pipe between services.

  ## Two stores, two owners

  `OnePlaylist.Library.Recording` belongs to nobody and is shared;
  `OnePlaylist.Library.Playlist` and its items belong to a user. Reads of the
  user's half go through `OnePlaylist.Repo.as_user/3`, so a forgotten scope
  returns nothing rather than somebody else's playlists. Writes stay privileged,
  exactly as the transfer pipeline owns `transfers`.

  ## Deduplication is the library's version of matching

  Everywhere else in this application a failure to match is a failure: the
  destination catalogue does not carry the recording and the track cannot be
  transferred. The library has no catalogue and can hold anything, so the
  question is not *can this be stored* but *do we already have it* — and a miss
  means **create**, not "unmatched".

  That inverts the risk. Transferring out of the library risks a wrong match;
  transferring into it risks a **duplicate recording**, stored twice because the
  second arrival was not recognised. So `find_or_create/1` is deliberately
  conservative about what counts as the same recording — see its documentation —
  and merging two recordings that turn out to be one is left to a later,
  reversible operation rather than guessed at here. Merging is destructive in a
  way that adding is not.
  """

  import Ecto.Query

  alias OnePlaylist.Library.Playlist
  alias OnePlaylist.Library.PlaylistItem
  alias OnePlaylist.Library.Recording
  alias OnePlaylist.Music.Isrc
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Repo

  use Bond

  @doc """
  A user's library playlists, most recently made first, with their sizes.

  One query for the playlists and one for every count, rather than a count per
  playlist: a user with fifty playlists should not cost fifty round trips to
  render a list.
  """
  @spec playlists(Ecto.UUID.t()) :: [{Playlist.t(), non_neg_integer()}]
  def playlists(user_id) do
    {:ok, found} =
      Repo.as_user(user_id, fn ->
        playlists =
          Playlist
          |> where(user_id: ^user_id)
          |> order_by(desc: :inserted_at)
          |> Repo.all()

        counts =
          PlaylistItem
          |> where([i], i.playlist_id in ^Enum.map(playlists, & &1.id))
          |> group_by([i], i.playlist_id)
          |> select([i], {i.playlist_id, count(i.id)})
          |> Repo.all()
          |> Map.new()

        Enum.map(playlists, &{&1, Map.get(counts, &1.id, 0)})
      end)

    found
  end

  @doc """
  One of a user's playlists, or `:error`.

  Scoped like `OnePlaylist.Transfers.fetch/2`, and for the same reason: a
  playlist belonging to somebody else is indistinguishable from one that does
  not exist, so an id is not a way to learn what exists.
  """
  @spec fetch_playlist(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Playlist.t()} | :error
  def fetch_playlist(user_id, id) do
    {:ok, found} =
      Repo.as_user(user_id, fn -> Repo.get_by(Playlist, id: id, user_id: user_id) end)

    case found do
      nil -> :error
      playlist -> {:ok, playlist}
    end
  end

  @doc "Creates an empty playlist."
  @spec create_playlist(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, Playlist.t()} | {:error, Ecto.Changeset.t()}
  def create_playlist(user_id, name, opts \\ []) do
    %Playlist{}
    |> Playlist.changeset(%{
      user_id: user_id,
      name: name,
      description: Keyword.get(opts, :description)
    })
    |> Repo.insert()
  end

  @doc """
  A playlist's recordings, in order.
  """
  @spec tracks(Ecto.UUID.t(), Ecto.UUID.t()) :: [Track.t()]
  def tracks(user_id, playlist_id) do
    query =
      from(i in PlaylistItem,
        join: r in Recording,
        on: r.id == i.recording_id,
        where: i.playlist_id == ^playlist_id,
        order_by: [asc: i.position, asc: i.inserted_at],
        select: r
      )

    {:ok, recordings} = Repo.as_user(user_id, fn -> Repo.all(query) end)

    Enum.map(recordings, &Recording.to_track/1)
  end

  @doc """
  Appends recordings to a playlist, returning how many went in.

  Appends without deduplicating *within the playlist*, exactly as every provider
  adapter does — deciding what to add is `OnePlaylist.Transfers.Runner`'s job,
  which is the only thing that can see both sides. Deduplication of
  **recordings** is a different question and is `find_or_create/1`'s.
  """
  # Conservation, in the same shape the adapter callback states: a store that
  # reported adding more than it was given would inflate every report built on
  # it, and the inflation would be invisible.
  @post never_more_than_offered: result <= length(tracks)
  @spec append(Ecto.UUID.t(), Ecto.UUID.t(), [Track.t()]) :: non_neg_integer()
  def append(user_id, playlist_id, tracks) do
    start = next_position(playlist_id)

    entries =
      tracks
      |> Enum.with_index(start)
      |> Enum.map(fn {track, position} ->
        recording = find_or_create(track)

        %{
          id: Ecto.UUID.generate(),
          playlist_id: playlist_id,
          user_id: user_id,
          recording_id: recording.id,
          position: position,
          inserted_at: DateTime.utc_now()
        }
      end)

    {count, _returned} = Repo.insert_all(PlaylistItem, entries)

    count
  end

  @doc """
  Removes every entry naming any of these recordings, returning how many went.

  Every occurrence, for the reason
  `c:OnePlaylist.Providers.Adapter.remove_tracks/4` gives: the caller's question
  is "this should not be here", which makes calling it twice harmless.
  """
  @spec remove(Ecto.UUID.t(), [Track.t()]) :: non_neg_integer()
  def remove(playlist_id, tracks) do
    ids = Enum.map(tracks, & &1.provider_id)

    {count, _returned} =
      PlaylistItem
      |> where([i], i.playlist_id == ^playlist_id and i.recording_id in ^ids)
      |> Repo.delete_all()

    count
  end

  @doc """
  Recordings that might be the same as this track, best evidence first.

  What the library offers the matching engine when it is a destination, and the
  reason a transfer into the library deduplicates instead of piling up copies.
  The ladder in `OnePlaylist.Matching` then decides; this only narrows.

  Searches the **shared** recording store rather than the user's own rows, which
  is deliberate. A recording another user caused to be stored is the same
  recording, and reusing its row is the whole point of the store belonging to
  nobody — that is §5's asset that compounds. It leaks nothing: the row says
  what the music is, never who has it.
  """
  @spec search(Track.t(), pos_integer()) :: [Track.t()]
  def search(%Track{} = track, limit) do
    track
    |> candidate_query()
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&Recording.to_track/1)
  end

  # ISRC first, always, for the reason every other adapter tries it first: it is
  # exact and it is one index hit. Title is the fallback, lower-cased to match
  # the index, and deliberately not fuzzy — narrowing is this function's job and
  # deciding is the ladder's.
  defp candidate_query(%Track{isrc: isrc} = track) when is_binary(isrc) do
    case Isrc.normalize(isrc) do
      nil -> by_title(track)
      canonical -> from(r in Recording, where: r.isrc == ^canonical)
    end
  end

  defp candidate_query(%Track{} = track), do: by_title(track)

  defp by_title(%Track{title: title}) when is_binary(title) and title != "" do
    from(r in Recording, where: fragment("lower(?)", r.title) == ^String.downcase(title))
  end

  defp by_title(_track), do: from(r in Recording, where: false)

  @doc """
  The recording for a track, storing it if the library does not have it yet.

  The point at which a miss becomes a **create** rather than a failure — see the
  module documentation.

  Conservative about what counts as the same recording, and only ever matches on
  an identifier: a canonical ISRC, or nothing. Titles are not enough here, even
  though they are enough to *offer* a candidate in `search/2`, because the two
  answers have different costs. Offering a wrong candidate is harmless — the
  matching ladder throws it out. Silently reusing the wrong recording row joins
  two different pieces of music forever, and the user's playlist then points at
  the wrong one.
  """
  @spec find_or_create(Track.t()) :: Recording.t()
  def find_or_create(%Track{provider: :library, provider_id: id}), do: Repo.get!(Recording, id)

  def find_or_create(%Track{} = track) do
    case existing(track) do
      %Recording{} = found -> found
      nil -> track |> Recording.from_track() |> Repo.insert!()
    end
  end

  defp existing(%Track{isrc: isrc}) when is_binary(isrc) do
    case Isrc.normalize(isrc) do
      nil -> nil
      canonical -> Repo.one(from(r in Recording, where: r.isrc == ^canonical, limit: 1))
    end
  end

  defp existing(_track), do: nil

  defp next_position(playlist_id) do
    PlaylistItem
    |> where(playlist_id: ^playlist_id)
    |> select([i], max(i.position))
    |> Repo.one()
    |> case do
      nil -> 0
      highest -> highest + 1
    end
  end
end
