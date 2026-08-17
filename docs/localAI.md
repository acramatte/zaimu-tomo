# Local AI backends

ZaimuTomo's document pipeline has three AI steps:

1. **OCR**: Mistral Document OCR converts the uploaded document to markdown. This step always uses Mistral and needs `MISTRAL_API_KEY`.
2. **Extractor**: an LLM extracts structured invoice fields from the OCR markdown.
3. **Verifier**: an LLM checks that the extracted fields are grounded in the OCR markdown.

The extractor and verifier each explicitly select a backend and model. Backend configuration owns only transport and credentials; the workflow owns the model choice:

```bash
export AI_EXTRACTOR_BACKEND=flm                 # flm | ollama | mistral | nousresearch
export AI_EXTRACTOR_MODEL="gemma4-it:e4b"
export AI_VERIFIER_BACKEND=flm                  # flm | ollama | mistral | nousresearch
export AI_VERIFIER_MODEL="phi4-mini-it:4b"
```

In development the default roles use local FastFlowLM: Gemma (`gemma4-it:e4b`) extracts and Phi (`phi4-mini-it:4b`) verifies. In production both use `nousresearch`, with Granite (`ibm-granite/granite-4.1-8b`) extracting and Qwen (`qwen/qwen3.6-35b-a3b`) verifying. Every role needs both a backend and a model; there is no backend-level model fallback.

The currency the extractor should prefer when several appear on a document comes from the user's base currency setting (see the account settings page), which defaults to CHF on the users table.

## FastFlowLM (`flm`)

`flm` is the local FastFlowLM backend. In the current development setup, FastFlowLM runs on the machine's AMD Ryzen AI HX 370 NPU and exposes an OpenAI-compatible API on localhost. This keeps extraction and verification local while the remote Mistral API is used only for the OCR markdown step.

```bash
export AI_EXTRACTOR_BACKEND=flm
export AI_EXTRACTOR_MODEL="gemma4-it:e4b"
export AI_VERIFIER_BACKEND=flm
export AI_VERIFIER_MODEL="phi4-mini-it:4b"
export FLM_URL="http://localhost:52625/v1"
export FLM_API_KEY="ollama"
```

Notes:

- `FLM_URL` must point to the FastFlowLM OpenAI-compatible `/v1` endpoint.
- `AI_EXTRACTOR_MODEL` and `AI_VERIFIER_MODEL` must match model names exposed by FastFlowLM.
- `FLM_API_KEY` is still required by the client, even for local servers. The default placeholder is `ollama`.
- If FastFlowLM is not running, extraction/verification will fail even if OCR succeeds.

Because the backend is a generic OpenAI-compatible client, `FLM_URL` can point at any local server that exposes a `/v1` endpoint — llama-server, vLLM, and similar work the same way.

## Ollama

```bash
export AI_EXTRACTOR_BACKEND=ollama
export AI_EXTRACTOR_MODEL="gemma4:e4b"
export AI_VERIFIER_BACKEND=ollama
export AI_VERIFIER_MODEL="gemma4:e4b"
export OLLAMA_URL="http://localhost:11434/v1"
export OLLAMA_API_KEY="ollama"
```

## Mistral (cloud)

Mistral can also serve as extractor and/or verifier, in addition to OCR:

```bash
export MISTRAL_API_KEY="..."
export AI_EXTRACTOR_BACKEND=mistral
export AI_EXTRACTOR_MODEL="mistral-small-latest"
export AI_VERIFIER_BACKEND=mistral
export AI_VERIFIER_MODEL="mistral-small-latest"
```

Optional override:

```bash
export MISTRAL_URL="https://api.mistral.ai/v1"
```

You can mix backends, for example Mistral extraction with local verification:

```bash
export AI_EXTRACTOR_BACKEND=mistral
export AI_EXTRACTOR_MODEL="mistral-small-latest"
export AI_VERIFIER_BACKEND=ollama
export AI_VERIFIER_MODEL="phi4-mini-it:4b"
```

## Nous Research (cloud)

Nous Research's hosted inference API routes to a curated catalog of frontier and
open models behind a single `NOUSRESEARCH_API_KEY`. It is OpenAI-compatible, so it
works as an extractor and/or verifier while OCR stays on Mistral:

```bash
export NOUSRESEARCH_API_KEY="..."
export AI_EXTRACTOR_BACKEND=nousresearch
export AI_VERIFIER_BACKEND=nousresearch
```

Model ids on the Nous portal use a `family/model` form. A few good fits for the
invoice pipeline:

```bash
# Extractor: strong JSON/schema adherence
export AI_EXTRACTOR_MODEL="ibm-granite/granite-4.1-8b"      # or "meta/muse-glimmer-30b"
# Verifier: grounded reasoning over OCR text
export AI_VERIFIER_MODEL="qwen/qwen3.6-35b-a3b"      # or "qwen/qwen3.7-max"
```

Optional transport override:

```bash
export NOUSRESEARCH_URL="https://inference-api.nousresearch.com/v1"
```

Mix freely — e.g. Mistral OCR + Nous extraction + local verification:

```bash
export MISTRAL_API_KEY="..."
export NOUSRESEARCH_API_KEY="..."
export AI_EXTRACTOR_BACKEND=nousresearch
export AI_EXTRACTOR_MODEL="ibm-granite/granite-4.1-8b"
export AI_VERIFIER_BACKEND=flm
export AI_VERIFIER_MODEL="phi4-mini-it:4b"
```
