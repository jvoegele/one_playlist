defmodule OnePlaylist.Providers.Tidal.MapperPropertyTest do
  @moduledoc """
  Robustness of the parsing layer against input nobody designed.

  The mapper turns a remote service's JSON into our structs, which makes it the
  one place in the application where arbitrary bytes from outside meet code that
  assumes a shape. The example-based tests pin the shapes TIDAL *does* send;
  these pin what happens for everything else.

  The property in every case is the same and is a product requirement rather
  than a nicety: **parsing must not raise**. A transfer reads thousands of
  tracks, and one unparseable duration killing the run — instead of costing that
  track one matching signal — is the difference between a report with a gap and
  no report at all.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers.Payload
  alias OnePlaylist.Providers.Tidal.Mapper

  describe "Payload.duration/1" do
    property "never raises, whatever it is handed" do
      check all(value <- term_that_might_be_a_duration()) do
        result = Payload.duration(value)

        # `is_integer/1` alone let a real bug through: ISO 8601 admits negative
        # components, so "PT-5S" parsed to -5 and this property passed. A
        # negative duration is not a shorter track, it is a value that would
        # score as a near miss against real durations in the matching engine.
        assert is_nil(result) or (is_integer(result) and result >= 0)
      end
    end

    property "a well-formed duration round-trips to non-negative seconds" do
      check all(
              hours <- integer(0..200),
              minutes <- integer(0..59),
              seconds <- integer(0..59)
            ) do
        iso = "PT#{hours}H#{minutes}M#{seconds}S"
        assert Payload.duration(iso) == hours * 3600 + minutes * 60 + seconds
      end
    end
  end

  describe "tracks_from_items_page/1" do
    property "never raises on an arbitrary document" do
      check all(document <- document()) do
        assert is_list(Mapper.tracks_from_items_page(document))
      end
    end

    property "the generators actually resolve, so the rest is not vacuous" do
      # This guards the properties below. An earlier generator produced 0
      # resolvable documents out of 500, which made them all trivially true.
      resolved =
        resolvable_document()
        |> Enum.take(200)
        |> Enum.count(&(Mapper.tracks_from_items_page(&1) != []))

      assert resolved > 50,
             "only #{resolved}/200 generated documents produced a track — the " <>
               "properties below would be vacuous"
    end

    property "never invents a track that was not in `data`" do
      check all(document <- document()) do
        ids = document |> Map.get("data", []) |> Enum.map(& &1["id"]) |> MapSet.new()
        mapped = Mapper.tracks_from_items_page(document)

        assert length(mapped) <= length(Map.get(document, "data", []))

        for track <- mapped do
          assert track.provider_id in ids
        end
      end
    end

    property "output order follows `data`, whatever order `included` is in" do
      check all(
              ids <- uniq_list_of(string(:alphanumeric, min_length: 1), min_length: 1),
              shuffle_seed <- integer()
            ) do
        data = Enum.map(ids, &%{"id" => &1, "type" => "tracks"})

        included =
          ids
          |> Enum.map(&%{"id" => &1, "type" => "tracks", "attributes" => %{"title" => &1}})
          |> Enum.shuffle()
          |> then(fn list -> if rem(shuffle_seed, 2) == 0, do: Enum.reverse(list), else: list end)

        mapped = Mapper.tracks_from_items_page(%{"data" => data, "included" => included})

        assert Enum.map(mapped, & &1.provider_id) == ids
      end
    end
  end

  describe "playlist/1" do
    property "never raises on an arbitrary resource" do
      check all(resource <- resource()) do
        assert %OnePlaylist.Music.Playlist{} = Mapper.playlist(resource)
      end
    end
  end

  # Deliberately includes values that are not strings at all: a provider that
  # changes a field's type is exactly the case a guard clause is for.
  defp term_that_might_be_a_duration do
    one_of([
      constant(nil),
      constant(""),
      string(:printable),
      string(:alphanumeric),
      map(integer(), &"PT#{&1}S"),
      map(integer(), & &1),
      constant("PT"),
      constant("P1Y2M3D"),
      constant("not a duration at all")
    ])
  end

  # `included` is *derived from* `data` rather than generated independently.
  #
  # An earlier version generated both with random ids. They never collided:
  # measured at 0 documents out of 500 producing a single track, which made
  # every property below vacuously true and left the whole resolution path —
  # artists, albums, the drop-when-absent branch — unexercised.
  #
  # Each item carries a flag for whether its resource appears in `included`, so
  # both the resolving and the dropping branch are reached.
  defp document do
    one_of([
      constant(%{}),
      constant(%{"data" => []}),
      fixed_map(%{"data" => list_of(item(), max_length: 5)}),
      resolvable_document()
    ])
  end

  defp resolvable_document do
    entry =
      tuple({
        string(:alphanumeric, min_length: 1),
        member_of(["tracks", "videos"]),
        boolean(),
        attributes()
      })

    entry
    |> uniq_list_of(max_length: 6, uniq_fun: fn {id, _, _, _} -> id end)
    |> map(fn entries ->
      data = for {id, type, _present, _attrs} <- entries, do: %{"id" => id, "type" => type}

      included =
        for {id, type, true, attrs} <- entries do
          %{
            "id" => id,
            "type" => type,
            "attributes" => attrs,
            "relationships" => %{
              "artists" => %{"data" => [%{"id" => "artist-#{id}", "type" => "artists"}]},
              "albums" => %{"data" => [%{"id" => "album-#{id}", "type" => "albums"}]}
            }
          }
        end

      related =
        Enum.flat_map(included, fn %{"id" => id} ->
          [
            %{"id" => "artist-#{id}", "type" => "artists", "attributes" => %{"name" => "A#{id}"}},
            %{"id" => "album-#{id}", "type" => "albums", "attributes" => %{"name" => "B#{id}"}}
          ]
        end)

      %{"data" => data, "included" => included ++ related}
    end)
  end

  defp item do
    fixed_map(%{
      "id" => string(:alphanumeric, min_length: 1),
      "type" => member_of(["tracks", "videos", "unknown"])
    })
  end

  defp resource do
    one_of([
      constant(%{"id" => "x"}),
      fixed_map(%{"id" => string(:alphanumeric, min_length: 1), "attributes" => attributes()})
    ])
  end

  defp attributes do
    optional_map(%{
      "title" => string(:printable),
      "name" => string(:printable),
      "isrc" => string(:alphanumeric),
      "duration" => term_that_might_be_a_duration(),
      "numberOfItems" => integer(),
      "createdAt" =>
        one_of([constant(nil), constant("nonsense"), constant("2025-01-01T00:00:00Z")]),
      "externalLinks" => one_of([constant(nil), constant([]), constant("not-a-list")])
    })
  end
end
