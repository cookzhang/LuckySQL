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

## Final error-path acceptance

The final packaged candidate reproduced DATA_TOO_LONG on the synthetic name
column. It retained all 160 input characters, target row/column and the server
error, with Save still enabled. Replacing the input with
`中文😀 · native batch · retry` succeeded and displayed `Saved · 1 affected row`.
The same native editor then restored `中文😀 · native batch`, again reporting one
affected row. Unknown transport outcomes remain blocked by separate regression
tests. No production data was used.

## Fixed-window comparison and small-window checks

Both applications ran on the same Mac/display, using the same 60-line SQL draft
and 100-row result. The draft selects id/bucket/name/LEFT(note,80)/HEX(payload)/amount
from acceptance_rows, followed by numbered English/Chinese/emoji/NULL comments.
Official v0.3.2 used an isolated QA bundle identifier; its executable was unchanged.
Window dimensions were verified from each application's saved native window frame.
Actual computer-use screenshots are retained in the task's tool transcript.

| Full native window | Build | Complete SQL lines | Complete result rows | Complete result columns |
| --- | --- | ---: | ---: | ---: |
| 1280×800 | v0.3.2 | 13 | 8 | 5 |
| 1280×800 | candidate 03c5c25 | 18 | 11 | 5 |
| 960×692 | v0.3.2 | 10 | 7 | 3 |
| 960×692 | candidate 03c5c25 | 14 | 9 | 3 |
| 960×640 | candidate 03c5c25 | 12 | 8 | 3 |

Counts exclude clipped trailing lines/rows/columns and transient overlay scrollbars.
The 1280×800 horizontal divider was aligned near 450 pt; the 960×692 divider near
396 pt. Sidebar width was 285 pt. Default SQL fonts were 14 pt before and 13 pt
after. The name column was widened during the resize check; counts of complete
columns remained unchanged. These are observed layouts, not universal capacity
or a HeidiSQL comparison. Data mode at 960×640 showed 16 complete rows while also
showing the large-field summary and successful-save notices.

The official old binary cannot shrink below 960×692 including its native toolbar
(its 640 pt minimum applies to content). The paired small-window comparison
therefore uses that actual minimum. The new binary was additionally checked at
exactly 960×640, including its toolbar. This resolves the earlier resize blocker;
screenshot-scaled side/top-edge dragging worked.

At 960×640:

- SQL/Data/Structure, table context, Run, tab close, filter, Apply, refresh and
  pagination controls fit without overlap. Long tree names stay on one line,
  with middle truncation and full qualified-name hover help.
- Data Next reached page 2; Previous returned to page 1.
- Selecting id in row 1, Down, Right, Return opened bucket in row 2 with value 1.
- Structure columns and its tabs/actions remained usable; Cmd1/2/3 retained context.
- Header-boundary dragging widened the name column and preserved alignment.
  Direct header reordering could not be driven by the computer-use drag gesture;
  the native grid regression verifies reordered widths, data mapping and selection.
  Horizontal/vertical scrolling and full-value previews were checked natively.

## Sidebar acceptance

The narrow outer strip came from macOS's floating navigation container. A flush
workspace split removes it. The search and connection tabs share a 34 pt row;
both bottom bars share 28 pt. Query tabs/actions are 32/38 pt. Width is draggable
within 210–380 pt (default 260), independently persisted through hiding/showing;
narrow windows cap it to retain 660 pt for SQL controls. The separator exposes
accessible increment/decrement actions. Actual dragging 270→285 pt and hiding/
showing at 270 pt passed. Final relaunch restored 285 pt. SQL labels, search and
expanded connection/database/table rows remained readable.

The final source passed 31 layout/model/transfer regressions; AppStorage is
isolated in the layout fixture. `layout/layout.json` records separate exact
content-size hosted geometry, excludes native chrome, and is not substituted
for the native-window observations above.
