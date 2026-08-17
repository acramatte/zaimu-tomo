import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/zaimu_tomo start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :zaimu_tomo, ZaimuTomoWeb.Endpoint, server: true
end

config :zaimu_tomo, ZaimuTomoWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

config :zaimu_tomo, :mistral,
  provider: :openai,
  base_url: System.get_env("MISTRAL_URL", "https://api.mistral.ai/v1"),
  api_key: System.get_env("MISTRAL_API_KEY")

default_extractor =
  if config_env() == :prod,
    do: [backend: :nousresearch, model: "ibm-granite/granite-4.1-8b"],
    else: [backend: :flm, model: "gemma4-it:e4b"]

default_verifier =
  if config_env() == :prod,
    do: [backend: :nousresearch, model: "qwen/qwen3.6-35b-a3b"],
    else: [backend: :flm, model: "phi4-mini-it:4b"]

config :zaimu_tomo, :ai_workflow,
  extractor: [
    backend: System.get_env("AI_EXTRACTOR_BACKEND", Atom.to_string(default_extractor[:backend])),
    model: System.get_env("AI_EXTRACTOR_MODEL", default_extractor[:model])
  ],
  verifier: [
    backend: System.get_env("AI_VERIFIER_BACKEND", Atom.to_string(default_verifier[:backend])),
    model: System.get_env("AI_VERIFIER_MODEL", default_verifier[:model])
  ]

config :zaimu_tomo, :ollama,
  provider: :openai,
  base_url: System.get_env("OLLAMA_URL", "http://localhost:11434/v1"),
  api_key: System.get_env("OLLAMA_API_KEY", "ollama")

config :zaimu_tomo, :flm,
  provider: :openai,
  base_url: System.get_env("FLM_URL", "http://localhost:52625/v1"),
  api_key: System.get_env("FLM_API_KEY", "ollama")

config :zaimu_tomo, :nousresearch,
  provider: :openai,
  base_url: System.get_env("NOUSRESEARCH_URL", "https://inference-api.nousresearch.com/v1"),
  api_key: System.get_env("NOUSRESEARCH_API_KEY")

langfuse_public_key = System.get_env("LANGFUSE_PUBLIC_KEY")
langfuse_secret_key = System.get_env("LANGFUSE_SECRET_KEY")

langfuse_base_url =
  System.get_env(
    "LANGFUSE_BASE_URL",
    System.get_env("LANGFUSE_HOST", "https://cloud.langfuse.com")
  )
  |> String.trim_trailing("/")

langfuse_enabled? =
  case {langfuse_public_key, langfuse_secret_key} do
    {nil, nil} ->
      false

    {"", ""} ->
      false

    {public_key, secret_key} when is_binary(public_key) and is_binary(secret_key) ->
      true

    _ ->
      raise "LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY must either both be set or both be unset"
  end

config :zaimu_tomo, :langfuse,
  enabled: langfuse_enabled?,
  environment: Atom.to_string(config_env()),
  public_key: langfuse_public_key,
  secret_key: langfuse_secret_key,
  base_url: langfuse_base_url

if langfuse_enabled? do
  langfuse_authorization = Base.encode64("#{langfuse_public_key}:#{langfuse_secret_key}")

  config :opentelemetry, :processors,
    otel_batch_processor: %{
      exporter:
        {:opentelemetry_exporter,
         %{
           # `opentelemetry_exporter` appends `/v1/traces` to configured endpoints.
           endpoints: ["#{langfuse_base_url}/api/public/otel"],
           headers: [
             {"authorization", "Basic #{langfuse_authorization}"},
             {"x-langfuse-ingestion-version", "4"}
           ]
         }}
    }
else
  config :opentelemetry, traces_exporter: :none
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :zaimu_tomo, ZaimuTomo.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :zaimu_tomo, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :zaimu_tomo, ZaimuTomoWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :zaimu_tomo, ZaimuTomoWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :zaimu_tomo, ZaimuTomoWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :zaimu_tomo, ZaimuTomo.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
