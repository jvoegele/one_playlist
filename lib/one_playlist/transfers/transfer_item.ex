defmodule OnePlaylist.Transfers.TransferItem do
  @moduledoc """
  What happened to one track, and why.

  One row per track of the source playlist — which is the point. "Never
  silently drop a track" is a claim about the whole application, and this table
  is where it becomes checkable: a source track with no row here is a bug the
  database can be asked about, rather than an absence nobody notices.

  Three outcomes, and the distinction between the last two is the one that
  makes a report worth reading:

  | Outcome | Means |
  | --- | --- |
  | `:matched` | Resolved and written to the destination. |
  | `:already_present` | Resolved, and the destination already had it. |
  | `:unmatched` | Not resolved confidently. `reason` says which kind. |

  `:already_present` is what idempotency looks like from the report's side. A
  re-run of a completed transfer turns every `:matched` into
  `:already_present` and adds nothing — and a user looking at the report can
  see that is what happened, rather than wondering why the second run "did
  nothing".

  > #### Why there is no `@invariant` here {: .info}
  >
  > Not a Bond limitation — since 1.15.0 an `Ecto.Schema` can carry one, and
  > `OnePlaylist.Transfers.Transfer` does. It would simply fire on nothing.
  >
  > `matched/4` and `unmatched/4` return **maps**, not structs: rows reach the
  > database through `Repo.insert_all/3`, so `changeset/2` is never called from
  > `lib/` at all. The only public function that takes a `%TransferItem{}` is
  > therefore unused, and an invariant would have no value to check on the way
  > in or out of anything.
  >
  > The two laws that matter — a resolved row names a destination track, an
  > unresolved one says why — are asserted as postconditions on the two
  > functions that build those maps, which is where the values actually come
  > from. Moving them would weaken them.
  """

  use Ecto.Schema
  use Bond

  import Ecto.Changeset

  alias OnePlaylist.Matching.Match
  alias OnePlaylist.Music.Track

  @outcomes ~w(matched already_present unmatched)a

  @type outcome :: :matched | :already_present | :unmatched

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          transfer_id: Ecto.UUID.t() | nil,
          position: non_neg_integer() | nil,
          source_track_id: String.t() | nil,
          candidates: [map()],
          source_album: String.t() | nil,
          source_artwork_url: String.t() | nil,
          destination_artwork_url: String.t() | nil,
          destination_title: String.t() | nil,
          destination_artist: String.t() | nil,
          destination_album: String.t() | nil,
          outcome: outcome() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "transfer_items" do
    field :transfer_id, :binary_id
    field :user_id, Ecto.UUID

    field :position, :integer

    field :source_track_id, :string
    field :source_isrc, :string
    field :source_title, :string
    field :source_artist, :string
    field :source_album, :string
    field :source_artwork_url, :string

    field :outcome, Ecto.Enum, values: @outcomes
    field :destination_track_id, :string

    # What was chosen, in the form a person reads. The id above is the identity;
    # these answer "is that the right recording?", which is the only question
    # anybody asks of a match.
    field :destination_title, :string
    field :destination_artist, :string
    field :destination_album, :string
    field :destination_artwork_url, :string
    field :confidence, :string
    field :score, :float
    field :strategy, :string
    field :reason, :string
    field :candidates_considered, :integer

    # What the winning rung considered and rejected, kept so a person can pick
    # one without a provider call. Populated only where somebody might act on
    # it — see `OnePlaylist.Transfers.Candidate`.
    field :candidates, {:array, :map}, default: []

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The outcomes an item can record."
  @spec outcomes() :: [outcome()]
  def outcomes, do: @outcomes

  # Set when a row is written, and meaningless before it is.
  @persistence_only ~w(id transfer_id user_id inserted_at candidates_considered)a

  @doc """
  The fields a report row is *shown* by, as opposed to stored with.

  Exists so that `OnePlaylist.Transfers.Runner`'s provisional rows can be held
  to the same shape. Those are drawn by the same template as a persisted row,
  so a field added here and forgotten there is a `KeyError` in the middle of a
  running transfer — which is where it happened, when the destination's title
  and album were added.

  Derived from the schema rather than listed, so a new column is required of
  provisional rows automatically. Over-including slightly is harmless: it costs
  a `nil`, where under-including costs a crash.
  """
  # Nothing to check on the way out: this answers what the *type* has, not what
  # any value of it holds.
  @bond_warn_skipped_invariants false
  @spec display_fields() :: [atom()]
  def display_fields, do: __schema__(:fields) -- @persistence_only

  @doc """
  The source track as this row recorded it.

  A report row is the only durable account of what the source said: the playlist
  it came from may have changed, and for a file source it is gone entirely. So
  the row is what a track has to be rebuilt from, and this is that rebuild.

  `provider` is the transfer's, because a row does not carry one — every row of a
  report shares it, so storing it per row would be forty thousand copies of one
  fact.

  Deliberately partial. A row keeps what a person reads — title, credit, album,
  artwork, and now the ISRC — and not the length, the track number or the
  explicit flag, because the report never showed them. What comes back is
  therefore the source *as reported*, which is the honest thing to call it and
  enough for `OnePlaylist.Library.find_or_create/1` to key on.
  """
  # `identifies_the_source` is the law that makes the result usable at all:
  # `Track`'s own `identifiable` invariant demands a non-blank `provider_id`, and
  # a row whose `source_track_id` were blank would build a track that compares
  # equal to every other blank one — `Runner`'s snapshot-and-diff conflating two
  # rows, one level further on. `source_track_id` is `validate_required`, so this
  # is a restatement over the value a caller actually receives.
  #
  # Proven by mutation: taking `provider_id` from `destination_track_id` fires it
  # on any unmatched row, where that field is `nil`.
  @post identifies_the_source:
          result.provider == provider and is_binary(result.provider_id) and
            result.provider_id != ""
  @post keeps_what_the_row_recorded:
          result.title == item.source_title and result.album == item.source_album and
            result.isrc == item.source_isrc
  @spec to_source_track(t(), atom()) :: Track.t()
  def to_source_track(%__MODULE__{} = item, provider) when is_atom(provider) do
    %Track{
      provider: provider,
      provider_id: item.source_track_id,
      isrc: item.source_isrc,
      title: item.source_title,
      artists: List.wrap(item.source_artist),
      album: item.source_album,
      artwork_url: item.source_artwork_url
    }
  end

  @doc """
  Counts a set of report rows by what happened to them.

  The shape matches `OnePlaylist.Transfers.Transfer.tally/1` exactly, and that is
  the point: the counters on a transfer and the rows of its report are built by
  two separate folds over the same resolutions, and this is what lets them be
  compared rather than assumed to agree. See the precondition on
  `OnePlaylist.Transfers.record_run/3`.

  Accepts rows in either representation — the plain maps `matched/4` and
  `unmatched/4` return before they are written, and the `%TransferItem{}` structs
  that come back out of the database.

      iex> alias OnePlaylist.Transfers.TransferItem
      iex> TransferItem.tally([%{outcome: :matched}, %{outcome: :already_present}, %{outcome: :unmatched}])
      %{total: 3, matched: 2, added: 1, unmatched: 1}

  A row whose outcome is missing or unrecognised counts toward `total` and
  nothing else, which is deliberate: the comparison then fails and says so,
  rather than the tally raising from inside an assertion.
  """
  @spec tally(Enumerable.t()) :: %{
          total: non_neg_integer(),
          matched: non_neg_integer(),
          added: non_neg_integer(),
          unmatched: non_neg_integer()
        }
  def tally(items) do
    Enum.reduce(items, %{total: 0, matched: 0, added: 0, unmatched: 0}, fn item, acc ->
      acc = %{acc | total: acc.total + 1}

      case Map.get(item, :outcome) do
        # `matched_count` counts everything that resolved; `added_count` only
        # what was actually written. The difference is what a re-run looks like.
        :matched -> %{acc | matched: acc.matched + 1, added: acc.added + 1}
        :already_present -> %{acc | matched: acc.matched + 1}
        :unmatched -> %{acc | unmatched: acc.unmatched + 1}
        _absent_or_unrecognised -> acc
      end
    end)
  end

  @doc """
  The row for a track that resolved.

  `added?` decides between `:matched` and `:already_present`; everything else
  is copied off the `OnePlaylist.Matching.Match` so the report can explain the
  decision without re-running it.

  A report row is this application's product: `docs/reference/domain.md` argues
  that explaining *what happened to every track* is what distinguishes it from
  the incumbents, so a row recording an outcome without the evidence for it is
  the feature failing quietly rather than a cosmetic problem.

  `outcome_is_a_resolution` is the specification of `added?` — a resolved track
  is `:matched` when this run wrote it and `:already_present` when the
  destination already had it, never anything else, which is what makes a re-run
  legible. `names_what_it_matched` is the half that can fail on data:
  `to_string(nil)` is `""`, so a provider omitting an id yields a row that says
  "matched" while naming nothing.
  """
  @post outcome_is_a_resolution: result.outcome in [:matched, :already_present],
        names_what_it_matched:
          is_binary(result.destination_track_id) and result.destination_track_id != ""
  @spec matched(map(), non_neg_integer(), Match.t(), boolean()) :: map()
  def matched(base, position, %Match{} = match, added?) do
    base
    |> common(position, match.source)
    |> Map.merge(%{
      outcome: if(added?, do: :matched, else: :already_present),
      destination_track_id: match.track.provider_id,
      destination_title: match.track.title,
      destination_artist: List.first(match.track.artists),
      destination_album: match.track.album,
      destination_artwork_url: match.track.artwork_url,
      confidence: to_string(match.confidence),
      score: match.score,
      strategy: to_string(match.strategy)
    })
  end

  @doc """
  The row for a track that did not resolve.

  Carries the reason and how many candidates were considered, because
  "nothing was found" and "four were found and none was good enough" are
  different problems with different fixes — and only the second is worth
  offering the user a manual choice for.
  """
  # The claim the docstring above makes, stated where it can be checked. An
  # unmatched row whose `reason` is blank renders as a track that failed for no
  # stated cause — which is precisely the row a user opens the report to read,
  # and the difference between "nothing was found" and "four were found and none
  # was good enough" is the difference between a dead end and a manual choice.
  @post outcome_is_unresolved: result.outcome == :unmatched,
        says_why: is_binary(result.reason) and result.reason != ""
  @spec unmatched(map(), non_neg_integer(), Track.t(), Exception.t()) :: map()
  def unmatched(base, position, %Track{} = source, error) do
    context = Errata.context(error)

    base
    |> common(position, source)
    |> Map.merge(%{
      outcome: :unmatched,
      reason: to_string(Errata.reason(error)),
      score: context[:best_score],
      confidence: context[:best_confidence] && to_string(context[:best_confidence]),
      candidates_considered: context[:candidates_considered]
    })
  end

  @doc false
  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :transfer_id,
      :user_id,
      :position,
      :source_track_id,
      :source_isrc,
      :source_title,
      :source_artist,
      :source_album,
      :source_artwork_url,
      :outcome,
      :destination_track_id,
      :destination_title,
      :destination_artist,
      :destination_album,
      :destination_artwork_url,
      :confidence,
      :score,
      :strategy,
      :reason,
      :candidates_considered,
      :candidates
    ])
    |> validate_required([:transfer_id, :user_id, :position, :source_track_id, :outcome])
  end

  defp common(base, position, %Track{} = source) do
    Map.merge(base, %{
      position: position,
      source_track_id: source.provider_id,
      source_isrc: source.isrc,
      source_title: source.title,
      source_artist: Track.primary_artist(source),
      source_album: source.album,
      source_artwork_url: source.artwork_url
    })
  end
end
