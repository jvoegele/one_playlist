defmodule OnePlaylist.Providers.ConnectionDisplayTest do
  @moduledoc "The names services use for themselves."

  use ExUnit.Case, async: true

  alias OnePlaylist.Providers.Connection

  test "every provider has a name of its own" do
    # The point of the check: a provider added to `providers/0` and forgotten in
    # the display map falls back to its atom, which is how "youtube_music" ends
    # up on a page. This fails when that happens rather than looking fine.
    for provider <- Connection.providers() do
      assert Connection.display_name(provider) != to_string(provider),
             "#{provider} has no display name"
    end
  end

  test "capitalisation follows the service, not a rule" do
    # These are facts about how each service writes its name, which is why they
    # cannot be derived. `String.capitalize/1` would give "Tidal" and
    # "Apple_music".
    assert Connection.display_name(:tidal) == "TIDAL"
    assert Connection.display_name(:apple_music) == "Apple Music"
    assert Connection.display_name(:youtube_music) == "YouTube Music"
  end

  test "a file is named too, because a transfer's source can be one" do
    assert Connection.display_name(:file) == "File"
  end

  test "something unrecognised is shown rather than dropped" do
    assert Connection.display_name(:some_future_service) == "some_future_service"
  end
end
