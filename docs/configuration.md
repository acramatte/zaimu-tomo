# Configuration reference

All runtime configuration is read from environment variables in
`config/runtime.exs`, at boot in every environment. Compile-time defaults live
in `config/config.exs` and `config/{dev,test,prod}.exs`. Production values that
are not secret are in `config/deploy.yml` (`env.clear`). Secrets are listed
there under `env.secret` and in `.kamal/secrets.example`.

**Rule:** when you add, rename, or remove an env var, update this table,
`config/deploy.yml`, and `.kamal/secrets.example` (if it is a secret) in the
same commit.

## Core (Phoenix and database)

| Variable | Default | Notes |
|---|---|---|
| `PHX_SERVER` | unset | `true` starts the endpoint in a release (set in the image). |
| `PHX_HOST` | `example.com` (prod) | Public host name used for URL generation. |
| `PORT` | `4000` | HTTP port inside the container. |
| `SECRET_KEY_BASE` | — | **Secret.** Required in prod (`mix phx.gen.secret`). |
| `DATABASE_URL` | — | **Secret.** Required in prod. |
| `POOL_SIZE` | `10` | Ecto pool size. |
| `ECTO_IPV6` | unset | `true` or `1` to connect over IPv6. |
| `DNS_CLUSTER_QUERY` | unset | Unused (single node). |
| `POSTGRES_PORT` | `5432` | Dev/test only: host port of the Compose Postgres. |
| `FORCE_SSL` | unset | **Build-time.** `true` enables `force_ssl` (excluding `/health` and `/up`). |

## Object storage (S3-compatible)

| Variable | Default (dev) | Notes |
|---|---|---|
| `S3_ENDPOINT` | `http://localhost:9000` | Prod: the RustFS accessory over Docker DNS. |
| `S3_REGION` | `eu-central-1` | |
| `S3_BUCKET` | `zaimu-tomo-dev` | Must be created with versioning and Object Lock. |
| `S3_PATH_STYLE` | `true` | `false` for virtual-hosted providers. |
| `S3_ACCESS_KEY_ID` | `rustfsadmin` | |
| `S3_SECRET_ACCESS_KEY` | `rustfsadmin` | **Secret.** Currently equal to the RustFS root secret (`RUSTFS_SECRET_KEY`). |

Tests always use `ZaimuTomo.Storage.Memory`, so these variables are not read in `:test`.

## AI pipeline

| Variable | Default (dev / prod) | Notes |
|---|---|---|
| `MISTRAL_API_KEY` | — | **Secret.** Required for OCR. |
| `MISTRAL_URL` | `https://api.mistral.ai/v1` | |
| `AI_EXTRACTOR_BACKEND` | `flm` / `nousresearch` | `flm`, `ollama`, `mistral`, or `nousresearch`. |
| `AI_EXTRACTOR_MODEL` | `gemma4-it:e4b` / `ibm-granite/granite-4.2-8b` | |
| `AI_VERIFIER_BACKEND` | `flm` / `nousresearch` | |
| `AI_VERIFIER_MODEL` | `phi4-mini-it:4b` / `qwen/qwen3.6-35b-a3b` | |
| `AI_VERIFIER_MAX_TOKENS` | `4096` | Reasoning verifiers need room before the JSON. |
| `NOUSRESEARCH_API_KEY` | — | **Secret.** |
| `NOUSRESEARCH_URL` | `https://inference-api.nousresearch.com/v1` | |
| `FLM_URL` / `FLM_API_KEY` | `http://localhost:52625/v1` / `ollama` | Any local OpenAI-compatible server. |
| `OLLAMA_URL` | `http://localhost:11434/v1` | No key is sent. |

Backend setup and model choices: [local-ai.md](local-ai.md).

## Background jobs (Oban)

| Variable | Default | Notes |
|---|---|---|
| `OBAN_DOCUMENTS_CONCURRENCY` | `2` | `documents` queue limit. Use `1` with a single local NPU. |
| `TYPESAFE_MAX_CONCURRENCY` | `2` | `typesafe` queue limit. |

Invalid integers make boot fail on purpose.

## TypeSafe shadow verification (optional)

Enabled only when `TYPESAFE_API_KEY` is non-empty.

| Variable | Default | Notes |
|---|---|---|
| `TYPESAFE_API_KEY` | unset | **Secret.** |
| `TYPESAFE_URL` | `https://api.typesafe.ai` | Only for a compatible endpoint override. |
| `TYPESAFE_MODEL` | `jev-latest` | |
| `TYPESAFE_REVIEW_THRESHOLD` | `0.7` | 0–1. A field whose error probability is at or above this is a shadow `needs_review` issue. |
| `TYPESAFE_TOTAL_TIMEOUT` | `10000` ms | Whole-call deadline. |
| `TYPESAFE_RECEIVE_TIMEOUT` | `30000` ms | Inactivity timeout. |
| `TYPESAFE_MAX_RETRIES` | `0` | HTTP-level retries. |

Results are shown on the review page under **Quality checks → View independent check**.
Logs show `[TypeSafe] Shadow verification started|succeeded|failed|skipped`.

## Langfuse and OpenTelemetry (optional)

Enabled only when both keys are set. Setting only one of them fails boot.

| Variable | Default | Notes |
|---|---|---|
| `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` | unset | **Secret.** |
| `LANGFUSE_BASE_URL` | falls back to `LANGFUSE_HOST`, then `https://cloud.langfuse.com` | |
| `OTEL_SERVICE_NAME` | — | `zaimu-tomo` in prod. |

When disabled, there is no trace export, and the prompts come from the built-in
templates in `ZaimuTomo.Langfuse`.

## Deployment-only (Kamal)

Read by `config/deploy.yml`, not by the app: `KAMAL_SSH_HOST`,
`KAMAL_SSH_USER`, `KAMAL_PROXY_BIND_IP`, `KAMAL_REGISTRY_PASSWORD`,
`POSTGRES_PASSWORD`, `RUSTFS_SECRET_KEY`. See [deployment.md](deployment.md).

## Local tooling

| Variable | Notes |
|---|---|
| `RUSTFS_ACCESS_KEY`, `RUSTFS_SECRET_KEY`, `RUSTFS_PORT`, `RUSTFS_CONSOLE_PORT` | `docker-compose.yml` overrides for local RustFS. |
| `RUN_INTEGRATION=true` | Include `@moduletag :integration` tests (RustFS through Testcontainers). |
| `SOURCE_DIR` | Source directory for `bin/migrate_to_s3` (legacy migration). |
