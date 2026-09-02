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

  test "the other ways in appear only when asked for" do
    plain = form(%{})

    refute plain =~ "formaction"
    refute plain =~ "Google"

    both = form(%{magic_link_action: "/sign-in/magic-link", google_action: "/sign-in/google"})

    # The link button lives inside the credentials form, re-targeted, and can
    # submit with the password blank — that is the point of it.
    assert both =~ ~s(formaction="/sign-in/magic-link")
    assert both =~ "formnovalidate"
    # Google is its own form, so it posts nothing typed into the other one.
    assert both =~ ~r/<form[^>]*action="\/sign-in\/google"/
  end

  test "an unconfigured server disables every way in, not just the password" do
    html = form(%{configured?: false, magic_link_action: "/m", google_action: "/g"})

    buttons = Regex.scan(~r/<button[^>]*type="submit"[^>]*>/, html) |> List.flatten()
    assert length(buttons) == 3
    assert Enum.all?(buttons, &(&1 =~ "disabled"))
  end

  describe "code_form/1" do
    defp code_form(assigns) do
      render_component(
        &OnePlaylistWeb.AuthComponents.code_form/1,
        Map.merge(%{action: "/sign-in/code", email: "someone@example.test"}, assigns)
      )
    end

    test "carries the address so nobody types it twice, and asks the device for the code" do
      html = code_form(%{})

      assert html =~ ~s(type="hidden")
      assert html =~ ~s(name="code[email]")
      assert html =~ ~s(value="someone@example.test")
      # What lets a phone offer the code from the email, and brings up a number pad.
      assert html =~ ~s(autocomplete="one-time-code")
      assert html =~ ~s(inputmode="numeric")
    end

    test "never echoes a code back" do
      html = code_form(%{error_message: "that code has expired"})

      assert html =~ ~s(role="alert")
      refute html =~ ~r/name="code\[token\]"[^>]*value="[^"]/
    end
  end
end
