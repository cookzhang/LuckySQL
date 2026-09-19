# LuckySQL

LuckySQL is a free, open-source, native macOS database client. This repository contains the first runnable MVP: a focused MySQL client built with Swift and SwiftUI, designed for Apple Silicon and structured so PostgreSQL, SSH tunnels, import/export, and MCP/Agent capabilities can be added without rewriting the UI.

## MVP features

- Multiple connection profiles (`host`, `port`, `user`, `password`, default database)
- Passwords stored in macOS Keychain; non-secret profile fields stored in UserDefaults
- Pure-Swift MySQL connection through MySQLNIO; no `libmysqlclient` installation
- Database/schema and table navigation tree
- SQL editor with **Command–Return** execution
- Horizontally and vertically scrollable result grid
- Double-click-style workflow: click a table to run a quoted `SELECT * … LIMIT 200`
- Clear driver/session boundary for future database engines

## Requirements

- macOS 14 or newer
- Xcode 15.3 or newer (Swift 5.10+)
- MySQL 5.7+/8+/9 or a compatible MariaDB server

Apple Silicon is the primary target. The code has no architecture-specific assumptions and may also build on Intel Macs.

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

## Known MVP limits

- One active connection and one editor tab
- Direct, non-TLS TCP only
- Results are buffered in memory and capped only when browsing tables
- No cancellation, query history, editing result cells, or transaction controls yet
- SQL statements entered by the user execute with the connected account's full privileges

## License

MIT. See [LICENSE](LICENSE).
