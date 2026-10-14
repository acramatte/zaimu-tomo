# ZaimuTomo documentation

Start here. Read top-down: the architecture first, then infrastructure and
operations as needed.

| Document | Read it to learn… |
|---|---|
| [architecture.md](architecture.md) | **The system design (arc42).** Goals, context and external services, building blocks, runtime flows, deployment overview, cross-cutting concepts, decision log, risks, glossary. |
| [deployment.md](deployment.md) | The production topology (Kamal, VPS, VPN, accessories), the image, secrets handling, first-time setup, routine deploys, CI. |
| [operations.md](operations.md) | Runbooks: migrations, jobs, stuck-document recovery, backups and restore, the legacy volume cleanup. |
| [configuration.md](configuration.md) | Every environment variable, its default, and whether it is a secret. |
| [local-ai.md](local-ai.md) | Choosing and running the OCR, extractor, and verifier backends (local NPU, Ollama, Mistral, Nous). |
| [../README.md](../README.md) | Product overview and local quickstart. |
| [../specs/](../specs/README.md) | *Historical* feature specs (spec-kit). Useful for the reasoning behind a feature, but not maintained. These docs win when they disagree. |

## Keeping the docs current

These docs are part of the code. A change is not finished until the docs that
describe it are true again. Update them **in the same commit or PR**.

| If your change… | Update |
|---|---|
| adds or removes a context, schema, table, or major module | `architecture.md` §5 (building blocks) and §8 (data model) |
| changes a user-visible flow, a job, a queue, retries, or PubSub topics | `architecture.md` §6 and §8 |
| adds or changes an external service, provider, or model default | `architecture.md` §3, `configuration.md`, `local-ai.md` |
| adds, renames, or removes an env var | `configuration.md`, `config/deploy.yml`, and `.kamal/secrets.example` for secrets |
| touches `Dockerfile`, `config/deploy.yml`, accessories, CI, or release scripts | `deployment.md`, and `operations.md` if it changes a runbook |
| makes a structural or infrastructure decision | append a row to `architecture.md` §9 |
| creates or resolves known debt or risk | `architecture.md` §11 |

Style:

- **Lightweight.** Prefer a table or a short paragraph. Use a Mermaid diagram only where a picture beats prose (context, flows, topology, data model).
- **Top-down.** Name modules and files so readers can jump into code, but don't copy code or restate what `@moduledoc` already says.
- **No secrets or host details.** Never write real hostnames, IPs, host port allocations, account names, credentials, or backup destinations. Name the variable instead (for example `KAMAL_SSH_HOST`).
- **Dated decisions.** Decision rows carry year and month so the history stays legible.
