# Architecture

LuckySQL follows a small ports-and-adapters design. SwiftUI depends on application/domain types, while database-specific networking stays behind `DatabaseDriver` and `DatabaseSession`.

```text
SwiftUI Views
     │
  AppModel                 @MainActor UI orchestration
     │
DatabaseDriver/Session     engine-neutral async boundary
     │
 MySQLDriver               MySQLNIO adapter and row conversion
```

## Layers

### App and views

`AppModel` owns the current profile, session, schema tree, editor text, and query result. All published changes happen on the main actor. `EditorSessions` retains each tab's native scroll view/text view and private undo manager across SwiftUI view replacement. `SQLAnalysisService` scans on its actor, reuses unchanged token prefixes, caches line offsets and shares analysis with statement-scoped completion. Highlight application touches only the viewport. Views do not import MySQLNIO.

### Domain

Domain models are deliberately engine-neutral. `QueryResult` is a display-oriented snapshot with explicit null locations, truncation and retained-payload accounting. Dynamically selected identifiers/literals are quoted centrally. SQL drafts are unchanged; `SQLPreview` may add/tighten SELECT preview limits before execution.

### Database port

`DatabaseDriver` creates a `DatabaseSession`. A session exposes query execution and metadata discovery. A future `PostgresDriver` can implement the same protocols while translating PostgreSQL rows into `QueryResult`. Engine-specific schema concepts can later move into a richer metadata capability protocol without affecting connection storage or the editor.

### MySQL adapter

`MySQLDriver` owns a single SwiftNIO event-loop group. `MySQLSession` owns the active connection, converts result values to strings for the grid, and implements MySQL metadata queries. `MySQLCommandQueue` serializes SQL and metadata. Cancellation opens a same-account control connection and sends `KILL QUERY` for the original server connection ID. The active command retains ownership until cancellation finishes, preventing a delayed KILL from reaching the next command. Failure to cancel does not force-close the user's connection. MySQLNIO performs socket I/O asynchronously.

### Persistence and secrets

Connection profile metadata is Codable and stored in `UserDefaults`. Passwords are keyed by profile UUID and stored separately through the Security framework in Keychain. `PasswordStoring` allows an in-memory fake in tests.

Draft/history JSON serialization uses an ordered background queue with an explicit termination flush. SQL file reads/writes, formatting and result-file encoding/writes run off the main actor with immutable snapshots. Tab IDs guard asynchronous saves against tab switches. Column metadata in-flight requests are coalesced; explicit refresh and successful writes invalidate cached snapshots.

## Extension seams

- **PostgreSQL:** add `PostgresDriver`/`PostgresSession`, then add an engine discriminator and driver registry.
- **SSH:** establish a local forwarded endpoint before creating a database session. Keep the tunnel handle beside the session and close both together.
- **Import/export:** stream rows through new cursor/command protocols instead of materializing `QueryResult`.
- **MCP/Agent:** expose a capability-restricted service above `DatabaseSession`. Default agent execution should be read-only, with explicit approval for mutations.
- **Large results:** the AppKit grid virtualizes rows; the decoder retains a contiguous 1,000-row / 16 MiB prefix and drains the rest. A 64 MiB workspace preview budget evicts older query results without touching drafts. Future full exports should stream rows with backpressure instead of lifting these guards.

## Concurrency and lifecycle

UI state is main-actor isolated. MySQLNIO performs network work on its event loop. The active session is closed before replacement and on explicit disconnect. A production connection manager should additionally own idle timeout, reconnect policy, cancellation, and app-termination cleanup.
