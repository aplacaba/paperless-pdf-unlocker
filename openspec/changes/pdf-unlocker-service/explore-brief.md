# Explore Brief — pdf-unlocker-service

## Goal
A Dockerized Common Lisp (SBCL) service that polls a Paperless-ngx instance for
user-password-encrypted PDFs (tagged `locked`), decrypts them with `qpdf` using a
configurable list of candidate passwords, and replaces each original with an
unlocked copy that preserves the original's metadata. Derived from the approved
design at `docs/superpowers/specs/2026-07-12-pdf-unlocker-service-design.md`.

## Rejected alternatives (and why)
- **Owner-password assumption** — rejected: the sample (`eStatement_*.pdf`) is
  user-password encrypted (`qpdf --requires-password` exit 0); a candidate
  password list is required.
- **Approach B: qpdf sidecar container** — rejected: qpdf is a CLI, not a daemon;
  wrapping it as a network service adds hops for no benefit.
- **Approach C: local state store (SQLite/file)** — rejected: we chose
  "mark unlock-failed" (not retry-N), so local state would duplicate what tags
  already express.
- **Tag-only commit for delete-failure safety** — rejected: a tag "mark then act"
  has a hole because the mark call itself can fail. Replaced by a custom-field
  lineage dedup key.
- **FiveAM** — rejected: user prefers Rove (cohesive Fukamachi stack:
  Dexador + Jonathan + Rove).
- **`UNLOCKED_TAG` traceability tag** — rejected: user opted off; new doc keeps
  original tags minus `locked`.
- **`--password-file` qpdf hardening** — deferred to post-v1 (single-tenant
  container makes argv acceptable for now).

## Env var table (complete)
| Var | Required | Default |
|---|---|---|
| `PAPERLESS_URL` | yes | — |
| `PAPERLESS_TOKEN` | yes | — |
| `PASSWORD_CANDIDATES` | yes | — (newline- or comma-separated) |
| `LOCKED_TAG` | no | `locked` |
| `UNLOCK_FAILED_TAG` | no | `unlock-failed` |
| `POLL_INTERVAL_SECONDS` | no | `60` |
| `HTTP_TIMEOUT_SECONDS` | no | `30` |
| `LOG_LEVEL` | no | `info` |

## Tag / label sets (complete)
- `locked` (configurable name) — documents to process.
- `unlock-failed` (configurable name) — applied when no candidate unlocks.
- Custom field `unlock-source-id` (type: number), created on first run on the
  *replacement* document, value = original document id. This is the dedup/lineage
  key. No other tags/fields are introduced.

## Module layout (complete)
```
unlocker.asd, src/{main,config,paperless,qpdf,logging}.lisp,
unlocker-tests/ (Rove), Dockerfile, docker-compose.example.yml
```

## Cross-module data flow
- **startup once:** `main` → `config:load-config` (env → config struct); missing
  required → exit non-zero.
- **per cycle:** `main` → `paperless:resolve-tag` (locked, unlock-failed),
  `paperless:ensure-custom-field` (unlock-source-id),
  `paperless:lineage-index` (maps source-id → replacement-id, derived from
  Paperless, not persisted), `paperless:list-docs-by-tag`.
- **per document:** `paperless:get-document` + `paperless:download` →
  `qpdf:unlock(bytes, candidates)`.
  - nil → `paperless:patch-tags` (remove locked, add unlock-failed).
  - present + in index → `paperless:delete` (duplicate cleanup).
  - present + not in index → `paperless:upload` (metadata minus locked tag +
    custom field unlock-source-id = original id) → `paperless:delete`.
- **signals:** SIGTERM/SIGINT set `*stopping*`; checked between docs and during
  sleep; current document finishes before exit 0.

## qpdf contract
- Command: `qpdf --password=<p> --decrypt <in> <out>` via `uiop:run-program`,
  temp files for in/out.
- Exit 0 → success (read out). Non-zero (2 = bad password/error) → next
  candidate. All fail → return nil. stderr captured → debug (warn on failure).

## Failure-class table (complete)
| Failure | Result | Loss? | Dup? |
|---|---|---|---|
| Upload fails | original stays locked, retried | no | no |
| Upload ok, delete fails | lineage exists → next cycle deletes only | no | no |
| All candidates fail | unlock-failed tag | no | no |
| qpdf missing/crash | unlock-failed | no | no |
| List call fails | log, sleep, retry cycle | no | no |
| Empty candidate list | warn; all docs → unlock-failed | no | no |

## Open questions (to resolve during apply)
1. **Upload metadata mechanism:** `POST /api/documents/post_document/` enqueues
   async consumption. Confirm whether metadata + the `unlock-source-id` custom
   field can be set in the upload call or require a follow-up `PATCH` after the
   new document appears (and how to await consumption completion). Finalize
   against the real instance.
2. **Custom-field filtering:** confirm whether Paperless supports filtering
   documents by custom-field value to build the lineage index efficiently, or
   whether we scan docs having the field populated and index in memory.
3. **Exact multipart field names** for `correspondent`/`document_type`/`created`
   on `post_document` (verify against API).
