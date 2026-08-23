defmodule OnePlaylistWeb.ImportLiveTest do
  @moduledoc """
  The upload form.

  The form itself is hermetic: rendering it and refusing it need no Supabase.
  A successful import stores a file, so that test is tagged `:supabase` — the
  storing is not incidental, it is the step that has to happen in the request.
  """

  use OnePlaylistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import OnePlaylist.AuthFixtures

  alias OnePlaylist.Providers

  @roon Path.join(__DIR__, "../../fixtures/roon_export.csv")

  # Signs a user up through GoTrue and gives them a connected service, so the
  # session carries an access token Storage will accept.
  defp live_conn_for_a_real_user(conn) do
    unless OnePlaylist.Supabase.configured?(), do: flunk("Supabase is not configured")

    email = "importlive-#{System.system_time(:nanosecond)}@one-playlist.test"
    {:ok, session} = OnePlaylist.Accounts.sign_up(email, "a-perfectly-fine-password")
    connect_tidal(session.user_id)

    log_in_user(conn, session)
  end

  defp connect_tidal(user_id) do
    {:ok, _connection} =
      Providers.connect(user_id, :tidal, %{
        provider_user_id: "p-#{System.unique_integer([:positive])}",
        display_name: "TIDAL",
        access_token: "at",
        refresh_token: "rt",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
      })
  end

  describe "with no connected service" do
    test "says so, and does not offer to import", %{conn: conn} do
      # An import needs somewhere to put the tracks. Offering the form anyway
      # would produce a submit whose only outcome is ConnectionNotFound.
      conn = log_in_user(conn, session_fixture())

      {:ok, _view, html} = live(conn, ~p"/imports/new")

      assert html =~ "No music service connected"
      assert html =~ "disabled"
    end
  end

  describe "with a service connected" do
    setup %{conn: conn} do
      user_id = user_id_fixture()
      connect_tidal(user_id)

      %{conn: log_in_user(conn, session_fixture(user_id: user_id)), user_id: user_id}
    end

    test "offers the connected service as a destination", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/imports/new")

      refute html =~ "No music service connected"
      assert html =~ "Put the tracks in"
      assert html =~ "TIDAL"
    end

    test "accepts the extensions the codecs claim", %{conn: conn} do
      # Derived from `Formats`, so adding a format cannot leave a picker that
      # refuses files the application can now read.
      {:ok, _view, html} = live(conn, ~p"/imports/new")

      assert html =~ ".csv"
    end

    test "submitting with no file says so rather than failing quietly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/imports/new")

      assert view |> element("#import-form") |> render_submit() =~ "Choose a file to import"
    end

    @tag :supabase
    test "a good file becomes a transfer", %{conn: conn} do
      # A *real* session, not `session_fixture/1`. Storing the upload is the
      # point of this test, and Storage authenticates the access token — a fake
      # one comes back as "that file could not be reached", which is Storage
      # correctly refusing a credential rather than anything about the form.
      conn = live_conn_for_a_real_user(conn)

      {:ok, view, _html} = live(conn, ~p"/imports/new")

      upload =
        file_input(view, "#import-form", :playlist, [
          %{name: "Pearl Jam.csv", content: File.read!(@roon), type: "text/csv"}
        ])

      render_upload(upload, "Pearl Jam.csv")

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("#import-form") |> render_submit()

      assert to =~ ~r"^/transfers/[0-9a-f-]{36}$"
    end

    test "a malformed file is reported on the form, not in a job", %{conn: conn} do
      # The whole argument for parsing in the request: the person is still
      # looking at the form when they find out.
      #
      # Untagged, and that is the interesting part. Parsing happens before the
      # upload is stored, so this passes with no Supabase at all — which is the
      # ordering the design claims, checked rather than asserted.
      {:ok, view, _html} = live(conn, ~p"/imports/new")

      upload =
        file_input(view, "#import-form", :playlist, [
          %{name: "broken.csv", content: "no header here\n", type: "text/csv"}
        ])

      render_upload(upload, "broken.csv")

      html = view |> element("#import-form") |> render_submit()

      assert html =~ "import-error"
      assert html =~ "must name the columns"
    end
  end
end
