# Native packaged UI acceptance — 2026-09-24

These observations used actual packaged applications and computer-use accessibility
and window screenshots, not `cacheDisplay` renderings. All database operations
used the isolated `Acceptance fixture` on loopback port 53887. No production
profile was connected or changed.

## Observed checks

- Unified window toolbar displays SQL / Data / Structure with text and icons;
  connection tabs occupy the detail pane, and the sidebar is continuous. Fixed
  label sizing prevents mode text collapsing after table/workspace changes.
- Two connection workspaces retain independent SQL drafts. Returning to the
  fixture restores the existing draft and connection; registry restoration keeps
  both workspaces across restart.
- The packaged build recovered its synthetic Keychain password after its build
  identity changed. Two subsequent normal quit/relaunch/connect cycles required
  no password input. SQL font 13→14 survived view changes and both restarts, then
  was restored to 13. Later changes only affected navigation/export UI and the
  explicit value-rejection path.
- Cmd1/2/3 switches modes; selecting a table retains the current mode. Actual
  screenshots show the current qualified table beside the mode buttons.
- Text summaries disable Copy Full Value before loading. Loading `note` preserves
  line breaks. Loading `payload` shows `00FF1020`, identified as four raw bytes,
  and then enables complete copying.
- Horizontal grid scrolling reveals the rightmost timestamp column with matching
  headers and values. Native performance/geometry tests separately cover wide
  grids and viewport allocation.
- Multiline Chinese/emoji input converts to UTF-8 hex and stages locally. Quit
  defaults to Keep Working; workspace close separately asks about staged changes.
  Cancelling both retained the draft, then Discard All removed the test draft.
  The staged test was never committed to the server.
- Schema designer shows columns and SQL preview. Submitting deliberately invalid
  DDL returns a persistent server error and retains the complete SQL draft.
- CSV preview automatically maps `id/name/note/payload`, displays Chinese/emoji,
  multiline text and binary hex. This fixture was previewed, not imported.
- Export selection places the current database first, visibly checks the selected
  table, reports the selected count and exposes a table filter.
- Option-Escape displays the completion list and keyboard guidance. A bound text
  parameter `参数😀` returns exactly that value. A failed SELECT retains its SQL
  and error after the alert closes; a corrected SELECT clears the failure.
- Advanced connection options display TLS, SSH, timeout and read-only controls.
- The update dialog completes its check and reports installed candidate 0.4.0 as
  up to date, with the official release link.

## Findings from manual testing

A too-long value was retained in the cell editor after MySQL rejected it, but Save
was disabled as if the write outcome were unknown. The follow-up fix distinguishes
specific received value/constraint errors from transport failures, retaining the
original optimistic predicate for a corrected manual retry. Live database tests
cover rejection, unchanged server value, correction and successful retry; a
separate regression keeps unknown transport outcomes blocked. The new packaged
error-path smoke check remains pending because the Mac locked again.

CI initially used Xcode 16.2 / Swift 6.0.3, while resolved SwiftASN1 1.7.3 requires
Swift 6.1. Both CI and release now select macOS 15 / Xcode 16.4. This does not raise
the application deployment target above macOS 14.

## Remaining visual boundary

The official v0.3.2 binary was launched with an isolated QA bundle identifier and
synthetic connection. Its actual default-size screenshot was inspected. The new
UI was inspected at the available large window size, including a saved frame of
1283×859. These are not identical-size before/after evidence.

Computer-use resize attempts returned `noWindowsAvailable` or
`windowNotFoundAtPosition`; manual resize to approximately 960×640 was requested.
The Mac subsequently locked again. Exact-size 1280×800 and 960×640 component
geometry passes independently, but includes no native title toolbar and cannot
replace final full-window interaction/screenshots. No release is authorized by
this incomplete visual sign-off alone.
