Repository: zaimu-tomo
Reviewed head SHA: e7f13f0c1cf8a221bce25160d6cd6acfa1185ddc (branch agent/t-7a25aa58)
Base: origin/main
Reviewer role: Kanban reviewer (document-preview candidate)

Verdict: APPROVE

Evidence and checks performed:

1) Diff scope and churn
- git diff origin/main..agent/t-7a25aa58 lists exactly 11 changed files (whitelist):
  lib/zaimu_tomo/media_preview.ex
  lib/zaimu_tomo/storage.ex
  lib/zaimu_tomo/storage/adapter.ex
  lib/zaimu_tomo/storage/memory.ex
  lib/zaimu_tomo/storage/s3.ex
  lib/zaimu_tomo_web/controllers/document_controller.ex
  lib/zaimu_tomo_web/live/document_live/index.ex
  lib/zaimu_tomo_web/router.ex
  test/zaimu_tomo/storage_test.exs
  test/zaimu_tomo_web/controllers/document_controller_test.exs
  test/zaimu_tomo_web/live/document_live_test.exs
- Diff summary: 11 files changed, 449 insertions, 20 deletions. No unrelated formatting churn observed in other files.

2) Authenticated owner-scoped preview/download routes ordering
- Router changes place GET /documents/:id/preview and GET /documents/:id/download inside the
  `live_session :require_authenticated_user` block and before Live routes for /documents.
  Verified in lib/zaimu_tomo_web/router.ex lines around the live_session block.

3) Storage binary read remains app-to-S3 only (no browser-side presigned URLs)
- Storage facade ZaimuTomo.Storage.read_object/1 maps to adapter().read_object/2.
- S3 adapter (lib/zaimu_tomo/storage/s3.ex) implements read_object/2 which performs an
  HTTP Req.request() to the S3 endpoint and returns {:ok, binary} to the application.
- No presigned URL generation or exposure found in changed files (searched for presign/presigned and found none).

4) No browser-visible storage keys / bucket / URLs / credentials / local paths / internal error reasons
- S3 adapter uses config fetches for :access_key_id and :secret_access_key, but these are used server-side only to sign requests (no code returns them to clients).
- object_url and virtual_hosted_url are internal helper functions; not exposed in responses.
- DocumentController logs internal errors with Logger.error(inspect(reason)) server-side but returns generic 503 ("Service unavailable") to clients  verified in lib/zaimu_tomo_web/controllers/document_controller.ex.
- No changed templates or controllers return internal paths (/tmp, file://), credentials, bucket names or presigned URLs.

5) Conservative content policy and disposition
- For previews: preview route sets content-type via MediaPreview.safe_content_type/2, sets security headers (X-Frame-Options, X-Content-Type-Options, CSP frame-ancestors 'self'), and Content-Disposition: inline.
- For downloads: sets safe filename via MediaPreview.safe_download_filename/1 and uses Content-Disposition: attachment; filename="...". Both use safe_content_type mapping.

6) Query-param selection does not fetch storage on index
- DocumentLive.Index.handle_params checks params["preview"] and only resolves document metadata via Documents.get_document!  explicit comment "Do not read storage here" and implementation does not call Storage.read_object on index mount/params. Verified and covered by tests.

7) PDF/img/non-inline UI behavior matches handoff
- LiveView renders iframe for PDFs and <img> for images using the proxied preview route.
- Non-previewable types show inline message and Download link pointing to download route.
- Tests asserting preview and download behavior exist and pass.

8) Tests
- Ran targeted tests covering storage, controller, and live behavior:
  mix test test/zaimu_tomo/storage_test.exs test/zaimu_tomo_web/controllers/document_controller_test.exs test/zaimu_tomo_web/live/document_live_test.exs
- Result: 25 tests, 0 failures. (Output attached in test run logs.)

Notes / Observations
- Server-side logging uses inspect(reason) (e.g., Logger.error("Document preview failed... #{inspect(reason)}")). This is acceptable as logs are not returned to clients; tests assert the generic 503 and verify logs are recorded. Keep logs as-is for debugging but ensure log aggregation is adequately protected in production.
- S3 adapter signs requests using credentials from Application config. Ensure production config does not leak these values into templates or API outputs elsewhere.

Conclusion / Recommendation
- The candidate replaces client-visible internal storage errors with generic responses and limits the diff to the explicit 11-file whitelist.
- All required acceptance criteria are satisfied: routing order and auth scope, app-to-S3 binary reads (no presigned URLs), no browser-visible credentials/paths/URLs, conservative content-disposition and CSP, query-param selection safe, UI behavior matches handoff, and relevant tests exist and pass.

Verdict: APPROVE

