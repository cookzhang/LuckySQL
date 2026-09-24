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
- Seek pagination uses a stable sort plus primary-key tie breakers, including composite and nullable cursors. Missing prior-page identity or unsupported ordering falls back to OFFSET.
- Speculative reads reuse at most one separate idle connection and are disabled after user SQL until reconnect. Server connection limits may disable prefetch without breaking ordinary browsing.
- Keychain ACLs remain intact. After successful authentication, an inaccessible record is replaced by a newly verified Keychain record. Only its UUID is persisted; old inaccessible records are not deleted or exported.

## Native and network measurements (2026-09-24)

Automated measurements below are complete. Final packaged visual acceptance is
tracked separately in `ISSUE_COMPLETION.md`; this is not release sign-off.

`NativePerformanceTests` creates the actual SQLTextEditor/DataGrid NSViewRepresentable
in an AppKit window. It inserts at head/middle/tail, exercises marked-text composition,
flushes native layout/drawing, and measures the separate syntax-highlight completion
(including the intentional 80 ms debounce). It covers multiline and long-single-line
Unicode documents and a 1,000 × 40 no-primary-key grid with a retained selected row.
This is input-to-AppKit-drawing, **not** screen-photon/compositor latency. The marked
text sequence is a native IME lifecycle test, not a claim to test every macOS IME.
Initial 3-sample runs are diagnostic only, too small for robust P95/P99 claims.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
LUCKYSQL_NATIVE_BENCHMARK=/tmp/luckysql-native-perf \
LUCKYSQL_BENCHMARK_SAMPLES=30 \
swift test -c release --filter NativePerformanceTests
```

Initial raw measurements are retained under `acceptance/native`. They exposed
multi-second long-line painting and ~700 ms wide-grid refresh, which earlier
lexer-only measurements did not capture. Enabling noncontiguous TextKit layout
and avoiding hashing every complete result row did not materially resolve those
costs. The retained grid optimization skips offscreen columns that AppKit still requests. A final 30-sample run reduced refresh median to 95.5 ms (P95 137.2 ms, P99 142.7 ms), with row selection, horizontal scrolling and reordered-column checks passing. The 10-sample before/after diagnostic was 652.2 → 96.7 ms; differing sample counts are not a controlled tail-latency comparison. Exact UTF-16 equality also avoids canonical Unicode comparison on editor updates. Long-single-line TextKit painting remains expensive. Do not advertise smoothness
or a speed advantage on the strength of passing functional tests.

`test-pagination-performance.py` creates a 100,000-row UUID-named table with
BIGINT UNSIGNED keys above Int64.max, nullable custom sort columns and indexes.
It verifies seek/offset identity (including descending and NULL boundaries),
records EXPLAIN and 30 request-to-decoded-result samples per query. Setup uses a
direct connection; measured queries use a bounded asyncio TCP proxy adding half
of the selected 0/50/150 ms RTT to each direction without intentional bandwidth
shaping or packet loss. Transport reports count TCP payload bytes, not headers.
Repeated queries use a warm server buffer pool; the first request is retained in
the samples, but these are not cold-disk or GUI-paint timings.

```sh
# Point at a disposable test server and set its fixture password in the environment.
LUCKYSQL_TEST_PORT=3306 LUCKYSQL_TEST_USER=luckysql \
python3 scripts/test-pagination-performance.py
```

Raw query plans/distributions and transport counts are in `acceptance/pagination`.
No actual HeidiSQL performance comparison has been performed; no claim of being
faster than HeidiSQL is made. Reused prefetch, cache expiry/cancellation tests,
input/draw distributions and sampled peak RSS are now recorded. Manual final
packaged UI checks still require an unlocked desktop.


Acceptance machine: Apple M1 Pro, 16 GiB RAM, macOS 26.5; release arm64.
Database versions and fixture options are emitted by the matrix scripts. MySQL
5.6/5.7 images run as linux/amd64 under Docker emulation; 8.4/MariaDB use the
locally available images. The matrix explicitly allows 64 MiB packets for SQL
hex round-trips of multi-MiB values and function creation in disposable servers.
These fixture options do not change existing databases or production settings.

A native run was invalidated by repeated 900-second Maintenance Sleep intervals
confirmed in macOS power logs. Final native runs use process-scoped
`caffeinate -i -s`; this does not change persistent power settings. Per-sample
checkpoints prevent losing measurements if a test is interrupted. Sleep-polluted
samples are diagnostic only and are excluded from acceptance distributions.

## Final distributions

Each case has 30 samples, in milliseconds. Input ends after synchronous native
layout/drawing; highlight is recorded separately and includes the 80 ms debounce.
The >50 ms column counts measured main-thread input/draw intervals, not every
possible main-thread task in the process. This offscreen/native-hosting harness
is not a compositor, FPS, screen-photon or interactive-user latency measurement.

| Native case | P50 | P95 | P99 | >50 ms samples |
| --- | ---: | ---: | ---: | ---: |
| 2 MB multiline, head | 21.94 | 32.08 | 32.67 | 0/30 |
| Multiline, middle | 170.80 | 177.85 | 178.01 | 30/30 |
| Multiline, tail | 320.25 | 323.87 | 324.19 | 30/30 |
| 2 MB single line, head | 2293.56 | 4353.01 | 4391.17 | 30/30 |
| Single line, middle | 1602.65 | 3365.44 | 3385.82 | 30/30 |
| Single line, tail | 515.56 | 1222.23 | 1242.55 | 30/30 |
| Wide grid, no key, selected row | 88.95 | 93.38 | 98.52 | 30/30 |

The full editor/grid run peaked at 1,205,904 KiB RSS (~1.15 GiB), including editing,
undo, analysis and layout caches; this is a sampled process high-water mark, not
an allocation budget. Existing 5 ms/50 ms responsiveness targets are **not met**
for these extreme text/grid workloads. The code and raw distributions expose
that limitation instead of using lexer-only timings as evidence of smoothness.

A separate 20-row table with a 3 MiB LONGTEXT in each row measured summary-ready
P50/P95/P99 of 8.67/10.74/11.97 ms, and first native screen draw of
47.77/54.91/140.11 ms (first sample includes initialization). Summaries retained
5,550 bytes. The complete run, including full 3 MiB text/binary reads, peaked at
107,664 KiB RSS and transferred 3,326,407 server TCP payload bytes plus 9,648 client
bytes over two connections. These are aggregate run bytes, including setup and
metadata; not an individual request size. The server buffer pool was warm.

At 150 ms RTT, foreground-only next-page P50/P95/P99 was 157.20/161.05/165.13 ms.
After allowing prefetch to finish with 700 ms reading dwell, cache-hit latency
was 0.22/0.44/0.45 ms, excluding dwell and GUI painting. The enabled run reused one
extra connection; it did not eliminate server queries or network work.

Native `cacheDisplay` does not reliably capture all composited SwiftUI/header
layers. Its optional PNGs are diagnostic only, not visual sign-off. Fixed-size
component geometry is recorded in `acceptance/layout/layout.json`; final actual
application screenshots, font persistence and manual interaction checks remain
separate.
