## Why

Paperless-ngx cannot index user-password-encrypted PDFs (e.g. bank eStatements
like the sample `eStatement_*.pdf`), leaving them unsearchable. There is no
built-in way to retroactively decrypt and replace such documents. A small
autonomous service that detects, decrypts (via `qpdf` with candidate passwords),
and replaces them restores full-text searchability without manual intervention.

## What Changes

- **New** Dockerized Common Lisp (SBCL) service that runs a long-lived poll loop.
- **New** tag-based detection: processes every Paperless-ngx document tagged
  `locked` (tag name configurable).
- **New** decryption using `qpdf` against a configurable list of candidate
  passwords (the documents are user-password encrypted, so a password is
  required).
- **New** replacement behavior: upload the unlocked PDF as a new document copying
  the original's metadata (title, correspondent, document type, created date, and
  tags **minus** the `locked` tag), then delete the original (moved to Paperless
  trash).
- **New** failure handling: when no candidate password unlocks a document, swap
  the `locked` tag for an `unlock-failed` tag (both tag names configurable). A
  transient API error or `qpdf` subprocess crash on one document is logged and
  never crashes the poll cycle.
- **New** duplicate-safety: a Paperless custom field `unlock-source-id` (auto-
  created on first run) records lineage from each replacement to its original, so
  a failed post-upload delete cannot produce duplicate replacements.
- **New** graceful shutdown on SIGTERM/SIGINT: the current document finishes, then
  the process exits 0.
- **New** configuration via environment variables only.

## Capabilities

### New Capabilities
- `pdf-unlock-pipeline`: end-to-end behavior — polling, tag-based detection,
  candidate-password decryption, metadata-preserving replacement, delete-failure
  safety, failure tagging, transient-API/subprocess resilience (errors logged,
  never crash the cycle), and graceful shutdown.
- `service-configuration`: the environment-variable contract that parameterizes
  the service (Paperless endpoint/token, candidate passwords, tag names, polling,
  HTTP timeout, log level), the required-variable fail-fast startup rule, and the
  warn-and-proceed rule for an empty candidate list (warns at startup; every
  document is then tagged `unlock-failed`).

### Modified Capabilities
- _(none — this is a greenfield service with no existing specs.)_

## Impact

- **Code:** new Common Lisp project (`unlocker.asd`, `src/{main,config,paperless,
  qpdf,logging}.lisp`) plus a Rove test suite (`unlocker-tests/`).
- **Runtime:** new multi-stage Dockerfile producing a slim Debian image containing
  a standalone SBCL executable + `qpdf`; `docker-compose.example.yml` provided.
- **External system — Paperless-ngx:** consumes the REST API (`/api/tags/`,
  `/api/documents/`, `/api/custom_fields/`); creates one custom field
  (`unlock-source-id`, number type); deletes (trashes) processed originals and
  uploads replacements. Requires a valid API token.
- **Dependencies (CL):** Dexador, Jonathan, UIOP (bundled with SBCL), Rove (tests).
- **System dependency:** `qpdf` binary inside the container.
- **No breaking changes** — net-new service, no existing behavior altered.

## Non-goals

Out of scope for this change (may be revisited later):

- Concurrent/parallel document processing within a cycle.
- Web UI, metrics, and an HTTP health endpoint.
- Per-document retry backoff beyond the natural poll loop.
- `qpdf --password-file` hardening (candidate passwords passed as argv; the
  container is single-tenant/single-process).
- The email-to-paperless ingestion pipeline itself — this service only consumes
  the `locked` tag, however it got there.

## Open questions / implementation risks

Resolved during apply against the real Paperless-ngx instance (do not over-specify
the mechanism in specs/tasks until tested):

1. Upload is via `POST /api/documents/post_document/`, which enqueues **async**
   consumption. Confirm whether copied metadata + the `unlock-source-id` custom
   field can be set in the upload call or require a follow-up `PATCH` after the
   new document appears (and how to await consumption completion).
2. Whether documents can be filtered by custom-field value to build the lineage
   index efficiently, or must be scanned + indexed in memory.
3. Exact multipart field names for `correspondent` / `document_type` / `created`
   on `post_document`.
