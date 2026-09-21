# Roadmap

Current implementation and acceptance status are tracked in [HEIDISQL_PARITY.md](HEIDISQL_PARITY.md). Multiple query tabs, selection/current execution, local history, basic formatting/completion, native grid, data paging/filtering, structure previews, and current-result exports have now landed. Items below describe broader targets; partial implementations are not full parity.

## Next — Harden the MySQL workbench

- TLS modes (`required`, CA verification, client certificates)
- Connection test button, timeouts, reconnect, and clear diagnostics
- Multiple editor tabs, query selection execution, history, formatting, and completion
- Cancel running queries and warn before destructive statements
- Virtualized result grid, paging, sorting, copying, and NULL/binary rendering
- Table structure/index views and safe cell editing with primary-key detection
- Unit tests with fake sessions plus MySQL/MariaDB integration tests in CI
- Signed/notarized `.app`, Sparkle updates, and accessibility/VoiceOver pass

## Further daily database work

- SSH tunnels using system keys and Keychain-managed passphrases
- CSV/JSON/SQL import and export with streaming progress
- Saved queries, favorites, recent connections, and workspace restoration
- Transaction mode, explain plans, server process list, and session variables
- PostgreSQL adapter using the existing driver/session boundary

## Future — MCP and Agent

- Local MCP server that reuses configured connections without exposing passwords
- Read-only-by-default tools for metadata, query, explain, and analysis
- Per-connection allowlists, row limits, audit log, and mutation approvals
- Schema-aware SQL assistant with query validation and explain-before-run

## Later

- Additional engines such as SQLite, ClickHouse, and Redis through capability-based adapters
- Schema diff/migration tools
- Team-safe profile export with secrets excluded
- Plugin API for result visualizers and custom database capabilities
