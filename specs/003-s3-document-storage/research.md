# Research: S3-Compatible Storage Providers and OCR Options

Facts gathered 2026-08-05. Sources are listed per section. Third-party pricing figures are marked as such; the authoritative pricing page is `https://www.hetzner.com/storage/object-storage/`.

## 1. RustFS (self-hosted initial deployment)

Source: official README — https://github.com/rustfs/rustfs

- Open-source, Apache 2.0, S3-compatible object storage written in Rust; positioned as a MinIO/Ceph migration-and-coexistence target ("2.3x faster than MinIO for 4KB object payloads" per the README).
- Docker image deployment pin: `rustfs/rustfs:1.0.0-beta.12@sha256:41fe89380f4120a337790c02af192c3fe7bb55c3edc2e6e9357b487b47c6ab21` (multi-arch amd64 + arm64, verified on Docker Hub 2026-08-05). Never deploy `latest`.
- Ports: `9000` S3 API, `9001` console.
- Container runs as non-root user `rustfs` (UID/GID `10001:10001`). Bind-mounted host paths must be writable by that user, or startup fails; named volumes are the safer choice.
- Data directory: `/data`; logs: `/logs`.
- Default console credentials: `rustfsadmin` / `rustfsadmin`.
- Relevant environment variables: `RUSTFS_ACCESS_KEY`, `RUSTFS_SECRET_KEY`, `RUSTFS_REGION`, `RUSTFS_CONSOLE_ENABLE` (per community deployment examples, e.g. the Milvus blog below).
- RustFS documents bucket versioning and Object Lock. Object Lock requires versioning and must be enabled at bucket creation; this was resolved in Phase 0.
- Reference compose example (Milvus blog): https://milvus.io/blog/evaluating-rustfs-as-a-viable-s3-compatible-object-storage-backend-for-milvus.md

## 2. Hetzner Object Storage (later managed migration target)

Source: official docs — https://docs.hetzner.com/storage/object-storage/overview/ and https://docs.hetzner.com/storage/object-storage/supported-actions

- S3-compatible, backed by a **Ceph cluster** (replicated/HA — not single-disk).
- Endpoints (virtual-hosted style): Falkenstein `fsn1.your-objectstorage.com`, Nuremberg `nbg1.your-objectstorage.com`, Helsinki `hel1.your-objectstorage.com`. URL format: `https://<bucket>.<location>.your-objectstorage.com/<key>`.
- Pricing: hourly base charge with a monthly cap; the base price includes ~1 TB storage + ~1 TB egress per month (third-party estimates: ~EUR 5–6/month base, ~EUR 5/TB excess storage, ~EUR 1/TB excess egress). Ingress, S3 operations, and **internal traffic within the `eu-central` network zone are free** — traffic between a Hetzner Cloud VPS and the object store costs nothing.
- Free of charge: incoming traffic, internal eu-central traffic, PUT/GET/DELETE operations.
- Limits: 5 GB per single PUT; 5 TB per object; 10,000 parts per multipart; 64 kB minimum billable object size; 100 buckets; 200 S3 credentials.
- Supported: versioning, Object Lock (retention + legal hold), SSE-C encryption, presigned URLs, multipart upload, bucket visibility private/public.
- NOT supported: replication, tagging, lifecycle rules (only `NoncurrentVersionExpiration`), CopyObject reliability (may fail even same-location), notifications, website hosting, analytics/logging/metrics, custom bucket domains, intelligent tiering.
- Access keys are per-project and by default valid for every bucket in the project; per-key restrictions exist (FAQ: "How do I restrict access per key?").
- S3 client compatibility note: URL style is virtual-hosted → `S3_PATH_STYLE=false` (rule R2 in spec.md §6.1).

Note: one third-party roundup (danubedata.ro) claims Hetzner has "no versioning"; the official docs list versioning + object lock how-tos and the supported-actions table references `NoncurrentVersionExpiration`, so the official docs are authoritative: versioning is supported.

## 3. OCR delivery options (spec.md §4.2)

| Option | Mechanics | VPN-compatible | Verdict |
|--------|-----------|----------------|---------|
| A. Temp file | App GETs object → temp file → multipart upload to Mistral `/files` (`purpose: ocr`) → OCR the returned URL | Yes (both connections originate from the app) | **Chosen** — `DocumentOCR` API unchanged, retryable |
| B. Byte streaming | Stream S3 GET body directly into the Mistral multipart request | Yes (both connections originate from the app) | Rejected — Req streaming complexity, no gain at ≤ 20 MB |
| C. Presigned URL | Store returns a presigned GET URL; Mistral `document_url` mode fetches it | No — store endpoint must be publicly reachable by Mistral | Rejected for RustFS phase; becomes possible after Hetzner migration (public endpoint) |

Current code uses Mistral's `/files` upload API (`document_ocr.ex:50-67`), not `document_url` mode; option C would additionally require switching OCR modes.

## 4. Backup tooling references

- restic (S3/SFTP backends): https://restic.net
- rclone (S3-to-S3 mirror/copy): https://rclone.org
- Hetzner Storage Box (SFTP backup target): https://www.hetzner.com/storage/storage-box
- Hetzner Object Storage FAQ (use cases, credential restriction): https://docs.hetzner.com/storage/object-storage/faq/
