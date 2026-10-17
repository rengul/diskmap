# Design QA — directory list

Reference: DaisyDisk directory list supplied by the user on 2026-10-15.

- Compact, borderless rows: passed.
- Directory name left and size right: passed.
- Colored marker matches the root palette used by the radial chart: passed.
- Selected row uses a neutral gray-blue background rather than the macOS accent color: passed.
- Pointer hover uses a lighter gray background and preserves selection state: passed by implementation inspection; it shares the verified custom row renderer.
- Header title and total share one baseline, matching the reference hierarchy: passed.
- Compact-window clipping: passed at the application's default 820 × 560 content size.
- Build and code signing: passed.

Final result: passed.

## Top navigation bar — 2026-10-17

- Source visual truth: `/var/folders/48/11xyrqy16rqfh4kn5c227fw80000gn/T/TemporaryItems/NSIRD_screencaptureui_RWCs39/Screenshot 2026-10-17 alle 20.13.55.png`.
- Implementation evidence: live Computer Use capture of `/Users/renatogulinelli/Projects/diskmap/DiskMap.app`, initial compact state and expanded `.git` navigation state.
- Viewport: 820 × 160 points (compact) and 820 × 560 points (expanded), dark appearance.
- Pixel dimensions and density: source 848 × 52 px; implementation captured at the native macOS window scale. Comparison was limited to the top navigation region because the source is a title-bar crop.
- Full-view evidence: the former standalone Back button is absent from the folder-action row; Back, Forward, and the breadcrumb now form one continuous top strip without overlapping the source header or expanded result area.
- Focused-region evidence: native chevron icons, disabled/enabled contrast, breadcrumb pills, spacing, truncation, and dark tokens were compared against the supplied crop.
- Typography: system font, compact 12.5-point breadcrumb labels, medium weight, and tail truncation match the reference hierarchy.
- Spacing and layout: navigation begins after the macOS window controls; 24-point history controls and a 28-point breadcrumb align on one center line.
- Colors and tokens: the existing dark title-bar palette and blue current-location state remain consistent with the reference.
- Image quality and assets: no raster assets are needed; Back and Forward use native SF Symbols rather than text glyphs or custom drawings.
- Copy and content: node names are sourced from the real navigation path; accessibility descriptions and tooltips identify Back and Forward.
- Interaction verification: navigated from `diskmap` into `.git`, then Back to `diskmap`, then Forward to `.git`; button enabled states and breadcrumb contents updated correctly at every step.
- Build verification: `make ui` passed; ad-hoc signing and deep signature verification passed.
- Findings: no actionable P0/P1/P2 differences in the requested navigation region.
- Comparison history: first implementation pass passed; no P0/P1/P2 visual fix iteration was required.
- Follow-up polish: none required for the requested scope.

Final result: passed.

## Compact launch and animated results — 2026-10-16

- Initial window shows only the source header, volume indicator, folder controls and breadcrumb at 820 × 160: passed with a live launch capture.
- Graph, directory list and status bar remain hidden before and during the first scan: passed by implementation inspection and live launch capture.
- Successful scan expands the window from 160 to 560 points over 0.42 seconds while keeping its top edge fixed: passed with a live scan.
- Result content fades in after the expansion and remains fully interactive: passed with a live scan.
- Expanded height is capped from the screen's visible frame and the compact window is pre-positioned inside the final footprint: passed by implementation inspection.
- Build, ad-hoc signing and deep bundle verification: passed.

Final result: passed.

## Long navigation names — 2026-10-16

- Long breadcrumb segments remain inside their pill and truncate with a trailing ellipsis: passed with a live navigation test.
- The radial chart title remains centered inside the inner circle and truncates with a trailing ellipsis: passed with a live navigation test.
- The directory-list heading stays on one line, truncates within its allotted column and leaves the size/item summary visible: passed with a live scan of a 139-character folder name.
- The full path and item name remain unchanged for navigation and actions; truncation affects drawing only: passed by implementation inspection.
- Build, ad-hoc signing and deep bundle verification: passed.

Final result: passed.

## macOS application chrome — 2026-10-16

- Native application, File, Edit, Window and Help menus are present: passed.
- Command-Q terminates the running application process: passed with live process verification.
- Splash version is positioned below the DiskMap wordmark with higher contrast: passed by layout inspection.
- App icon is compiled by Xcode into AppIcon.icns and Assets.car at all required macOS sizes: passed.
- Bundle metadata references AppIcon through CFBundleIconName and CFBundleIconFile: passed.
- Final bundle code signing and strict verification: passed.

Final result: passed.

## Finder deletion state — 2026-10-16

- The currently displayed directory is monitored for external Finder changes: passed.
- A removed file remains in the scan snapshot but its name and size become gray and struck through: passed with a live move-out test.
- Restoring the file clears the deleted appearance without rescanning: passed with a live move-back test.
- Monitoring is limited to the current directory and is replaced when navigating, avoiding a watcher per scanned node: passed.

Final result: passed.

## Long names and sidebar footer — 2026-10-16

- Removed the lower-right volume, item-detail and status text block: passed.
- Removed the redundant Show in Finder button while retaining the context-menu action: passed.
- Long directory and file names remain on one row and truncate with a trailing ellipsis: passed.
- Name column expands with the sidebar while the size column remains fixed and readable: passed.
- The list now extends to the bottom status bar without the former reserved footer gap: passed.

Final result: passed.

## Directory-list hover during scrolling — 2026-10-16

- Hover state is derived from the pointer's current window position whenever a row is drawn: passed by implementation inspection.
- Moving or reusing a row no longer preserves a stale hover flag: passed by resetting state when the row changes window ownership.
- Tracking-area replacement removes only the row's own tracking area and does not disturb AppKit-managed areas: passed by implementation inspection.
- Build, ad-hoc signing and deep bundle verification: passed.

Final result: passed.
