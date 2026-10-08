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
  base_url: "https://api.mistral.ai/v1",
  api_key: nil

# Base role defaults for local development. config/runtime.exs replaces this
# configuration at boot from environment variables in every environment.
config :zaimu_tomo, :ai_workflow,
  extractor: [backend: :flm, model: "gemma4-it:e4b"],
  verifier: [backend: :flm, model: "phi4-mini-it:4b", max_tokens: 4096]

config :zaimu_tomo, :typesafe,
  enabled: false,
  api_key: nil,
  base_url: "https://api.typesafe.ai",
  model: "jev-latest",
  review_threshold: 0.7,
  receive_timeout: 30_000,
  total_timeout: 10_000,
  max_retries: 0

# Durable background jobs for document processing (Oban OSS). The documents
# queue is deliberately small: OCR + LLM runs are expensive and, in local dev
# with a single-NPU FLM backend, must be serialized (see OBAN_DOCUMENTS_
# CONCURRENCY in config/runtime.exs). The typesafe queue bounds concurrent
# TypeSafe shadow verification runs (see TYPESAFE_MAX_CONCURRENCY).
# testing: :manual in config/test.exs.
config :zaimu_tomo, Oban,
  engine: Oban.Engines.Basic,
  repo: ZaimuTomo.Repo,
  queues: [documents: 2, typesafe: 2],
  plugins: [
    # Keep finished jobs a week for debugging/audit of retries.
    {Oban.Pruner, max_age: 7 * 24 * 60 * 60},
    # OSS Oban leaves jobs in `executing` when a node dies mid-run (deploy/OOM);
    # Lifeline moves them back. Must be > OCRJob.timeout/1.
    {Oban.Lifeline, rescue_after: :timer.minutes(30)}
  ]

config :zaimu_tomo, :ollama,
  # Native ReqLLM Ollama provider: no Authorization header is sent, so no
  # API key is needed.
  provider: :ollama,
  base_url: "http://localhost:11434/v1",
  api_key: nil

config :zaimu_tomo, :flm,
  provider: :openai,
  base_url: "http://localhost:52625/v1",
  api_key: "ollama"

config :zaimu_tomo, :nousresearch,
  provider: :openai,
  base_url: "https://inference-api.nousresearch.com/v1",
  api_key: nil

config :zaimu_tomo, :langfuse,
  enabled: false,
  environment: "development",
  public_key: nil,
  secret_key: nil,
  base_url: "https://cloud.langfuse.com"

config :zaimu_tomo, :storage,
  adapter: ZaimuTomo.Storage.S3,
  endpoint: "http://localhost:9000",
  region: "eu-central-1",
  access_key_id: "rustfsadmin",
  secret_access_key: "rustfsadmin",
  bucket: "zaimu-tomo-dev",
  path_style: true

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
