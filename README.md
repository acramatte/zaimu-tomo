<p align="center">
    <a href="https://github.com/acramatte/zaimu-tomo"><img src="./priv/static/images/zaimutomo-logo-tanuki-mascot.png" alt="ZaimuTomo Logo"></a>
</p>

<h1 align="center">
ZaimuTomo
</h1>


<p align="center">
AI-assisted bookkeeping for less data entry and more confidence.
</p>

<p align="center">
    <a href="https://github.com/acramatte/zaimu-tomo/actions/workflows/ci.yml">
        <img alt="CI status" src="https://github.com/acramatte/zaimu-tomo/actions/workflows/ci.yml/badge.svg">
    </a>
    <a href="LICENSE">
        <img alt="MIT License" src="https://img.shields.io/badge/License-MIT-blue.svg">
    </a>
</p>


Upload invoices and receipts, and ZaimuTomo handles the grunt work:

1. **OCR** converts the uploaded document to markdown.
2. **Extraction** uses an LLM to read the markdown and pull out the structured invoice or receipt fields.
3. **Verification** runs a second LLM pass that checks the extracted fields are actually grounded in the document and flags anything it can't support. Optionally, TypeSafe Jev runs an independent per-field check in shadow mode for comparison.

You review the results and approve what looks right — only then does it become an accounting journal entry. Nothing is recorded without your sign-off.

## Features

- **Tax-claim workflow** — review potentially deductible expenses by tax year, record those included in a tax return, and retain any later tax-authority disallowance with its decision reference. See the [C4 analysis](docs/tax-claim-lifecycle-c4.md).

_The name “Zaimu Tomo” (財務の友) comes from the Japanese words for “finance” and “friend,” where 財務 (zaimu) means “financial affairs” and 友 (tomo) means “friend” or “companion.”_

## Documentation

Architecture, infrastructure, deployment, and operations docs live in
[`docs/`](docs/README.md):

- [Architecture (arc42)](docs/architecture.md): system design, top-down
- [Deployment](docs/deployment.md) and [Operations runbook](docs/operations.md)
- [Configuration reference](docs/configuration.md): every environment variable
- [AI backends](docs/local-ai.md): OCR, extractor, and verifier setup

## Run Locally

You need Docker (for PostgreSQL and the local RustFS object store) and an
Elixir/Phoenix toolchain:

```bash
docker compose up -d db rustfs
docker compose --profile bootstrap run --rm rustfs-init
mix setup
mix phx.server
```

Then open [localhost:4000](http://localhost:4000). The bundled PostgreSQL service maps to host port `5432`; set `POSTGRES_PORT` in the shell (or as a Compose variable) to override if another local Postgres already uses that port.

### Development demo data

`mix setup` seeds an idempotent demo account alongside the development database. Re-run it at any time with:

```bash
mix run priv/repo/seeds.exs
```

The seed data creates Maya Keller (`demo@zaimutomo.test`) with password
`demo-password-123`, plus five financial accounts. They cover cash, savings, and
investments; CHF, EUR, and USD balances; and manual and bank-synced sources.
Each account has five changing balance snapshots over the last six months, with
monthly and bi-monthly intervals. It only creates missing demo records, so
re-running it does not duplicate the user, accounts, or balance snapshots.

RustFS exposes its S3-compatible API on [localhost:9000](http://localhost:9000)
and its local console on [localhost:9001](http://localhost:9001). The bootstrap
command creates the disposable `zaimu-tomo-dev` bucket with versioning and
Object Lock; Object Lock cannot be added to a bucket after it exists. To reset a
local development bucket, remove the Compose volumes and bootstrap it again.

The application uses generic `S3_*` settings only. Local defaults work with the
bundled RustFS service, so no S3 variables are needed for ordinary development.
For a different S3-compatible provider, set `S3_ENDPOINT`, `S3_REGION`,
`S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_BUCKET`, and `S3_PATH_STYLE`.
RustFS uses path-style addressing (`S3_PATH_STYLE=true`); a future
virtual-hosted provider uses `false`.

### AI configuration

OCR always uses Mistral's Document OCR API, so set `MISTRAL_API_KEY` to process documents. The extractor and verifier each select an explicit backend and model with `AI_EXTRACTOR_BACKEND` / `AI_EXTRACTOR_MODEL` and `AI_VERIFIER_BACKEND` / `AI_VERIFIER_MODEL`. See [docs/local-ai.md](docs/local-ai.md) for setup, and [docs/configuration.md](docs/configuration.md) for optional Langfuse tracing and TypeSafe shadow verification.
