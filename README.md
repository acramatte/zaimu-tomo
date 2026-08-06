![ZaimuTomo Tanuki](./priv/static/images/zaimutomo-logo-tanuki-mascot.png)
# ZaimuTomo

[![CI](https://github.com/acramatte/zaimu-tomo/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jido/actions/workflows/ci.yml)

> AI-assisted bookkeeping for less data entry and more confidence.

Upload invoices and receipts, and ZaimuTomo handles the grunt work:

1. **OCR** converts the uploaded document to markdown.
2. **Extraction** uses an LLM to read the markdown and pull out the structured invoice or receipt fields.
3. **Verification** runs a second LLM pass that checks the extracted fields are actually grounded in the document and flags anything it can't support.

You review the results and approve what looks right — only then does it become an accounting journal entry. Nothing is recorded without your sign-off.

_The name “Zaimu Tomo” (財務の友) comes from the Japanese words for “finance” and “friend,” where 財務 (zaimu) means “financial affairs” and 友 (tomo) means “friend” or “companion.”_

## Langfuse (optional)

ZaimuTomo integrates with Langfuse for prompt management (the extract and verify prompts live there), OpenTelemetry traces of the document-processing workflow, and user feedback on extraction quality. Set `LANGFUSE_PUBLIC_KEY` and `LANGFUSE_SECRET_KEY` to enable it.

## Run Locally

You need Docker (for PostgreSQL) and an Elixir/Phoenix toolchain:

```bash
docker compose up -d db
mix setup
POSTGRES_PORT=55432 mix phx.server
```

Then open [localhost:4000](http://localhost:4000). The bundled PostgreSQL service maps to host port `55432` to avoid collisions with other local projects.

### AI configuration

OCR always uses Mistral's Document OCR API, so set `MISTRAL_API_KEY` to process documents. The extractor and verifier backends are selected independently with `AI_EXTRACTOR` and `AI_VERIFIER` (`flm`, `ollama`, or `mistral`). See [docs/localAI.md](docs/localAI.md) for setting up local LLM backends — FastFlowLM on AMD NPUs, Ollama, or any OpenAI-compatible server such as llama-server.
