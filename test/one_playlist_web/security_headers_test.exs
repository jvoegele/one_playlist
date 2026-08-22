defmodule OnePlaylistWeb.SecurityHeadersTest do
  @moduledoc """
  Pins the security headers on the browser pipeline.

  A Content-Security-Policy is the kind of thing that gets weakened one
  directive at a time to unbreak something, so the directives that matter are
  asserted individually rather than as one opaque string.
  """

  use OnePlaylistWeb.ConnCase, async: true

  setup %{conn: conn}, do: %{conn: get(conn, ~p"/")}

  test "a content-security-policy is sent at all", %{conn: conn} do
    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "default-src 'self'"
  end

  test "scripts may not be inlined", %{conn: conn} do
    [csp] = get_resp_header(conn, "content-security-policy")

    assert csp =~ "script-src 'self'"

    refute csp =~ "script-src 'self' 'unsafe-inline'",
           "inline scripts are forbidden by AGENTS.md and must stay forbidden here"

    refute csp =~ "'unsafe-eval'"
  end

  test "the page cannot be framed by another origin", %{conn: conn} do
    [csp] = get_resp_header(conn, "content-security-policy")

    # dev relaxes this to 'self' for LiveReload's iframe; under test it is 'none'.
    assert csp =~ "frame-ancestors 'none'"

    # This is the *only* framing protection now: current Plug no longer emits
    # x-frame-options, having deferred to CSP. Without the policy above there
    # would be nothing stopping the app being framed.
    assert get_resp_header(conn, "x-frame-options") == []
  end

  test "images from provider CDNs are allowed", %{conn: conn} do
    [csp] = get_resp_header(conn, "content-security-policy")

    assert csp =~ "img-src 'self' data: https:",
           "album art is served from the providers' own CDNs"
  end

  test "the usual Phoenix headers are still present", %{conn: conn} do
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "referrer-policy") == ["strict-origin-when-cross-origin"]
    assert get_resp_header(conn, "x-permitted-cross-domain-policies") == ["none"]
  end
end
