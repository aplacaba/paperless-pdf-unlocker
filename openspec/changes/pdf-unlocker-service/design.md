## Context

Greenfield service. Paperless-ngx cannot index user-password-encrypted PDFs (sample:
`eStatement_*.pdf`, an RCBC bank statement confirmed via `qpdf --requires-password`).
Because these are user-password encrypted (not merely owner-password restricted),
`qpdf --decrypt` needs a password. The service autonomously detects tagged locked
PDFs, tries a configurable candidate-password list, and replaces originals with
unlocked copies that preserve metadata. Approved reference design lives at
`docs/superpowers/specs/2026-07-12-pdf-unlocker-service-design.md`; proposal at
`openspec/changes/pdf-unlocker-service/proposal.md`.

Stakeholders: single operator running a self-hosted Paperless-ngx (Docker).

## Goals / Non-Goals

**Goals:**
- Autonomous, restart-safe replacement of locked PDFs with unlocked copies.
- No data loss and no duplicate documents, even across failures.
- Zero-touch operation in Docker, configured entirely by env vars.
- Verifiable behavior via automated (Rove) tests.

**Non-Goals:** (see proposal.md §Non-goals) concurrency, web UI/metrics/health,
retry backoff beyond the poll loop, `--password-file` hardening, and the email
ingestion pipeline.

## Decisions

**D1 — Stateless architecture; Paperless tags + a custom field are the only state.**
Rationale: a failed post-upload delete must not create duplicates and must not lose
data. A local DB/file would duplicate state already expressible in Paperless and
add an ops surface. Alternatives considered:
- *Local state store (SQLite):* rejected — duplicates tag state; we chose
  "mark unlock-failed" (no retry-N), so there is nothing else to persist.
- *Tag-only two-phase commit:* rejected — the "mark" call itself can fail across
  the unreliable boundary, leaving a hole (either dup or loss). A dedup **key** is
  required, hence D7.

**D2 — Common Lisp (SBCL), packaged as a standalone executable in a slim Docker image.**
Rationale: operator/runtime choice. Build produces a single binary via
`sb-ext:save-lisp-and-die :executable t`; runtime image only needs `qpdf` + system
libs. Cohesive library stack from one author (Dexador + Jonathan + Rove).

**D3 — `qpdf` invoked as a subprocess via UIOP, with temp files for input/output.**
Rationale: `qpdf` is the reliable, purpose-built tool; a CL PDF library would add a
large dependency and re-implement decryption poorly. Temp files (UIOP) are robust;
stdin/stdout piping is avoided to keep error capture simple. Per candidate:
`qpdf --password=<p> --decrypt <in> <out>`; exit 0 → success, non-zero (2 = bad
password/error) → next candidate; all fail → `nil`. `qpdf` stderr logged at debug.

**D4 — Candidate-password list (env var), tried in order until one works.**
Rationale: bank-statement passwords follow known formats; a small candidate set
covers a household's accounts. Alternatives: single fixed password (too rigid), or
per-document password stored in Paperless (extra metadata overhead). Empty list →
warn at startup, proceed (every doc → `unlock-failed`).

**D5 — Upload-before-delete ordering.**
Rationale: deleting first risks data loss if the upload then fails; uploading first
only risks a duplicate, and D7 eliminates even that.

**D6 — Tag-based detection (`locked`), with `unlock-failed` on exhaustion.**
Rationale: explicit, cheap, and controllable via the API's tag filter. Alternatives:
scan-all + per-doc qpdf check (expensive on large libraries); no-content detection
(also catches unrelated parse failures). Tag application is out of scope for this
service — however the tag got there, we consume it. **Tag creation:** the service
**ensures both configurable tags exist** (create-if-missing via an `ensure-tag`
helper, consistent with D7's auto-create of the custom field), so the operator is
not required to pre-create either; if they pre-create them, the service simply
reuses the existing tags.

**D7 — Dedup/lineage via a Paperless custom field `unlock-source-id` (number), set
on each replacement to the original document id; auto-created on first run.**
Rationale: the only fully lossless + duplicate-free option. Each cycle derives an
in-memory index `source-id → replacement-id` from Paperless. Before processing a
locked doc: if its id is in the index, a replacement already exists → **delete
original only** (no re-upload). Alternatives: `archive_serial_number` hack
(rejected — abuses a user-facing field), local state (rejected — see D1), tag-only
commit (rejected — see D1).

**Synthesis — losslessness & duplicate-freeness across every failure mode** (the
point of D1 + D5 + D7, made explicit):

| Failure | Result | Loss? | Dup? |
|---|---|---|---|
| Upload fails | No lineage written; original stays `locked`; retried next cycle | no | no |
| Upload ok, delete fails | Lineage exists → next cycle hits the index branch and deletes original, no re-upload | no | no |
| All candidates fail | `locked` → `unlock-failed` | no | no |
| qpdf missing / crash / malformed PDF | Caught as unlock failure → `unlock-failed` (D10) | no | no |
| Per-document Paperless call fails transiently | That doc skipped + logged; cycle continues (D10) | no | no |
| Cycle-level list/resolve fails (instance down, bad token) | Logged; sleep; retry whole cycle; never crash (D10) | no | no |
| Empty candidate list | Warn at startup; every doc → `unlock-failed` | no | no |

The invariant: a replacement is created **only** when an unlocked file is in hand,
and the original is deleted **only** either right after a confirmed upload or after
the lineage index proves a replacement already exists.

**D8 — Graceful shutdown: SIGTERM/SIGINT set a `*stopping*` flag.**
Rationale: Docker `stop` sends SIGTERM. The flag is checked between documents and
during the interruptible inter-cycle sleep. A signal mid-document does **not** abort
that document (avoids half-written uploads); the current document finishes, then the
process exits 0.

**D9 — Module boundaries.** `config` (pure env → struct), `paperless` (all REST),
`qpdf` (bytes + candidates → bytes|nil), `main` (loop + signals), `logging` (leveled
stdout). Each is independently testable; the Paperless client is designed for
mocking so the full cycle is unit-testable.

**D10 — Resilience via condition handlers (the HOW behind "never crash the cycle").**
Every individual Paperless REST call (`resolve-tag`, `get-document`, `download`,
`upload`, `delete`, `patch-tags`, custom-field ops) and the `qpdf` subprocess
invocation are each wrapped in a CL condition handler (`handler-case`/`handler-bind`).
Mapping to the explore-brief failure-class table:
- A `uiop:run-program` error (qpdf binary missing, signaled crash, malformed PDF)
  is caught inside `qpdf:unlock` and treated as "this candidate failed"; if no
  candidate succeeds, the function returns `nil` → the document is tagged
  `unlock-failed`. It is never propagated to the cycle.
- A transient error on a **per-document** Paperless call is caught in the
  per-document handler → logged at warn/error → that document is skipped, and the
  loop continues to the next document.
- A failure on the **cycle-level** list/resolve calls (instance down, bad token,
  5xx) is caught at the cycle boundary → logged at error → the service sleeps
  `POLL_INTERVAL_SECONDS` and retries the whole cycle. It never crashes the process.
This realizes the frozen proposal's "transient-API/subprocess resilience (errors
logged, never crash the cycle)" capability.

## Risks / Trade-offs

- [Async upload consumption may delay metadata application] → `post_document`
  enqueues consumption; reliably attaching copied metadata + the lineage field may
  require upload-then-poll-then-`PATCH`. Mitigation: implement the PATCH-after-
  consume path; poll for the new document before patching. (Open Q1.)
- [Custom-field filtering may be unsupported by the API] → cannot build the lineage
  index via a filtered query. Mitigation: scan documents with the field populated
  and build the index in memory each cycle. (Open Q2.)
- [Candidate password exposed briefly in process argv] → only relevant inside the
  container. Mitigation: single-tenant/single-process; flagged for `--password-file`
  hardening post-v1. (Non-goal.)
- [Candidate list maintenance burden] → operator must keep the env var current.
  Mitigation: additive only; unknown passwords fall through to `unlock-failed`.
- [Docker build needs network for Quicklisp] → fetches Dexador/Jonathan/Rove at
  build time. Mitigation: accepted for v1; deps could be vendored later.
- [SBCL signal-handling specifics] → use `sb-sys:enable-interrupt`; verify the
  mid-document "finish then exit" guarantee in tests/manual checks.
- [Paperless API token permissions] → token must permit read/write/delete/custom-
  field creation. Mitigation: document required scopes in README/compose.

## Migration Plan

No data migration. Deploy steps:
1. (Optional) Pre-create the `locked` tag in Paperless-ngx if you want to start
   tagging documents before the service's first run. The service auto-creates both
   `locked` and `unlock-failed` on first run if absent (D6), and reuses existing
   tags of the same name.
2. Build the image (`docker build`) or use the compose file.
3. Set env vars (`PAPERLESS_URL`, `PAPERLESS_TOKEN`, `PASSWORD_CANDIDATES`, …) and
   `docker compose up -d` with `restart: unless-stopped`.
4. On first run the service creates the `unlock-source-id` custom field and
   ensures the `locked` / `unlock-failed` tags exist.
5. Tag a known locked PDF with `locked` and observe one cycle.

Rollback: stop the container. Until a replacement is confirmed uploaded and the
original deleted, originals are untouched; there is no destructive action that
cannot be halted by stopping the service. Deleted originals are in Paperless trash
(restoreable).

## Open Questions

1. **Upload mechanism:** metadata-in-upload vs. `PATCH`-after-consume (and how to
   await consumption). Resolve by testing against the real instance during apply.
2. **Custom-field filtering:** supported as a query, or scan + index in memory?
3. **Exact multipart field names** for `correspondent` / `document_type` / `created`
   on `post_document`.
