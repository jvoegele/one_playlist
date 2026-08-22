defmodule OnePlaylist.Matching.SignalsPropertyTest do
  @moduledoc """
  `Signals.compare/2` driven over random tracks, with its own invariant as the
  oracle.

  ## Why this is not covered by `SimilarityPropertyTest`

  That file drives each scoring primitive in isolation, and every one of them is
  total and independently contracted. This one drives the layer that *composes*
  them, which is where the interesting inputs are:

    * `Normalize.title/2` strips version markers and pulls `(feat. X)` out into
      the artist list **before** anything is compared, so the strings the
      primitives see are not the strings the tracks carry;
    * artist similarity is `Enum.max/1` over two `dice/2` results — the name
      sets and the word sets — and a max over contracted values is exactly the
      kind of composition that looks obviously safe and is worth checking;
    * every field is independently absent-able, so a real comparison mixes
      `nil` and float in ways an example test picks one of.

  ## The generator is deliberately a tight pool

  `contract_holds/2` draws each argument independently, so it cannot produce a
  *correlated* pair — two tracks are only ever similar because the pool they are
  drawn from is small. A generator of unrelated random tracks would compare
  nothing to nothing several hundred times, every similarity would be `nil` or
  near zero, and the arithmetic that can actually leave the unit interval would
  never run. The guards at the bottom are what keep that honest; they exist
  because the equivalent guard in `SimilarityPropertyTest` caught precisely that
  mistake.
  """

  use ExUnit.Case, async: true
  use Bond.PropertyTest

  alias OnePlaylist.Matching.Signals
  alias OnePlaylist.Music.Track

  # One-word variations, so the Winkler prefix bonus — the only arithmetic in
  # the title and album paths that can exceed 1.0 — is actually reached.
  defp title_generator do
    StreamData.frequency([
      {6,
       StreamData.member_of([
         "Hey Grandma",
         "Hey Grandma!",
         "hey grandma",
         "Hey Grandmas",
         "Omaha",
         "Omaha (Remastered)",
         "Omaha - Live",
         "Sitting by the Window"
       ])},
      {2, StreamData.string(:alphanumeric, max_length: 20)},
      {1, StreamData.constant("")},
      {1, StreamData.constant(nil)}
    ])
  end

  defp artists_generator do
    StreamData.list_of(
      StreamData.member_of([
        "Moby Grape",
        "moby grape",
        "The Beatles",
        "Beatles, The",
        "Skip Spence",
        "Bob Mosley"
      ]),
      max_length: 3
    )
  end

  defp album_generator do
    StreamData.frequency([
      {6, StreamData.member_of(["Moby Grape", "Moby Grape (Expanded)", "Wow", "Grape Jam"])},
      {1, StreamData.constant(nil)}
    ])
  end

  defp duration_generator do
    StreamData.frequency([
      {6, StreamData.integer(60..400)},
      {1, StreamData.constant(nil)}
    ])
  end

  defp upc_generator do
    StreamData.frequency([
      {4, StreamData.member_of(["00602547670052", "602547670052", "888880001234"])},
      {2, StreamData.constant(nil)}
    ])
  end

  defp version_generator do
    StreamData.frequency([
      {4, StreamData.constant(nil)},
      {1, StreamData.member_of(["Live", "Remastered", "Karaoke Version", "Radio Edit"])}
    ])
  end

  defp track_generator do
    StreamData.map(
      StreamData.tuple({
        title_generator(),
        artists_generator(),
        album_generator(),
        duration_generator(),
        upc_generator(),
        version_generator()
      }),
      fn {title, artists, album, duration, upc, version} ->
        %Track{
          provider: :tidal,
          provider_id: "t1",
          title: title,
          artists: artists,
          album: album,
          duration_seconds: duration,
          album_upc: upc,
          version: version
        }
      end
    )
  end

  # No expectations, because the invariant already states the law: every
  # similarity field is `nil` or a float in `0.0..1.0`. A value outside that
  # range does not raise — it outranks an exact ISRC match.
  contract_holds(&Signals.compare/2, args: [track_generator(), track_generator()])

  describe "the generator reaches the branches that can break the bound" do
    property "comparisons are usually real comparisons, not nil against nil" do
      # The guard that matters. If the pool were loose, almost every field would
      # be `nil` — the invariant would hold, the property would pass, and the
      # arithmetic it exists to check would never have run.
      pairs = Enum.take(StreamData.tuple({track_generator(), track_generator()}), 300)

      scored =
        Enum.count(pairs, fn {left, right} ->
          signals = Signals.compare(left, right)
          is_float(signals.title) and is_float(signals.artists) and is_float(signals.duration)
        end)

      assert scored > 60,
             "only #{scored}/300 generated pairs produced title, artist and duration scores"
    end

    property "the Winkler prefix bonus is reached" do
      # Jaro must exceed 0.7 before the bonus applies, and the bonus is the one
      # place the title and album paths can exceed 1.0.
      pairs = Enum.take(StreamData.tuple({title_generator(), title_generator()}), 300)

      boosted =
        Enum.count(pairs, fn {left, right} ->
          is_binary(left) and is_binary(right) and left != "" and right != "" and
            String.jaro_distance(left, right) > 0.7
        end)

      assert boosted > 20, "only #{boosted}/300 generated title pairs reached the bonus branch"
    end

    property "both the veto and the editorial penalty are exercised" do
      # `version_generator/0` exists to make these reachable: without a version
      # marker on either side nothing is ever tagged, so `discriminating` and
      # `editorial` would be empty sets in every single comparison and two of
      # the nine fields would be constant.
      pairs = Enum.take(StreamData.tuple({track_generator(), track_generator()}), 300)

      %{vetoed: vetoed, editorial: editorial} =
        Enum.reduce(pairs, %{vetoed: 0, editorial: 0}, fn {left, right}, acc ->
          signals = Signals.compare(left, right)

          %{
            vetoed: acc.vetoed + if(Signals.vetoed?(signals), do: 1, else: 0),
            editorial: acc.editorial + if(signals.editorial_conflict, do: 1, else: 0)
          }
        end)

      assert vetoed > 10, "only #{vetoed}/300 comparisons hit a discriminating conflict"
      assert editorial > 10, "only #{editorial}/300 comparisons hit an editorial conflict"
    end
  end
end
