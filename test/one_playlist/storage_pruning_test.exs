defmodule OnePlaylist.StoragePruningTest do
  @moduledoc """
  `public.prune_stored_exports/1`, the nightly deletion of old export files.

  Everything here runs inside the sandbox transaction, which is what makes it
  testable at all: `pg_net` queues a request rather than sending one, and the
  queue row is visible before the transaction commits. So the *whole* call can
  be checked — the URL, the method, the body, the credential — and then rolled
  back without a single HTTP request leaving the machine.

  The one thing this cannot prove is that Storage honours the request. That was
  verified by hand against the running stack: two aged export objects, one
  import beside them, the function called, HTTP 200 back, the exports gone and
  the import untouched.
  """

  use OnePlaylist.DataCase, async: false

  alias Ecto.Adapters.SQL

  @user "11111111-1111-4111-8111-111111111111"

  defp put_object(kind, name, age_days) do
    SQL.query!(
      Repo,
      """
      insert into storage.objects (bucket_id, name, owner_id, created_at)
      values ('playlists', $1, $2, now() - ($3 || ' days')::interval)
      """,
      ["#{@user}/#{kind}/#{name}", @user, to_string(age_days)]
    )
  end

  defp prune(days) do
    %{rows: [[requested]]} =
      SQL.query!(Repo, "select public.prune_stored_exports(($1 || ' days')::interval)", [
        to_string(days)
      ])

    requested
  end

  # `body` is `bytea` in the queue, so it comes back as raw bytes rather than as
  # the jsonb it was built from. Decoding here keeps every assertion below about
  # the request rather than about pg_net's storage.
  defp queued do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "select method, url, headers, convert_from(body, 'UTF8') from net.http_request_queue order by id desc limit 1",
        []
      )

    case rows do
      [[method, url, headers, body]] ->
        %{method: method, url: url, headers: headers, body: Jason.decode!(body)}

      [] ->
        nil
    end
  end

  describe "what it selects" do
    test "old exports, and only exports" do
      # An export is regenerable and its signed URL died after an hour. An import
      # is the record of what somebody uploaded and is what a re-run re-parses.
      put_object(:exports, "old.csv", 30)
      put_object(:imports, "uploaded.csv", 30)

      assert prune(7) == 1
      assert queued().body["prefixes"] == ["#{@user}/exports/old.csv"]
    end

    test "leaves an export that is still recent" do
      put_object(:exports, "yesterday.csv", 1)

      assert prune(7) == 0
      assert queued() == nil
    end

    test "asks for nothing when there is nothing to ask for" do
      # No request at all, rather than one with an empty list: an HTTP call that
      # deletes nothing is still a call, and this runs every night.
      assert prune(7) == 0
      assert queued() == nil
    end

    test "takes at most one batch, leaving the rest for tomorrow" do
      # A backlog drains over several runs rather than putting every path in one
      # request body. The objects are still there, so the next run finds them.
      for n <- 1..105, do: put_object(:exports, "old-#{n}.csv", 30)

      assert prune(7) == 100
      assert length(queued().body["prefixes"]) == 100
    end
  end

  describe "the request it makes" do
    setup do
      put_object(:exports, "old.csv", 30)
      _ = prune(7)
      %{request: queued()}
    end

    test "is a DELETE to the bucket's object endpoint", %{request: request} do
      assert request.method == "DELETE"
      assert request.url =~ "/storage/v1/object/playlists"
    end

    test "carries a bearer credential", %{request: request} do
      # Asserting that one is present, never what it is. The value is a service
      # role key, and a test that printed it on failure would put it in CI logs.
      assert %{"Authorization" => "Bearer " <> token} = request.headers
      assert byte_size(token) > 0
    end

    test "names the objects as prefixes, which is what the API expects" do
      %{body: body} = queued()

      assert Map.has_key?(body, "prefixes")
      assert is_list(body["prefixes"])
    end
  end

  describe "when it is not configured" do
    test "reports and prunes nothing rather than failing the schedule" do
      # A checkout without the vault secrets must still migrate and still run its
      # nightly jobs. Deleted inside the sandbox, so the real secrets survive.
      _ = SQL.query!(Repo, "delete from vault.secrets where name like 'one_playlist%'", [])

      put_object(:exports, "old.csv", 30)

      assert prune(7) == 0
      assert queued() == nil
    end
  end
end
