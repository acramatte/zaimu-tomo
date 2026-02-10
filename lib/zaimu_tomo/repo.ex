defmodule ZaimuTomo.Repo do
  use Ecto.Repo,
    otp_app: :zaimu_tomo,
    adapter: Ecto.Adapters.Postgres
end
