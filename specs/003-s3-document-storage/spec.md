# Feature Specification: S3-Compatible Document Storage (RustFS → Hetzner Object Storage)

**Feature Branch**: `feat/s3-document-storage`
**Created**: 2026-08-05
**Status**: In progress — Phase 1 storage foundation complete; Phases 2–6 remain
**Input**: User request — "documents are stored on the filesystem, a temporary setup that will not scale; move them to an S3-compatible store (RustFS)". Follow-up decisions: start with self-hosted RustFS, keep a cheap migration path to Hetzner Object Storage.

## 1. Context and problem

Document bytes are currently written to the local filesystem of the app node:

- **Dev / test**: `File.cp!` into `:code.priv_dir(:zaimu_tomo)/uploads/<uuid>.<ext>` from the two LiveView upload flows:
  - `lib/zaimu_tomo_web/live/document_upload_live.ex:111-116` (dashboard drop-zone)
  - `lib/zaimu_tomo_web/live/document_live/form.ex:131-137` (new/edit form)
- **Prod (Kamal)**: the same code path resolves to the release directory `/app/lib/zaimu_tomo-0.1.0/priv/uploads`, mounted as the named volume `zaimu_tomo_uploads` — `config/deploy.yml:74-77`. The path contains the release version from `mix.exs` and must be updated on every version bump (the comment in `deploy.yml` says exactly that).
- `documents.filepath` stores the URL-style path `/uploads/<uuid>.<ext>`; `documents.filename` stores the client filename (`lib/zaimu_tomo/documents/document.ex`).
- The OCR worker rebuilds the local path (`lib/zaimu_tomo/document_processing/ocr_worker.ex:125-127`) and `DocumentOCR.process/1` reads the whole file into memory before uploading it to Mistral's `/files` API (`lib/zaimu_tomo/document_processing/document_ocr.ex:50-67`).

Why this does not scale:

1. **Ephemeral/single-host storage.** In a container, the uploads directory is a per-host named volume: no durability guarantees, no backup story, and a second app instance would need shared storage.
2. **Version-dependent path.** The volume mount breaks on release bumps unless remembered.
3. **Write-only data.** Files are never served: `ZaimuTomoWeb.static_paths()` (`lib/zaimu_tomo_web.ex:20`) excludes `uploads`, and no controller route serves them. Any future preview must route through the app anyway.
4. **No backup.** Nothing in `DEPLOYMENT.md` covers the volume; the documents are the raw evidence behind journal entries and must survive.

## 2. Goals and non-goals

### Goals

- **G1**: An S3-compatible object store is the single source of truth for document bytes, in every environment.
- **G2**: Store is swappable via configuration only. Phase 1 runs self-hosted RustFS; a later phase can move to Hetzner Object Storage without Elixir code changes (rules R1–R4, §6.1).
- **G3**: All access is app-mediated; the bucket stays private.
- **G4**: OCR keeps working over the VPN-only production network — the app downloads the object to a temp file and uploads it to Mistral (option A, §4.2).
- **G5**: A backup and restore story covering both Postgres and the object store, with a documented restore order.
- **G6**: Existing files migrate idempotently.

### Non-goals

- Serving/previewing documents in the browser (future work; design keeps it possible via presigned URLs or a proxy).
- Multipart upload machinery (objects are ≤ 20 MB, below the 5 GB single-PUT limit).
- Object-store features beyond basic PUT/GET/DELETE/HEAD: no lifecycle rules, no replication, no public buckets.
- Switching the Mistral OCR call to `document_url` mode (see decision D3).

## 3. Decisions

| ID | Decision | Rationale |
|----|----------|-----------|
| D1 | S3 client = `:aws_signature` + `Req`, a thin `ZaimuTomo.Storage` facade over a configured adapter | AGENTS.md mandates Req as the HTTP client; `:aws_signature` is the maintained Hex SigV4 implementation; minimal deps; std-lib-over-wrapper preference. `ex_aws_s3` remains the fallback if multipart or presigning complexity grows. |
| D2 | Phase 1 = self-hosted RustFS; Hetzner Object Storage is a later config-level migration | Zero recurring cost now, fully self-contained, everything behind the VPN; the S3 boundary makes the later hop cheap (see §11). |
| D3 | OCR reads via temp file (option A), not byte-streaming (B) or presigned URL (C) | C is impossible while the store is VPN-only (Mistral must fetch the URL). B adds Req streaming complexity for no gain at ≤ 20 MB. A keeps `DocumentOCR` untouched and is retryable. |
| D4 | `documents.filepath` → `documents.object_key`; keys are `documents/<uuid>.<ext>`; one bucket per environment | Column name should describe what it holds; flat UUID keys are portable across S3 stores; per-env buckets prevent cross-env data mixing. |
| D5 | Delete the object only after the row delete succeeds | The FK constraint can refuse deletion (posted journal entry); an object must never be removed while its row still exists. |
| D6 | Migration-readiness rules R1–R4 are enforced from day one (§6.1) | They are the entire cost of the future RustFS → Hetzner migration. |
| D7 | Files are ≤ 20 MB (`max_file_size: 20_000_000` in both LiveViews), so one PUT per upload | No multipart code paths to build or test. |
| D8 | Tests are layered: Memory + `Req.Test` run by default; a tagged Testcontainers/RustFS suite is added in Phase 4 | Fast hermetic tests must cover application flows and request construction on every run. A real RustFS instance separately proves end-to-end SigV4 compatibility without making `mix precommit` depend on Docker. |

## 4. Target architecture

### 4.1 Data flow

```
Upload:
  Browser ── chunks ──> LiveView (allow_upload)
                            │ consume_uploaded_entries (temp file)
                            ▼
                      ZaimuTomo.Storage
                            │ PUT documents/<uuid>.<ext>   (Content-Type from ext)
                            ▼
                      RustFS  :9000  (S3 API, path-style)  [prod: Hetzner OS later]
                            ▲
                            │ GET documents/<uuid>.<ext>  -> temp file in System.tmp_dir!
                      ZaimuTomo.Storage
                            │
                      DocumentProcessing.Worker ── temp file ──> DocumentOCR
                                                                   │ multipart upload
                                                                   ▼
                                                                Mistral /files -> OCR
                                                                   │ markdown
                                                                   ▼
                                                      LLM extract + verify -> ExtractedContent
```

```
Delete:
  delete_document (FK check) ── row deleted ──> Storage.delete_object(key)
```

```
Future preview (non-goal today):
  DocumentLive.Show ──> presigned GET URL (or app proxy) ──> browser
  (only possible once the store endpoint is public, i.e. after Hetzner migration)
```

### 4.2 OCR options considered

| Option | Works over VPN? | Notes |
|--------|-----------------|-------|
| **A. GET → temp file → Mistral `/files` upload** | ✅ (both legs from app) | **Chosen.** `DocumentOCR` API unchanged; worker removes the temp file in an `after` block; retryable. |
| B. GET stream → pipe into Mistral multipart | ✅ (both legs from app) | Fiddlier Req streaming, harder error handling; no real gain at ≤ 20 MB. |
| C. Presigned URL → Mistral `document_url` mode | ❌ (store not public) | Would require exposing RustFS publicly — rejected. Becomes possible only after Hetzner migration (public endpoint). |

## 5. Storage design

### 5.1 Buckets and keys

- One bucket per environment: `zaimu-tomo-dev`, `zaimu-tomo-prod` (configurable via `S3_BUCKET`).
- Key format: `documents/<uuid>.<ext>` — same UUID scheme as today, extension preserved.
- The bucket is private; there is no public-read policy. All access is app-mediated.
- `Content-Type` is set explicitly on PUT from the extension (portable metadata, future previews behave).

### 5.2 Database

Migration (one file, e.g. `rename_documents_filepath_to_object_key`):

```sql
ALTER TABLE documents RENAME COLUMN filepath TO object_key;
UPDATE documents SET object_key = 'documents/' || replace(object_key, '/uploads/', '')
  WHERE object_key LIKE '/uploads/%';
```

- Schema: `field :object_key, :string` replaces `field :filepath, :string`; still `validate_required([:filename, :object_key])`.
- `documents.filename` (client name) is unchanged.

## 6. Elixir design

### 6.1 Migration-readiness rules (D6) — mandatory constraints

- **R1 — S3-only config**: the app reads only `S3_*` environment variables (`:storage` config Keyword). No `RUSTFS_*` vars, no RustFS-specific features (lifecycle, replication, console) anywhere in application code.
- **R2 — path-style flag**: `Storage.S3` builds URLs from a `path_style` boolean. RustFS is path-style (`host:9000/<bucket>/<key>`); Hetzner is virtual-hosted (`<bucket>.<location>.your-objectstorage.com/<key>`). SigV4 signs the actual host + path, so both work; the flag defaults to `true`.
- **R3 — portable keys**: flat `documents/<uuid>.<ext>`, `Content-Type` from extension, single PUT per object. Nothing RustFS-shaped leaks into keys or metadata.
- **R4 — verification task**: `mix zaimu_tomo.verify_storage` HEADs every `documents.object_key` and reports missing objects. It must be complete before the legacy-file migration/cutover; it is the migration validation tool and a periodic health check.

### 6.2 Module shape

```
ZaimuTomo.Storage                (public facade; resolves :adapter from :storage config)
├── ZaimuTomo.Storage.Adapter    (behaviour)
├── ZaimuTomo.Storage.S3         (real adapter: Req + :aws_signature, path-style aware)
└── ZaimuTomo.Storage.Memory     (test adapter: ETS-backed, no network)

Public facade functions:
  put_object(key, body)              -> {:ok, key} | {:error, term}       # Content-Type derived from key extension inside Storage.S3
  get_object(key, dest_path)          -> {:ok, dest_path} | {:error, term} # streams to temp file
  delete_object(key)                  -> :ok | {:error, term}
  head_object(key)                    -> :ok | {:error, :not_found | term}

Adapter callbacks take the configured storage Keyword as their final argument
(`put_object(key, body, config)`, `get_object(key, dest_path, config)`, and so
on). Presigning is deliberately deferred: it is a future preview feature, not
needed by the initial private-store flow.
```

Configuration (mirrors the `:mistral` / `:langfuse` Keyword pattern):

```elixir
# config/config.exs
config :zaimu_tomo, :storage,
  adapter: ZaimuTomo.Storage.S3,
  endpoint: "http://localhost:9000",
  region: "eu-central-1",
  access_key_id: "rustfsadmin",
  secret_access_key: "rustfsadmin",
  bucket: "zaimu-tomo-dev",
  path_style: true

# config/runtime.exs — env overrides
config :zaimu_tomo, :storage,
  adapter: ZaimuTomo.Storage.S3,
  endpoint: System.get_env("S3_ENDPOINT", "http://localhost:9000"),
  region: System.get_env("S3_REGION", "eu-central-1"),
  access_key_id: System.get_env("S3_ACCESS_KEY_ID", "rustfsadmin"),
  secret_access_key: System.get_env("S3_SECRET_ACCESS_KEY", "rustfsadmin"),
  bucket: System.get_env("S3_BUCKET", "zaimu-tomo-dev"),
  path_style: System.get_env("S3_PATH_STYLE", "true") == "true"
```

Dependency added: `{:aws_signature, "~> 0.4"}` (the maintained AWS-BEAM SigV4 implementation on Hex). `config/test.exs` selects `ZaimuTomo.Storage.Memory`; individual tests reset its ETS state, so tests never hit the network.

### 6.3 Flow changes

**Upload** (`document_upload_live.ex` `do_consume/1`, `document_live/form.ex` `handle_event("save", ...)`):
- Replace `File.cp!(path, dest)` with `Storage.put_object("documents/#{Ecto.UUID.generate()}#{ext}", File.read!(path))` — `Storage.S3` derives the `Content-Type` from the key extension.
- On `{:error, changeset}` from `create_document` after a successful PUT: best-effort `Storage.delete_object(key)` (caller-owned cleanup; today's code silently leaves orphan files).

**OCR** (`ocr_worker.ex` `process/1`):
- Replace `build_document_path/1` with: `tmp = Path.join(System.tmp_dir!(), "zaimu-#{Ecto.UUID.generate()}#{Path.extname(document.object_key)}")`, `{:ok, tmp} <- Storage.get_object(document.object_key, tmp)`, then `DocumentOCR.process(tmp)` as today. Wrap the complete path in `try ... after File.rm(tmp) end` so worker downloads never accumulate. `DocumentOCR` is unchanged.

**Delete** (`documents.ex` `delete_document/2`):
- After a successful `Repo.delete` (i.e. not blocked by the FK constraint), call `Storage.delete_object(document.object_key)`; log and continue on error (row is authoritative; orphan object cleanup is a follow-up concern, detectable via `verify_storage`).

**Edit form**: same consume change as upload; keys are always new UUIDs, so replacing a document's file never overwrites an existing object. Retain the prior key before the update; after a successful DB update, best-effort delete the prior object if its key changed. If the update fails after a PUT, best-effort delete the newly uploaded object. A storage failure must not create/update a document row.

## 7. Development infrastructure (docker-compose)

RustFS facts (verified 2026-08-05, official docs): S3 API on `9000`, console on `9001`, container runs as UID/GID `10001:10001`, data at `/data`, logs at `/logs`, default root credentials `rustfsadmin` / `rustfsadmin`. The deployed image is the Phase 0 tag-and-digest pin below, never `latest`.

Add to `docker-compose.yml` (dev), keeping RustFS's conventional ports with env overrides like the existing `POSTGRES_PORT` pattern:

```yaml
  rustfs:
    # 1.0.0-beta.12 (digest-pinned, verified 2026-08-05)
    image: rustfs/rustfs:1.0.0-beta.12@sha256:41fe89380f4120a337790c02af192c3fe7bb55c3edc2e6e9357b487b47c6ab21
    restart: unless-stopped
    environment:
      RUSTFS_ACCESS_KEY: rustfsadmin
      RUSTFS_SECRET_KEY: rustfsadmin
      RUSTFS_REGION: eu-central-1
      RUSTFS_CONSOLE_ENABLE: "true"
    ports:
      - "${RUSTFS_PORT:-9000}:9000"
      - "${RUSTFS_CONSOLE_PORT:-9001}:9001"
    volumes:
      - rustfs_data:/data
      - rustfs_logs:/logs
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:9000/health/ready"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  pg_data:
  rustfs_data:
  rustfs_logs:
```

One-time setup after boot: create the bucket **with versioning + Object Lock enabled at creation time** — RustFS follows S3 semantics and Object Lock cannot be enabled on an existing bucket. Easiest: the console at `:9001` (enable Object Lock when creating the bucket), or the MinIO client: `mc mb --with-lock local/zaimu-tomo-dev`. Dev config then works with no env vars.

## 8. Production infrastructure (Kamal)

`config/deploy.yml`:

- **Migration release: retain** the `zaimu_tomo_uploads` volume and its existing mount temporarily. The migration task needs it as its read-only legacy source. Do not remove the mount or the Dockerfile upload-directory preparation in this deployment.
- **Add** a `rustfs` accessory (mirroring the `db` accessory, same Watchtower exclusion):

```yaml
  rustfs:
    # 1.0.0-beta.12 (digest-pinned, verified 2026-08-05)
    image: rustfs/rustfs:1.0.0-beta.12@sha256:41fe89380f4120a337790c02af192c3fe7bb55c3edc2e6e9357b487b47c6ab21
    host: <%= ENV.fetch("KAMAL_SSH_HOST") %>
    labels:
      com.centurylinklabs.watchtower.enable: "false"
    env:
      clear:
        RUSTFS_ACCESS_KEY: zaimu_tomo
        RUSTFS_REGION: eu-central-1
      secret:
        - RUSTFS_SECRET_KEY
    directories:
      - data:/data
      - logs:/logs
```

  No host port: the app reaches it over the Docker network at `http://zaimu-tomo-rustfs:9000` (consistent with the WireGuard-only posture). Optionally bind `127.0.0.1:9001` for console access.
- **App env additions**: put `S3_ENDPOINT`, `S3_REGION`, `S3_BUCKET`, `S3_PATH_STYLE=true`, and `S3_ACCESS_KEY_ID` in `env.clear`; put only `S3_SECRET_ACCESS_KEY` in `env.secret`. The initial app credential intentionally matches the RustFS access key/secret; its names remain provider-neutral on the app side.
- **`.kamal/secrets.example`**: add `RUSTFS_SECRET_KEY` and `S3_SECRET_ACCESS_KEY` with a comment that both resolve to the same initial RustFS credential. Do not place endpoint, bucket, or access-key ID in secrets.
- **Cleanup release only after verification**: after the migration task reports no source failures and `verify_storage` reports zero missing keys, remove the legacy `zaimu_tomo_uploads` mount and then remove the `mkdir -p .../priv/uploads` + `chown` line from the Dockerfile.
- **`DEPLOYMENT.md`**: document the migration-release/cleanup-release sequence, one-time bucket creation, and the backup cron.

## 9. Backup and restore

Threat model: single VPS; while on RustFS the object data lives on one host disk. Postgres and the objects must be backed up together and restorable to the same point.

### While on RustFS (self-hosted store)

- **Nightly cron on the VPS**: create the object-store backup/export **before** `pg_dump`, then run `verify_storage`. This order follows the write protocol (object PUT before row insert; row delete before object delete): a completed object snapshot can contain harmless orphans, but must not be newer than the database dump. RPO = 1 day.
- **Snapshot method is an operational acceptance criterion**: validate a RustFS-supported online backup/export or a crash-consistent filesystem snapshot before adopting `restic /data` against a live server. A plain file walk of a live object-store data directory is not assumed application-consistent. Until the method is validated, briefly quiesce document writes during the object snapshot plus `pg_dump` window.
- **Restore order matters**: restore the object snapshot FIRST, then the DB. A `documents` row whose `object_key` is missing from the store is the failure mode; the reverse order only orphans bytes.
- Enable bucket versioning + Object Lock at bucket creation — confirmed supported on RustFS `1.0.0-beta.12` (object lock must be enabled when the bucket is created, and it requires versioning). Cheap protection on top of restic; an optional governance-mode retention (e.g. 7 days) can be added later.
- Test a restore quarterly; record RPO/RTO in `DEPLOYMENT.md`.

### After Hetzner migration (managed store)

- The objects are now managed (Ceph-replicated) and off-host; the object backup story shrinks to **versioning + Object Lock** enabled on the buckets.
- Keep the nightly `pg_dump` → Storage Box via restic (critical piece).
- Optional paranoia: nightly `rclone`/`mc mirror` of the buckets to the Storage Box.

## 10. Migration of existing files

`mix zaimu_tomo.migrate_to_s3 --source-dir PATH` (idempotent, safe to re-run):

- The database migration has already converted `/uploads/<uuid>.<ext>` to its destination key `documents/<uuid>.<ext>`. For each row, derive the legacy source filename from `Path.basename(object_key)` and look for it under the explicit `--source-dir`; do not mutate the row again.
- HEAD the destination first. If it exists, skip it. If it is missing, PUT the source file once with the existing `object_key`; do not overwrite an existing object.
- Report every missing source and PUT failure, return non-zero if any occur, and make no deletion. Print totals for skipped-existing, uploaded, missing-source, and failed.
- Dev/test sources are `priv/uploads` (gitignored). Production uses the old `zaimu_tomo_uploads` volume, retained during the migration release.
- Drain document work and pause new document uploads for the database migration plus copy/verification cutover. After the task succeeds, `verify_storage` reports zero missing objects, and a restore check passes, publish the cleanup release that removes the legacy volume and Dockerfile directory preparation.

## 11. Later migration: RustFS → Hetzner Object Storage

Objects are WORM-style (UUID keys, never updated), so there is no dual-write machinery — copy, switch, verify:

1. Create buckets in the Hetzner console; enable versioning + Object Lock; create an access key.
2. `rclone copy rustfs:zaimu-tomo-prod hetzner:zaimu-tomo-prod` (incremental, S3-to-S3).
3. Config swap: `S3_ENDPOINT=https://fsn1.your-objectstorage.com`, new keys, `S3_PATH_STYLE=false`. `kamal deploy`.
4. Re-run the rclone copy once more (catches objects written during the window), then `mix zaimu_tomo.verify_storage` — every `object_key` must exist in Hetzner.
5. Decommission the rustfs accessory + volume; keep the local dev compose service (hermetic offline dev).
6. Bonus unlocked now: presigned URLs work for external consumers (Mistral `document_url` mode, future previews).

Expected Elixir code changes: none, if R1–R4 were followed.

## 12. Testing strategy

- **Default hermetic suite**: set `:storage, adapter: ZaimuTomo.Storage.Memory` in `config/test.exs`; reset the adapter's ETS table in test setup — no network or Docker. `Storage.Memory` remains a test double, not a production fallback or migration staging store; it holds `{object_key, binary}` only.
- **S3 adapter unit suite**: `Storage.S3` gets `Req.Test` cases asserting URL shape, SigV4 headers, response mapping, streamed GET output, and the `path_style` flag. Application-flow tests use `Storage.Memory` so cleanup and failure sequences remain deterministic.
- **RustFS integration suite (Phase 4)**: add test-only `testcontainers` support and a tagged `:integration` ExUnit suite that starts the digest-pinned RustFS image with `RUSTFS_REGION=eu-central-1` and an isolated bucket. It validates live SigV4 authentication, path-style PUT/GET/HEAD/DELETE byte round-trips, and bucket provisioning assumptions. Keep it out of the default test/precommit path; run it explicitly on Docker-capable developer machines and CI runners (for example, `RUN_INTEGRATION=true mix test --only integration`).
- Mechanical updates: fixtures and tests that build `filepath` strings switch to `object_key` (`test/support/fixtures/documents_fixtures.ex`, `documents_test.exs`, `worker_test.exs`, `document_processing_test.exs`, `accounting_test.exs`, `page_controller_test.exs`, `journal_entry_live_test.exs`).
- Upload LiveView tests keep asserting on the row, not the file, so they are storage-agnostic.

## 13. Implementation order

1. Deps + `Storage` facade + `Storage.Adapter` behaviour + `Storage.S3` + `Storage.Memory`; `:storage` config in `config/config.exs`, `config/runtime.exs`, and `config/test.exs`.
2. Migration: rename `filepath` → `object_key` + backfill.
3. Swap the two consume callbacks to PUT; worker to GET → temp file; `delete_document` cleanup.
4. docker-compose RustFS service; migration-release `deploy.yml` + secrets + docs while retaining the legacy volume/Dockerfile directory.
5. Validate the backup method; `mix zaimu_tomo.migrate_to_s3 --source-dir PATH`; `mix zaimu_tomo.verify_storage` (R4); then publish the cleanup deployment.
6. Tests updated per §12; README section.

## 14. Phase 0 decisions (resolved 2026-08-05)

- **RustFS image pin**: `rustfs/rustfs:1.0.0-beta.12@sha256:41fe89380f4120a337790c02af192c3fe7bb55c3edc2e6e9357b487b47c6ab21` in both `docker-compose.yml` and `config/deploy.yml` — tag **and** digest pinned (no `latest` floats), matching the existing Postgres pin convention (`postgres@sha256:...`). Digest verified on Docker Hub 2026-08-05 (multi-arch: amd64 + arm64). Still pre-1.0, so the pin is a known-risk choice with a simple upgrade path (bump tag + digest together).
- **Versioning + Object Lock**: confirmed supported (docs.rustfs.com — object-lock page). Enable both at bucket creation; Object Lock cannot be enabled on an existing bucket and requires versioning.
- **Content-Type mapping**: lives inside `Storage.S3`, derived from the key extension, default `application/octet-stream`. No shared helper (YAGNI); callers stay dumb — `put_object/2` needs no content-type argument.
- **`verify_storage` cadence**: on-demand for migrations **and** as a step in the nightly backup cron (after `pg_dump` + restic), so missing objects are caught within a day — one cron owns backup + verification.
