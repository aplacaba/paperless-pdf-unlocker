# Tasks — pdf-unlocker-service

Reference: `proposal.md`, `design.md`, `specs/pdf-unlock-pipeline/spec.md`,
`specs/service-configuration/spec.md`. Each task is verifiable and ≤ 2h.

## 1. Project scaffold

- [ ] 1.1 Create `unlocker.asd` (ASDF system def): components for
  `src/{config,logging,qpdf,paperless,main}.lisp`; depends-on `:dexador`,
  `:jonathan`, `:uiop`; plus a separate `unlocker-tests` system (depending on
  `:unlocker` and `:rove`) wired via
  `:in-order-to (test (test-op "unlocker-tests"))` on the main system.
- [ ] 1.2 Add `src/packages.lisp` (or per-file `defpackage`s) defining packages
  `unlocker.config`, `unlocker.logging`, `unlocker.qpdf`, `unlocker.paperless`,
  `unlocker.main`.
- [ ] 1.3 Add `.gitignore` (ignore `.fasl`, `*.fasl`, `build/`, quicklisp local
  dirs, `.sbclrc` artifacts) and a minimal `README.md` with build/run pointers.
- [ ] 1.4 Verify the system loads in SBCL (`(asdf:load-system :unlocker)`) and
  `rove` tests run green with zero tests as a baseline.

## 2. Configuration module (`src/config.lisp`)

- [ ] 2.1 Implement `load-config` reading all env vars in
  `specs/service-configuration/spec.md` → a `config` struct (url, token,
  candidates list, locked-tag, unlock-failed-tag, poll-interval, http-timeout,
  log-level). Parse `PASSWORD_CANDIDATES` splitting on newline **or** comma,
  trimming + dropping empties.
- [ ] 2.2 Implement required-var fail-fast: missing/empty `PAPERLESS_URL`,
  `PAPERLESS_TOKEN`, or `PASSWORD_CANDIDATES` → log error + exit non-zero before
  polling.
- [ ] 2.3 Implement empty-candidate-list handling: warn at startup, continue (do
  not exit).
- [ ] 2.4 Rove tests: defaults applied; comma split; newline split with blanks;
  each required var missing → error; empty list → warns + returns config.

## 3. Logging module (`src/logging.lisp`)

- [ ] 3.1 Implement leveled logging (`debug`/`info`/`warn`/`error`) to stdout,
  filtered by level; each line: ISO timestamp, level, optional doc-id, message.
- [ ] 3.2 Rove tests: level filtering (info suppresses debug; emits info/warn/
  error); timestamp/doc-id formatting.

## 4. qpdf decryption module (`src/qpdf.lisp`)

- [ ] 4.1 Implement `unlock (bytes candidates) → (or bytes null)`: write input to
  a temp file, for each candidate run `qpdf --password=<c> --decrypt <in> <out>`
  via `uiop:run-program`; on exit 0 read+return output bytes; on non-zero or
  subprocess error try next; return `nil` if all fail. Capture stderr (debug).
  Clean up temp files (unwind-protect).
- [ ] 4.2 Rove tests: at test time, generate an encrypted PDF with a known
  password via qpdf; assert correct candidate returns bytes, wrong returns nil,
  multi-candidate order returns first success, all-wrong returns nil, and
  missing-binary / malformed input is contained (returns nil, no raise).

## 5. Paperless-ngx client module (`src/paperless.lisp`)

- [ ] 5.1 Implement a thin HTTP client over Dexador with the configured base URL,
  token (Authorization header), and `HTTP_TIMEOUT_SECONDS`. Provide functions:
  `resolve-tag-by-name`, `ensure-tag`, `list-docs-by-tag`, `get-document`,
  `download-document`, `delete-document`, `patch-document-tags`,
  `patch-document-custom-fields`, and `upload-document` (multipart
  `post_document`).
- [ ] 5.2 Implement `ensure-custom-field` (create `unlock-source-id` if absent;
  reuse if present) and `lineage-index` (derive `source-id → replacement-id` for
  the current cycle from Paperless).
- [ ] 5.3 Design functions for mockability (Rove `mocking` / DI of the HTTP
  layer) so the full cycle can be unit-tested without network.
- [ ] 5.4 Rove tests (mocked HTTP): ensure-tag creates-then-reuses; ensure-custom-
  field creates-then-reuses; lineage-index builds from a fixture; tag/custom-field
  patch payloads are well-formed; the configured `HTTP_TIMEOUT_SECONDS` is
  forwarded to each Dexador call (mock assertion).

## 6. Pipeline orchestration (`src/main.lisp`)

- [ ] 6.1 Implement the cycle: resolve/ensure tags + custom field, build lineage
  index, list locked docs. Per doc, in this order:
  - if the original's id is already in the lineage index → delete the original
    only (a replacement already exists from a prior run; do **not** attempt unlock
    or apply `unlock-failed`). This check precedes unlock so an in-index document
    whose unlock would fail this cycle is never stranded as `unlock-failed`.
  - else: `get-document` + `download` → `qpdf:unlock`:
    - `nil` → patch-tags (remove locked, add unlock-failed).
    - present → upload replacement (metadata minus locked tag + `unlock-source-id`
      = original id) → delete original.
- [ ] 6.2 Wrap each Paperless call and the qpdf call in condition handlers
  (design D10): per-document errors skip + log; cycle-level errors log + sleep +
  retry; never crash the process. Upload-before-delete enforced.
- [ ] 6.3 Implement graceful shutdown: SIGTERM/SIGINT handler sets `*stopping*`;
  checked between docs and during the (interruptible/re-checked) inter-cycle sleep;
  mid-document signal finishes the current doc then exits 0.
- [ ] 6.4 Implement the entrypoint (`main`/`start`) that loads config (fail-fast)
  then enters the loop; wire as the SBCL `:toplevel` for `save-lisp-and-die`.
- [ ] 6.5 Rove tests (mocked client + a stub qpdf fake): cover — unlock success
  (upload+delete); all-candidates-fail (`unlock-failed` tag, no delete);
  in-index → delete-only (no upload, no unlock attempt); **in-index AND unlock
  would fail → still delete-only, not `unlock-failed`** (guards against
  stranding); a per-document transient error is logged and the cycle continues; a
  cycle-level (list/resolve/custom-field) failure is logged, does not crash, and
  triggers sleep + retry; a stop request between docs exits cleanly.

## 7. Packaging (Docker)

- [ ] 7.1 `Dockerfile` multi-stage: builder installs SBCL + Quicklisp, quickloads
  the system (fetches Dexador/Jonathan/Rove), dumps a standalone executable via
  `sb-ext:save-lisp-and-die :executable t :toplevel 'unlocker.main:start`.
- [ ] 7.2 Runtime stage `debian:bookworm-slim` + `apt-get install -y --no-install-
  recommends qpdf ca-certificates`; copy the `unlocker` binary; `ENTRYPOINT`/`CMD`
  the binary.
- [ ] 7.3 `docker-compose.example.yml` wiring env vars + `restart: unless-stopped`.
- [ ] 7.4 Verify: `docker build` succeeds; `docker run` with bogus env fails fast
  (exit non-zero, missing-var logged); image runs the loop (smoke test against a
  throwaway/no URL → fail-fast, proving the binary executes).

## 8. Verification against the real Paperless-ngx instance

- [ ] 8.1 Resolve Open Q1: confirm whether `post_document` applies copied metadata
  + `unlock-source-id` in-upload or requires patch-after-consume; implement the
  correct path (poll for new doc then PATCH if needed). Update client + tests.
- [ ] 8.2 Resolve Open Q2: confirm custom-field filtering for the lineage index,
  else use scan + in-memory index. Update `lineage-index` accordingly.
- [ ] 8.3 Resolve Open Q3: confirm exact multipart field names for correspondent /
  document_type / created. Update `upload-document`.
- [ ] 8.4 Run the manual E2E checklist (reference design §11): locked PDF →
  replaced with unlocked copy (original trashed, metadata preserved, locked tag
  gone, `unlock-source-id` set); wrong candidates → `unlock-failed`; simulated
  delete failure → next cycle cleans up without a duplicate; SIGTERM
  mid-document → current document finishes then the process exits 0.

## 9. Done

- [ ] 9.1 All Rove tests green; `openspec validate pdf-unlocker-service` passes;
  design/proposal/specs consistent with implementation.
