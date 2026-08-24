defmodule OnePlaylistWeb.AuthComponentsTest do
  @moduledoc """
  The shared credentials form.

  Tested as a component rather than through a controller because its two states
  are a *parameter*, not an ambient fact. Asserted through the controller, the
  same claim has to read `OnePlaylist.Supabase.configured?/0`, so it passes or
  fails depending on whether the environment happens to have `SUPABASE_URL`
  set — green in the default suite, red as soon as the tagged integration tests
  are included.
  """

  use OnePlaylistWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  defp form(assigns) do
    render_component(
      &OnePlaylistWeb.AuthComponents.credentials_form/1,
      Map.merge(
        %{
          action: "/sign-in",
          submit_label: "Sign in",
          password_autocomplete: "current-password",
          footer: [%{__slot__: :footer, inner_block: fn _assigns, _ -> "footer" end}]
        },
        assigns
      )
    )
  end

  test "an unconfigured server says why rather than taking a password" do
    # The fresh-checkout case: nobody copied config/dev_local.example.exs. A
    # form that cannot possibly work should say so.
    html = form(%{configured?: false})

    assert html =~ "not configured"
    assert html =~ "dev_local.exs"
    assert html =~ "disabled", "the submit button is disabled too, not merely captioned"
  end

  test "a configured server just shows the form" do
    html = form(%{configured?: true})

    refute html =~ "not configured"
    assert html =~ ~s(name="user[email]")
  end

  test "an error is announced to assistive technology" do
    html = form(%{configured?: true, error_message: "could not sign you in"})

    assert html =~ "could not sign you in"
    assert html =~ ~s(role="alert")
  end

  test "the password is never given a value attribute" do
    # Re-rendering after a failed attempt must not echo the password back into
    # the DOM, where it would sit in the page source and in browser history.
    html = form(%{configured?: true, email: "someone@example.test"})

    assert html =~ ~s(value="someone@example.test")
    refute html =~ ~r/type="password"[^>]*value="[^"]/
  end
end
