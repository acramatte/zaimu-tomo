# Local AI backends

ZaimuTomo's document pipeline has three AI steps:

1. **OCR**: Mistral Document OCR converts the uploaded document to markdown. This step always uses Mistral and needs `MISTRAL_API_KEY`.
2. **Extractor**: an LLM extracts structured invoice fields from the OCR markdown.
3. **Verifier**: an LLM checks that the extracted fields are grounded in the OCR markdown.

The extractor and verifier backends are selected independently with `AI_EXTRACTOR` and `AI_VERIFIER`:

```bash
export AI_EXTRACTOR=flm      # flm | ollama | mistral
export AI_VERIFIER=flm       # flm | ollama | mistral
```

In development the default is `flm`; in production both default to `mistral`.

The currency the extractor should prefer when several appear on a document comes from the user's base currency setting (see the account settings page), which defaults to CHF on the users table.

## FastFlowLM (`flm`)

`flm` is the local FastFlowLM backend. In the current development setup, FastFlowLM runs on the machine's AMD Ryzen AI HX 370 NPU and exposes an OpenAI-compatible API on localhost. This keeps extraction and verification local while the remote Mistral API is used only for the OCR markdown step.

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

Because the backend is a generic OpenAI-compatible client, `FLM_URL` can point at any local server that exposes a `/v1` endpoint — llama-server, vLLM, and similar work the same way.

## Ollama

```bash
export AI_EXTRACTOR=ollama
export AI_VERIFIER=ollama
export OLLAMA_URL="http://localhost:11434/v1"
export OLLAMA_MODEL="gemma4:e4b"
export OLLAMA_API_KEY="ollama"
```

## Mistral (cloud)

Mistral can also serve as extractor and/or verifier, in addition to OCR:

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
