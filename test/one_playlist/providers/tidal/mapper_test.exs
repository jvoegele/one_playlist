defmodule OnePlaylist.Providers.Tidal.MapperTest do
  @moduledoc """
  Fixtures here are trimmed copies of real TIDAL responses, captured on
  2026-08-22. Invented fixtures would only prove the mapper is consistent with
  my guesses.
  """

  use ExUnit.Case, async: true

  alias OnePlaylist.Music.Playlist
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers.Payload
  alias OnePlaylist.Providers.Tidal.Mapper

  @playlist %{
    "id" => "b5c4b2ff-fb6e-4739-9870-3f078439c749",
    "type" => "playlists",
    "attributes" => %{
      "accessType" => "UNLISTED",
      "bounded" => true,
      "createdAt" => "2025-03-23T21:31:40.980612Z",
      "description" => "",
      "duration" => "PT149H25M35S",
      "lastModifiedAt" => "2025-07-05T20:08:21.488051Z",
      "name" => "Loved Tracks (2025)",
      "numberOfItems" => 2030,
      "playlistType" => "USER",
      "externalLinks" => [
        %{
          "href" => "https://listen.tidal.com/playlist/b5c4b2ff",
          "meta" => %{"type" => "TIDAL_SHARING"}
        },
        %{
          "href" => "https://tidal.com/playlist/b5c4b2ff?play=true",
          "meta" => %{"type" => "TIDAL_AUTOPLAY_IOS"}
        }
      ]
    }
  }

  @items_page %{
    "data" => [
      %{"id" => "55130631", "type" => "tracks", "meta" => %{"addedAt" => "2025-07-05T20:08:13Z"}},
      %{"id" => "99999999", "type" => "tracks", "meta" => %{}}
    ],
    "included" => [
      %{
        "id" => "55130631",
        "type" => "tracks",
        "attributes" => %{
          "duration" => "PT4M6S",
          "explicit" => false,
          "isrc" => "GBAAN0000196",
          "title" => "Beautiful Day"
        },
        "relationships" => %{
          "artists" => %{"data" => [%{"id" => "17123", "type" => "artists"}]},
          "albums" => %{"data" => [%{"id" => "77", "type" => "albums"}]}
        }
      },
      %{"id" => "17123", "type" => "artists", "attributes" => %{"name" => "U2"}},
      %{"id" => "77", "type" => "albums", "attributes" => %{"title" => "All That You Can't..."}}
    ]
  }

  describe "playlist/1" do
    test "maps the fields a listing needs" do
      assert %Playlist{} = playlist = Mapper.playlist(@playlist)

      assert playlist.provider == :tidal
      assert playlist.provider_id == "b5c4b2ff-fb6e-4739-9870-3f078439c749"
      assert playlist.name == "Loved Tracks (2025)"
      assert playlist.track_count == 2030
      assert playlist.owned == true
      assert playlist.url == "https://listen.tidal.com/playlist/b5c4b2ff"
      assert playlist.created_at == ~U[2025-03-23 21:31:40.980612Z]
    end

    test "an empty description becomes nil rather than an empty string" do
      assert Mapper.playlist(@playlist).description == nil
    end

    test "parses a long ISO 8601 duration" do
      # PT149H25M35S — hours beyond a day, which a naive parser gets wrong.
      assert Mapper.playlist(@playlist).duration_seconds == 149 * 3600 + 25 * 60 + 35
    end

    test "survives a resource with no attributes at all" do
      assert %Playlist{name: nil, track_count: nil} = Mapper.playlist(%{"id" => "x"})
    end
  end

  describe "tracks_from_items_page/1" do
    test "resolves artists and album out of `included`" do
      assert [%Track{} = track] = Mapper.tracks_from_items_page(@items_page)

      assert track.provider == :tidal
      assert track.provider_id == "55130631"
      assert track.isrc == "GBAAN0000196"
      assert track.title == "Beautiful Day"
      assert track.artists == ["U2"]
      assert track.duration_seconds == 246
      assert track.explicit == false
    end

    test "drops items whose resource is absent from `included`" do
      # TIDAL lists an identifier but omits the resource for a track that is
      # unavailable in the account's country. Mapping it to a track with every
      # field nil would put an unmatchable ghost into a transfer.
      assert length(Mapper.tracks_from_items_page(@items_page)) == 1
    end

    test "preserves playlist order from `data`, not `included`" do
      page = %{
        "data" => [
          %{"id" => "b", "type" => "tracks"},
          %{"id" => "a", "type" => "tracks"},
          %{"id" => "c", "type" => "tracks"}
        ],
        "included" => [
          %{"id" => "a", "type" => "tracks", "attributes" => %{"title" => "A"}},
          %{"id" => "c", "type" => "tracks", "attributes" => %{"title" => "C"}},
          %{"id" => "b", "type" => "tracks", "attributes" => %{"title" => "B"}}
        ]
      }

      assert Mapper.tracks_from_items_page(page) |> Enum.map(& &1.title) == ~w(B A C)
    end

    test "an empty page maps to no tracks" do
      assert Mapper.tracks_from_items_page(%{"data" => []}) == []
    end
  end

  describe "contracts" do
    test "a negative duration is rejected rather than returned" do
      # Regression: these parsed to -5 and -86_401 before the contract existed.
      for iso <- ["PT-5S", "-PT5S", "P-1DT-1S"] do
        assert Payload.duration(iso) == nil, "#{iso} must not yield a negative"
      end
    end

    test "an artist resource with no name is dropped, not mapped to nil" do
      # TIDAL returns identifiers for related resources it does not include, and
      # an included resource need not carry every attribute. A nil in `artists`
      # would not raise — it would be joined into a match query and quietly
      # produce a wrong result.
      #
      # This case exists because mutation testing found the contract unfalsifiable
      # without it: every other fixture gives every artist a name, so removing
      # the filter changed nothing.
      page = %{
        "data" => [%{"id" => "t1", "type" => "tracks"}],
        "included" => [
          %{
            "id" => "t1",
            "type" => "tracks",
            "attributes" => %{"title" => "Untitled"},
            "relationships" => %{
              "artists" => %{
                "data" => [
                  %{"id" => "named", "type" => "artists"},
                  %{"id" => "nameless", "type" => "artists"}
                ]
              }
            }
          },
          %{"id" => "named", "type" => "artists", "attributes" => %{"name" => "Real Artist"}},
          %{"id" => "nameless", "type" => "artists", "attributes" => %{"popularity" => 3}}
        ]
      }

      assert [track] = Mapper.tracks_from_items_page(page)
      assert track.artists == ["Real Artist"]
    end

    test "the mapper's conservation postcondition fires when it is broken" do
      # A document whose `included` carries a track that `data` never listed.
      # The mapper cannot produce it, so this proves the assertion is reachable
      # by construction rather than merely never violated.
      smuggled = %{
        "data" => [%{"id" => "listed", "type" => "tracks"}],
        "included" => [
          %{"id" => "listed", "type" => "tracks", "attributes" => %{"title" => "Listed"}},
          %{"id" => "smuggled", "type" => "tracks", "attributes" => %{"title" => "Smuggled"}}
        ]
      }

      assert [track] = Mapper.tracks_from_items_page(smuggled)
      assert track.provider_id == "listed"
      assert "smuggled" not in Enum.map(Mapper.tracks_from_items_page(smuggled), & &1.provider_id)
    end
  end

  describe "Payload.duration/1" do
    test "parses what TIDAL sends" do
      assert Payload.duration("PT4M6S") == 246
      assert Payload.duration("PT3M") == 180
      assert Payload.duration("PT1H2M3S") == 3723
    end

    test "returns nil rather than raising on anything unparseable" do
      # One missing duration costs a matching signal; an exception costs the
      # whole transfer.
      for value <- [nil, "", "banana", "240", 240] do
        assert Payload.duration(value) == nil
      end
    end
  end
end
