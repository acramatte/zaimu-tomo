# ZaimuTomo

ZaimuTomo is a Phoenix web application for AI-assisted bookkeeping and document processing. Authenticated users upload financial documents, run OCR, extract and verify invoice or receipt data with LLM backends, review the results, and turn approved data into accounting journal entries.

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Development database

The application connects to PostgreSQL on `localhost:5432` by default. The bundled Compose service maps its database to host port `55432` to avoid collisions with other local projects, so run development commands with:

```bash
POSTGRES_PORT=55432 mix phx.server
```

## AI/OCR configuration

Document processing has three AI-related steps:

1. **OCR**: Mistral Document OCR converts the uploaded document to markdown.
2. **Extractor**: an LLM extracts structured invoice fields from the OCR markdown.
3. **Verifier**: an LLM checks that the extracted fields are grounded in the OCR markdown.

### Required for OCR

```bash
export MISTRAL_API_KEY="..."
```

The OCR step always uses Mistral's OCR API with `mistral-ocr-latest`.

### Extractor and verifier backend selection

Choose backends independently with:

```bash
export AI_EXTRACTOR=flm      # flm | ollama | mistral
export AI_VERIFIER=flm       # flm | ollama | mistral
```

Defaults are:

```bash
AI_EXTRACTOR=flm
AI_VERIFIER=flm
AI_CURRENCY_HINT=CHF
```

`AI_CURRENCY_HINT` helps the extractor choose the intended currency when several currencies appear in a document.

### FLM backend

`flm` is the local FastFlowLM backend. In my current development setup, FastFlowLM runs on the machine's AMD Ryzen AI HX 370 NPU and exposes an OpenAI-compatible API on localhost. This lets us keep extraction/verification local while still using the remote Mistral API only for the OCR markdown step.

Use this when FastFlowLM is running locally:

```bash
export AI_EXTRACTOR=flm
export AI_VERIFIER=flm
export FLM_URL="http://localhost:52625/v1"
export FLM_MODEL="gemma4-it:e4b"
export FLM_API_KEY="ollama"
```

Notes:

- `FLM_URL` must point to the FastFlowLM OpenAI-compatible `/v1` endpoint.
- `FLM_MODEL` must match the model name exposed by FastFlowLM.
- `FLM_API_KEY` is still required by the client, even for local servers. The default placeholder is `ollama`.
- If FastFlowLM is not running, extraction/verification will fail even if OCR succeeds.

### Ollama backend

```bash
export AI_EXTRACTOR=ollama
export AI_VERIFIER=ollama
export OLLAMA_URL="http://localhost:11434/v1"
export OLLAMA_MODEL="gemma4:e4b"
export OLLAMA_API_KEY="ollama"
```

### Mistral backend for extraction/verification

Mistral can also be used for the extractor and/or verifier, in addition to OCR:

```bash
export MISTRAL_API_KEY="..."
export AI_EXTRACTOR=mistral
export AI_VERIFIER=mistral
export MISTRAL_LLM_MODEL="mistral-small-latest"
```

Optional override:

```bash
export MISTRAL_URL="https://api.mistral.ai/v1"
```

You can mix backends, for example Mistral extraction with local verification:

```bash
export AI_EXTRACTOR=mistral
export AI_VERIFIER=ollama
```

