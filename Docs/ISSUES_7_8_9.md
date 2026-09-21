# Issues #7–#9 acceptance notes

## #7 — SQL completion

- Automatic suggestions after two identifier characters or a qualifier dot; Control-Space / Option-Escape also open the list.
- Schema and table suggestions use the active database. FROM/JOIN references trigger debounced metadata loading without browsing a table first; aliases resolve to their columns.
- Tab/Return or mouse click accepts; arrows navigate; Escape dismisses. Suggestions do not pre-insert text, interrupt marked IME text, or appear inside strings/comments.
- UTF-16 ranges preserve Chinese/emoji, quoted identifiers, and the SQL after the caret. Middle-of-word completion replaces the entire identifier.
- This is a lightweight resolver, not a complete SQL parser. Nested alias shadowing, CTE-derived fields, and arbitrary expression type inference are not implemented.

## #8 — Online updates

- LuckySQL menu → Check for Updates opens an asynchronous update sheet with version/status/release notes and explicit download/install controls.
- Only stable, newer semantic versions and the exact repository's arm64 asset are accepted. HTTPS GitHub metadata supplies the required SHA-256 digest.
- Verify archive size/hash, paths, symbolic links/expanded size, bundle identity/version, minimum macOS, Mach-O architecture, and code signature before installation.
- Save SQL drafts, stage on the destination volume, atomically replace the app, and retain a uniquely named old-app backup. Database operations block installation/restart. Explicit restart waits for the old process to exit.
- Errors are surfaced with retry/manual-reveal options. No elevation, certificate bypass, automatic background installation, or disabling Gatekeeper.
- Trust remains in the GitHub repository/HTTPS release metadata. Ad-hoc signing is not Developer ID or notarization. Existing v0.2.0 installations need one manual upgrade to gain the updater.

## #9 — 1,000-row previews

- Add or cap the outer SELECT/CTE/UNION LIMIT; do not wrap in a derived table, which would reject duplicate column names or alter ordering/locking behavior.
- Preserve smaller explicit limits and offsets; place LIMIT before locking clauses and trailing comments. Original drafts/history stay unchanged.
- Never add LIMIT to UPDATE/DELETE/INSERT or SELECT INTO. Unsupported parameterized LIMIT/executable-comment cases fail clearly instead of making an unsafe rewrite.
- Client retention is also capped at 1,000 rows for SHOW and other result-producing commands. Metadata discovery uses its separate unbounded path. Single large cells and expensive server plans are still not bounded by a row limit.

## Verification

- Unit and model regressions cover completion context/replacement, metadata loading, preview rewriting, versions, checksums, traversal rejection, and real signed disposable-app replacement with backup preservation.
- MySQL 5.6.51 and 8.4.11 integration tests exercise 1,205 disposable rows, check server-side FOUND_ROWS=1,000, smaller limits, offsets, UNION, locks, and MySQL 8 CTEs. Existing user tables are untouched.
- Optional actual GitHub download test validates the published archive without installing it.
- Actual window checks: automatic keyword and alias-column suggestions, Tab and mouse acceptance, and online version checking. Installation is tested on disposable apps, not by replacing the user's installed app.

References: [Apple completion API](https://developer.apple.com/documentation/appkit/nstextview/insertcompletion(_:forpartialwordrange:movement:isfinal:)), [MySQL SELECT syntax](https://dev.mysql.com/doc/refman/8.4/en/select.html), [GitHub release asset digests](https://docs.github.com/en/rest/releases/assets), [Apple file replacement](https://developer.apple.com/documentation/foundation/filemanager/itemreplacementoptions).
