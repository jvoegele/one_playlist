defmodule OnePlaylist.Providers.Tidal.DocumentPropertyTest do
  @moduledoc """
  The three document shapes, with the mapper's own conservation laws as oracle.

  `OnePlaylist.Providers.Tidal.Mapper` now reads three differently-shaped JSON:API
  documents, and they are easy to confuse:

  | Function | `data` holds | Tracks resolved from |
  | --- | --- | --- |
  | `tracks_from_items_page/1` | item identifiers | `included` |
  | `tracks_from_data/1` | the track resources | `data` itself |
  | `tracks_from_search/1` | one `searchResults` resource | `data[0].relationships.tracks` |
  | `tracks_from_album_items/2` | items with `meta` positions | `included` |

  Getting two of them the wrong way round yields an **empty list**, not an
  error — which is why all four carry the same conservation postconditions, and
  why those postconditions are worth driving with generated input rather than
  only with the captured fixtures.

  `contract_holds/2` is the whole test here. There are no expectations to
  write: `no_tracks_invented`, `never_more_than_*` and `positions_are_populated`
  already say what must hold, and restating them in an `assert` would be the
  same law maintained in two places.

  Each generator is paired with a guard measuring that it actually resolves
  tracks. `docs/reference/contracts.md` records a property suite here that
  produced 0 useful documents out of 500 and passed anyway; every generator
  below derives `included` from `data` for exactly that reason.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties
  use Bond.PropertyTest

  alias OnePlaylist.Providers.Tidal.Mapper

  contract_holds(&Mapper.tracks_from_data/1, args: [catalogue_document()])
  contract_holds(&Mapper.tracks_from_search/1, args: [search_document()])

  contract_holds(&Mapper.tracks_from_album_items/2,
    args: [album_items_document(), StreamData.constant("602547670052")]
  )

  describe "the generators are not vacuous" do
    test "each shape actually produces tracks" do
      measurements = [
        {"tracks_from_data", catalogue_document(), &Mapper.tracks_from_data/1},
        {"tracks_from_search", search_document(), &Mapper.tracks_from_search/1},
        {"tracks_from_album_items", album_items_document(),
         &Mapper.tracks_from_album_items(&1, "602547670052")}
      ]

      for {name, generator, map} <- measurements do
        produced =
          generator
          |> Enum.take(200)
          |> Enum.count(&(map.(&1) != []))

        assert produced > 50,
               "#{name}: only #{produced}/200 generated documents produced a track — " <>
                 "the contract_holds property above it would be vacuous"
      end
    end
  end

  describe "the shapes are not interchangeable" do
    property "a search document read as a catalogue page yields nothing" do
      # The confusion the conservation contracts exist to survive. It must be
      # an empty list rather than an exception or, worse, a plausible-looking
      # list of the wrong tracks.
      check all(document <- search_document()) do
        assert Mapper.tracks_from_data(document) == []
      end
    end

    property "a catalogue page read as a search document yields nothing" do
      check all(document <- catalogue_document()) do
        assert Mapper.tracks_from_search(document) == []
      end
    end
  end

  # `data` holds the track resources directly, as `/tracks?filter[isrc]` returns.
  defp catalogue_document do
    gen all(entries <- track_entries()) do
      %{
        "data" => Enum.map(entries, &track_resource/1),
        "included" => Enum.flat_map(entries, &related_resources/1)
      }
    end
  end

  # `data` holds a single `searchResults` resource whose relationship names the
  # tracks, and the resources live in `included`. Some ids deliberately have no
  # resource, to reach the drop-when-absent branch.
  defp search_document do
    gen all(entries <- track_entries(), extra <- StreamData.list_of(id(), max_length: 3)) do
      ids = Enum.map(entries, fn {id, _present, _attrs} -> id end)

      %{
        "data" => [
          %{
            "id" => "search-token",
            "type" => "searchResults",
            "attributes" => %{"query" => "anything"},
            "relationships" => %{
              "tracks" => %{
                "data" =>
                  for id <- ids ++ extra do
                    %{"id" => id, "type" => "tracks"}
                  end
              }
            }
          }
        ],
        "included" =>
          Enum.flat_map(entries, fn {_id, present, _attrs} = entry ->
            if present, do: [track_resource(entry)], else: []
          end) ++ Enum.flat_map(entries, &related_resources/1)
      }
    end
  end

  # `data` holds items carrying `meta` positions; resources live in `included`.
  # Positions are generated *independently of list order* so that a mapper
  # counting by index would disagree — the mutation that survived a real-fixture
  # test until a multi-volume case was added.
  defp album_items_document do
    gen all(entries <- track_entries(), volumes <- StreamData.integer(1..2)) do
      data =
        entries
        |> Enum.with_index()
        |> Enum.map(fn {{id, _present, _attrs}, index} ->
          %{
            "id" => id,
            "type" => "tracks",
            "meta" => %{
              "trackNumber" => div(index, volumes) + 1,
              "volumeNumber" => rem(index, volumes) + 1
            }
          }
        end)

      included =
        Enum.flat_map(entries, fn {_id, present, _attrs} = entry ->
          if present, do: [track_resource(entry)], else: []
        end)

      %{"data" => data, "included" => included ++ Enum.flat_map(entries, &related_resources/1)}
    end
  end

  defp track_entries do
    StreamData.uniq_list_of(
      StreamData.tuple(
        {id(),
         StreamData.frequency([{4, StreamData.constant(true)}, {1, StreamData.constant(false)}]),
         attributes()}
      ),
      min_length: 1,
      max_length: 6,
      uniq_fun: fn {id, _present, _attrs} -> id end
    )
  end

  defp id, do: StreamData.string(:alphanumeric, min_length: 1, max_length: 6)

  defp track_resource({id, _present, attrs}) do
    %{
      "id" => id,
      "type" => "tracks",
      "attributes" => attrs,
      "relationships" => %{
        "artists" => %{"data" => [%{"id" => "artist-#{id}", "type" => "artists"}]},
        "albums" => %{"data" => [%{"id" => "album-#{id}", "type" => "albums"}]}
      }
    }
  end

  defp related_resources({id, _present, _attrs}) do
    [
      %{"id" => "artist-#{id}", "type" => "artists", "attributes" => %{"name" => "Artist #{id}"}},
      %{
        "id" => "album-#{id}",
        "type" => "albums",
        "attributes" => %{"title" => "Album #{id}", "barcodeId" => "00602547670052"}
      }
    ]
  end

  defp attributes do
    StreamData.optional_map(%{
      "title" => StreamData.string(:printable, max_length: 12),
      "isrc" => StreamData.string(:alphanumeric, max_length: 12),
      "duration" => StreamData.map(StreamData.integer(0..600), &"PT#{&1}S"),
      "version" => StreamData.string(:printable, max_length: 8),
      "popularity" => StreamData.float(min: 0.0, max: 1.0)
    })
  end
end
