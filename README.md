# LuckySQL

LuckySQL is a free, open-source, native macOS MySQL workbench built with Swift and SwiftUI. It is designed for Apple Silicon, with separate SQL, Data, and Structure workspaces.

## Workbench features

- Multiple connection profiles (`host`, `port`, `user`, `password`, default database)
- Passwords stored in macOS Keychain; non-secret profile fields stored in UserDefaults
- Pure-Swift MySQL connection through MySQLNIO; no `libmysqlclient` installation
- Database/schema/table navigation tree with column types, nullability, and primary-key details
- Color-coded SQL editor with line numbers, native find, completion (**Control–Space**), and basic formatting
- Multiple auto-saved query drafts; **Command–Return** runs the selection/current statement, **Shift–Command–Return** runs all statements
- Local query history, SQL files, snippets, EXPLAIN, and server information shortcuts
- Native virtualized result grid with resizable columns, keyboard selection, copying, and full cell previews
- Table-data workspace with server-side filters, sorting, and 100/200/500-row pagination, without replacing SQL drafts
- Structure workspace with columns, indexes, foreign keys, comments, and syntax-colored CREATE SQL
- Primary-key-based cell editing, explicit NULL values, confirmed row deletion, and INSERT SQL drafts
- CSV/JSON export of the current result/page, TSV copying, favorites, and loaded-table search
- SQL write confirmation, multi-result selection, preview row limits, and stop/disconnect
- Clear driver/session boundary for future database engines

## Requirements

- macOS 14 or newer
- Xcode 16 or newer (Swift 5.10+ package compatibility)
- MySQL 5.6+/8+/9 or a compatible MariaDB server

Apple Silicon is the primary target. The code has no architecture-specific assumptions and may also build on Intel Macs.

## Download

Prebuilt Apple Silicon packages are available from [GitHub Releases](https://github.com/cookzhang/LuckySQL/releases). The current community build uses an ad-hoc signature and is not notarized by Apple. After downloading, right-click **LuckySQL.app**, choose **Open**, and confirm the first launch if macOS displays a security prompt.

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

To create a distributable Apple Silicon app bundle locally:

```sh
./scripts/package-release.sh 0.2.0
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
- SQL results retain at most 10,000 rows (remaining packets are drained); exports contain only retained rows/current page
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
