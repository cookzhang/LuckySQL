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

`AppModel` owns the current profile, session, schema tree, editor text, and query result. All published changes happen on the main actor. Views remain declarative and do not import MySQLNIO.

### Domain

Domain models are deliberately engine-neutral. `QueryResult` is a display-oriented snapshot. `SQLIdentifier.quote` is the only place where dynamically selected MySQL identifiers are interpolated; user-authored editor SQL is sent unchanged.

### Database port

`DatabaseDriver` creates a `DatabaseSession`. A session exposes query execution and metadata discovery. A future `PostgresDriver` can implement the same protocols while translating PostgreSQL rows into `QueryResult`. Engine-specific schema concepts can later move into a richer metadata capability protocol without affecting connection storage or the editor.

### MySQL adapter

`MySQLDriver` owns a single SwiftNIO event-loop group. `MySQLSession` owns the active connection, converts result values to strings for the grid, and implements MySQL metadata queries. MySQLNIO is pure Swift and asynchronous, so UI work never blocks on socket I/O.

### Persistence and secrets

Connection profile metadata is Codable and stored in `UserDefaults`. Passwords are keyed by profile UUID and stored separately through the Security framework in Keychain. `PasswordStoring` allows an in-memory fake in tests.

## Extension seams

- **PostgreSQL:** add `PostgresDriver`/`PostgresSession`, then add an engine discriminator and driver registry.
- **SSH:** establish a local forwarded endpoint before creating a database session. Keep the tunnel handle beside the session and close both together.
- **Import/export:** stream rows through new cursor/command protocols instead of materializing `QueryResult`.
- **MCP/Agent:** expose a capability-restricted service above `DatabaseSession`. Default agent execution should be read-only, with explicit approval for mutations.
- **Large results:** add async row streaming, backpressure, pagination, cancellation, and virtualized AppKit grid rendering.

## Concurrency and lifecycle

UI state is main-actor isolated. MySQLNIO performs network work on its event loop. The active session is closed before replacement and on explicit disconnect. A production connection manager should additionally own idle timeout, reconnect policy, cancellation, and app-termination cleanup.
