# Issues #13–#30: implementation and acceptance

Updated 2026-09-24. The user requires one release after all functionality and
acceptance are complete. **Release remains pending; no version tag has been pushed.**

Automated acceptance is complete below. The Mac has been unlocked and most
packaged UI acceptance has now passed. User feedback required another layout
revision: the sidebar now spans the workspace, connection tabs live only in the
detail pane, and SQL/Data/Structure are unified with the native title toolbar.
The latest validated candidate is `/tmp/luckysql-validated-candidate/LuckySQL.app`.

Exact-size native before/after screenshots remain incomplete: computer-use
window dragging returned `noWindowsAvailable` / `windowNotFoundAtPosition`.
The user has been asked to resize the window; the Mac subsequently locked again. Actual native screenshots at the
available sizes were inspected; they are not an equal-size comparison. Do not
close all issues or publish before the remaining checks finish.

| Issue | Implementation and evidence | Remaining |
| --- | --- | --- |
| #13 | Canonical Releases fallback for API 403/429, mandatory SHA-256, stage errors; mocked HTTP cases and real release download/verification passed | Update dialog passed (0.4.0 up to date); verify published assets after release |
| #14 | Compact chrome/22 pt rows, persistent SQL font; fixed content-size native geometry checks | Exact-size before/after native screenshots remain; 13→14, view switching and two restarts persisted; restored 13 |
| #15 | Writes invalidate snapshots, stale/error notices, refresh on return; UPDATE/INSERT/DELETE regressions and live DDL paths passed | Packaged Cmd1/2/3, table context and SQL draft preservation passed |
| #16 | Operation identity, browse/metadata cancel, command barrier and generation guards; live cancellation/reuse passed | Packaged navigation smoke check passed |
| #17 | Original-value BINARY null-safe predicates, affected rows, no-op/unknown outcomes; live conflict and batch rollback, Unicode byte distinctions passed | Native field-too-long failure retained input; follow-up enables corrected retry for explicit value rejection. Four-engine live regression passed; new packaged smoke check remains |
| #18 | Column projection, bounded summaries, raw bytes, lazy full value, paged text preview; 20 × 3 MiB native/transport/RSS benchmark passed | Native text and binary full-value loading, byte count, and summary-copy protection passed |
| #19 | Strict TLS/CA/name/client certificate, SSH key/passphrase/host identity, DNS/TCP/handshake/query deadlines | TLS positives/negatives, SSH positives/negatives, DNS/refused endpoint/auth retry/handshake timeout all passed |
| #20 | Independent sessions/cancel/cache/drafts; registry restoration; live parallel query, cancel A while B continues, disconnect isolation passed on four engines | Two workspace tabs, independent drafts and registry restoration passed |
| #21 | Typed/NULL edits, new rows, TSV validation/staging, reviewed InnoDB transactions; native commit and live conflict/rollback passed | Multiline→UTF-8 hex staging, Keep Working, close-workspace confirmation and discard passed without committing |
| #22 | Field/index/FK SQL differences and object management; columns/index/FK/view/procedure/function/trigger/event workflows passed on four engines | Packaged sheet fit and invalid-DDL error/draft retention passed |
| #23 | Streaming CSV/JSON/SQL data export, mapped transactional CSV and bounded DELIMITER scripts; >1,000 rows, >2 MB, Unicode/binary, multi-batch failure and cancellation passed | CSV Unicode/multiline/hex preview and auto-mapping passed; export list now shows current database first, checkboxes, filter and selected count |
| #24 | CTE/derived/nested scope completion, typed server-bound parameters, mode-safe formatter; unit and live UInt64 tests passed | Native completion popup and bound Chinese/emoji parameter execution passed |
| #25 | Composite/NULL seek, prefix filter, reusable idle prefetch; 30-sample 0/50/150 ms RTT distributions, EXPLAIN, cache expiry and stale-prefetch checks passed | None |
| #26 | Actual native input/highlight/drawing distributions, wide first screen, RSS, network counts; measured offscreen-column optimization | No HeidiSQL comparison or speed-equivalence claim; native tab/scroll checks passed, exact-size comparison remains |
| #27 | Advanced read-only toggle, accurate endpoint snapshot and explicit language policy; live read-only change/isolation passed | Advanced TLS/SSH/timeouts/read-only controls displayed correctly |
| #28 | Umbrella | Close only when every child is accepted |
| #29 | Nearby Run/cancel, shortcuts, preserved context, pending/applied filters and persistent errors; model/native geometry tests passed | Final native minimum-size/navigation/error matrix |
| #30 | Inaccessible Keychain record rotation, verify-before-publishing UUID, no plaintext defaults | Real separately signed recovery passed twice; packaged candidate connected without password on two restarts (subsequent changes only navigation/export UI) |

## Automated results

- MySQL 5.6.51: 118 tests, 109 passed, 9 environment/opt-in skips, 0 failures.
- MySQL 5.7.44: 118 tests, 109 passed, 9 skips, 0 failures.
- MySQL 8.4.11 with verified TLS/client certificates: 118 tests, 110 passed,
  8 skips, 0 failures.
- MariaDB 11.4: 118 tests, 109 passed, 9 skips, 0 failures.
- SSH fixture: 9 remote tests, 7 passed, 2 unrelated TLS-environment skips.
  Includes real passphrase tunnel, unknown host rejection and wrong passphrase.
- Actual update download: all 8 IssueRegressionTests passed with the opt-in enabled.
- Final optimized UI/model/transfer/live regression: 32 tests passed after unified
  navigation, explicit accessibility labels, fixed-size mode buttons and export
  selection usability changes. Exact 1280×800 / 960×640 component geometry passed.
  The four-engine matrix was rerun after the final value-rejection fix (118 tests each).
- Candidate `/tmp/luckysql-validated-candidate/LuckySQL.app` and its v0.4.0 ZIP were
  rebuilt; bundle signature and archive SHA-256 verified. This is not a release.
- Real Keychain: old identity denied (-25293), replacement saved/read, fresh
  process reads the recovered secret; no UI authorization and no ACL weakening.
- Native editor/grid: 30 samples per case, complete run passed. Wide-field native
  benchmark and fixed-size workbench geometry tests passed separately.
- Pagination/prefetch: both benchmarks passed at 0, 50 and 150 ms RTT.
- Raw evidence: `acceptance/database-matrix.json`, `acceptance/native/final`,
  `acceptance/wide`, `acceptance/pagination`, `acceptance/layout/layout.json`.

Native `cacheDisplay` snapshots omit some composited SwiftUI/header layers; these
images were removed and are not visual acceptance evidence. Geometry and actual
AppKit layout/drawing timings remain distinct from compositor/presentation timing.

## Findings resolved during acceptance

- Keychain may permit updating an old inaccessible record while still denying
  reads. Probe readability first, then verify the replacement before saving UUID.
- NIOSSL's IP SAN fallback must not override an explicit DNS name. Keep full
  chain verification and apply the macOS hostname policy afterwards.
- MySQL 5.6 can reinterpret unsigned user variables as signed. Bind large UInt64
  values via DECIMAL(20,0).
- Late DNS resolution is now bounded and its late-arriving channel is closed.
- Grid offscreen columns were still creating text views: skip their layout and
  refresh newly visible columns after scrolling/reordering.
- Full-value copying cannot copy an unloaded summary; original binary bytes stay
  hex. Large read-only values are paged without changing complete copy content.
- Disconnect retains profile-bound staged changes. Workspace close/quit asks
  before discarding; unknown COMMIT blocks replay until destination verification.
- Paste is guarded against snapshot/connection changes and concurrent staging.
- Canonically equivalent Unicode with different stored bytes remains a real edit.
- All workspaces are checked before updater installation; all drafts are flushed.

## Reproduction boundaries

Fixtures are uniquely named disposable Docker tmpfs databases. Existing
`luckysql-mysql56` and user data remain intact. The matrix explicitly configures
64 MiB max_allowed_packet because a 3 MiB value expands when SQL-exported as hex,
and permits function creation in disposable servers. No existing server settings
were changed. One earlier failure was an invalid fixture VARCHAR-to-LONGTEXT
migration with its index still present; it was corrected before the successful run.

A native run was polluted by repeated 900-second macOS Maintenance Sleep events.
Final runs used process-scoped `caffeinate -i -s`, without changing persistent power
settings. Per-sample checkpoints are retained. Long single lines still have
seconds-level TextKit cost; passing correctness tests does not imply smoothness.

Branch `codex/issue-fixes-release`, base `010ad71` (v0.3.2). Preserve user changes
in historical release notes v0.1.0/v0.1.1/v0.2.0/v0.3.0/v0.3.1. Use full Xcode for
tests. Pushing a v* tag publishes automatically; do not tag before final acceptance.

## Latest native findings and CI

Native checks and remaining visual boundaries are recorded in
[acceptance/native-ui.md](acceptance/native-ui.md). Explicit MySQL value/constraint
rejections now retain an editable snapshot for a corrected manual retry, while
transport failures and unknown outcomes remain blocked. The original optimistic
predicate still checks concurrency. This was retested on all four database engines.

The first cloud CI attempt failed before compilation because Xcode 16.2's Swift
6.0.3 could not resolve SwiftASN1's Swift 6.1 tools requirement. Both workflows
now select macOS 15 / Xcode 16.4; the rerun passed its regression-test step.
Application deployment remains macOS 14. A UI-fixture-only broad test attempt
also lacked routine-creation privileges; the complete fresh matrix uses the
documented disposable fixture configuration and passes.

Implementation is committed on `codex/issue-fixes-release`; draft PR #31 tracks
CI and final acceptance. No release tag has been pushed.
