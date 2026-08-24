exclude = if System.get_env("RUN_INTEGRATION") == "true", do: [], else: [:integration]

ExUnit.start(exclude: exclude)
Ecto.Adapters.SQL.Sandbox.mode(ZaimuTomo.Repo, :manual)
