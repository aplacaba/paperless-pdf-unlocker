# Paperless-ngx PDF Unlocker Service — Design

**Date:** 2026-07-12
**Status:** Proposed (awaiting implementation plan)
**Project:** `email-to-paperless` (new service)

## 1. Purpose

Poll a Paperless-ngx instance for user-password-encrypted PDFs, decrypt them with
`qpdf` using a configurable list of candidate passwords, and replace each original
with an unlocked copy that preserves the original's metadata.

## 2. Background & Constraints

- Sample input: `eStatement_HEXAGON MC PLATINUM_JUL 09 2026_1001.pdf` (RCBC bank
  statement, user-password encrypted; `qpdf --is-encryption` requires a password).
- These are **user-password** PDFs (not merely owner-password/permissions-restricted),
  so `qpdf --decrypt` cannot succeed without a password. The service must try a set
  of candidate passwords per document.
- `qpdf` is available locally (`/usr/bin/qpdf`, v12.3.2) and confirmed able to
  decrypt the sample when given the correct password.
- Runtime choice: **Common Lisp (SBCL)** packaged as a **Docker** container running
  a long-lived poll loop.
- Testing framework: **Rove**.

## 3. Decisions (locked)

| Decision | Choice |
|---|---|
| Architecture | Stateless poll loop; Paperless tags + a custom field are the only state |
| Password strategy | Configurable list of candidate passwords; try each until one works |
| Detection | Tag-based: documents tagged `locked` are processed |
| After success | Upload unlocked copy with copied metadata (minus `locked` tag), then delete original |
| After failure (no candidate works) | Swap `locked` → `unlock-failed` tag |
| Delete-failure safety | Dedup via a Paperless custom field `unlock-source-id` (auto-created on first run) |
| Shutdown | Graceful on SIGTERM/SIGINT: finish current document, then exit 0 |
| Configuration | Environment variables only |
| Runtime | SBCL executable in a slim Debian container with `qpdf` |
| Extra `unlocked` tag | **Not** applied (new doc keeps original tags minus `locked`) |

## 4. Architecture & Module Layout

Single SBCL application, no local persistent state.

```
unlocker.asd              # ASDF system definition + dependency list
src/main.lisp             # entry point, poll loop, signal handling
src/config.lisp           # env-var parsing -> config struct
src/paperless.lisp        # Paperless-ngx REST client
src/qpdf.lisp             # unlock via qpdf subprocess
src/logging.lisp          # leveled logging to stdout
unlocker-tests/           # Rove test suite
Dockerfile                # multi-stage build
docker-compose.example.yml
```

**Libraries:** Dexador (HTTP + multipart), Jonathan (JSON), UIOP (shipped with SBCL;
subprocess + temp files), Rove (tests). All Quicklisp-installable.

**Responsibility boundaries:**
- `config` — pure: environment → `config` struct. No I/O.
- `paperless` — all REST: resolve tag → id, list docs by tag, get metadata, download,
  upload, delete, patch tags, manage the `unlock-source-id` custom field, and build
  the per-cycle lineage index.
- `qpdf` — input bytes + candidate list → unlocked bytes, or `nil`. Uses temp files.
- `main` — orchestration loop and signals only.

## 5. Data Flow

### 5.1 Cycle

```
loop forever (unless *stopping*):
  locked-tag-id = paperless:resolve-tag(LOCKED_TAG)
  failed-tag-id = paperless:resolve-tag(UNLOCK_FAILED_TAG)
  source-field  = paperless:ensure-custom-field("unlock-source-id", type=number)
  index         = paperless:lineage-index(source-field)   # {source-doc-id -> replacement-doc-id}

  docs = paperless:list-docs-by-tag(locked-tag-id)
  for each doc in docs (unless *stopping*):
    handle-document(doc, ...)

  interruptible-sleep(POLL_INTERVAL_SECONDS)
```

### 5.2 Per-document handling

```
meta, bytes = paperless:get-document(doc) + paperless:download(doc)
unlocked    = qpdf:unlock(bytes, PASSWORD_CANDIDATES)

if unlocked is nil:
  paperless:patch-tags(doc, remove=locked-tag-id, add=failed-tag-id)
  log warn "no candidate unlocked document"
  return

if index contains doc.id:                       # replacement already exists
  paperless:delete(doc)                         # safe: proven replacement exists
  log info "deleted original (duplicate cleanup)"
  return

new-id = paperless:upload(
           content   = unlocked,
           filename  = meta.original_filename,
           title     = meta.title,
           tags      = meta.tags - locked-tag-id,
           correspondent = meta.correspondent,
           document_type  = meta.document_type,
           created        = meta.created,
           custom_fields  = { source-field: doc.id })
paperless:delete(doc)
```

### 5.3 Failure-class safety

| Failure | Result | Data loss? | Duplicates? |
|---|---|---|---|
| Upload fails | No lineage written; original stays `locked`; retried next cycle | No | No |
| Upload ok, delete fails | Lineage field exists; next cycle hits the `index contains doc.id` branch and deletes original without re-uploading | No | No |
| All candidates fail | Original tagged `unlock-failed`; leaves queue | No | No |
| qpdf missing/crashes | Treated as unlock failure → `unlock-failed` | No | No |
| Cycle-list call fails (instance down / bad token) | Logged; sleep; retry next cycle. Never crashes | No | No |
| Empty candidate list | Config validation warns; every doc gets `unlock-failed` | No | No |

Upload is always performed **before** delete, so a failed upload can never lose a
document.

## 6. Configuration

Environment variables:

| Var | Required | Default | Purpose |
|---|---|---|---|
| `PAPERLESS_URL` | yes | — | Base URL (e.g. `https://paperless.example.com`) |
| `PAPERLESS_TOKEN` | yes | — | API token |
| `PASSWORD_CANDIDATES` | yes | — | Newline- **or** comma-separated candidate passwords |
| `LOCKED_TAG` | no | `locked` | Tag marking documents to process |
| `UNLOCK_FAILED_TAG` | no | `unlock-failed` | Tag applied when no candidate works |
| `POLL_INTERVAL_SECONDS` | no | `60` | Sleep between cycles |
| `HTTP_TIMEOUT_SECONDS` | no | `30` | Per-request timeout |
| `LOG_LEVEL` | no | `info` | `debug` / `info` / `warn` / `error` |

On startup, a missing required variable logs an error and the process exits non-zero.

## 7. Paperless-ngx API Mapping

To be confirmed empirically against the real instance during implementation:

- `GET /api/tags/?name__exact=<name>` → tag id
- `GET /api/documents/?tags__id__=<id>` → documents by tag
- `GET /api/documents/<id>/` → metadata
- `GET /api/documents/<id>/download/` → original file bytes
- `DELETE /api/documents/<id>/` → trash (soft delete)
- `PATCH /api/documents/<id>/` with `{tags: [...]}` → swap tags
- `POST /api/custom_fields/` → create `unlock-source-id` (type number) if absent
- `GET /api/custom_fields/` → locate the field id
- Upload: `POST /api/documents/post_document/` (multipart). **Open detail:** this
  enqueues asynchronous consumption, so reliably attaching copied metadata and the
  lineage custom field may require a follow-up `PATCH` on the new document once it
  exists. The exact mechanism (metadata-in-upload vs. patch-after-consume, and how
  to await consumption completion) is finalized during implementation.

## 8. qpdf Integration

- Per candidate password `p`: run
  `qpdf --password=<p> --decrypt <input.pdf> <output.pdf>` via `uiop:run-program`,
  writing input to a temp file and reading the output temp file.
  - Exit 0 → success; read output bytes; clean up; stop trying.
  - Non-zero (exit 2 = bad password / error) → try next candidate.
- If all candidates fail → return `nil`.
- `qpdf`'s stderr is captured and logged at debug (warn on overall failure).
- Candidate passwords are passed as a process argument. **Security note:** this
  exposes a candidate briefly in the container's process list. The container is
  single-tenant and single-process, so this is acceptable for v1. A future
  hardening may switch to `--password-file=<tempfile>` with `0600` perms.

## 9. Logging

Leveled output to stdout (for Docker logs). Each line: ISO timestamp, level,
document id (when relevant), message. Levels controlled by `LOG_LEVEL`.

## 10. Graceful Shutdown

- SBCL signal handler for `SIGTERM` and `SIGINT` sets a global `*stopping*` flag.
- The poll loop checks `*stopping*` between documents and before/repeatedly during
  the inter-cycle sleep.
- A signal arriving mid-document does **not** abort that document: the current
  document finishes (upload + delete), then the process exits with code 0.
- Compose uses `restart: unless-stopped` so transient crashes self-recover while
  intentional `docker stop` exits cleanly.

## 11. Testing (Rove)

- **`config`** — defaults; comma vs newline splitting; missing-required → error.
- **`qpdf`** — generate an encrypted PDF with a known password at test time using
  qpdf itself; assert unlock succeeds with the correct candidate, fails with wrong
  ones, and returns `nil` when no candidate matches.
- **Tag arithmetic** — `meta.tags − locked-tag-id`; lineage-index lookup.
- **Paperless client** — designed for mocking (Rove `mocking` / DI); one full cycle
  exercised against a stubbed client covering: unlock success, all-candidates-fail,
  and duplicate-already-exists (delete-only).
- **End-to-end** — manual checklist against the real instance (below), not
  automated.

### Manual E2E checklist
1. Tag a known locked PDF with `locked` in Paperless.
2. Run the container with `PASSWORD_CANDIDATES` containing the right password.
3. Verify: original deleted (trash), new unlocked doc exists with same metadata and
   no `locked` tag, `unlock-source-id` set to the original's id.
4. Repeat with a wrong candidate list → verify `unlock-failed` tag applied, original
   preserved.
5. Simulate delete failure (e.g. revoke delete between upload and delete in a test
   build) → verify next cycle deletes the original without creating a second copy.

## 12. Docker

**Multi-stage:**
- **Build stage:** SBCL + Quicklisp; `ql:quickload :unlocker`; dump a standalone
  executable with `sb-ext:save-lisp-and-die :executable t :toplevel
  'unlocker.main:start`.
- **Runtime stage:** `debian:bookworm-slim`; `apt-get install -y --no-install-
  recommends qpdf ca-certificates`; copy the `unlocker` binary; `ENTRYPOINT` the
  binary. No SBCL, no source, no Quicklisp at runtime.

**`docker-compose.example.yml`** wires the env vars and sets
`restart: unless-stopped`.

## 13. Out of Scope (v1)

- Concurrent/parallel document processing.
- Web UI, metrics, and HTTP health endpoint.
- Per-document retry backoff beyond the natural cycle loop.
- `--password-file` hardening.
- The email-to-paperless ingestion pipeline itself — this service only consumes the
  `locked` tag however it got there.
