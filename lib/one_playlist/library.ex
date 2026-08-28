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

  alias OnePlaylist.Library.Enrichment
  alias OnePlaylist.Library.EnrichmentWorker
  alias OnePlaylist.Library.Playlist
  alias OnePlaylist.Library.PlaylistItem
  alias OnePlaylist.Library.Recording
  alias OnePlaylist.Library.RecordingEnrichment
  alias OnePlaylist.Matching
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

  `linked?` says whether anybody has decided which recording this is, which is
  not the same question as whether MusicBrainz has been asked about it — an item
  can be unlinked by hand at any time, and an unlinked item has nothing to ask
  about.

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
          linked?: boolean(),
          enriched?: boolean(),
          recording: %{
            id: Ecto.UUID.t() | nil,
            title: String.t() | nil,
            artists: [String.t()],
            album: String.t() | nil
          },
          musicbrainz: %{
            isrc_disputed: boolean(),
            recording_id: Ecto.UUID.t() | nil,
            release_id: Ecto.UUID.t() | nil,
            looked_up_at: DateTime.t() | nil,
            outcome: atom() | nil,
            candidates: integer() | nil
          }
        }

  @doc """
  A user's library playlists, most recently made first, with their sizes.

  Only theirs, and the postcondition says so rather than trusting the two scopes
  beneath it. This is what `/playlists` renders and what every picker offers as a
  transfer source, so another user's playlist reaching this list is not a display
  bug — it is a playlist somebody can read the contents of and copy.

  One query for the playlists and one for every count, rather than a count per
  playlist: a user with fifty playlists should not cost fifty round trips to
  render a list.
  """
  # Proven by mutation: dropping both the `where user_id` and `Repo.as_user/3`
  # fires it — neither alone does, since each scope suffices on its own.
  @post all_belong_to_the_user: forall({playlist, _count} <- result, playlist.user_id == user_id)
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
    {:ok, rows} = Repo.as_user(user_id, fn -> Repo.all(items_with_recordings(playlist_id)) end)

    # The attempt is joined but not wanted here: a track is what the playlist
    # holds, and how enrichment got on is not part of it.
    Enum.map(rows, fn {item, recording, _attempt} -> PlaylistItem.to_track(item, recording) end)
  end

  @doc """
  A playlist's entries, in order, each with the recording it names.

  What the editor works from, and different from `tracks/2` in one way that
  matters: it carries the **entry's** id as well as the recording's. A playlist
  may hold the same recording twice, so "remove this one" and "move this one"
  are questions about an entry, and a recording id cannot answer them.

  Two guarantees the editor is built on. **Positions are distinct** — the drag
  handle, the arrow keys and `place_entry/5` all derive an order from them, and a
  tie means the list renders in whatever order the tie-break happens to give.
  And **`enriched?` implies `linked?`**: the three states this returns are "not
  linked", "linked but not looked up" and "looked up", so a row claiming to be
  enriched while naming no recording is a fourth state nothing downstream knows
  how to draw.
  """
  # Proven by mutation: `position: 0` in the map fires `positions_are_distinct`
  # on any two-entry playlist, and reading `enriched?` from the *item* rather
  # than the recording fires `enriched_implies_linked`.
  @post positions_are_distinct: distinct_positions?(result)
  @post enriched_implies_linked: forall(entry <- result, entry.enriched? ~> entry.linked?)
  @spec entries(Ecto.UUID.t(), Ecto.UUID.t()) :: [entry()]
  def entries(user_id, playlist_id) do
    {:ok, rows} = Repo.as_user(user_id, fn -> Repo.all(items_with_recordings(playlist_id)) end)

    Enum.map(rows, fn {item, recording, attempt} ->
      # `nil` here means "loaded, and there is no attempt", which is what the
      # left join actually established. Leaving the association unloaded would
      # make `RecordingEnrichment.of/1` raise, correctly.
      recording =
        case recording do
          %Recording{} = found -> %Recording{found | enrichment: attempt}
          nil -> nil
        end

      %{
        id: item.id,
        position: item.position,
        track: PlaylistItem.to_track(item, recording),
        # Three states rather than two, because "nobody has decided what this is"
        # and "MusicBrainz has not been asked yet" are different answers and a
        # reader acts differently on each.
        linked?: not is_nil(item.recording_id),
        enriched?: not is_nil(RecordingEnrichment.of(recording)),
        # What the *recording* says, beside what the item says. The screen showed
        # a bare UUID here, which tells a reader nothing — and the one time it
        # would have told them everything was the case where the two disagree.
        recording: recording_details(recording),
        musicbrainz: musicbrainz(recording)
      }
    end)
  end

  @doc false
  @spec recording_details(Recording.t() | nil) :: map()
  def recording_details(nil), do: %{id: nil, title: nil, artists: [], album: nil}

  def recording_details(%Recording{} = recording) do
    %{
      id: recording.id,
      title: recording.title,
      artists: recording.artists || [],
      album: recording.album
    }
  end

  @doc false
  @spec musicbrainz(Recording.t() | nil) :: map()
  def musicbrainz(nil) do
    %{
      recording_id: nil,
      release_id: nil,
      looked_up_at: nil,
      outcome: nil,
      candidates: nil,
      artists: [],
      isrc_disputed: false
    }
  end

  def musicbrainz(%Recording{} = recording) do
    attempt = RecordingEnrichment.of(recording)

    %{
      recording_id: recording.musicbrainz_recording_id,
      release_id: recording.musicbrainz_release_id,
      looked_up_at: attempt && attempt.attempted_at,
      outcome: attempt && attempt.outcome,
      candidates: attempt && attempt.candidates,
      # What the catalogue credits it to, which is not always what the source
      # said — see the migration `add_musicbrainz_artists_to_recordings` for the
      # Roon album-artist problem this answers. `nil` means never asked.
      artists: recording.musicbrainz_artists || [],
      # Durable in a way the outcome is not: enrichment now sets the code aside
      # and asks by name instead, so a recording with a wrong ISRC can end up
      # `:identified` while its code is still wrong.
      isrc_disputed: recording.isrc_disputed
    }
  end

  # One query behind both readers, and a `left_join` because an item may not
  # know what recording it is. An inner join would silently drop exactly the
  # rows a person most needs to see.
  # The enrichment attempt is joined rather than preloaded because the recording
  # is not this query's root — it arrives through a left join of its own, and may
  # be absent. Selected as a third element and attached in `entries/2`, which
  # also keeps this a single query for a screen that renders a whole playlist.
  defp items_with_recordings(playlist_id) do
    from(i in PlaylistItem,
      left_join: r in Recording,
      on: r.id == i.recording_id,
      left_join: e in RecordingEnrichment,
      on: e.recording_id == r.id,
      where: i.playlist_id == ^playlist_id,
      order_by: [asc: i.position, asc: i.inserted_at],
      select: {i, r, e}
    )
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
  Asks MusicBrainz again about the recordings in a playlist it could not identify.

  Enrichment is a background job that runs once as a recording arrives and then
  nightly for anything still unresolved, which is the right cadence for a
  process nobody is watching. It is the wrong cadence for somebody who has just
  corrected a track and wants to know whether it helped. This is that button.

  **Only the unidentified are re-asked.** A recording that carries a MusicBrainz
  id is left alone, and that is the same rule `OnePlaylist.Library.Enrichment.due/1`
  keeps: enrichment fills gaps and never overwrites, so re-running it over an
  identified recording changes nothing and spends a request finding that out.
  Re-deciding a settled identity means discarding it first, which is
  `Enrichment.reset/1` and belongs in a narrower gesture than this one.

  `reset/1` is still called on the ones that *are* re-asked, because it clears
  the bookkeeping — the recording goes back to reading "still being looked up"
  rather than sitting on a stale decline while the queue works through.

  Answers with how many were queued, which is what the caller tells the user.
  """
  @spec reenrich(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, non_neg_integer()} | :error
  def reenrich(user_id, playlist_id) do
    with {:ok, _playlist} <- fetch_playlist(user_id, playlist_id) do
      ids = unidentified_recording_ids(playlist_id)

      _cleared = Enrichment.reset(ids)
      Enum.each(ids, &EnrichmentWorker.enqueue/1)

      {:ok, length(ids)}
    end
  end

  @doc """
  The same, for the one recording behind one entry.

  Narrower on purpose. A playlist of five hundred tracks is five hundred
  requests at one a second, and somebody who has just fixed a single row wants
  an answer about that row.

  An unlinked entry answers `{:ok, 0}` rather than an error: there is nothing to
  look up, and that is a true statement about it rather than a failure.
  """
  @spec reenrich_entry(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, non_neg_integer()} | :error
  def reenrich_entry(user_id, playlist_id, entry_id) do
    with {:ok, item} <- fetch_item(user_id, playlist_id, entry_id) do
      ids = if item.recording_id, do: [item.recording_id], else: []

      _cleared = Enrichment.reset(ids)
      Enum.each(ids, &EnrichmentWorker.enqueue/1)

      {:ok, length(ids)}
    end
  end

  defp unidentified_recording_ids(playlist_id) do
    PlaylistItem
    |> join(:inner, [i], r in Recording, on: r.id == i.recording_id)
    |> where([i, r], i.playlist_id == ^playlist_id and is_nil(r.musicbrainz_recording_id))
    |> select([_i, r], r.id)
    |> distinct(true)
    |> Repo.all()
  end

  @doc """
  Corrects what one of a user's items says about its track.

  Only the fields in `OnePlaylist.Library.PlaylistItem.owned/0` — the source's
  account of the track, which is the user's to fix. Nothing here touches the
  recording, and that is the whole reason phase 1 moved this metadata: a
  correction to your playlist is not a correction to everybody's.

  The **link is deliberately left alone**. A person fixing a typo should not
  lose the recording their track is matched to, and a person fixing something
  substantial can unlink in the same visit — see `unlink/3`. Guessing which of
  those an edit was would be wrong about half the time.

  What an edit *does* change is what `link_candidates/4` will offer, because
  that searches on the item's own words. Correcting a credit is often exactly
  how somebody finds the recording that had been unreachable.
  """
  @spec update_item(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          :ok | {:error, Ecto.Changeset.t()} | :error
  def update_item(user_id, playlist_id, entry_id, attrs) do
    with {:ok, item} <- fetch_item(user_id, playlist_id, entry_id) do
      item
      |> PlaylistItem.changeset(Map.take(attrs, PlaylistItem.owned() ++ owned_strings()))
      |> Ecto.Changeset.put_change(:updated_at, DateTime.utc_now())
      |> Repo.update()
      |> case do
        {:ok, _updated} -> :ok
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  defp owned_strings, do: Enum.map(PlaylistItem.owned(), &Atom.to_string/1)

  @doc """
  Stores this item's own account of the track as a recording, and links to it.

  The answer to "none of these is right", and the reason `link_candidates/4` is
  not the whole story: it can only offer recordings the library already holds,
  so a track whose real recording nobody has imported has nothing to choose
  from.

  Uses the item's metadata *as corrected*, which is what makes this worth having
  after `update_item/4`. A track whose credit named the wrong artist could never
  be identified while it said so; fixed and stored, enrichment asks MusicBrainz
  the right question — `find_or_create/1` queues that on the way past.

  **Says which happened**, and that is not bookkeeping. An item whose details
  already describe something the library holds links to *that* rather than
  making a second copy — and when the thing it describes is the recording the
  person just rejected, the button looks like it did nothing.

  It usually has not done nothing; it has discovered that the two are the same
  recording. `existing/1` joins on a canonical ISRC, which is the project's
  anchor for identity, so a corrected credit against an unchanged ISRC is a
  claim that the *recording's metadata* is wrong rather than that the link is.
  A second row could not be created for it in any case: the partial unique index
  on `isrc` would make the insert a no-op and the re-read would find the same
  row again.

  The caller is expected to say so. Somebody who genuinely has a different
  recording clears the ISRC first, at which point the exact title-album-credit
  key applies instead and their corrected words make a row of their own.
  """
  @spec link_to_own_details(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, :created | :existing, Recording.t()} | :error
  def link_to_own_details(user_id, playlist_id, entry_id) do
    with {:ok, item} <- fetch_item(user_id, playlist_id, entry_id) do
      {how, recording} = item |> PlaylistItem.to_track(nil) |> store()

      case set_link(user_id, playlist_id, entry_id, recording.id) do
        :ok -> {:ok, how, recording}
        :error -> :error
      end
    end
  end

  @doc """
  Breaks the link between one of a user's items and its recording.

  What a person does when a track is matched to the wrong music. The item keeps
  everything its source said — that is phase 1's whole point — and simply stops
  claiming to know which recording it is.

  Deliberately not a delete. The alternative before this existed was removing
  the track and adding it again, which loses its place in the playlist and any
  correction made to it.

  Answers `:error` for an item that is not this user's, exactly as
  `fetch_playlist/2` does: an id is not a way to learn what exists.
  """
  @spec unlink(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | :error
  def unlink(user_id, playlist_id, entry_id), do: set_link(user_id, playlist_id, entry_id, nil)

  @doc """
  Links one of a user's items to a recording it names by hand.

  The choice is the person's and is not scored: `link_candidates/3` uses the
  matching engine to *offer* sensible recordings, and this accepts whichever the
  user picked. That asymmetry is the same one `OnePlaylist.Matching.Match`
  states for `chosen_by_hand/2` — a threshold decides what somebody should look
  at, and there is nothing to review about a track they chose themselves.

  Answers `:error` for an item or a recording that does not exist.
  """
  @spec link(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | :error
  def link(user_id, playlist_id, entry_id, recording_id) do
    case Repo.get(Recording, recording_id) do
      nil -> :error
      %Recording{} -> set_link(user_id, playlist_id, entry_id, recording_id)
    end
  end

  @doc """
  Recordings this item might be, best first, with the engine's opinion of each.

  Searched on demand rather than remembered. Enrichment keeps only a *count* of
  what it considered, and storing candidate lists for every item would be a
  large amount of data that goes stale the moment the library grows — which is
  precisely when somebody would want to look at it.

  The score is the ladder's and is shown rather than enforced: it is there to
  help a person choose, not to stop them.
  """
  @spec link_candidates(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), pos_integer()) ::
          [%{recording: Recording.t(), score: float(), strategy: atom()}]
  def link_candidates(user_id, playlist_id, entry_id, limit \\ 10) do
    case fetch_item(user_id, playlist_id, entry_id) do
      :error -> []
      {:ok, item} -> ranked(item, limit)
    end
  end

  defp ranked(item, limit) do
    # Built without its recording on purpose: the question is what this item
    # might be, and the answer must not be steered by whatever it is currently
    # linked to.
    track = PlaylistItem.to_track(item, nil)

    track
    |> Matching.rank(search(track, limit), threshold: :none)
    |> Enum.map(
      &%{
        recording: Repo.get(Recording, &1.track.provider_id),
        score: &1.score,
        strategy: &1.strategy
      }
    )
    |> Enum.reject(&is_nil(&1.recording))
  end

  # `:ok` rather than the changed entry: every caller re-reads the playlist
  # anyway — a link changes which recording a row shows, and the row is drawn
  # from both halves — so returning one row would be a value nobody could use
  # without asking for the rest.
  defp set_link(user_id, playlist_id, entry_id, recording_id) do
    with {:ok, item} <- fetch_item(user_id, playlist_id, entry_id),
         {:ok, _updated} <-
           item
           |> Ecto.Changeset.change(recording_id: recording_id, updated_at: DateTime.utc_now())
           |> Repo.update() do
      :ok
    else
      _otherwise -> :error
    end
  end

  defp fetch_item(user_id, playlist_id, entry_id) do
    with {:ok, _playlist} <- fetch_playlist(user_id, playlist_id) do
      case Repo.get_by(PlaylistItem, id: entry_id, playlist_id: playlist_id, user_id: user_id) do
        nil -> :error
        item -> {:ok, item}
      end
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

  The returned order always has **distinct positions** — a swap that wrote one
  position to both rows leaves a tie, and a swap that lost an entry leaves a
  short list. That is deliberately weaker than "no entry was lost", which cannot
  be a contract here: two tabs reordering one playlist can produce an order
  neither asked for, so a before-and-after law over shared state would accuse
  correct code. It lives in a test, where the sandbox makes the state exclusive.
  """
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

  The same distinct-positions guarantee `move_entry/4` makes, and it matters
  more here: a renumber writes every row in one statement, so getting the
  expression wrong collapses an entire playlist's ordering at once, silently —
  the list still renders, in whatever order the tie-break happens to give.
  """
  # Proven by mutation: making `renumber/1` write a constant position instead of
  # the index fires it.
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
        now = DateTime.utc_now()

        # The item keeps the *source's* account of the track, not the
        # recording's. They are usually the same on the way in and stop being so
        # the moment enrichment improves one or a person corrects the other —
        # see `OnePlaylist.Library.PlaylistItem`.
        %{
          id: Ecto.UUID.generate(),
          playlist_id: playlist_id,
          user_id: user_id,
          recording_id: recording.id,
          position: position,
          title: track.title,
          artists: track.artists,
          album: track.album,
          version: track.version,
          duration_seconds: track.duration_seconds,
          isrc: track.isrc,
          inserted_at: now,
          updated_at: now
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
  # `limit` is the caller's bound and this is a shared, ownerless table — an
  # unbounded read here is every recording anyone has ever imported, sent to a
  # LiveView to render. Proven by mutation: dropping the `limit/2` fires it once
  # the library holds more rows than the caller asked for.
  @post no_more_than_asked_for: length(result) <= limit
  @post every_candidate_is_addressable:
          forall(
            candidate <- result,
            is_binary(candidate.provider_id) and candidate.provider_id != ""
          )
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

  The recording handed back always **agrees with the track on whichever key
  matched it**, and `recognised_by_an_exact_key` below says so. A similarity
  match reaching this function is not a near miss to be tidied up later: it joins
  two pieces of music forever, and every playlist naming one then points at the
  other.
  """
  # Stated over the canonical ISRC, because that is the key — a track carrying
  # `ussm11100234` and a row carrying `USSM11100234` are a correct match, and
  # comparing raw would report it as a violation.
  #
  # `~>` gates on the track having a code at all, since the second key admits a
  # row whose ISRC is `nil` or differs. Proven by mutation: relaxing `existing/1`
  # to a title-only lookup fires it against `library_test.exs`'s two-sessions
  # fixture, which is the *Hard to Imagine* case the docstring describes.
  @post recognised_by_an_exact_key:
          (not is_nil(Isrc.normalize(track.isrc)) and not is_nil(result.isrc))
          ~> (result.isrc == Isrc.normalize(track.isrc))
  @spec find_or_create(Track.t()) :: Recording.t()
  def find_or_create(%Track{provider: :library, provider_id: id}) when not is_nil(id),
    do: Repo.get!(Recording, id)

  def find_or_create(%Track{} = track), do: track |> store() |> elem(1)

  # The two keys, applied. Separate from `find_or_create/1` because the shortcut
  # clause above it is a shortcut for *arriving* tracks, and `link_to_own_details/3`
  # asks the other question: not "which recording is this track" but "store what
  # this item says". Routing that through `find_or_create/1` would hand back the
  # recording the item is already linked to, which is the one answer it must
  # never give.
  defp store(%Track{} = track) do
    case existing(track) do
      %Recording{} = found -> {:existing, found}
      nil -> {:created, create(track)}
    end
  end

  # Reading and then inserting is a race, and the store is **shared**: two users
  # transferring the same track at the same moment both miss and both insert.
  # Observed, not theorised — two overlapping runs of one transfer produced
  # exactly two of every recording, sub-millisecond apart.
  #
  # `on_conflict: :nothing` against the ISRC index makes the loser's insert a
  # no-op rather than a second row, and the re-read then finds the winner's. The
  # index is what makes this true; without it there is no conflict to detect.
  defp create(track) do
    track
    |> Recording.from_track()
    # The index is **partial** — `where isrc is not null` — and Postgres will not
    # infer a partial index from a bare column list, so the predicate has to be
    # repeated here. A track with no ISRC does not satisfy it and simply inserts.
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: {:unsafe_fragment, "(isrc) where isrc is not null"}
    )
    |> case do
      {:ok, %Recording{id: nil}} ->
        # The conflict fired: somebody else inserted this ISRC between our read
        # and our write, so their row is the one to use.
        existing(track)

      {:ok, %Recording{} = created} ->
        enqueue_enrichment(created)
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
