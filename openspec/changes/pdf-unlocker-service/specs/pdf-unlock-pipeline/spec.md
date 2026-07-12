## ADDED Requirements

### Requirement: Tag-based detection of locked documents

The system SHALL, on each poll cycle, identify the set of Paperless-ngx documents
to process as exactly those carrying the configured locked tag
(`LOCKED_TAG`, default `locked`). The system SHALL ensure both the locked tag and
the unlock-failed tag exist in Paperless-ngx (create-if-missing) before use, and
SHALL reuse an existing tag of the same name.

#### Scenario: Documents tagged locked are returned for processing
- **WHEN** a poll cycle runs and document 7 carries the locked tag while document 9
  does not
- **THEN** the system processes document 7 and does not process document 9

#### Scenario: Locked tag does not exist yet
- **WHEN** the configured locked tag does not exist in Paperless-ngx
- **THEN** the system creates it (or reuses it if concurrently created) and the
  cycle completes with zero documents to process

#### Scenario: Unlock-failed tag does not exist yet
- **WHEN** the configured unlock-failed tag does not exist when first needed
- **THEN** the system creates it before applying it, rather than failing

### Requirement: Candidate-password decryption via qpdf

The system SHALL attempt to decrypt each locked PDF by invoking
`qpdf --password=<candidate> --decrypt <in> <out>` once per candidate password from
the configured candidate list, in order. A qpdf exit code of 0 SHALL be treated as
success; any non-zero exit code or subprocess error SHALL be treated as a failed
candidate. The system SHALL return the unlocked bytes of the first successful
candidate, or indicate failure if no candidate succeeds.

#### Scenario: Correct candidate unlocks the document
- **WHEN** the candidate list is `["wrong", "right"]` and "right" is the document's
  password
- **THEN** the system returns the unlocked PDF bytes produced by the qpdf run that
  used "right"

#### Scenario: No candidate unlocks the document
- **WHEN** every candidate fails (wrong passwords)
- **THEN** the system indicates decryption failure without raising

#### Scenario: qpdf binary missing or crashes
- **WHEN** the qpdf subprocess cannot be started or exits with a subprocess error
  (not a normal non-zero exit) for every candidate
- **THEN** the system treats this as a decryption failure (does not propagate the
  error to the poll cycle)

### Requirement: Metadata-preserving replacement on success

When decryption succeeds, the system SHALL upload the unlocked PDF as a new
Paperless-ngx document copying the original's title, correspondent, document type,
created date, and tags, with the locked tag removed. The system SHALL NOT add any
additional "unlocked" traceability tag. The system SHALL set the lineage custom
field `unlock-source-id` on the new document to the original document's id.

#### Scenario: Replacement preserves metadata minus the locked tag
- **WHEN** a document with title "Statement", correspondent C, document type T,
  created date D, and tags {locked, bank} is successfully unlocked
- **THEN** the uploaded replacement has title "Statement", correspondent C, type T,
  created D, tags {bank} (locked removed), and `unlock-source-id` equal to the
  original's id

#### Scenario: Upload mechanism is asynchronous
- **WHEN** Paperless-ngx `post_document` enqueues consumption rather than applying
  metadata synchronously
- **THEN** the system SHALL still ensure the copied metadata and the
  `unlock-source-id` field end up on the new document (the exact mechanism —
  in-upload vs. patch-after-consume — is an implementation choice resolved during
  apply, not a behavioral difference)

### Requirement: Upload-before-delete ordering

The system SHALL upload and confirm the replacement document before deleting the
original. The system SHALL never delete an original whose replacement has not been
confirmed.

#### Scenario: Upload failure leaves the original intact
- **WHEN** the upload of the unlocked replacement fails
- **THEN** the original document is not deleted and remains tagged locked

### Requirement: Custom-field lineage key creation

The system SHALL ensure the `unlock-source-id` custom field (type number) exists in
Paperless-ngx, creating it on first run if it is absent and reusing it thereafter.
The system SHALL do this before it reads the field to build the lineage index or
sets the field's value on a replacement.

#### Scenario: unlock-source-id field does not exist yet
- **WHEN** the `unlock-source-id` custom field does not exist in Paperless-ngx at
  startup
- **THEN** the system creates it before its first use in the cycle

#### Scenario: unlock-source-id field already exists
- **WHEN** the `unlock-source-id` custom field already exists
- **THEN** the system reuses the existing field and does not create a duplicate

### Requirement: Duplicate-safe replacement via lineage

The system SHALL maintain, per cycle, an index mapping original document ids to
replacement document ids, derived from Paperless-ngx by reading the
`unlock-source-id` custom field of documents that have it set. Before uploading a
replacement, if the original's id is already present in the index, the system SHALL
delete the original and SHALL NOT upload a new replacement.

#### Scenario: Replacement already exists from a prior failed delete
- **WHEN** a previous run uploaded a replacement but failed to delete the original,
  and the original is still tagged locked
- **THEN** the current cycle finds the original's id in the lineage index, deletes
  the original, and creates no additional replacement

#### Scenario: Normal first-time processing
- **WHEN** an original's id is not in the lineage index
- **THEN** the system uploads exactly one replacement and deletes the original

### Requirement: Failure tagging when decryption is impossible

When decryption fails for a document, the system SHALL remove the locked tag from
that document and add the configured unlock-failed tag
(`UNLOCK_FAILED_TAG`, default `unlock-failed`). The system SHALL NOT delete such a
document.

#### Scenario: All candidates fail
- **WHEN** no candidate password unlocks document 5
- **THEN** document 5 ends the cycle with the unlock-failed tag, without the locked
  tag, and is not deleted

### Requirement: Cycle resilience (never crash)

A failure while processing a single document SHALL NOT abort the poll cycle or the
process. The system SHALL log such failures and continue with the next document. A
failure of a cycle-level call (listing documents, tag resolution, custom-field
creation, or building the lineage index) SHALL be logged and the system SHALL sleep
for the configured poll interval and retry the cycle, without exiting.

#### Scenario: Transient error on one document's download
- **WHEN** downloading document 3 raises a transient HTTP error
- **THEN** the system logs the error, skips document 3, and proceeds to document 4

#### Scenario: Instance unreachable at cycle start
- **WHEN** the cycle-level call to list locked documents fails because the
  Paperless-ngx instance is unreachable
- **THEN** the system logs the error, sleeps for the poll interval, and retries the
  cycle; the process keeps running

### Requirement: Graceful shutdown

The system SHALL install handlers for SIGTERM and SIGINT that request a stop. The
system SHALL check for the stop request between documents and during the inter-cycle
sleep. A stop request received while a document is mid-processing SHALL NOT abort
that document; the system SHALL finish the current document and then exit with code
0.

#### Scenario: Stop between documents
- **WHEN** SIGTERM is received after document 2 finishes and before document 3 starts
- **THEN** the system exits with code 0 without processing document 3

#### Scenario: Stop during a document
- **WHEN** SIGTERM is received while document 4 is being uploaded
- **THEN** the system completes document 4 (upload and delete) and then exits with
  code 0

### Requirement: Periodic polling

The system SHALL run poll cycles repeatedly, sleeping for the configured poll
interval between cycles, until a stop is requested.

#### Scenario: Cycle cadence
- **WHEN** the poll interval is 60 seconds and no stop is requested
- **THEN** the system starts a new cycle roughly every 60 seconds
