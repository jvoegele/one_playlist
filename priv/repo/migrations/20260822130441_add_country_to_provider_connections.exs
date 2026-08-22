defmodule OnePlaylist.Repo.Migrations.AddCountryToProviderConnections do
  use Ecto.Migration

  @moduledoc """
  The account's country, as the provider reports it.

  Most TIDAL endpoints take a `countryCode` and return different catalogue
  availability without it. It is a property of the connected account rather
  than of the request, so it belongs on the connection — fetching it per call
  would be a round trip to `/users/me` before every other round trip.
  """

  def change do
    alter table(:provider_connections) do
      add :country, :text
    end
  end
end
