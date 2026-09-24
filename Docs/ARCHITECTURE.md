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

Connection creation/editing is a sheet owned by the workspace, not an application Settings scene. `ConnectionDraft` isolates unsaved changes and validates the host/port/user before persisting. Cancel leaves saved profiles untouched; connection failures stay inline for retry. The default fields remain host, port, user, password, optional database and optional name; collapsed Advanced adds read-only, TLS, SSH and deadlines. Legacy environment tags are ignored on decode and are no longer displayed or written. Existing read-only flags remain effective. Saved connections expose edit/delete actions directly in the sidebar, and deleting the last profile no longer recreates a phantom connection.

`ConnectionWorkspaces` owns one `AppModel` per independent connection, with per-profile draft namespaces. Each `AppModel` owns its profile, session, schema tree, and query results. Each tab's `QueryDocument` publishes text/line/dirty state only to its editor and labels; caret changes do not publish view updates. All UI mutations happen on the main actor. `EditorSessions` retains native text views and private undo managers across view replacement. `SQLAnalysisService` consumes coalesced UTF-16 edit ranges, restarts before the edit and stops lexing when an unchanged token boundary matches. It reuses the remaining suffix and incrementally updates line offsets. External replacements fall back to a prefix/suffix diff. Unterminated quotes/comments may legitimately require scanning to EOF. Flat token arrays still require copying/offset adjustment; this is not a constant-time parser. Analysis cache is limited to eight documents and an estimated 96 MiB (one active snapshot is retained).

Highlighting coalesces scroll notifications and only colors previously uncovered viewport ranges, with a 300-point look-ahead. Grid selection keys are computed only when results change; empty selections skip all-row key generation. Visible cell text is cached with a 2,048-cell bound. Keyboard/context-menu TSV encoding runs off-main and checks pasteboard generation before publishing. Table search normalizes/indexes metadata off-main, then debounces and filters immutable snapshots; late results are discarded. Views do not import MySQLNIO.

### Domain

Domain models are deliberately engine-neutral. `QueryResult` is a display-oriented snapshot with explicit null locations, truncation and retained-payload accounting. Dynamically selected identifiers/literals are quoted centrally. SQL drafts are unchanged; `SQLPreview` may add/tighten SELECT preview limits before execution.

### Database port

`DatabaseDriver` creates a `DatabaseSession`. A session exposes query execution and metadata discovery. A future `PostgresDriver` can implement the same protocols while translating PostgreSQL rows into `QueryResult`. Engine-specific schema concepts can later move into a richer metadata capability protocol without affecting connection storage or the editor.

### MySQL adapter

`MySQLDriver` owns a single SwiftNIO event-loop group. `MySQLSession` owns the active connection, converts result values to strings for the grid, and implements MySQL metadata queries. `MySQLCommandQueue` serializes SQL and metadata. Cancellation opens a same-account control connection and sends `KILL QUERY` for the original server connection ID. The active command retains ownership until cancellation finishes, preventing a delayed KILL from reaching the next command. Failure to cancel does not force-close the user's connection. MySQLNIO performs socket I/O asynchronously.

### Persistence and secrets

Connection profile metadata is Codable and stored in `UserDefaults`. Passwords are keyed by profile UUID and stored separately through the Security framework in Keychain. `PasswordStoring` allows an in-memory fake in tests.

All legacy file-based Keychain operations run synchronously inside a serialized no-interaction scope, restoring the prior policy afterwards. This deliberately uses the deprecated macOS `SecKeychain` interaction API because `LAContext` is not a replacement for existing file-based ACLs. No ACL is broadened and no item is deleted to bypass trust. If access requires authorization, the app shows a nonmodal message and lets the user enter the password. On save, RecoveringPasswordStore checks readability first: an inaccessible signing identity rotates to a fresh random record, verifies a read, then stores only that record UUID in defaults. The old ACL is never weakened. Successful connections survive secure-storage failures; that password is then kept only in process memory. Ad-hoc builds do not have a stable Developer ID identity, so silent access to a prior build's password cannot be promised. Stable signing is needed for a seamless cross-update persistence story.

Draft/history JSON serialization uses an ordered background queue with an explicit termination flush. SQL file reads/writes, formatting and result-file encoding/writes run off the main actor with immutable snapshots. Tab IDs guard asynchronous saves against tab switches. Column metadata in-flight requests are coalesced; explicit refresh and successful writes invalidate cached snapshots.

### Browse previews

`BrowsePageCache` is connection-scoped, capped at eight pages / 16 MiB estimated data plus container overhead, and expires entries after 30 seconds. Explicit refresh/filter changes, mutation attempts, arbitrary SQL and connection changes invalidate it. Sequential pages use stable composite keyset predicates (including custom ordering and NULL handling) when a compatible prior snapshot exists; missing/expired cursors retain OFFSET. Numeric values preserve server precision and strings use server collation. Previous pages can reuse cached snapshots. A cached preview is not a live database view; use Refresh to observe external writes immediately.

After an idle delay, one generated next-page SELECT may use a separate reusable idle connection. It never borrows the foreground transaction connection, changes busy/error UI, or delays execution in its queue. Cancellation closes the speculative connection; epoch/generation guards reject stale results. Prefetch is disabled after any user SQL until reconnect, because arbitrary SQL can change transaction/session/temporary-table semantics. Drivers may decline speculative connections. Foreground metadata remains serialized on the original connection; background metadata discovery yields before scheduling further work when a query starts.

## Extension seams

- **PostgreSQL:** add `PostgresDriver`/`PostgresSession`, then add an engine discriminator and driver registry.
- **SSH/TLS:** system OpenSSH establishes a strictly verified local forwarding endpoint; each session owns its tunnel. NIOSSL validates the chain and a separate macOS SSL identity policy enforces the requested hostname.
- **Import/export:** a serial row consumer writes bounded chunks to disk without retaining result arrays. CSV imports batch up to 100 rows / about 1 MiB / 60,000 bound parameters inside one InnoDB transaction. SQLScriptReader scans bounded chunks and honors DELIMITER and SQL_MODE transitions.
- **MCP/Agent:** expose a capability-restricted service above `DatabaseSession`. Default agent execution should be read-only, with explicit approval for mutations.
- **Large results:** the AppKit grid virtualizes rows; the decoder retains a contiguous 1,000-row / 16 MiB prefix and drains the rest. A 64 MiB workspace preview budget evicts older query results without touching drafts. Full exports stream separately with disk backpressure; these preview guards remain.

## Concurrency and lifecycle

UI state is main-actor isolated. MySQLNIO performs network work on its event loop. The active session is closed before replacement and on explicit disconnect. A production connection manager should additionally own idle timeout, reconnect policy, cancellation, and app-termination cleanup.
