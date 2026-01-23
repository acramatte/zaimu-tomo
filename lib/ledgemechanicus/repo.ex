defmodule Ledgemechanicus.Repo do
  use Ecto.Repo,
    otp_app: :ledgemechanicus,
    adapter: Ecto.Adapters.Postgres
end
