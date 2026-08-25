defmodule OnePlaylist.Library.EnrichmentTest do
  @moduledoc """
  Filling in what a recording does not know about itself.

  MusicBrainz is stubbed with `Req.Test`. What is being tested is the shape of
  the outcome: that gaps are filled, that nothing is overwritten, that a
  recording nobody can identify is not asked about forever, and — the case the
  whole design exists for — that a plausible wrong answer is declined.
  """

  use OnePlaylist.DataCase, async: false

  import Req.Test, only: [set_req_test_from_context: 1]

  alias OnePlaylist.Cache
  alias OnePlaylist.CoverArt
  alias OnePlaylist.Library.Enrichment
  alias OnePlaylist.AuthFixtures
  alias OnePlaylist.Library
  alias OnePlaylist.Library.PlaylistItem
  alias OnePlaylist.Library.Recording
  alias OnePlaylist.MusicBrainz.Client
  alias OnePlaylist.MusicBrainz.IsrcLookup

  # `ZZ` is an unassigned ISRC country code, so a fixture cannot collide with
  # music somebody imported into the dev database this shares.
  defp unique_isrc do
    "ZZZ9925" <>
      String.pad_leading(to_string(rem(System.unique_integer([:positive]), 100_000)), 5, "0")
  end

  @second_release "3f2a1c88-7d55-4e2b-9a10-6c4e0b7d2e91"
  # `ZZ` is an unassigned ISRC country code. A real one here collides with dev
  # data in the shared database — and now that one ISRC is one recording, the
  # collision is a constraint violation rather than a surprising row.
  @isrc "ZZZ992500090"
  @mbid "ea8c7b4c-bd88-4029-96ba-fb483eb29e8b"
  @release "9c5b2d61-4e8c-4f43-9b71-2c8bd0e1a5f0"
  # The release *group* — the album across all its pressings, which is what a
  # cover belongs to. See `OnePlaylist.CoverArt.Client`.
  @group "7a1f0f0e-2c44-4a1e-9d3f-6b8e5c2a1d90"

  setup :set_req_test_from_context

  setup do
    {:ok, _cleared} = Cache.delete_all()
    Repo.delete_all(IsrcLookup)

    Application.put_env(:one_playlist, :musicbrainz_req_options, plug: {Req.Test, Client})

    Application.put_env(:one_playlist, :cover_art_req_options, plug: {Req.Test, CoverArt.Client})

    stub_cover_art(:found)

    on_exit(fn ->
      Application.delete_env(:one_playlist, :musicbrainz_req_options)
      Application.delete_env(:one_playlist, :cover_art_req_options)
    end)
  end

  # A separate service from MusicBrainz, so a separate stub. `counter` records
  # each call so a test can assert an album is asked about only once.
  defp stub_cover_art(answer, counter \\ nil) do
    Req.Test.stub(CoverArt.Client, fn conn ->
      if counter, do: Agent.update(counter, &(&1 + 1))

      # A redirect is the archive's "yes" — see `OnePlaylist.CoverArt.Client`.
      case answer do
        :found ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://archive.test/cover.jpg")
          |> Plug.Conn.send_resp(307, "")

        :none ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end

  defp recording(attrs) do
    Repo.insert!(struct(%Recording{title: "Corduroy", artists: ["Pearl Jam"]}, attrs))
  end

  # One stub for every endpoint, dispatching on the path the way the real
  # service does. `overrides` replaces any of the three bodies.
  defp stub_musicbrainz(overrides \\ %{}, counter \\ nil) do
    Req.Test.stub(Client, fn conn ->
      if counter, do: Agent.update(counter, &[conn.request_path | &1])

      # `request_path` carries the `/ws/2` prefix from the base URL, so these
      # match on the segment rather than on the whole path.
      cond do
        conn.request_path =~ "/isrc/" ->
          Req.Test.json(conn, overrides[:isrc] || isrc_body())

        conn.request_path =~ "/recording/" ->
          Req.Test.json(conn, overrides[:lookup] || lookup_body())

        search?(conn.request_path) ->
          Req.Test.json(conn, overrides[:search] || search_body())

        conn.request_path =~ "/release/" ->
          Req.Test.json(conn, overrides[:release] || %{"cover-art-archive" => %{"front" => true}})
      end
    end)
  end

  defp search?(path), do: String.ends_with?(path, "/recording")

  defp isrc_body do
    %{"isrc" => @isrc, "recordings" => [%{"id" => @mbid, "isrcs" => [@isrc]}]}
  end

  defp lookup_body do
    %{
      "id" => @mbid,
      "title" => "Corduroy",
      "length" => 285_000,
      "isrcs" => [@isrc],
      "artist-credit" => [%{"name" => "Pearl Jam"}],
      "releases" => [
        %{
          "id" => @release,
          "title" => "Vitalogy",
          "barcode" => "074646690123",
          "release-group" => %{"id" => @group}
        }
      ]
    }
  end

  defp search_body(recordings \\ nil) do
    %{
      "recordings" =>
        recordings ||
          [
            %{
              "id" => @mbid,
              "score" => 100,
              "title" => "Corduroy",
              "length" => 285_000,
              "artist-credit" => [%{"name" => "Pearl Jam"}],
              "releases" => [
                %{"id" => @release, "title" => "Vitalogy", "release-group" => %{"id" => @group}}
              ]
            }
          ]
    }
  end

  describe "enrich/1 reconsidering with a person's correction" do
    # Roon's CSV export writes the album artist into the artist column, so every
    # track on a tribute record arrives credited to its subject. The recording
    # takes that credit, no search can find the real recording from it, and the
    # correction has nowhere to live but the playlist item.
    setup do
      recording =
        recording(%{
          title: "Kryptic Anthem",
          artists: ["Wrong Credit Co"],
          album: "A Tribute Record",
          isrc: nil
        })

      user_id = AuthFixtures.user_id_fixture()
      {:ok, playlist} = Library.create_playlist(user_id, "Somebody's")

      %{recording: recording, playlist: playlist, user_id: user_id}
    end

    # Answers only the corrected credit, so a test that passes proves the second
    # search was actually made with the item's words rather than the recording's.
    defp stub_only_for(credit) do
      Req.Test.stub(Client, fn conn ->
        cond do
          search?(conn.request_path) and URI.decode_www_form(conn.query_string) =~ credit ->
            Req.Test.json(conn, search_body([corrected_hit()]))

          search?(conn.request_path) ->
            Req.Test.json(conn, %{"recordings" => []})

          conn.request_path =~ "/recording/" ->
            Req.Test.json(conn, corrected_lookup())

          conn.request_path =~ "/release/" ->
            Req.Test.json(conn, %{"cover-art-archive" => %{"front" => true}})
        end
      end)
    end

    defp corrected_hit do
      %{
        "id" => @mbid,
        "score" => 100,
        "title" => "Kryptic Anthem",
        "artist-credit" => [%{"name" => "Real Performer"}],
        "releases" => [
          %{"id" => @release, "title" => "A Tribute Record", "release-group" => %{"id" => @group}}
        ]
      }
    end

    defp corrected_lookup do
      %{
        "id" => @mbid,
        "title" => "Kryptic Anthem",
        "artist-credit" => [%{"name" => "Real Performer"}],
        "releases" => [
          %{
            "id" => @release,
            "title" => "A Tribute Record",
            "release-group" => %{"id" => @group}
          }
        ]
      }
    end

    defp item_for(context, recording, attrs) do
      Repo.insert!(
        struct(
          %PlaylistItem{
            playlist_id: context.playlist.id,
            user_id: context.user_id,
            recording_id: recording.id,
            position: 0,
            title: recording.title,
            artists: recording.artists,
            album: recording.album,
            updated_at: DateTime.utc_now(),
            inserted_at: DateTime.utc_now()
          },
          attrs
        )
      )
    end

    test "a corrected item is tried when the recording's own words fail", context do
      %{recording: recording} = context
      item_for(context, recording, %{artists: ["Real Performer"]})
      stub_only_for("Real Performer")
      stub_cover_art(:none)

      assert {:ok, enriched} = Enrichment.enrich(recording)
      assert enriched.musicbrainz_recording_id == @mbid
    end

    test "and the recording keeps its own credit", context do
      %{recording: recording} = context
      # The item supplies a better question, never an answer written back. A
      # recording belongs to nobody, so one person's edit must not become
      # everybody's.
      item_for(context, recording, %{artists: ["Real Performer"]})
      stub_only_for("Real Performer")
      stub_cover_art(:none)

      {:ok, enriched} = Enrichment.enrich(recording)

      assert enriched.artists == ["Wrong Credit Co"]
      assert enriched.title == "Kryptic Anthem"
    end

    test "an item saying the same thing costs no extra request", context do
      %{recording: recording} = context
      # The ordinary case: an item imported alongside its recording carries
      # identical words, so there is no second question to ask. If this ever
      # regresses, every enrichment doubles its request count against a service
      # that allows one a second.
      item_for(context, recording, %{})

      {:ok, calls} = Agent.start_link(fn -> [] end)
      stub_musicbrainz(%{search: %{"recordings" => []}}, calls)
      stub_cover_art(:none)

      Enrichment.enrich(recording)

      searches = calls |> Agent.get(& &1) |> Enum.count(&search?/1)
      assert searches <= 2, "one subject asks at most a release-qualified and a broad search"
    end

    test "the question keeps the recording's own ISRC", context do
      # The anchor is what says the item and the recording are the same piece of
      # music. A subject carrying the *item's* ISRC would be asking about
      # something else, and the corroboration would be about a different
      # recording than the one being described. Somebody who has corrected an
      # ISRC has said the link is wrong, and unlinking is the gesture for that.
      #
      # This is the test that proves `subject_keeps_the_anchor` can fail: add
      # `isrc: item.isrc` to `subject/2` and the postcondition fires here.
      anchored = context.recording |> Ecto.Changeset.change(isrc: @isrc) |> Repo.update!()

      item_for(context, anchored, %{artists: ["Real Performer"], isrc: "ZZZ992500091"})

      Req.Test.stub(Client, fn conn ->
        cond do
          conn.request_path =~ "/isrc/" ->
            Req.Test.json(conn, %{"isrc" => @isrc, "recordings" => []})

          search?(conn.request_path) and URI.decode_www_form(conn.query_string) =~ "Real" ->
            Req.Test.json(conn, search_body([corrected_hit()]))

          search?(conn.request_path) ->
            Req.Test.json(conn, %{"recordings" => []})

          conn.request_path =~ "/recording/" ->
            Req.Test.json(conn, corrected_lookup())

          conn.request_path =~ "/release/" ->
            Req.Test.json(conn, %{"cover-art-archive" => %{"front" => true}})
        end
      end)

      stub_cover_art(:none)

      assert {:ok, enriched} = Enrichment.enrich(anchored)
      assert enriched.musicbrainz_recording_id == @mbid
      assert enriched.isrc == @isrc
    end

    test "an identified recording is not reconsidered", context do
      %{recording: recording} = context
      # Nothing to improve on, and `only_filled_gaps?/2` would refuse the write
      # anyway. Spending a request to learn that is the waste `due/1` avoids.
      identified =
        recording
        |> Ecto.Changeset.change(musicbrainz_recording_id: @mbid)
        |> Repo.update!()

      item_for(context, identified, %{artists: ["Real Performer"]})

      {:ok, calls} = Agent.start_link(fn -> [] end)
      stub_musicbrainz(%{search: %{"recordings" => []}}, calls)
      stub_cover_art(:none)

      Enrichment.enrich(identified)

      searches = calls |> Agent.get(& &1) |> Enum.count(&search?/1)
      assert searches <= 2
    end
  end

  describe "enrich/1 with an ISRC" do
    test "fills in everything the recording did not know" do
      stub_musicbrainz()

      {:ok, enriched} = Enrichment.enrich(recording(%{isrc: @isrc}))

      assert enriched.musicbrainz_recording_id == @mbid
      assert enriched.album == "Vitalogy"
      assert enriched.album_upc == "074646690123"
      assert enriched.duration_seconds == 285

      assert enriched.artwork_url ==
               "https://coverartarchive.org/release-group/#{@group}/front-250"

      assert enriched.enriched_at
    end

    test "never searches, because an identifier does not need arguing for" do
      {:ok, calls} = Agent.start_link(fn -> [] end)
      stub_musicbrainz(%{}, calls)

      {:ok, _enriched} = Enrichment.enrich(recording(%{isrc: @isrc}))

      refute Enum.any?(Agent.get(calls, & &1), &search?/1),
             "an ISRC identifies the recording outright; a search would be a wasted request"
    end

    test "leaves alone every field that already had a value" do
      # The failure this guards is quiet: a background job that assigned rather
      # than merged would rewrite a user's own titles and albums on a schedule.
      existing =
        recording(%{
          isrc: @isrc,
          title: "Corduroy (Remastered)",
          album: "Vitalogy",
          duration_seconds: 999
        })

      stub_musicbrainz()

      {:ok, enriched} = Enrichment.enrich(existing)

      assert enriched.title == "Corduroy (Remastered)"
      assert enriched.album == "Vitalogy"
      assert enriched.duration_seconds == 999
      assert enriched.album_upc == "074646690123", "the gaps should still be filled"
    end

    test "asks about an album's artwork once, however many recordings name it" do
      {:ok, covers} = Agent.start_link(fn -> 0 end)
      stub_musicbrainz()
      stub_cover_art(:found, covers)

      # Two *different* recordings — one ISRC is one recording — that resolve to
      # the same release group, which is the thing asked about once.
      {:ok, _first} = Enrichment.enrich(recording(%{isrc: @isrc}))
      {:ok, _second} = Enrichment.enrich(recording(%{isrc: unique_isrc(), title: "Nothingman"}))

      assert Agent.get(covers, & &1) == 1, "an album's worth of recordings asks this once"
    end

    test "asks the release group rather than the release" do
      # The bug this replaced: which pressing wins the barcode has nothing to do
      # with which pressing somebody uploaded a scan for. Of six releases of
      # Pearl Jam (2006) three have a cover, and the one chosen for its barcode
      # was not among them.
      {:ok, asked} = Agent.start_link(fn -> [] end)
      stub_musicbrainz()

      Req.Test.stub(CoverArt.Client, fn conn ->
        Agent.update(asked, &[{conn.method, conn.request_path} | &1])
        Plug.Conn.send_resp(conn, 404, "")
      end)

      {:ok, _enriched} = Enrichment.enrich(recording(%{isrc: @isrc}))

      assert Agent.get(asked, & &1) == [{"HEAD", "/release-group/#{@group}/front-250"}],
             "one HEAD on the constructed URL, and no redirect followed"
    end

    test "an unreachable archive is not a completed attempt" do
      # The failure that made this a rule. A whole library was re-enriched
      # against a CoverArt.Service that had not been started, every artwork call
      # errored, no job failed, and 150 recordings were stamped as fully looked
      # at with no cover between them — permanently, because `due/1` never
      # offers a stamped recording again.
      stub_musicbrainz()
      Req.Test.stub(CoverArt.Client, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      stored = recording(%{isrc: @isrc})

      assert {:error, error} = Enrichment.enrich(stored)
      assert Errata.reason(error) == :archive_unreachable
      assert Errata.retryable?(error), "so the worker snoozes rather than giving up"

      refreshed = Repo.get!(Recording, stored.id)

      refute refreshed.enriched_at, "so it will be offered again"
      assert refreshed.album == "Vitalogy", "and what was learned is still kept"
      assert refreshed.musicbrainz_recording_id == @mbid
    end

    test "an album with no cover *is* a completed attempt" do
      # The distinction that matters: 404 is the archive answering, not failing.
      stub_musicbrainz()
      stub_cover_art(:none)

      {:ok, enriched} = Enrichment.enrich(recording(%{isrc: @isrc}))

      assert enriched.enriched_at
      refute enriched.artwork_url
    end

    test "stores no artwork URL when the archive has no cover" do
      # The URL is constructed rather than fetched, so storing one unasked
      # would put a broken image in every playlist that shows the track.
      stub_musicbrainz()
      stub_cover_art(:none)

      {:ok, enriched} = Enrichment.enrich(recording(%{isrc: @isrc}))

      refute enriched.artwork_url
      assert enriched.album == "Vitalogy", "the rest should still have been filled in"
    end
  end

  describe "an ISRC that names a different recording" do
    test "is refused rather than believed" do
      # An identifier can be wrong *in the source*. Measured on a real library: a
      # CSV gave "Blood" from Vs. the ISRC USSM11100233, which MusicBrainz
      # resolves to "Pry, To" — a different song on a different album. The
      # matching was correct and the answer was not, and enrichment wrote that
      # identity down as fact.
      stub_musicbrainz(%{lookup: Map.put(lookup_body(), "title", "Pry, To")})

      {:ok, enriched} = Enrichment.enrich(recording(%{isrc: @isrc, title: "Blood"}))

      refute enriched.musicbrainz_recording_id
      refute enriched.album_upc, "nothing from that lookup belongs to this recording"
      assert enriched.enrichment_outcome == :identifier_disagreed
    end

    test "a title spelled differently is still believed" do
      # The floor is "is this the same piece of music at all", not "is this a
      # good match". Every exact-identifier pair in the captured corpus scores
      # 1.0 after normalization; the observed failures sit at 0.41 to 0.46.
      stub_musicbrainz(%{
        lookup: Map.put(lookup_body(), "title", "Corduroy (feat. Nobody) [Remastered]")
      })

      {:ok, enriched} = Enrichment.enrich(recording(%{isrc: @isrc, title: "Corduroy"}))

      assert enriched.musicbrainz_recording_id == @mbid
    end

    test "a recording found by *search* is not asked again" do
      # The search path already scored the candidate through the whole ladder at
      # the text ceiling. Re-checking the title there could only reject
      # something the ladder had already accepted on better evidence.
      stub_musicbrainz(%{
        isrc: %{"isrc" => @isrc, "recordings" => []},
        lookup: Map.put(lookup_body(), "title", "Pry, To")
      })

      {:ok, enriched} = Enrichment.enrich(recording(%{isrc: @isrc, album: "Vitalogy"}))

      assert enriched.musicbrainz_recording_id == @mbid
    end
  end

  describe "an ISRC MusicBrainz does not index" do
    test "falls through to searching by name" do
      # Found by looking at a playlist: seven of ten unidentified recordings
      # carried a perfectly good ISRC MusicBrainz simply does not hold, and the
      # identifier path gave up rather than trying the name.
      stub_musicbrainz(%{isrc: %{"isrc" => @isrc, "recordings" => []}})

      {:ok, enriched} = Enrichment.enrich(recording(%{isrc: @isrc, album: "Vitalogy"}))

      assert enriched.musicbrainz_recording_id == @mbid
      assert enriched.album_upc, "and the search result is used like any other"
    end

    test "does not attach the searched recording's ISRC over the one it has" do
      # The recording's own ISRC is real; MusicBrainz just has no such code. A
      # candidate found by name may legitimately carry a different one, and
      # overwriting would replace a true identifier with another recording's.
      stub_musicbrainz(%{isrc: %{"isrc" => @isrc, "recordings" => []}})

      {:ok, enriched} = Enrichment.enrich(recording(%{isrc: @isrc, album: "Vitalogy"}))

      assert enriched.isrc == @isrc
    end
  end

  describe "how the search query is built" do
    # The stub answers the *first* search with nothing and the second with the
    # real body, so a test can tell whether a retry happened at all.
    defp stub_second_attempt_only(counter) do
      Req.Test.stub(Client, fn conn ->
        cond do
          conn.request_path =~ "/isrc/" ->
            Req.Test.json(conn, %{"isrc" => @isrc, "recordings" => []})

          conn.request_path =~ "/recording/" ->
            Req.Test.json(conn, lookup_body())

          search?(conn.request_path) ->
            attempt = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

            Req.Test.json(
              conn,
              if(attempt == 1, do: %{"recordings" => []}, else: search_body(collaboration()))
            )

          conn.request_path =~ "/release/" ->
            Req.Test.json(conn, %{"cover-art-archive" => %{"front" => true}})
        end
      end)
    end

    # A candidate credited to both names, so the retry has something that can
    # actually reach the threshold.
    defp collaboration do
      [
        %{
          "id" => @mbid,
          "score" => 100,
          "title" => "Corduroy",
          "length" => 285_000,
          "artist-credit" => [
            %{"name" => "Nusrat Fateh Ali Khan"},
            %{"name" => "Eddie Vedder"}
          ],
          "releases" => [%{"id" => @release, "title" => "Vitalogy"}]
        }
      ]
    end

    test "asks for the parsed title, not the stored one" do
      # A stored title often carries in parentheses what MusicBrainz keeps out
      # of the title entirely. Verified live: "The Face Of Love (with Eddie
      # Vedder)" matches no recording and "the face of love" matches it exactly.
      {:ok, asked} = Agent.start_link(fn -> [] end)

      Req.Test.stub(Client, fn conn ->
        if search?(conn.request_path) do
          Agent.update(asked, &[conn.query_string | &1])
        end

        Req.Test.json(conn, search_body())
      end)

      Enrichment.enrich(recording(%{isrc: nil, album: "Vitalogy", title: "Corduroy (Live)"}))

      query = asked |> Agent.get(& &1) |> List.first() |> URI.decode()

      assert query =~ ~s(recording:"corduroy")
      refute query =~ "Live", "the version belongs to the ladder, not to the query"
    end

    test "retries an empty search with the credit's first name" do
      # A credit naming several people is often written as one string — a CSV
      # import carries "Nusrat Fateh Ali Khan, Eddie Vedder" as one artist — and
      # MusicBrainz has no artist of that name, so it answers with nothing.
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      stub_second_attempt_only(counter)

      {:ok, enriched} =
        Enrichment.enrich(
          recording(%{
            isrc: nil,
            album: "Vitalogy",
            artists: ["Nusrat Fateh Ali Khan, Eddie Vedder"]
          })
        )

      assert Agent.get(counter, & &1) == 2, "the empty answer should have been retried"
      assert enriched.musicbrainz_recording_id == @mbid
    end

    test "does not retry when the credit already names one artist" do
      # Nothing to narrow, so a second attempt would spend a request to be told
      # the same thing.
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      stub_second_attempt_only(counter)

      {:ok, enriched} = Enrichment.enrich(recording(%{isrc: nil, artists: ["Pearl Jam"]}))

      assert Agent.get(counter, & &1) == 1
      refute enriched.musicbrainz_recording_id
    end

    test "does not retry a search that found candidates and declined them" do
      # An empty answer says the *question* was wrong. A search that found
      # candidates was asked a good question and given a bad answer, and a
      # narrower question would not improve it.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Client, fn conn ->
        if search?(conn.request_path), do: Agent.update(counter, &(&1 + 1))

        cond do
          conn.request_path =~ "/isrc/" -> Req.Test.json(conn, %{"recordings" => []})
          search?(conn.request_path) -> Req.Test.json(conn, search_body())
          true -> Req.Test.json(conn, lookup_body())
        end
      end)

      # No album, so the candidate cannot reach the threshold and is declined.
      Enrichment.enrich(recording(%{isrc: nil, album: nil, artists: ["A, B"]}))

      assert Agent.get(counter, & &1) == 1
    end
  end

  describe "enrich/1 without an ISRC" do
    test "declines a plausible top hit that nothing corroborates" do
      # The case the whole design exists for. Verified live: MusicBrainz scores
      # a live Barcelona bootleg 100 for "Corduroy" by Pearl Jam. Taking the top
      # hit would attach that recording's identity — and then its ISRC, its
      # length, its artwork — to the studio track somebody imported.
      bootleg = [
        %{
          "id" => "11111111-2222-3333-4444-555555555555",
          "score" => 100,
          "title" => "Corduroy",
          "length" => 402_000,
          "artist-credit" => [%{"name" => "Pearl Jam"}],
          "releases" => [%{"id" => @release, "title" => "2000-06-01: Barcelona, Spain"}]
        }
      ]

      stub_musicbrainz(%{search: search_body(bootleg)})

      {:ok, enriched} = Enrichment.enrich(recording(%{isrc: nil, album: "Vitalogy"}))

      refute enriched.musicbrainz_recording_id
      refute enriched.isrc
      assert enriched.enriched_at, "declining is still an answer, and must be remembered"
    end

    test "accepts a candidate the album corroborates" do
      stub_musicbrainz()

      {:ok, enriched} = Enrichment.enrich(recording(%{isrc: nil, album: "Vitalogy"}))

      assert enriched.musicbrainz_recording_id == @mbid
      assert enriched.isrc == @isrc, "which is the whole point: it is matchable everywhere now"
    end

    test "declines a match on an exact title and an exact credit alone" do
      # The case that disproved `:high`. Scored 0.9139 against a real library —
      # over the 0.90 threshold — on nothing but a title and a credit, with a
      # different album and no duration to check. Every correct identification in
      # that same measurement scored 0.98, which is the top of the text band and
      # means every compared field agreed.
      other_album = [
        %{
          "id" => "99999999-8888-7777-6666-555555555555",
          "score" => 100,
          "title" => "Corduroy",
          "artist-credit" => [%{"name" => "Pearl Jam"}],
          "releases" => [%{"id" => @second_release, "title" => "Living in Large Rooms"}]
        }
      ]

      stub_musicbrainz(%{search: search_body(other_album)})

      {:ok, enriched} = Enrichment.enrich(recording(%{isrc: nil, album: "Vitalogy"}))

      refute enriched.musicbrainz_recording_id
    end

    test "declines when there is nothing to corroborate with at all" do
      # Not a tuned rule of enrichment's own: `Strategy.Text` scores an
      # uncorroborated match at 0.89 and `:high` is 0.90, so the ladder already
      # knows that a title and an artist are not enough.
      stub_musicbrainz()

      {:ok, enriched} = Enrichment.enrich(recording(%{isrc: nil, album: nil}))

      refute enriched.musicbrainz_recording_id
    end
  end

  describe "enrich/1 when MusicBrainz has nothing to say" do
    test "remembers the attempt, so an unknown recording is not asked about nightly" do
      # 404 from the ISRC lookup — an identifier it does not hold — and an empty
      # 200 from the search, which is how that endpoint says "nothing". An
      # earlier version of this stub answered 404 to both, and the difference
      # matters now: a search that *errors* is an outage, not an absence.
      Req.Test.stub(Client, fn conn ->
        if conn.request_path =~ "/isrc/" do
          Plug.Conn.send_resp(conn, 404, ~s({"error":"Not Found"}))
        else
          Req.Test.json(conn, %{"recordings" => []})
        end
      end)

      {:ok, enriched} = Enrichment.enrich(recording(%{isrc: unique_isrc()}))

      assert enriched.enriched_at
      refute enriched.musicbrainz_recording_id
      assert enriched.enrichment_outcome == :no_candidates
    end

    test "a search that could not be made is not an absence" do
      # The same rule the artwork lookup follows. Recording an outage as "no such
      # recording" would make it permanent, because `due/1` never offers a
      # stamped recording again.
      Req.Test.stub(Client, fn conn ->
        if conn.request_path =~ "/isrc/" do
          Plug.Conn.send_resp(conn, 404, "")
        else
          Req.Test.transport_error(conn, :econnrefused)
        end
      end)

      stored = recording(%{isrc: unique_isrc()})

      assert {:error, error} = Enrichment.enrich(stored)
      assert Errata.reason(error) == :search_unavailable
      assert Errata.retryable?(error)
      refute Repo.get!(Recording, stored.id).enriched_at
    end

    test "says how many candidates it declined" do
      # The distinction the column exists for: "nothing came back" reads as a
      # catalogue gap, "one came back and was not certain" reads as a scoring
      # decision. Collapsing them made the screen report the second as the first.
      stub_musicbrainz(%{isrc: %{"isrc" => @isrc, "recordings" => []}})

      {:ok, enriched} = Enrichment.enrich(recording(%{isrc: @isrc, album: "Nowhere"}))

      assert enriched.enrichment_outcome == :declined
      assert enriched.enrichment_candidates == 1
    end

    test "does not remember an outage, because it says nothing about the recording" do
      Req.Test.stub(Client, fn conn ->
        if conn.request_path =~ "/isrc/" do
          Req.Test.json(conn, isrc_body())
        else
          Plug.Conn.send_resp(conn, 500, "")
        end
      end)

      stored = recording(%{isrc: @isrc})

      assert {:error, _reason} = Enrichment.enrich(stored)

      assert %Recording{enriched_at: nil} = Repo.get!(Recording, stored.id)
    end
  end

  describe "choosing which release the metadata comes from" do
    defp releases(recording_ids) do
      Recording
      |> Ecto.Query.where([r], r.id in ^recording_ids)
      |> Repo.all()
      |> Enum.map(& &1.musicbrainz_release_id)
    end

    defp two_releases_body do
      %{
        lookup: %{
          "id" => @mbid,
          "title" => "Wreckage",
          "length" => 300_000,
          "releases" => [
            # Listed first, and the wrong answer: a compilation the track also
            # appears on. MusicBrainz returns these in no meaningful order.
            %{"id" => @second_release, "title" => "Rearviewmirror", "date" => "2004"},
            %{
              "id" => @release,
              "title" => "Dark Matter",
              "barcode" => "602458971163",
              "date" => "2024"
            }
          ]
        }
      }
    end

    test "prefers the release naming the album the track says it is on" do
      stub_musicbrainz(two_releases_body())

      {:ok, enriched} =
        Enrichment.enrich(recording(%{isrc: @isrc, album: "Dark Matter", title: "Wreckage"}))

      assert enriched.musicbrainz_release_id == @release
      assert enriched.album_upc == "602458971163", "the barcode must come from the same release"
    end

    test "an album agrees with itself, even when a later track sees a better candidate" do
      # The defect this was written for: eight tracks of one album resolved to
      # three releases, so the album contradicted itself about its own barcode
      # and showed a cover on two tracks out of eight.
      stub_musicbrainz(two_releases_body())

      first = recording(%{isrc: unique_isrc(), album: "Dark Matter", title: "Wreckage"})
      {:ok, first} = Enrichment.enrich(first)

      # The second track's own ranking would prefer the *other* release, because
      # nothing here names the album. Rule 1 should override that.
      # Same title as the stub's lookup: this test is about the *release* choice,
      # and a title disagreement would be refused by `agrees_by_name?/2` first.
      second = recording(%{isrc: unique_isrc(), album: "Dark Matter", title: "Wreckage"})
      {:ok, second} = Enrichment.enrich(second)

      assert first.musicbrainz_release_id == second.musicbrainz_release_id
      assert releases([first.id, second.id]) |> Enum.uniq() |> length() == 1
    end

    test "a settled release from a different album cannot mislead" do
      # Two albums may share a name. The membership test is what makes matching
      # on title alone safe: the other album's release is not in this
      # recording's list, so it is ignored rather than adopted.
      Repo.insert!(%Recording{
        title: "Something Else",
        album: "Dark Matter",
        musicbrainz_release_id: "11111111-2222-3333-4444-555555555555"
      })

      stub_musicbrainz(two_releases_body())

      {:ok, enriched} =
        Enrichment.enrich(recording(%{isrc: @isrc, album: "Dark Matter", title: "Wreckage"}))

      assert enriched.musicbrainz_release_id == @release
    end

    test "a recording on no releases at all is still enriched with what there is" do
      stub_musicbrainz(%{lookup: %{"id" => @mbid, "length" => 300_000, "isrcs" => [@isrc]}})

      {:ok, enriched} =
        Enrichment.enrich(recording(%{isrc: @isrc, album: nil, title: "Wreckage"}))

      refute enriched.musicbrainz_release_id
      assert enriched.duration_seconds == 300
    end
  end

  describe "reset/1" do
    test "puts a recording back in front of due/1" do
      stub_musicbrainz()

      {:ok, enriched} = Enrichment.enrich(recording(%{isrc: @isrc}))

      assert Enrichment.reset([enriched.id]) == 1

      refreshed = Repo.get!(Recording, enriched.id)

      refute refreshed.enriched_at
      refute refreshed.musicbrainz_recording_id
      refute refreshed.musicbrainz_release_id
    end

    test "clears a barcode and cover it chose the release for" do
      stub_musicbrainz()

      {:ok, enriched} = Enrichment.enrich(recording(%{isrc: @isrc}))

      assert enriched.album_upc && enriched.artwork_url

      Enrichment.reset([enriched.id])
      refreshed = Repo.get!(Recording, enriched.id)

      refute refreshed.album_upc
      refute refreshed.artwork_url
    end

    test "leaves alone what the track brought with it" do
      # The rule that stops `reset/1` becoming the overwrite `enrich/1` refuses
      # to do, reached by the back door. Nothing here came from MusicBrainz, so
      # `musicbrainz_release_id` is null and none of it is ours to clear.
      own =
        recording(%{
          isrc: @isrc,
          title: "Corduroy",
          album: "Vitalogy",
          album_upc: "074646690123",
          artwork_url: "https://tidal.test/cover.jpg",
          duration_seconds: 285
        })

      assert Enrichment.reset([own.id]) == 1

      refreshed = Repo.get!(Recording, own.id)

      assert refreshed.title == "Corduroy"
      assert refreshed.artists == ["Pearl Jam"]
      assert refreshed.isrc == @isrc
      assert refreshed.album == "Vitalogy"
      assert refreshed.duration_seconds == 285
      assert refreshed.album_upc == "074646690123", "not enrichment's to clear"
      assert refreshed.artwork_url == "https://tidal.test/cover.jpg", "nor this"
    end

    test "clears a cover it fetched even when no release was chosen" do
      # The URL says who wrote it, so artwork needs no provenance proxy at all.
      fetched =
        recording(%{
          isrc: @isrc,
          artwork_url: "https://coverartarchive.org/release-group/#{@group}/front-250"
        })

      Enrichment.reset([fetched.id])

      refute Repo.get!(Recording, fetched.id).artwork_url
    end

    test "resetting nothing is not an error" do
      assert Enrichment.reset([]) == 0
    end
  end

  describe "due/1" do
    test "offers the never-enriched before the merely stale" do
      # Recordings belong to nobody, so there is no user to scope this to and
      # the dev rows sharing the `postgres` database would otherwise fill the
      # answer. Settling them inside the sandbox is the scoping — it is rolled
      # back with the rest of the test.
      Repo.update_all(Recording, set: [enriched_at: DateTime.utc_now()])

      stale = DateTime.add(DateTime.utc_now(), -60 * 24 * 3600, :second)

      fresh =
        recording(%{
          title: "fresh",
          enriched_at: DateTime.utc_now(),
          enrichment_engine: Enrichment.engine()
        })

      old = recording(%{title: "old", enriched_at: stale, enrichment_engine: Enrichment.engine()})
      never = recording(%{title: "never"})

      ids = Enrichment.due(50) |> Enum.map(& &1.id)

      assert never.id in ids
      assert old.id in ids
      refute fresh.id in ids, "a recording asked about this minute is not due"

      assert Enum.find_index(ids, &(&1 == never.id)) <
               Enum.find_index(ids, &(&1 == old.id)),
             "a recording nothing is known about is worth more than a month-old answer"
    end

    test "offers back a failure decided by rules that are no longer current" do
      # The gap this closes. In one working day the matching rules changed five
      # times, and each change left every earlier decline stale with nothing to
      # say so — the sweep would have reached them in thirty days, or never.
      Repo.update_all(Recording, set: [enriched_at: DateTime.utc_now()])

      under_old_rules =
        recording(%{
          title: "decided long ago",
          enriched_at: DateTime.utc_now(),
          enrichment_outcome: :declined,
          enrichment_engine: "an engine that no longer exists"
        })

      assert under_old_rules.id in Enum.map(Enrichment.due(50), & &1.id)
    end

    test "does not offer back a *success* decided by older rules" do
      # Enrichment fills gaps and never overwrites, so running it again over an
      # identified recording spends a request to change nothing. Re-deciding a
      # settled identity means discarding it first, which is `reset/1`.
      Repo.update_all(Recording, set: [enriched_at: DateTime.utc_now()])

      already_identified =
        recording(%{
          title: "settled",
          enriched_at: DateTime.utc_now(),
          musicbrainz_recording_id: "aaaaaaaa-1111-2222-3333-444444444444",
          enrichment_outcome: :identified,
          enrichment_engine: "an engine that no longer exists"
        })

      refute already_identified.id in Enum.map(Enrichment.due(50), & &1.id)
    end

    test "the fingerprint is stable across calls" do
      # It has to be: a fingerprint that varied per call would re-offer every
      # failure on every sweep, for ever.
      assert Enrichment.engine() == Enrichment.engine()
      assert is_binary(Enrichment.engine())
    end
  end
end
