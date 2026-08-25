defmodule OnePlaylist.Library.Identities do
  @moduledoc """
  The identity spine: where a recording is known, at every service.

  `docs/reference/domain.md` §5's L5, and the answer to a question §2 raises and
  leaves open. Every transfer resolves each track against a destination
  catalogue, and today the answer is thrown away when the run ends — so the next
  transfer of the same track pays for the same search and risks the same
  mistake. This is the table that keeps it.

  The claim is economic and worth stating plainly:

  | | Cost of transferring one track |
  | --- | --- |
  | Without a spine | one search per track, per transfer, matched every time |
  | With one | one search per track **ever**, then a lookup that costs no request |

  ## Only what is certain gets in

  A spine that records guesses is worse than no spine, because a wrong identity
  is applied silently to every future transfer of that recording and nothing
  re-derives it. So `record/3` accepts two kinds of evidence and refuses the
  rest:

    * **A track's own identity at its own service.** A TIDAL track carrying an
      ISRC *is* that recording at TIDAL — no matching happened, so there is
      nothing to have got wrong. This is where most rows come from, and it costs
      nothing to learn.
    * **A destination match at an exact identifier, or a person's own choice.**
      `:exact_isrc`, `:exact_upc`, `:linked_isrc`, `:chosen` and `:stored` — the
      confidences at or above `@trustworthy`. A `:high` text match is good
      enough to put a track in a playlist, where a person sees the result and a
      wrong answer is one row in one report. It is not good enough to assert as
      a fact about the world's music, for ever, unreviewed.

  That is deliberately stricter than the transfer threshold, and the asymmetry
  is the point: the cost of a wrong row here is unbounded in a way the cost of a
  wrong row in a report is not.

  ## Anchored on an ISRC, always

  An identity is meaningless without a recording to attach it to, and
  `OnePlaylist.Library.find_or_create/1` joins on a canonical ISRC and never on
  a title — deliberately, because merging two recordings that turn out to be one
  is reversible and splitting one that was never two is not.

  So `anchor/1` answers `nil` for a track with no ISRC, and the spine simply
  learns nothing from it. That is the honest trade: a Subsonic library with no
  ISRCs teaches nothing rather than filling the shared store with duplicates
  that only a merge tool could undo.

  ## A recalled identity is a hint, not a promise

  Services remove tracks. An id recorded last year may name nothing today, and
  nothing here re-checks it in the background — that would be a crawl of every
  service on a schedule, for a question that answers itself in use.

  Instead the existing safety net does the work: `Transfers.Runner` confirms
  every write by reading the destination playlist afterwards, so an identity
  that has gone stale surfaces as a track reported written and not found.
  `forget/2` is what removes it.
  """

  import Ecto.Query

  alias OnePlaylist.Library
  alias OnePlaylist.Library.Identity
  alias OnePlaylist.Library.Recording
  alias OnePlaylist.Matching.Confidence
  alias OnePlaylist.Matching.Match
  alias OnePlaylist.Music.Isrc
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Repo

  use Bond

  # The weakest evidence allowed in. See the moduledoc for why this is stricter
  # than the threshold a transfer matches at.
  @trustworthy :exact_upc

  @doc """
  The recording a track belongs to, or `nil` if it cannot be anchored.

  `nil` is the ordinary answer for a track with no ISRC and is not a failure —
  see the moduledoc. Creating the recording is deliberate rather than a side
  effect: the shared store is the asset, and a transfer between two services
  that never touches the library still contributes to it.
  """
  @spec anchor(Track.t()) :: Recording.t() | nil
  def anchor(%Track{provider: :library, provider_id: id}), do: Repo.get(Recording, id)

  def anchor(%Track{} = track) do
    case Isrc.normalize(track.isrc) do
      nil -> nil
      _canonical -> track |> Library.find_or_create() |> undisputed()
    end
  end

  # A code already caught naming other music is not an anchor.
  #
  # `enrich/1` sets `isrc_disputed` when an ISRC resolves to a recording that is
  # plainly not ours — Roon's export writes *Vitalogy*'s codes onto *Vs.*
  # tracks. Anchoring on one would assert, about every future transfer and
  # unreviewed, that some other recording is this one; and the whole reason this
  # spine anchors on a canonical ISRC is that the code is supposed to be the one
  # thing beyond argument.
  #
  # `nil` is the same answer a track with no ISRC gets, and means the same
  # thing: nothing here can be said with the certainty this table requires. The
  # recording is still created and still enriched — only the *identity claim* is
  # withheld.
  defp undisputed(%Recording{isrc_disputed: true}), do: nil
  defp undisputed(%Recording{} = recording), do: recording

  @doc """
  Anchors a source track and records where it lives at its own service.

  The cheapest row the spine ever gets, and the commonest: a track carrying an
  ISRC *is* that recording at the service it came from. Nothing was matched, so
  there is nothing to have got wrong, and it costs no request.

  Answers with the recording so a caller can go straight on to `recall/3`, or
  `nil` when the track cannot be anchored.

  Records nothing for a track without an ISRC: there is no anchor, and claiming
  `:isrc` evidence for a title match would be a lie the spine then repeats for
  ever. Nothing for a library track either, though that rule now lives in
  `record/4` where every caller passes through it.
  """
  @spec record_source(Recording.t() | nil, Track.t()) :: :ok
  def record_source(recording, %Track{} = track) do
    if track.provider != :library and is_binary(track.isrc) do
      record(recording, track, :isrc, 1.0)
    end

    :ok
  end

  @doc """
  Records where a recording is known, if the evidence is good enough.

  Answers `:ok` whether or not anything was written, because every caller is
  doing something else — running a transfer — and a spine that failed to learn
  is not a reason to fail the thing it was learning from.

  `strategy` and `score` are `OnePlaylist.Matching`'s own, and are replayed by
  `recall/2` so a later report can say *why* two tracks correspond rather than
  only that they do.
  """
  # The rule the moduledoc argues for, stated where it can be checked rather
  # than left to each call site to remember. It is the one thing about this
  # module that must not drift: a weaker rung admitted here is not a bad match
  # in one report, it is a wrong fact asserted about every future transfer of
  # that recording.
  @pre evidence_is_at_least_trustworthy: trustworthy?(Confidence.for_score(score, strategy))
  @spec record(Recording.t() | nil, Track.t(), atom(), float()) :: :ok
  def record(recording, track, strategy, score)

  def record(nil, _track, _strategy, _score), do: :ok
  def record(_recording, %Track{provider_id: nil}, _strategy, _score), do: :ok
  def record(_recording, %Track{provider_id: ""}, _strategy, _score), do: :ok
  def record(_recording, %Track{provider: :file}, _strategy, _score), do: :ok

  # A library track's `provider_id` **is** the recording's id, so a row saying so
  # restates its own primary key. `record_source/2` already refused these; this
  # is the same rule at the one place every caller passes through, because the
  # *destination* path was writing them anyway — a real import produced 128 rows
  # that carried no information. Nothing ever reads them either: a destination
  # that accepts any track skips the spine entirely.
  def record(_recording, %Track{provider: :library}, _strategy, _score), do: :ok

  def record(%Recording{} = recording, %Track{} = track, strategy, score) do
    now = DateTime.utc_now()

    attrs = %{
      recording_id: recording.id,
      provider: track.provider,
      provider_id: track.provider_id,
      title: track.title,
      artists: track.artists || [],
      album: track.album,
      artwork_url: track.artwork_url,
      duration_seconds: track.duration_seconds,
      strategy: to_string(strategy),
      score: score,
      first_seen_at: now,
      last_confirmed_at: now
    }

    %Identity{}
    |> Identity.changeset(attrs)
    |> Repo.insert(
      # One answer per service, and better evidence replaces weaker. The
      # `where` is what makes that true without reading first: a concurrent
      # transfer that recorded a stronger identity between our read and our
      # write would otherwise be overwritten by ours.
      on_conflict:
        from(i in Identity,
          where: i.score <= ^score or i.provider_id == ^track.provider_id,
          update: [
            set: [
              provider_id: ^track.provider_id,
              title: ^track.title,
              artists: ^(track.artists || []),
              album: ^track.album,
              artwork_url: ^track.artwork_url,
              duration_seconds: ^track.duration_seconds,
              strategy: ^to_string(strategy),
              score: ^score,
              last_confirmed_at: ^now
            ]
          ]
        ),
      conflict_target: [:recording_id, :provider],
      # Without this, an upsert whose `where` matches nothing raises
      # `Ecto.StaleEntryError` — and "nothing was updated" is the *intended*
      # outcome here, not a fault: it is what happens when the row already holds
      # better evidence than we are offering.
      stale_error_field: :recording_id
    )

    :ok
  end

  @doc """
  Where this recording is known at that service, as a match, or `nil`.

  The read side of the spine and the whole point of it: answers with the
  destination's own track, built from the snapshot, so a transfer can add it
  without asking the service anything.

  The match replays the strategy and score the identity was recorded with, and
  carries `recalled: true` in its evidence — so a report says the tracks
  correspond because their ISRCs agreed, and also that nobody re-checked that
  today.
  """
  @spec recall(Recording.t() | nil, Track.t(), atom()) :: Match.t() | nil
  def recall(nil, _source, _provider), do: nil

  def recall(%Recording{} = recording, %Track{} = source, provider) do
    source_id = if source.provider == provider, do: source.provider_id

    Identity
    |> where([i], i.recording_id == ^recording.id and i.provider == ^provider)
    |> Repo.one()
    |> case do
      nil ->
        nil

      # An identity naming the source track itself is not a memory of anything.
      # It happens on a same-provider transfer, where what the spine knows about
      # the source is trivially also true of the destination — and answering
      # with it would skip the search to "match" a track to itself. That
      # shortcut is real and worth taking, but it is a different feature from
      # recall and belongs where it can be reasoned about on its own.
      %Identity{provider_id: same} when same == source_id ->
        nil

      %Identity{} = identity ->
        Match.new(
          source: source,
          track: Identity.to_track(identity),
          score: identity.score,
          strategy: String.to_existing_atom(identity.strategy),
          evidence: [recalled: true, first_seen_at: identity.first_seen_at]
        )
    end
  end

  @doc """
  Forgets what this recording was known as at that service, returning how many.

  For an identity that has stopped being true — a track a service removed, or an
  id a correction supersedes. Deleting rather than marking: a spine's answer is
  the current one, and a row that is known to be wrong has no second use.
  """
  @spec forget(Recording.t() | nil, atom()) :: non_neg_integer()
  def forget(nil, _provider), do: 0

  def forget(%Recording{} = recording, provider) do
    {count, _returned} =
      Identity
      |> where([i], i.recording_id == ^recording.id and i.provider == ^provider)
      |> Repo.delete_all()

    count
  end

  @doc """
  Every service a recording is known at, best evidence first.

  For a recording's own page and for answering "what does the spine actually
  hold" without a query per service.
  """
  @spec for_recording(Recording.t() | nil) :: [Identity.t()]
  def for_recording(nil), do: []

  def for_recording(%Recording{} = recording) do
    Identity
    |> where([i], i.recording_id == ^recording.id)
    |> order_by([i], desc: i.score, asc: i.provider)
    |> Repo.all()
  end

  @doc """
  Whether a confidence is strong enough to be asserted as a fact.

  Public because `record/4` names it in a precondition, and an assertion
  rendered into the documentation should reference something a reader can look
  up.
  """
  @spec trustworthy?(Confidence.t()) :: boolean()
  def trustworthy?(confidence), do: Confidence.at_least?(confidence, @trustworthy)
end
