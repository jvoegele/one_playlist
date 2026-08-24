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

  alias OnePlaylist.Library.EnrichmentWorker
  alias OnePlaylist.Library.Playlist
  alias OnePlaylist.Library.PlaylistItem
  alias OnePlaylist.Library.Recording
  alias OnePlaylist.Matching.Normalize
  alias OnePlaylist.Music.Isrc
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Repo

  use Bond

  @typedoc """
  One row of a playlist as the editor sees it.

  Carries the **entry's** id as well as the recording, because a playlist may
  hold the same recording twice and "remove this one" is a question about an
  entry.

  The `musicbrainz` half is what the editor shows when a row is expanded, and it
  is deliberately not on `t:OnePlaylist.Music.Track.t/0`: a track is what gets
  transferred, and where its metadata was resolved from is a fact about the
  *stored recording* rather than about the music. `enriched?` says whether
  MusicBrainz has been **asked**, which is not the same as whether it had
  anything to say — three states, and a view that collapses them to two tells a
  finished playlist it is still loading.
  """
  @type entry :: %{
          id: Ecto.UUID.t(),
          position: integer(),
          track: Track.t(),
          enriched?: boolean(),
          musicbrainz: %{
            recording_id: Ecto.UUID.t() | nil,
            release_id: Ecto.UUID.t() | nil,
            looked_up_at: DateTime.t() | nil,
            outcome: atom() | nil,
            candidates: integer() | nil
          }
        }

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
  A playlist's entries, in order, each with the recording it names.

  What the editor works from, and different from `tracks/2` in one way that
  matters: it carries the **entry's** id as well as the recording's. A playlist
  may hold the same recording twice, so "remove this one" and "move this one"
  are questions about an entry, and a recording id cannot answer them.
  """
  @spec entries(Ecto.UUID.t(), Ecto.UUID.t()) :: [entry()]
  def entries(user_id, playlist_id) do
    query =
      from(i in PlaylistItem,
        join: r in Recording,
        on: r.id == i.recording_id,
        where: i.playlist_id == ^playlist_id,
        order_by: [asc: i.position, asc: i.inserted_at],
        select: {i, r}
      )

    {:ok, rows} = Repo.as_user(user_id, fn -> Repo.all(query) end)

    Enum.map(rows, fn {item, recording} ->
      %{
        id: item.id,
        position: item.position,
        track: Recording.to_track(recording),
        enriched?: not is_nil(recording.enriched_at),
        musicbrainz: %{
          recording_id: recording.musicbrainz_recording_id,
          release_id: recording.musicbrainz_release_id,
          looked_up_at: recording.enriched_at,
          outcome: recording.enrichment_outcome,
          candidates: recording.enrichment_candidates
        }
      }
    end)
  end

  @doc "Renames a playlist, or changes its description."
  @spec update_playlist(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, Playlist.t()} | {:error, Ecto.Changeset.t()} | :error
  def update_playlist(user_id, playlist_id, attrs) do
    with {:ok, playlist} <- fetch_playlist(user_id, playlist_id) do
      playlist
      |> Playlist.changeset(attrs)
      |> Repo.update()
    end
  end

  @doc """
  Deletes a playlist and everything in it.

  The entries go by foreign key; the **recordings do not**. They belong to
  nobody and may be in somebody else's playlist, which is the whole reason they
  are a separate table — deleting a playlist is not a licence to delete music.
  """
  @spec delete_playlist(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | :error
  def delete_playlist(user_id, playlist_id) do
    with {:ok, playlist} <- fetch_playlist(user_id, playlist_id),
         {:ok, _deleted} <- Repo.delete(playlist) do
      :ok
    else
      _otherwise -> :error
    end
  end

  @doc """
  Removes one entry, named by its own id rather than by what it holds.

  Deliberately not `remove/2`, which takes recordings and removes **every**
  occurrence — right for a transfer correcting itself, wrong for a person
  deleting the second of two copies they meant to keep one of.
  """
  @spec remove_entry(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | :error
  def remove_entry(user_id, playlist_id, entry_id) do
    with {:ok, _playlist} <- fetch_playlist(user_id, playlist_id) do
      PlaylistItem
      |> where([i], i.id == ^entry_id and i.playlist_id == ^playlist_id)
      |> Repo.delete_all()
      |> case do
        {1, _returned} -> :ok
        {0, _returned} -> :error
      end
    end
  end

  @doc """
  Moves one entry up or down by one place, returning the new order.

  A swap of two `position` values rather than a renumber. Dense integers were
  kept over the fractional ranks `docs/reference/domain.md` §5 first guessed at,
  because the guess was not measured and does not survive being measured: a
  renumber of half a five-thousand-entry playlist is **2.3ms** in one statement,
  and an adjacent move does not need even that.
  """
  # Sound under interleaving, which is what it costs to be honest here. Two
  # tabs reordering one playlist can produce an order neither asked for, so a
  # before-and-after conservation law over shared state would accuse correct
  # code — the failure `docs/reference/contracts.md` and `Providers.disconnect/2`
  # both name as the worst a contract can have.
  #
  # What survives is a claim about the value returned: a swap that wrote one
  # position to both rows leaves a tie, and a swap that lost an entry leaves a
  # short list. Neither is falsifiable by another writer's timing.
  #
  # "No entry was lost" belongs in a test, where the sandbox makes the state
  # genuinely exclusive and the strong assertion is sound.
  @post positions_stay_distinct: distinct_positions?(result)
  @spec move_entry(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), :up | :down) :: [entry()]
  def move_entry(user_id, playlist_id, entry_id, direction)
      when direction in [:up, :down] do
    ordered = entries(user_id, playlist_id)

    case swap_partner(ordered, entry_id, direction) do
      {moving, partner} ->
        {:ok, _result} =
          Repo.transaction(fn ->
            set_position(moving.id, partner.position)
            set_position(partner.id, moving.position)
          end)

        entries(user_id, playlist_id)

      nil ->
        # Already at the end it was asked to move toward, or not in this
        # playlist at all. Nothing to do, and not an error: the button being
        # pressed twice is not a failure.
        ordered
    end
  end

  @doc """
  Moves one entry to sit immediately before or after another, returning the new
  order.

  What a drag lands on. The client says *what was dropped where* — an entry and
  a neighbour — rather than submitting a whole new ordering, so the order itself
  is only ever computed here. A client that sent a permutation would be trusted
  to have got it right, and a malformed or stale one would silently reorder
  somebody's playlist into something nobody asked for.

  Renumbers densely rather than swapping, because a drag moves an entry an
  arbitrary distance. Measured at **2.3ms** for half a five-thousand-entry
  playlist, in one statement, which is why the fractional ranks
  `docs/reference/domain.md` §5 guessed at were not needed.

  Answers with the current order unchanged when either id is not in this
  playlist, or when the entry is dropped onto itself. None of those is an error:
  a drag that ends where it began is a drag the user cancelled.
  """
  # The same claim `move_entry/4` makes, and sound for the same reason: it is
  # about the value returned rather than about shared state, so another tab
  # reordering concurrently cannot falsify it.
  #
  # No input can falsify it either, so it is verified by mutation: making
  # `renumber/1` write a constant position instead of the index fires it. That is
  # the failure worth guarding, because a renumber writes every row in one
  # statement and getting the expression wrong collapses an entire playlist's
  # ordering at once, silently — the list still renders, in whatever order the
  # tie-break happens to give.
  @post positions_stay_distinct: distinct_positions?(result)
  @spec place_entry(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), :before | :after) ::
          [entry()]
  def place_entry(user_id, playlist_id, entry_id, target_id, side)
      when side in [:before, :after] do
    ordered = entries(user_id, playlist_id)

    case reordered(ordered, entry_id, target_id, side) do
      nil ->
        ordered

      placed ->
        renumber(placed)
        entries(user_id, playlist_id)
    end
  end

  # `nil` rather than a changed list whenever there is nothing to do, so the
  # caller can tell "no move" from "moved" without comparing two lists.
  defp reordered(ordered, entry_id, target_id, side) do
    moving = Enum.find(ordered, &(&1.id == entry_id))
    target = Enum.find(ordered, &(&1.id == target_id))

    if moving && target && moving.id != target.id do
      remaining = Enum.reject(ordered, &(&1.id == entry_id))
      at = Enum.find_index(remaining, &(&1.id == target_id))

      List.insert_at(remaining, if(side == :before, do: at, else: at + 1), moving)
    end
  end

  # One statement rather than a query per row: a drag from the bottom of a long
  # playlist to the top moves every position between them.
  defp renumber(ordered) do
    {ids, positions} =
      ordered
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} -> {entry.id, index} end)
      |> Enum.unzip()

    %{num_rows: written} =
      Repo.query!(
        """
        update public.library_playlist_items as i
        set position = new.position
        from unnest($1::uuid[], $2::int[]) as new(id, position)
        where i.id = new.id
        """,
        [Enum.map(ids, &Ecto.UUID.dump!/1), positions]
      )

    written
  end

  @doc """
  Whether an ordering has no two entries claiming the same place.

  Public because `move_entry/4` names it in a postcondition, and an assertion
  rendered into the documentation should reference something a reader can look
  up.
  """
  @spec distinct_positions?([%{position: integer()}]) :: boolean()
  def distinct_positions?(ordered) do
    positions = Enum.map(ordered, & &1.position)

    length(Enum.uniq(positions)) == length(positions)
  end

  defp swap_partner(ordered, entry_id, direction) do
    index = Enum.find_index(ordered, &(&1.id == entry_id))
    partner_index = if direction == :up, do: index && index - 1, else: index && index + 1

    cond do
      is_nil(index) -> nil
      partner_index < 0 -> nil
      partner_index >= length(ordered) -> nil
      true -> {Enum.at(ordered, index), Enum.at(ordered, partner_index)}
    end
  end

  defp set_position(entry_id, position) do
    PlaylistItem
    |> where([i], i.id == ^entry_id)
    |> Repo.update_all(set: [position: position])
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

  Two keys, and both are **exact**. A canonical ISRC when the track has one;
  otherwise the title, the album and the credit all agreeing after
  normalization.

  Never a similarity match, and that is the distinction that matters rather than
  which fields are used. Titles alone are enough to *offer* a candidate in
  `search/2` — the ladder throws a wrong one out — and they are not enough to
  *conclude* here, because reusing the wrong row joins two pieces of music
  forever and every playlist naming one then points at the other. Measured on a
  real import: a title-similarity match merged two different studio sessions of
  *Hard to Imagine*, and one of them silently vanished.

  The second key exists because an identifier alone is not the safe direction it
  looks like. Roughly 40% of a real self-hosted library carries no ISRC, and
  without a way to recognise those, a playlist re-imported grows a second copy
  of every one of them — a slower kind of wrong rather than a safer one.
  """
  @spec find_or_create(Track.t()) :: Recording.t()
  def find_or_create(%Track{provider: :library, provider_id: id}), do: Repo.get!(Recording, id)

  def find_or_create(%Track{} = track) do
    case existing(track) do
      %Recording{} = found -> found
      nil -> track |> Recording.from_track() |> Repo.insert!() |> enqueue_enrichment()
    end
  end

  # Only a recording that is genuinely new. One that was found has been asked
  # about already, or is queued to be — and a playlist imported twice names
  # mostly the same recordings, so enqueueing on every arrival would spend the
  # enrichment queue re-asking about music it already knows.
  defp enqueue_enrichment(%Recording{} = recording) do
    :ok = EnrichmentWorker.enqueue(recording.id)
    recording
  end

  defp existing(%Track{isrc: isrc} = track) when is_binary(isrc) do
    case Isrc.normalize(isrc) do
      nil -> identical(track)
      canonical -> Repo.one(from(r in Recording, where: r.isrc == ^canonical, limit: 1))
    end
  end

  defp existing(track), do: identical(track)

  # The second key, for the tracks that carry no ISRC — roughly 40% of a real
  # self-hosted library, and a tenth of the playlist that produced this rule.
  #
  # **Exact equality, not similarity**, and the distinction is the whole of it. A
  # similarity match on title alone merged two different studio sessions of
  # *Hard to Imagine* — one from *Lost Dogs*, one from the *Chicago Cab*
  # soundtrack — and the second silently vanished from the playlist. Requiring
  # the album and the credit to agree as well keeps those apart, because they
  # disagree about the album.
  #
  # Without it, an ISRC-less track can never be recognised on its second arrival
  # and a re-imported playlist grows a second copy of every one of them. That is
  # not the safe direction either: it is just a slower kind of wrong.
  #
  # Compared after normalization so punctuation and case cannot split one
  # recording in two, and the artists as a **set** so a service that orders a
  # credit differently is still the same credit.
  defp identical(%Track{title: title} = track) when is_binary(title) and title != "" do
    Recording
    # The index the library migration added for exactly this lookup.
    |> where([r], fragment("lower(?)", r.title) == ^String.downcase(title))
    |> Repo.all()
    |> Enum.find(&same_recording?(&1, track))
  end

  defp identical(_track), do: nil

  defp same_recording?(%Recording{} = recording, %Track{} = track) do
    Normalize.text(recording.title) == Normalize.text(track.title) and
      Normalize.text(recording.album) == Normalize.text(track.album) and
      Normalize.artists(recording.artists) == Normalize.artists(track.artists)
  end

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
