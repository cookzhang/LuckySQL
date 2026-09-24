# LuckySQL

LuckySQL is a free, open-source, native macOS MySQL workbench built with Swift and SwiftUI. It is designed for Apple Silicon, with separate SQL, Data, and Structure workspaces.

## Workbench features

- Independent connection workspaces, each with its own SQL tabs, session, transactions, results and cancellation; reusable saved profiles
- Passwords stored in macOS Keychain when silently accessible; no Keychain authorization popups. If storage is unavailable, re-enter the password for the current session only; passwords are never written to UserDefaults
- Pure-Swift MySQL connection through MySQLNIO; no `libmysqlclient` installation
- Database/schema/table navigation tree with column types, nullability, and primary-key details
- Color-coded SQL editor with line numbers, native find, automatic keyword/schema/table/alias-column suggestions (**Control–Space** or **Option–Escape** opens suggestions; **Tab/Return** accepts, **Escape** dismisses), and basic formatting
- Multiple auto-saved query drafts; **Command–Return** runs the selection/current statement, **Shift–Command–Return** runs all statements
- Local query history, SQL files, snippets, EXPLAIN, and server information shortcuts
- Native virtualized result grid with resizable columns, keyboard selection, copying, and full cell previews
- Table-data workspace with server-side filters, sorting, and 100/200/500-row pagination, without replacing SQL drafts
- Structure workspace with columns, indexes, foreign keys, comments, and syntax-colored CREATE SQL
- Optimistic primary-key cell editing and staged typed updates, new rows, TSV paste and reviewed InnoDB batch commits; conflicts roll back the batch
- Separate preview export and streaming full/filtered table CSV/JSON/SQL data export; mapped CSV import and large UTF-8 SQL scripts with DELIMITER
- SQL write confirmation, multi-result selection, preview row limits, and stop/disconnect
- In-app GitHub release checks, SHA-256-verified downloads, confirmed installation with a retained backup, and restart
- Background edit-range SQL analysis with token-boundary convergence, incremental line numbers, scroll-range coloring reuse, and per-document state isolation
- Bounded 30-second page cache, composite/nullable seek pagination with safe OFFSET fallback, and reusable isolated next-page prefetch; Refresh fetches current server data
- Independent per-tab undo/caret/scroll, dirty markers, rename/close/switch shortcuts, and remembered split/column layouts
- **Command–P** finds tables across all visible databases, including collapsed schemas; recently visited tables appear first
- **Command–Period** cancels the current SQL through a separate control connection without disconnecting; elapsed time and previous results remain visible
- Six-field connection form with collapsible read-only, verified TLS, client-certificate, SSH and timeout options; no separate Settings window or environment tags
- Clear driver/session boundary for future database engines

## Requirements

- macOS 14 or newer
- Xcode 16 or newer (Swift 5.10+ package compatibility)
- MySQL 5.6/5.7/8.x or a compatible MariaDB server (tested with MariaDB 11.4)

Apple Silicon is the primary target. The code has no architecture-specific assumptions and may also build on Intel Macs.

## Download

Prebuilt Apple Silicon packages are available from [GitHub Releases](https://github.com/cookzhang/LuckySQL/releases). The current community build uses an ad-hoc signature and is not notarized by Apple. After downloading, right-click **LuckySQL.app**, choose **Open**, and confirm the first launch if macOS displays a security prompt.

In builds containing the updater, choose **LuckySQL → Check for Updates…**. Stable releases are compared numerically; a newer compatible arm64 archive is downloaded only on request. Before installation, LuckySQL checks the SHA-256 digest supplied by GitHub's HTTPS API, archive paths, app identity/version, minimum macOS version, architecture, and code-signature integrity. This is not an independent publisher signature or Apple notarization. The GitHub repository remains the trust source.

Installation needs a writable, non-translocated app location (move the app to Applications first). It saves drafts and retains a uniquely named previous-app backup beside the installation; installation and restart are disabled during database operations. No administrator password is requested. Network/checksum/validation failures leave the existing app untouched. A verified download can also be revealed for manual installation. Old versions without this menu require one manual upgrade before they can update in-app.

## Build and run

1. Clone the repository.
2. Open `Package.swift` in Xcode.
3. Select the `LuckySQL` executable scheme and **My Mac** destination.
4. Build and run.
5. Click **Add Connection…** in the sidebar (or **⇧⌘N**), enter host/port/user/password, and choose **Connect**. Name and database are optional. The pencil beside a saved connection edits it; its context menu provides deletion.

From Terminal with a full Xcode selected:

```sh
swift build
swift test
swift run LuckySQL
```

MySQLNIO 1.8.0 is vendored with narrowly scoped TLS/lifecycle changes documented in [LOCAL_CHANGES](Vendor/mysql-nio/LOCAL_CHANGES.md). Swift Package Manager fetches SwiftNIO dependencies. NIOSSL is pinned to 2.34.1 because strict identity verification uses its additional-verification callback.

LuckySQL uses its own text-result decoder through MySQLNIO's public command API.
It supports the metadata EOF packet sent by MySQL 5.6 and early 5.7, as well as
the modern result format negotiated by newer servers. This applies to queries,
database/table lists, and column metadata. The vendored transport version check reflects the tested MySQL 5.6 baseline.
LuckySQL verifies a query before reporting a connection as successful.
Connections explicitly set `utf8mb4_general_ci`, since MySQLNIO's handshake
collation belongs to MySQL 8 and can fall back to a non-UTF-8 charset on older
servers. Integration tests check both Unicode/emoji roundtrips and stored HEX
bytes, so a broken client encoding cannot accidentally pass a roundtrip test.
Live integration tests have passed on MySQL 5.6.51, 5.7.44, and 8.4.11
(including the default `caching_sha2_password` authentication on 8.4).

To run the optional integration test against a local test server, set
`LUCKYSQL_TEST_PORT`, `LUCKYSQL_TEST_PASSWORD`, and optionally `LUCKYSQL_TEST_USER`
(defaults to `luckysql`), then run `swift test`. The account needs access to a
`luckysql` database. The test creates and removes a uniquely named test table;
it verifies metadata, empty results, Unicode/NULL values, writes, and sequential
queries after a server error.

The integration test also verifies the 1,000-row server-side limit, smaller explicit limits, and offsets. Set `LUCKYSQL_TEST_UPDATE_DOWNLOAD=1` to additionally download and validate the actual latest GitHub package (without installing it). Installer tests use disposable signed app fixtures and verify that the previous app is retained.

To create a distributable Apple Silicon app bundle locally:

```sh
./scripts/package-release.sh 0.4.0
```

The archive and its SHA-256 checksum are written to `dist/`.

Enable TLS in Advanced for remote connections. TLS verifies the trust chain and requested server identity and never silently downgrades. SSH uses system OpenSSH, strict known-host verification, an agent/identity file or a Keychain-stored secret. Query deadlines close the session; transaction state is lost and writes are never automatically replayed.

## Project layout

```text
Sources/LuckySQL/
├── App/              app entry point and observable application state
├── Database/         database-neutral protocols and MySQL adapter
├── Domain/           profiles, schema/table, results, safe identifiers
├── Infrastructure/   Keychain and profile persistence
└── Views/            SwiftUI navigation, editor, settings and result grid
```

See [Architecture](Docs/ARCHITECTURE.md) and [Roadmap](Docs/ROADMAP.md) for design decisions and planned work.

See [Responsiveness verification](Docs/PERFORMANCE.md) for workloads, measured analysis costs, profiling intervals, and limits. Ad-hoc signatures can prevent a new build from silently reading an old build's Keychain item; LuckySQL asks for re-entry inside connection settings instead of opening an OS authorization dialog. It does not weaken Keychain permissions to avoid this.

See the detailed [HeidiSQL comparison and acceptance checklist](Docs/HEIDISQL_PARITY.md) for implemented capabilities and remaining gaps. Feature parity is not complete.

## Current limits

- Query tabs within one connection workspace share its transaction and temporary tables. Other connection workspaces and migration/batch sessions are independent.
- Preview results retain at most 1,000 rows and 16 MiB per result, with a 64 MiB workspace retained-payload budget. These are not process-RSS or network caps. Full transfer is a separate streaming path; memory still depends on the largest protocol row/field.
- Table browsing selects requested columns plus keys, summarizing large fields. Full-value fetch requires a stable primary key and is capped at 16 MiB. Summaries never become write values.
- Direct edits require usable nonbinary keys. Staged binary edits use raw bytes/hex. Generated columns, stale/truncated snapshots and missing keys remain protected. Batches require InnoDB; unknown COMMIT outcomes require verification before retrying. Pending changes remain in memory on disconnect and are bound to the original connection profile. Closing a workspace or quitting asks before discarding staged changes; grid changes are not persisted across process termination.
- SQL export contains data INSERT statements, not a complete schema/server backup. JSON preserves columns plus positional rows; binary cells are 0x-prefixed hex strings. CSV uses unquoted \N for SQL NULL, quoted text for literal \N, and hex for binary data.
- CSV import supports UTF-8/Latin-1, comma/tab/semicolon, multiline quoted fields and field mapping. The entire import uses one InnoDB transaction. SQL scripts follow explicit transaction commands; earlier committed statements and DDL remain after failure. Never blindly replay a partially executed script.
- The editor opens files up to 2 MB and executes up to 100 statements per batch. Data Transfer executes larger UTF-8 scripts incrementally, with a 16 MiB per-statement bound and DELIMITER support.
- Completion resolves CTE/derived outputs and nested aliases, but is a tolerant completion parser, not a complete SQL grammar/type checker. Formatting conservatively leaves ambiguous SQL-mode literals unchanged.
- Schema changes show generated SQL and original definitions. MySQL DDL is not promised to roll back; routine replacement can drop the old object before a failed CREATE. Generated-column expressions use the SQL definition editor.
- Cancellation uses a same-account control connection and a command barrier. The server may reject/delay it; Stop & Disconnect is a fallback. Earlier committed writes are not rolled back.
- Drafts and the last 100 history entries stay on the local machine and may contain sensitive values. User SQL executes with all privileges of the server account. Client read-only protection is **not a database permission sandbox**.

The primary form deliberately keeps host, port, user, password, database and name. Advanced exposes read-only protection for new and existing profiles and preserves legacy read-only flags. Connection identity is name plus host/port/database; legacy environment tags remain removed.

Language follows macOS app language preferences. There is no in-app language switch. A previously saved `AppleLanguages` override continues to be honored by macOS; change LuckySQL under System Settings → General → Language & Region → Applications to choose a language. English and Simplified Chinese resources are bundled; newly added advanced workflows currently use English labels where translations are unavailable.

## Daily-work shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘T / ⌘W | New / close query tab (unsaved drafts require confirmation) |
| ⇧⌘[ / ⇧⌘] | Previous / next query tab |
| ⌘P | Find table across visible databases |
| ⌘. | Cancel current SQL, browse or metadata operation |
| ⌘1 / ⌘2 / ⌘3 | SQL / Data / Structure workspace |
| ← / → in a result grid | Move the active cell column |
| ⌘C / ⇧⌘C in a result grid | Copy cell / selected rows in displayed column order |
| Return / Space in a result grid | Preview full cell value |

Column metadata requests are coalesced and cached, and structure views reuse their last snapshot. Refresh explicitly reloads metadata; successful write statements invalidate caches. Refresh after external schema changes. Read-only protection is a conservative client guard, **not a database permission sandbox**; use a read-only server account for enforcement. Generated columns and incomplete previews remain protected; the typed batch editor uses raw binary values.

The packaged application includes Chinese localization resources. `swift run` uses the unbundled executable and is intended for development; use the packaging script to verify localized UI.

## License

MIT. See [LICENSE](LICENSE).
