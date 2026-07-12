# Review Log — pdf-unlocker-service

## proposal Round 1 — 2026-07-12T12:00:00Z
### 🔴 Fixed
- none

### 🟡 Addressed (applied to proposal.md before freeze)
- Cycle-resilience behaviors (transient API list-call failure → log/sleep/retry;
  qpdf missing/crash → never crash the cycle) were not surfaced in the
  `pdf-unlock-pipeline` capability → added "transient-API/subprocess resilience
  (errors logged, never crash the cycle)" to that capability's description, and a
  sentence to the failure-handling "What Changes" bullet.
- Empty-`PASSWORD_CANDIDATES` behavior was unplaced → assigned the warn-and-proceed
  rule to `service-configuration` (warns at startup; every document then tagged
  `unlock-failed`).
- No Non-goals section → added one mirroring design §13 (concurrency, web
  UI/metrics/health, retry backoff, `--password-file` hardening, email pipeline).
- Three open API questions unacknowledged → added an "Open questions /
  implementation risks" section (upload async-vs-PATCH mechanism, custom-field
  filtering for the lineage index, exact multipart field names).
- Clarified that `unlock-failed` tag name is configurable (matching the env var).

### 🔴 Outstanding
- none

**Verdict: PASS — proposal.md frozen.**

## design Round 1 — 2026-07-12T13:00:00Z
### 🔴 Fixed
- none

### 🟡 Addressed (applied to design.md before freeze)
- Resilience mechanism (HOW) was missing: the frozen proposal names
  "transient-API/subprocess resilience (errors logged, never crash the cycle)"
  but only qpdf's exit-code contract was specified. → added **D10**: each
  Paperless call and the qpdf subprocess are wrapped in condition handlers;
  qpdf binary-missing/crash/malformed-PDF caught in `qpdf:unlock` → unlock
  failure; per-document call errors skip the doc + log; cycle-level list/resolve
  errors log + sleep + retry; never crashes the process.
- `unlock-failed` tag creation responsibility was ambiguous (D6 vs Migration).
  → **D6** now states the service **ensures both configurable tags exist**
  (create-if-missing via `ensure-tag`, consistent with D7); Migration step 1 and
  step 4 updated accordingly.
- Failure-class safety argument was scattered across D1/D5/D7. → added a
  "Synthesis — losslessness & duplicate-freeness" table after D7 covering all
  seven failure modes (including qpdf-missing, per-document transient, cycle-level,
  empty-candidate-list) plus the load-bearing invariant.

### 🔴 Outstanding
- none

**Verdict: PASS — design.md frozen.**

## specs Round 1 — 2026-07-12T14:30:00Z
### 🔴 Fixed
- none (this round)

### 🟡 Addressed (applied before Round 2)
- `HTTP_TIMEOUT_SECONDS` was declared but had no behavioral requirement → added a
  "HTTP request timeout" requirement + scenario in service-configuration.
- "Upload mechanism is asynchronous" scenario mixed a SHALL assertion with
  deferral prose → tightened the THEN to assert the metadata + `unlock-source-id`
  invariant; mechanism note reframed as an implementation choice, not a caveat.

### 🔴 Outstanding (fixed before Round 2)
- Missing requirement/scenario for auto-creating the `unlock-source-id` custom
  field (D7 ensure-custom-field commitment). → added "Custom-field lineage key
  creation" requirement + two scenarios (field absent → created before first use;
  field present → reused) in pdf-unlock-pipeline, mirroring the ensure-tag
  treatment.

## specs Round 2 — 2026-07-12T15:45:00Z
### 🔴 Fixed
- Round 1 🔴 (missing custom-field creation requirement): resolved —
  "Custom-field lineage key creation" added with two scenarios; type number,
  timing before first read/write; consistent with D7.
- Round 1 🟡 (HTTP_TIMEOUT_SECONDS no behavioral requirement): resolved —
  "HTTP request timeout" requirement + scenario added in service-configuration.
- Round 1 🟡 (async-upload scenario mixed normative + deferral): resolved —
  THEN now asserts the metadata + unlock-source-id invariant; mechanism
  reframed as implementation choice (frozen Open Q1).

### 🟡 Addressed (applied before freeze)
- "Cycle resilience (never crash)" enumerated cycle-level failures as "list or
  tag-resolution calls", omitting ensure-custom-field and lineage-index. →
  tightened to enumerate "listing documents, tag resolution, custom-field
  creation, or building the lineage index". Design D10 already covered this.

### 🔴 Outstanding
- none

**Verdict: PASS — specs frozen.**

## tasks Round 1 — 2026-07-12T17:30:00Z
### 🔴 Fixed
- none

### 🟡 Addressed (applied before freeze)
- Lineage-index check ordering (6.1): the flow previously checked the index only
  on the unlock-success branch, risking an in-index doc whose unlock fails this
  cycle being stranded as `unlock-failed` next to its existing replacement. → 6.1
  now checks the index FIRST (in-index → delete-only, no unlock attempt, no
  unlock-failed); 6.5 adds the "in-index AND unlock would fail → delete-only"
  test.
- Cycle-level resilience unverified (6.5): added a cycle-level (list/resolve/
  custom-field) failure test (logged, no crash, sleep+retry).
- Graceful-shutdown mid-document unverified: added the SIGTERM-mid-document case
  to the 8.4 manual E2E checklist.
- HTTP_TIMEOUT_SECONDS application unverified (5.4): added a mock assertion that
  the configured timeout is forwarded to each Dexador call.
- ASDF test-op nit (1.1): corrected to reference the `unlocker-tests` system via
  `:in-order-to (test (test-op "unlocker-tests"))` rather than `"rove"` directly.

### 🔴 Outstanding
- none

**Verdict: PASS — tasks.md frozen. All proposal artifacts complete; ready to apply.**
