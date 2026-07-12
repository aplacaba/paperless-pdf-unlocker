## ADDED Requirements

### Requirement: Environment-variable configuration

The system SHALL be configured exclusively via environment variables. The system
SHALL read: `PAPERLESS_URL` (base URL), `PAPERLESS_TOKEN` (API token),
`PASSWORD_CANDIDATES` (candidate passwords), `LOCKED_TAG` (default `locked`),
`UNLOCK_FAILED_TAG` (default `unlock-failed`), `POLL_INTERVAL_SECONDS` (default
`60`), `HTTP_TIMEOUT_SECONDS` (default `30`), and `LOG_LEVEL` (default `info`).

#### Scenario: Defaults applied when optionals are unset
- **WHEN** only `PAPERLESS_URL`, `PAPERLESS_TOKEN`, and `PASSWORD_CANDIDATES` are set
- **THEN** the effective config uses `LOCKED_TAG=locked`,
  `UNLOCK_FAILED_TAG=unlock-failed`, `POLL_INTERVAL_SECONDS=60`,
  `HTTP_TIMEOUT_SECONDS=30`, and `LOG_LEVEL=info`

### Requirement: Required-variable fail-fast startup

The system SHALL treat `PAPERLESS_URL`, `PAPERLESS_TOKEN`, and
`PASSWORD_CANDIDATES` as required. If any required variable is missing or empty at
startup, the system SHALL log an error naming the missing variable and exit with a
non-zero status, without starting the poll loop.

#### Scenario: Missing Paperless token
- **WHEN** `PAPERLESS_TOKEN` is unset
- **THEN** the system logs an error and exits non-zero before polling

#### Scenario: Missing Paperless URL
- **WHEN** `PAPERLESS_URL` is unset
- **THEN** the system logs an error and exits non-zero before polling

### Requirement: Candidate-password list parsing

The system SHALL parse `PASSWORD_CANDIDATES` as a list accepting either newline- or
comma-separated values, trimming surrounding whitespace from each entry and
dropping empty entries.

#### Scenario: Comma-separated candidates
- **WHEN** `PASSWORD_CANDIDATES` is `alpha,beta,gamma`
- **THEN** the candidate list is `["alpha", "beta", "gamma"]`

#### Scenario: Newline-separated candidates with blanks
- **WHEN** `PASSWORD_CANDIDATES` is `alpha\n\nbeta\n`
- **THEN** the candidate list is `["alpha", "beta"]`

### Requirement: Empty candidate list warns and proceeds

The system SHALL log a warning at startup when `PASSWORD_CANDIDATES` is provided
but parses to an empty list, and SHALL continue running (it SHALL NOT exit). Under
this condition, the system SHALL tag every locked document `unlock-failed` (since
no candidate can succeed).

#### Scenario: Empty list does not stop the service
- **WHEN** `PASSWORD_CANDIDATES` is set but parses to an empty list
- **THEN** the system starts the poll loop after logging a warning, and any locked
  document is moved to the unlock-failed tag without deletion

### Requirement: HTTP request timeout

The system SHALL apply the configured `HTTP_TIMEOUT_SECONDS` as the timeout for
every HTTP call it makes to Paperless-ngx.

#### Scenario: Timeout is applied to each request
- **WHEN** `HTTP_TIMEOUT_SECONDS` is 30 and the service issues any Paperless-ngx
  REST call
- **THEN** that call is subject to a 30-second timeout

### Requirement: Leveled logging

The system SHALL emit leveled log output to stdout with levels `debug`, `info`,
`warn`, and `error`, filtered by `LOG_LEVEL`. Each line SHALL include a timestamp,
the level, and (when relevant) the document id.

#### Scenario: Debug level suppressed below configured level
- **WHEN** `LOG_LEVEL` is `info`
- **THEN** messages at `debug` are not emitted, while `info`, `warn`, and `error`
  are
