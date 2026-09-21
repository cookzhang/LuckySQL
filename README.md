# LuckySQL

LuckySQL is a free, open-source, native macOS MySQL workbench built with Swift and SwiftUI. It is designed for Apple Silicon, with separate SQL, Data, and Structure workspaces.

## Workbench features

- Multiple connection profiles (`host`, `port`, `user`, `password`, default database)
- Passwords stored in macOS Keychain; non-secret profile fields stored in UserDefaults
- Pure-Swift MySQL connection through MySQLNIO; no `libmysqlclient` installation
- Database/schema/table navigation tree with column types, nullability, and primary-key details
- Color-coded SQL editor with line numbers, native find, automatic keyword/schema/table/alias-column suggestions (**Control–Space** or **Option–Escape** opens suggestions; **Tab/Return** accepts, **Escape** dismisses), and basic formatting
- Multiple auto-saved query drafts; **Command–Return** runs the selection/current statement, **Shift–Command–Return** runs all statements
- Local query history, SQL files, snippets, EXPLAIN, and server information shortcuts
- Native virtualized result grid with resizable columns, keyboard selection, copying, and full cell previews
- Table-data workspace with server-side filters, sorting, and 100/200/500-row pagination, without replacing SQL drafts
- Structure workspace with columns, indexes, foreign keys, comments, and syntax-colored CREATE SQL
- Primary-key-based cell editing, explicit NULL values, confirmed row deletion, and INSERT SQL drafts
- CSV/JSON export of the current result/page, TSV copying, favorites, and loaded-table search
- SQL write confirmation, multi-result selection, preview row limits, and stop/disconnect
- In-app GitHub release checks, SHA-256-verified downloads, confirmed installation with a retained backup, and restart
- Clear driver/session boundary for future database engines

## Requirements

- macOS 14 or newer
- Xcode 16 or newer (Swift 5.10+ package compatibility)
- MySQL 5.6+/8+/9 or a compatible MariaDB server

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
5. Open **LuckySQL → Settings**, add connection details, and choose **Save & Connect**.

From Terminal with a full Xcode selected:

```sh
swift build
swift test
swift run LuckySQL
```

Swift Package Manager fetches MySQLNIO and its SwiftNIO dependencies automatically. Version `1.8.0` is intentionally pinned: it supports Swift 5.10 and modern MySQL `caching_sha2_password` authentication.

LuckySQL uses its own text-result decoder through MySQLNIO's public command API.
It supports the metadata EOF packet sent by MySQL 5.6 and early 5.7, as well as
the modern result format negotiated by newer servers. This applies to queries,
database/table lists, and column metadata. The upstream library still logs its
5.7 minimum-version warning on 5.6; that warning does not reject the connection.
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
./scripts/package-release.sh 0.2.1
```

The archive and its SHA-256 checksum are written to `dist/`.

> Security note: the MVP currently uses a direct non-TLS MySQL connection. Use it with localhost or a trusted private network. TLS configuration and SSH tunnelling are high-priority roadmap items.

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

See the detailed [HeidiSQL comparison and acceptance checklist](Docs/HEIDISQL_PARITY.md) for implemented capabilities and remaining gaps. Feature parity is not complete.

## Current limits

- One active connection; multiple query tabs share it
- Direct, non-TLS TCP only
- SQL results retain at most 1,000 rows. SELECT/CTE/UNION previews add or cap the outer LIMIT, preserve smaller limits and offsets, and leave SQL drafts and write statements unchanged. SHOW/other non-SELECT results have a client-side cap; remaining packets are drained. Exports contain only retained rows/current page
- Completion uses the current database and referenced tables, loading metadata without requiring a table click; it is not a full SQL scope/type resolver (nested alias shadowing and CTE-derived columns remain unsupported)
- No streaming full-database import/export or visual schema designer yet
- Stop closes the connection, not a server-side KILL QUERY; writes already sent can still complete
- No transaction editing / concurrent-change detection; use a least-privilege account
- Binary and generated columns are preview-only; tables with binary primary keys cannot be edited through the grid
- No DELIMITER/routine scripts; at most 100 statements per batch, SQL files up to 2 MB
- CSV uses display strings; JSON's columns + rows form distinguishes SQL NULL from the text "NULL"
- Query history (100 entries) and drafts are local and may contain sensitive SQL values; history can be cleared in the UI
- SQL statements entered by the user execute with the connected account's full privileges

## License

MIT. See [LICENSE](LICENSE).
