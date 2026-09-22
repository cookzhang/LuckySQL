# Responsiveness verification

## Workloads and evidence (2026-09-22)

Run the optimized configuration; debug timing is not representative:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
LUCKYSQL_TEST_PORT=3306 LUCKYSQL_TEST_PASSWORD=<local-test-password> \
swift test -c release
```

The local optimized suite contains 64 tests (one unrelated opt-in release-download test is skipped). Coverage includes MySQL protocol/cancellation integration, 600 deterministic Unicode/quote/comment edits, native marked-text commit, coalesced replacement ranges, combining-mark cell bounds, cache expiry/eviction, seek-page SQL (including UInt64 precision), stale prefetch rejection, connection-endpoint snapshots, Keychain UI-policy restoration, and successful connection despite credential-store failure.

Final runs against both **MySQL 5.6.51** and **MySQL 8.4.11** completed with **63 passed, 1 skipped, 0 failures** each. The temporary 8.4 test container used tmpfs; the existing 5.6 volume was preserved. The local preview bundle is `dist/smoothness-preview-final/LuckySQL.app` (0.3.1-dev), not a published GitHub release.

For a 2,025,000-byte SQL document, one-character edits with native edit hints took **19.7 ms at the head, 10.8 ms in the middle, and 4.2 ms at the tail** in one optimized local run. They lexed 7 / 10 / 4 UTF-16 units respectively; remaining work includes immutable array copies and suffix offset adjustment. These are background analysis timings, not input-to-screen latency, P95 values, or FPS. A separate 2,115,410-byte no-hint fallback test reported 115.3 ms full scanning versus 17.6 ms tail-edit analysis. Do not compare these different workloads as a universal speedup ratio.

The 10,001-table normalized search workload completed 50 filters in 258 ms total (~5.2 ms per filter), off-main. One hundred text/caret changes emitted zero workspace-wide publications. Repeated highlighting of an unchanged viewport performed no additional color passes.

Native optimized-app checks: launch showed an inline inaccessible-password notice without a Keychain authorization dialog; Chinese/emoji SQL, native per-tab undo, tab switching, and a 44,000-statement (~1.9 MB) paste plus head/tail edits and scrolling were exercised. Existing user drafts were preserved.

The local `Animation Hitches` capture exited with signal 11 while finalizing and could not be exported. A fallback `Time Profiler` recording completed, but it is not evidence of frame pacing. No 120 Hz or end-to-end P95 claim is made.

## Profiling and acceptance

The subsequent v0.3.1 connection-flow regression run contains 71 tests: **70 passed, 1 opt-in download test skipped, 0 failures**, against MySQL 5.6.51. The seven added tests cover draft validation/cancellation, failed-connection retries, legacy profile compatibility, deleting the last saved profile, and routing missing passwords to the connection form. Native UI checks confirmed the six-field sheet, inline invalid-port errors, cancel without creating a profile, editing existing connections, and removal of the Settings menu. The earlier 64-test MySQL 8.4 and performance measurements above remain separate historical runs.

Instruments can capture `com.cookzhang.LuckySQL` / `Responsiveness` intervals:

- `Editor change`: native edit callback and model propagation (main thread).
- `Visible highlight`: viewport coloring/layout lookup (main thread).
- `Grid reload`: result refresh and selection restoration (main thread).
- `SQL analysis`: background lexical analysis and index construction.

Targets remain: main-thread continuous-interaction work below ~5 ms, and cached tab/page switching P95 below 50 ms on the supported test machine. End-to-end frame pacing needs Instruments measurements across 60/120 Hz hardware; passing unit tests does **not** establish these targets. Exercise Chinese marked-text composition, head/middle/tail edits, fast tab switching, wide result grids, multi-MiB cells, cancellation, and repeated connection changes. Record p50/p95/p99 and process memory, not only averages.

## Deliberate limits

- Quotes/comments can change lexical state to EOF. Flat token arrays are still O(n) to shift after an insertion; viewport TextKit layout remains a possible bottleneck for giant single lines.
- Browse snapshots expire after 30 seconds; explicit refresh is required for immediate visibility of external writes. Cache bounds are estimates, not process-RSS limits.
- Seek pagination requires a single integer primary key and compatible ordering. Other types, composite keys and custom sorts use OFFSET.
- Speculative reads use at most one separate short-lived connection and are disabled after user SQL until reconnect. Server connection limits may disable prefetch without breaking ordinary browsing.
- Keychain ACLs remain intact. An inaccessible old credential is not automatically migrated, deleted, or exported; session-only passwords disappear when the process exits.
