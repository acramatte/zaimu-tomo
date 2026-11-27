# PR Review Rubrics

Path-matched, domain-specific grading rubrics used by an independent LLM critic
to review pull requests alongside deterministic CI (`mix precommit`,
`mix credo --strict`, `git diff --check`).

## How the two-layer model works

1. **Repo rubrics (`.rubrics/*.yaml`)** — versioned pure-data invariants derived
   from `docs/architecture.md` and real bug classes caught in past PR reviews.
   Only files whose `paths:` globs match the PR's changed files are activated,
   keeping every review focused (~6–15 active criteria).
2. **Optional pre-code task rubric** — written from the issue/plan *before*
   implementation (never generated from the finished diff to avoid self-grading).
   Include a fenced ```` ```yaml rubric ```` block in the PR description or pass
   `--task-rubric path/to/task.yaml` locally:

   ````markdown
   ```yaml rubric
   name: task_override
   criteria:
     - id: acceptance_check
       weight: 0.25
       inspect: [diff, raw_logs]
       check: Describe the task-specific requirement to verify.
   penalties:
     - id: slop_workaround
       penalty: -0.20
       check: Describe the specific shortcut or failure mode to penalize.
   ```
   ````

## Local usage

Validate all rubric YAML files (also verified automatically by `mix test` /
`test/zaimu_tomo/rubrics_test.exs`):

```sh
mix zaimu_tomo.rubric_review --validate-only
```

Preview which rubrics match a branch diff and render the critic prompt (no API
key required — useful for piping into any local coding/review agent):

```sh
mix zaimu_tomo.rubric_review \
  --base origin/main --head HEAD --dry-run \
  --render-prompt /tmp/critic_prompt.md
```

Run a live review against any OpenAI-compatible chat-completions endpoint:

```sh
RUBRIC_LLM_BASE_URL="https://generativelanguage.googleapis.com/v1beta/openai" \
RUBRIC_LLM_MODEL="gemini-4-carbon" \
RUBRIC_LLM_API_KEY="..." \
mix zaimu_tomo.rubric_review \
  --base origin/main --head HEAD \
  --output-md /tmp/review.md
```

## CI setup (`.github/workflows/rubric-review.yml`)

- **Schema validation** runs automatically inside `ci.yml` (`mix test` →
  `ZaimuTomo.RubricsTest`), with zero extra jobs or runtimes.
- **`rubric-review`** is advisory (`continue-on-error: true`) and shares the
  same `erlef/setup-beam` + `deps`/`_build` cache key as `ci.yml`. Configure
  these GitHub Actions secrets/variables to enable live PR comments:
  - Secret: `RUBRIC_LLM_API_KEY`
  - Variables (optional defaults in workflow): `RUBRIC_LLM_BASE_URL`,
    `RUBRIC_LLM_MODEL`
- When `RUBRIC_LLM_API_KEY` is unset, the workflow exits early in step 1 without
  installing Elixir or failing CI.

## Keeping rubrics high-signal (the ratchet)

- **Promote mechanical checks to deterministic tooling first** (tests, Ecto
  constraints/triggers, Credo). Keep LLM rubrics for semantic/architectural
  judgment calls.
- Whenever a human or reviewing agent catches a subtle bug class that passed CI,
  add **one concise criterion or penalty** to the relevant `.rubrics/*.yaml` file.
- Every deduction requires exact `file:line` or log evidence.
