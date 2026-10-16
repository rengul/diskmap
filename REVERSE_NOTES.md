# Clean-room reverse-engineering notes

These notes record behavioral evidence used to guide the independent UI
implementation. Decompiled representations are observations, not original
source code, and were not copied into the implementation.

## Visual hierarchy and report layout

- `TreePieView::drawRect:` (`0x1000f9c40`, REA evidence `ev_992a19b3f75fbeb90021cbe612a0d407c4c32aa94f9f2246f72eafac08db2d74`) centers the radial plot, draws the inner size label from the first ring, then paints the segment collection and callouts.
- `ReportPageController::updateLayoutWithResizeAxis:forceUpdate:` (`0x100024190`, REA evidence `ev_6a7daae05a9e9ec1b8213173af13cf9310899705cd045e3a41892e30d3b5f151`) coordinates separate pie, summary and auxiliary widths rather than treating the report as one undivided canvas.
- Public product screenshots were used only as a visual reference for hierarchy: dominant radial map, compact dark sidebar, restrained chrome and right-aligned sizes. The implementation uses new AppKit code, system typography and an independent palette; DaisyDisk artwork, icons and branding are not included.

## Hierarchical map navigation

Artifact: `DaisyDisk-arm64`, SHA-256
`3eedccbb5d38ed6044d69453b48f24275a58d37ba485b5d83d7da980fc31c75b`.
Provider: Ghidra 12.1.4 through REA.

- `TreePieViewController::treePieView:userDidSelectItem:` forwards selection to
  the report controller (REA Evidence
  `ev_de32458340e7b7bd04c9cb3c9a869d08096198676f0df7e6e8b916b1a15b9b81`).
- `TreePieViewController::treePieView:userDidClickItem:` forwards activation to
  the report controller (REA Evidence
  `ev_b8655962b07921ee3760ff637192f058742bd845aae1c25aeaa90b0bdc8d8894`).
- `ReportPageController::reportViewController:userDidClickItem:` dispatches by
  item type (REA Evidence
  `ev_bbf1a2a97260316d40226bbb9bd0aef5d1ddf27f0b3f81aa81f8d6531dbf27e2`).
- The item-type dispatcher changes the current directory when the selected item
  resolves to a navigable directory, otherwise it follows a non-navigation path
  (REA Evidence
  `ev_e9ed6e45be9c70d80147ae1328c79561af9456e78f7f9b964c062f5f7bade948`).
- Setting the current directory updates the controller's current item and
  forwards the same transition to the radial view (REA Evidence
  `ev_f42a990c91cc3107bc7ec6c6040d8314cbdacf5995f8e6bd90a697baf89f2ca2`).
- Navigation completion refreshes the radial view and summary when needed and
  validates the new current directory (REA Evidence
  `ev_65db7101641860352747c75959333d8c9486f28f14eb2be95c864f5f7606a195`).

Clean-room implementation: selection is synchronized between the radial map
and table; activation enters directory nodes; an explicit local history powers
the Back button; map and table are rebuilt from the selected tree node.

## Multi-ring radial layout

- `TreePieView::rebuildRings` creates indexed rings with separate lower-radius
  and width values (REA Evidence
  `ev_e1fd37ed330988c64bbad779b9cdcce0d79f7c616a6a3a6110041c9c1485d337`).
- `TreePieView::rebuildSegmentsForDirectory:ringIndex:baseDir:` clears the old
  segment collections and recursively builds segments for a directory while
  applying a minimum visual size (REA Evidence
  `ev_b32dd2cdc2c4daffaf998a5c9a97065a06a103b508050638c900308e71c3064b`).
- `TPSegment::calculateWithSpan:` stores angular span data and rebuilds the
  segment path (REA Evidence
  `ev_8674fbe08e108becff9061576ea14517f2800d6f2dfd28a1980638cf8aec0110`).
- `TreePieView::hitTestPoint:` searches the generated segment collection and
  returns the item belonging to the matching segment (REA Evidence
  `ev_aa34cc697f7910cca9b8666492618c9cf7dc3ec03a92b115f3f75a49742846d7`).

Clean-room implementation: the current directory's children occupy the inner
ring and descendants recursively occupy aligned outer rings. Angular spans are
proportional to allocated bytes. Very small spans are omitted from rendering,
and hit-testing prefers the deepest visible segment.

## Scan progress and cancellation

- `SourcePageController::cancelAllScans` enumerates active source controllers
  and requests cancellation on each one (REA Evidence
  `ev_c2ae156d7f43b8098b3d0d2ef350bacfc707b12e760c33f5810939c2f71d6b11`).
- `SourceController::cancelScan` distinguishes active and waiting work, stops
  the active request, resets its scan state, and notifies the queue controller
  (REA Evidence
  `ev_5c841ab89750d5e67b3774e07c106340637244ecfa1455abf96b7dde9dff91bd`).
- `ScanQueue::currentScanProgress` aggregates progress from active and queued
  scans rather than exposing only a binary busy flag (REA Evidence
  `ev_63be3d28316cd52c2d9b6b44e4c5e31c54a8d125c78c2f37644833002229ce4a`).
- The UI contains distinct update paths for active progress, waiting state, and
  paused animation (procedure inventory Evidence
  `ev_99366b8cc56331d3efeaabdaf84805a0e00068b8e7854893a863a465b3dd5360`).

Clean-room implementation: `ddscan --progress` emits counters on standard error,
which the AppKit process drains asynchronously to avoid pipe back-pressure. A
Cancel button sends SIGINT to the owned scanner process; the scanner cooperates,
finishes serialization, and the UI accepts its partial JSON result.

## Selection actions and Finder integration

- `ReportPageController::reportViewControllerUserWillRequestContextMenu:` checks
  the selected item and synchronizes delayed radial selection before presenting
  contextual actions (REA Evidence
  `ev_f4f48cfdb220a639f7990cbf1c75419387e642d68e84dc589506bcdd471d1dea`).
- `ReportPageController::showInFinder:` chooses the selected item, falls back to
  the current directory, resolves a usable path, and asks `NSWorkspace` to
  select it in Finder (REA Evidence
  `ev_aac94446caf1c923ef134dac521878f9d4f9dd2f020b6dcc9380465cd31d105d`).
- `SourceController::showSourceInFinder:` applies the same `NSWorkspace`
  selection behavior to a source path (REA Evidence
  `ev_a1b598f832864c09c692746cac68af5938071360d7b9dbba4f32887aa1ec4041`).

Clean-room implementation: the selected node drives a compact details line and
Finder action. The current directory is the fallback when no child is selected.
The context menu adds a local Copy Path convenience action; this is an explicit
design choice rather than a claimed reconstruction of a specific original menu.

## Volume-space summary

- `ReportPageController::updateSpaceSummary:` refreshes the summary/list,
  enumerates special space items, rebuilds the radial map, and refreshes
  selection when the volume summary changes (REA Evidence
  `ev_98c1f7e6fc001ff3f660ac220fe60cb6d36b6318ded51920af643805e9e713e7`).
- The original constructs distinct special items for free, purgeable, and
  reserved space (REA Evidence `ev_b6286b388f0a9b4a724ac6fdb860e2513952fc063ad46831f4d4c049b014e74b`,
  `ev_84346bd9593249cb048ee1c974b2548dbdb36685ec6d885b476af8eb27dd69e9`, and
  `ev_6d7609f6a6db9135fad898ff4ade1d0894c655564816f021c6c511e1231bf717`).

Clean-room implementation: the footer presents the scanner's public-API volume
summary as separate capacity, free, purgeable-estimate, and reserved-estimate
values. It does not inject estimated categories into the radial hierarchy,
because doing so without the original accounting model could double-count
space. Availability flags distinguish unsupported estimates from genuine zero.

## Restricted-directory presentation

- Restricted state is stored on individual items and can be applied
  recursively to descendants (REA Evidence
  `ev_2a6aa18f6d0cbb1139528d6123705a11264ad6d0767ad2909840ad62ce83052e`).
- Scan completion passes restricted directories independently from ordinary
  output directories, hard links, clones, space summary, and snapshots (REA
  Evidence `ev_e454ebbac2d250b93051d445492347fc18bd2d33738f05f41f3d1b75fd097531`).
- Restricted-state changes are reflected through a dedicated source error
  state when the app is neither scanning nor already displaying the report
  (REA Evidence
  `ev_b8201f560bdb42092e6f15ef7a4f6d23efdd2f1900976b6a7ccc98f0164de9e2`).
- Finder-style actions walk upward until an unrestricted parent path is found
  (REA Evidence
  `ev_edca64fb608256150a11eaff1b50d8eef81b924b4d3e0cfa407738faedcfd16d`).

Clean-room implementation: restricted nodes stay in the hierarchy, use warning
styling in both table and radial map, and contribute to an explicit limited-
access completion message. No privilege escalation or system-setting change is
attempted.
