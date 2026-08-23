defmodule OnePlaylist.Music.Track do
  @moduledoc """
  A recording, described independently of the service it came from.

  This is the currency the matching engine deals in: a track read from TIDAL and
  a track read from Apple Music become the same shape, and matching compares
  these rather than two providers' JSON.

  ## The fields exist because matching needs them

  Each corresponds to a rung on the matching ladder in
  `docs/reference/domain.md`:

    * `isrc` — the International Standard Recording Code. Globally unique per
      *recording*, so an ISRC match is an exact match rather than a guess. This
      is the whole reason the struct exists; everything else is fallback.
    * `title`, `artists` — normalized text matching, when ISRC is absent or
      differs across territorial releases.
    * `album` — disambiguates a title that appears on several releases.
    * `duration_seconds` — the cheapest signal for rejecting covers, edits and
      karaoke versions, which often match on title and artist alone.
    * `isrc` being `nil` is expected and normal: local files, podcasts, and
      some regional catalogue entries have none.
    * `album_upc`, `track_number`, `volume_number` — rung 2 of the ladder, which
      recovers tracks whose ISRC differs across territorial releases. Note that
      a UPC alone is not a match: it identifies a *release*, so it only becomes
      one in combination with a position within that release.
    * `version` — the provider's own subtitle for a recording, such as
      `"Remastered 2015"` or `"Live"`. Worth a field of its own rather than
      folding into `title`, because it is the difference between two recordings
      that are otherwise identical in every matchable field, and reading it from
      a structured field beats parsing it back out of a title.
    * `popularity` — not a matching signal. It breaks ties deterministically
      when two candidates are otherwise indistinguishable, which happens on the
      very first live ISRC lookup: one ISRC, two catalogue entries.

  `provider` and `provider_id` identify where this came from, so a match can be
  cached as "this recording is that id over there" rather than re-derived.
  """

  use Bond

  @enforce_keys [:provider, :provider_id]
  defstruct [
    :provider,
    :provider_id,
    :isrc,
    :title,
    :album,
    :album_upc,
    :track_number,
    :volume_number,
    :version,
    :duration_seconds,
    :explicit,
    :popularity,
    artists: []
  ]

  @type t :: %__MODULE__{
          provider: atom(),
          provider_id: String.t(),
          isrc: String.t() | nil,
          title: String.t() | nil,
          album: String.t() | nil,
          album_upc: String.t() | nil,
          track_number: pos_integer() | nil,
          volume_number: pos_integer() | nil,
          version: String.t() | nil,
          duration_seconds: non_neg_integer() | nil,
          explicit: boolean() | nil,
          popularity: number() | nil,
          artists: [String.t()]
        }

  # What a track *is*, stated once, on the type rather than at each of the
  # several places that build one.
  #
  # These fire on entry to and exit from the functions below — which is why they
  # can exist at all. Until `search_query/1` and friends moved here, this module
  # had no function taking or returning a `%Track{}`, so an invariant would have
  # been checked nowhere. See `docs/reference/contracts.md`.
  #
  # `identifiable` is the law the whole application leans on without saying so.
  # `to_string(nil)` is `""`, so a provider omitting an id yields a track that
  # compares equal to every other id-less track: `Runner`'s snapshot-and-diff
  # then treats them as one, and either duplicates a track or silently skips
  # one. The same shape as `ids_are_usable_keys` on the adapter boundary, caught
  # one level earlier.
  #
  # `artists_is_a_list` is a type check, and earns its place under the exception
  # this project already recognises: `nil` there makes `[title | artists]` an
  # improper list, so `search_query/1` raises a `Protocol.UndefinedError` from
  # inside `Enum.filter/2` rather than saying what was wrong.
  #
  # `duration_is_never_negative` is the poisonous value from shape 4, lifted
  # from the parser to the type. A negative duration is not a shorter track — it
  # scores as a *near miss* against real durations in `Matching.Similarity`.
  @invariant identifiable:
               is_atom(subject.provider) and is_binary(subject.provider_id) and
                 subject.provider_id != "",
             artists_is_a_list: is_list(subject.artists),
             duration_is_never_negative:
               is_nil(subject.duration_seconds) or subject.duration_seconds >= 0

  @doc """
  The track as a person would type it into a search box: title, then artists.

  Every provider that can only search by text needs exactly this string, and
  both `OnePlaylist.Providers.Tidal` and `OnePlaylist.Providers.Navidrome` had
  written it out identically — one rule in two places, with nothing keeping them
  in step.

  Deliberately the **raw** title rather than the normalized one.
  `OnePlaylist.Matching.Normalize` exists to compare two strings that already
  describe the same recording; stripping `(Live)` here would ask the provider
  for the studio version and then reject everything it sent back. The matching
  engine applies its own rules to whatever comes back.

      iex> alias OnePlaylist.Music.Track
      iex> Track.search_query(%Track{provider: :tidal, provider_id: "1",
      ...>   title: "Omaha", artists: ["Moby Grape"]})
      "Omaha Moby Grape"

  Absent fields are dropped rather than rendered, so a track with no artists
  still searches by title:

      iex> alias OnePlaylist.Music.Track
      iex> Track.search_query(%Track{provider: :tidal, provider_id: "1", title: "Omaha"})
      "Omaha"
  """
  # The law that makes this usable as a query: an absent field leaves no trace.
  # Dropping the `is_binary/1` filter renders `nil` as the empty string, so a
  # track carrying `artists: [nil, "Moby Grape"]` — which the invariant permits,
  # since it constrains the list and not its members — searches for
  # `"Omaha  Moby Grape"`. The doubled space is what a provider's tokenizer sees
  # as an extra empty term, and it is invisible in every log and test output
  # that does not quote the string.
  #
  # Trimming alone would not catch it: a `nil` at either end is absorbed by the
  # trim, and only one in the middle survives. Both halves are needed.
  @post no_absent_fields_rendered:
          result == String.trim(result) and not String.contains?(result, "  ")
  @spec search_query(t()) :: String.t()
  def search_query(%__MODULE__{} = track) do
    [track.title | track.artists]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> String.trim()
  end

  @doc """
  Whether two tracks sit at the same position on their respective releases.

  Rung 2 of the matching ladder pairs this with a barcode: the same position on
  the same release is the same recording, and that holds when neither side
  carries an ISRC.

  A missing `volume_number` is treated as disc 1, which is what a single-disc
  release means when a provider omits the field — `OnePlaylist.Providers.Tidal`
  reports it and Subsonic servers frequently do not.

      iex> alias OnePlaylist.Music.Track
      iex> a = %Track{provider: :tidal, provider_id: "1", track_number: 3}
      iex> b = %Track{provider: :navidrome, provider_id: "2", track_number: 3, volume_number: 1}
      iex> Track.same_position?(a, b)
      true
  """
  # Two `nil` track numbers are not "the same position" — they are two unknowns,
  # and treating them as equal would let rung 2 pair arbitrary untagged tracks
  # off a shared barcode. That is a false *positive*, the more dangerous
  # direction, so it is stated rather than left to the equality.
  @post unknown_positions_never_match:
          (is_nil(left.track_number) or is_nil(right.track_number)) ~> (result == false)
  @spec same_position?(t(), t()) :: boolean()
  def same_position?(%__MODULE__{} = left, %__MODULE__{} = right) do
    not is_nil(left.track_number) and
      left.track_number == right.track_number and
      (left.volume_number || 1) == (right.volume_number || 1)
  end

  @doc """
  A track's identity: which provider, and which id there.

  Provider ids are only unique *within* a provider, so this pair is what
  identifies a recording across the application — it is the key
  `OnePlaylist.Matching.source_ids/1` builds the transfer ledger from, and the
  reason a TIDAL id and a Navidrome id that happen to coincide are not confused.

      iex> alias OnePlaylist.Music.Track
      iex> Track.identity(%Track{provider: :tidal, provider_id: "12345"})
      {:tidal, "12345"}
  """
  @spec identity(t()) :: {atom(), String.t()}
  def identity(%__MODULE__{} = track), do: {track.provider, track.provider_id}

  @doc """
  The first credited artist, or `nil`.

  What a report row and a track listing show: the full credit is on the track
  for anyone who needs it, and a list a person scans wants one name.

      iex> alias OnePlaylist.Music.Track
      iex> Track.primary_artist(%Track{provider: :tidal, provider_id: "1",
      ...>   artists: ["Paul Simon", "Art Garfunkel"]})
      "Paul Simon"
  """
  @spec primary_artist(t()) :: String.t() | nil
  def primary_artist(%__MODULE__{} = track), do: List.first(track.artists)

  @doc """
  Parses an ISO 8601 duration into whole seconds.

  Providers report duration in incompatible ways — TIDAL uses ISO 8601
  (`"PT4M6S"`), others use milliseconds — so normalizing here keeps the
  difference out of the matching code.

  Returns `nil` rather than raising on anything unparseable: a missing duration
  costs one matching signal, while an exception costs the whole transfer.
  """
  # A recording cannot be of negative length, so a negative result is not a
  # shorter duration — it is a value that must not reach the matching engine,
  # where it would be compared against real durations and score as a near miss.
  #
  # This is not hypothetical: ISO 8601 admits negative components, and
  # `Duration.from_iso8601/1` accepts them. Measured before this contract
  # existed: `"PT-5S"` parsed to `-5`, `"P-1DT-1S"` to `-86_401`.
  #
  # Bond's linter notes that this function never mentions the struct, and here
  # that is a false positive worth distinguishing from the true one. When the
  # same warning fired on `Matching.Signals`, it was pointing at a barcode
  # utility that had no business in a module about comparing two tracks, and the
  # answer was to move it out — it is now `OnePlaylist.Music.Barcode`.
  #
  # This is the other case: a parser for one of the struct's **own fields**,
  # which is exactly what a struct module is for (`Date.from_iso8601/1` lives on
  # `Date`). Moving it would fragment the type across modules to satisfy a
  # heuristic.
  @bond_warn_skipped_invariants false
  @post non_negative: is_nil(result) or result >= 0
  @spec parse_iso8601_duration(String.t() | nil) :: non_neg_integer() | nil
  def parse_iso8601_duration(value)

  def parse_iso8601_duration(nil), do: nil

  def parse_iso8601_duration(value) when is_binary(value) do
    with {:ok, duration} <- Duration.from_iso8601(value),
         seconds when seconds >= 0 <- to_seconds(duration) do
      seconds
    else
      _negative_or_unparseable -> nil
    end
  end

  def parse_iso8601_duration(_value), do: nil

  # Deliberately ignores :year and :month. They cannot appear in a track length,
  # and treating them as fixed spans would be wrong if they ever did.
  defp to_seconds(%Duration{} = d) do
    d.week * 604_800 + d.day * 86_400 + d.hour * 3600 + d.minute * 60 + d.second
  end
end
