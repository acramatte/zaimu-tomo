# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :zaimu_tomo, :scopes,
  user: [
    default: true,
    module: ZaimuTomo.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: ZaimuTomo.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :zaimu_tomo,
  ecto_repos: [ZaimuTomo.Repo],
  generators: [timestamp_type: :utc_datetime]

config :zaimu_tomo, :mistral,
  provider: :openai,
  base_url: System.get_env("MISTRAL_URL") || "https://api.mistral.ai/v1",
  model: System.get_env("MISTRAL_LLM_MODEL") || "mistral-small-latest",
  api_key: System.get_env("MISTRAL_API_KEY")

config :zaimu_tomo, :ai_workflow,
  extractor: System.get_env("AI_EXTRACTOR", "flm"),
  verifier: System.get_env("AI_VERIFIER", "flm"),
  # TODO: Move this global extraction hint to user preferences once settings exist.
  currency_hint: System.get_env("AI_CURRENCY_HINT", "CHF")

config :zaimu_tomo, :ollama,
  provider: :openai,
  base_url: System.get_env("OLLAMA_URL") || "http://localhost:11434/v1",
  model: System.get_env("OLLAMA_MODEL") || "gemma4:e4b",
  api_key: System.get_env("OLLAMA_API_KEY") || "ollama"

config :zaimu_tomo, :flm,
  provider: :openai,
  base_url: System.get_env("FLM_URL") || "http://localhost:52625/v1",
  model: System.get_env("FLM_MODEL") || "gemma4-it:e4b",
  api_key: System.get_env("FLM_API_KEY") || "ollama"

# Configure the endpoint
config :zaimu_tomo, ZaimuTomoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ZaimuTomoWeb.ErrorHTML, json: ZaimuTomoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ZaimuTomo.PubSub,
  live_view: [signing_salt: "2SJdmlGK"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :zaimu_tomo, ZaimuTomo.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  zaimu_tomo: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  zaimu_tomo: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
