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
