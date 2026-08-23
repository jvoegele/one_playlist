defmodule OnePlaylist.Music.TrackSerializationTest do
  @moduledoc """
  `to_map/1` and `from_map/1`, which carry an uploaded playlist from the request
  that parsed it to the worker that runs it.

  The round trip is the whole guarantee. A field silently lost here is a field
  the matching engine never sees, and the symptom would be a worse match rate on
  imports with no error anywhere.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias OnePlaylist.Music.Track

  defp maybe(gen), do: one_of([constant(nil), gen])

  defp text do
    gen all(s <- string(:printable, min_length: 1, max_length: 30), String.trim(s) != "") do
      s
    end
  end

  defp track do
    gen all(
          provider <- member_of([:file, :tidal, :navidrome, :subsonic]),
          provider_id <- text(),
          isrc <- maybe(string(?A..?Z, length: 12)),
          title <- maybe(text()),
          album <- maybe(text()),
          upc <- maybe(string(?0..?9, length: 13)),
          track_number <- maybe(integer(1..99)),
          volume_number <- maybe(integer(1..9)),
          version <- maybe(text()),
          duration <- maybe(integer(0..7200)),
          explicit <- maybe(boolean()),
          popularity <- maybe(float(min: 0.0, max: 1.0)),
          artwork_url <- maybe(text()),
          artists <- list_of(text(), max_length: 3)
        ) do
      %Track{
        provider: provider,
        provider_id: provider_id,
        isrc: isrc,
        title: title,
        album: album,
        album_upc: upc,
        track_number: track_number,
        volume_number: volume_number,
        version: version,
        duration_seconds: duration,
        explicit: explicit,
        popularity: popularity,
        artwork_url: artwork_url,
        artists: artists
      }
    end
  end

  property "a track survives to_map and back unchanged" do
    check all(track <- track()) do
      assert Track.from_map(Track.to_map(track)) == track
    end
  end

  property "and survives a real trip through JSON" do
    # `to_map/1`'s output goes into a jsonb column, so it has to be encodable and
    # come back with string keys. Testing the struct round trip alone would miss
    # a field that is fine in Elixir and unrepresentable in JSON.
    check all(track <- track()) do
      decoded = track |> Track.to_map() |> Jason.encode!() |> Jason.decode!()

      assert Track.from_map(decoded) == track
    end
  end

  test "every field of the struct is carried" do
    # The property above would still pass if a field were dropped from *both*
    # functions. This is the check that notices a new field nobody wired up.
    fields = %Track{provider: :file, provider_id: "1"} |> Map.from_struct() |> Map.keys()
    carried = Track.to_map(%Track{provider: :file, provider_id: "1"}) |> Map.keys()

    assert Enum.sort(carried) == Enum.sort(Enum.map(fields, &to_string/1))
  end

  test "an unknown provider raises rather than producing a track with none" do
    # Only reachable for a row written by a build that supported a provider this
    # one does not. `Track`'s `identifiable` invariant would reject the nil a
    # tolerant version produced, but somewhere else entirely.
    assert_raise ArgumentError, fn ->
      Track.from_map(%{"provider" => "a_provider_that_has_never_existed", "provider_id" => "1"})
    end
  end
end
