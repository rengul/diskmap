# Clean-room macOS disk scanner

This is an independent Objective-C++ implementation based on externally observed
behavioral requirements. It does not contain recovered DaisyDisk source code.

## Build

```sh
make
```

Requires macOS 13 or later, Xcode Command Line Tools, and the Foundation
framework.

## Graphical app

```sh
make ui
open DiskMap.app
```

The clean-room AppKit shell follows the observed two-stage UI flow: choose a
source, scan it asynchronously, then inspect a radial size map and a sorted item
list. It uses original system controls and generated colors; DaisyDisk artwork,
branding, nib files, and proprietary assets are not included.

The report view uses a unified dark macOS window, a dominant four-level radial
map, center labels and a compact contents sidebar with aligned sizes.
Its initial size is derived from the current screen's visible frame (capped at
820 × 560 points), so the window stays inside smaller displays and leaves room
for the menu bar and Dock.

At launch the startup volume (`/`) is already selected and the **Scan** button
is enabled; **Open Folder…** can replace it with another directory.

During scanning the header switches to an indeterminate horizontal progress
bar with a live status subtitle and a dedicated **Cancel** action. Result rows
use larger 15-point labels, 14-point aligned sizes and 36-point row spacing.

The report includes a clickable breadcrumb built from the actual navigation
history. Its root uses the macOS display name of the startup volume instead of
the literal `/`; clicking an ancestor returns directly to that level.

The header no longer duplicates the current path. Before scanning, its
determinate bar represents used capacity and the subtitle reports free space;
during scanning the same bar advances from the allocated bytes reported by the
scanner toward the volume's estimated used bytes.

Disk occupancy uses green below 70%, orange from 70–90%, and red above 90%.
While scanning, progress is blue and capped at 94% until the scanner process
actually completes, avoiding a false finished state while directories remain
queued. Live file, folder and pending counts appear in the bottom status bar.

Click a row or radial segment to select it. Double-click a directory row or
segment to make it the current directory. The compact top navigation bar keeps
**Back**, **Forward**, and the clickable breadcrumb together, with disabled
states when no history is available. The radial map renders up to four hierarchy levels at once; nested
segments remain selectable and navigable. Files are selectable but are not
treated as navigable containers.

While scanning, the status line reports live file, directory, allocated-space,
and pending-work counters. **Cancel** requests a cooperative stop and keeps any
valid partial hierarchy returned by the scanner.

Selecting an item shows its kind, allocated size, logical size, and complete
path. Use **Show in Finder**, or the equivalent context-menu action, to reveal
it. The context menu also provides **Copy Path**.

After each scan, the footer reports the containing volume and filesystem,
capacity, immediately free space, and the available purgeable/reserved
estimates. Unsupported estimates are shown as unavailable rather than zero.

Directories that macOS refuses to enumerate remain visible with a warning
prefix and orange/red styling. The completion status reports how many folders
were restricted, making clear that the resulting hierarchy is incomplete.

## Run

```sh
./ddscan --threads 8 /path/to/scan
```

Use `--progress` for live counters on standard error. Press Control-C to request
a cooperative stop: the scanner returns the partial result with `cancelled: true`
and exits with status 1, while still emitting valid JSON.

Use `--snapshots` to resolve the containing volume and list APFS snapshot names
and object IDs through macOS `fs_snapshot_list`. `--snapshot-sizes` additionally
attempts DaisyDisk's observed read-only APFS range-size query. That query is an
undocumented filesystem interface, so failures are reported per snapshot and
never suppress the inventory. Snapshot deletion and thinning are not performed.

Use `--volume-summary` to include total capacity, immediately free space,
capacity available for important/opportunistic usage, and a purgeable-space
estimate. The estimate uses documented Foundation volume-resource keys and is
computed as important-usage capacity minus immediately available capacity.
The summary also reports a reserved-space estimate derived from the public
volume size/free/used attributes. Availability flags distinguish a real zero
from a value the filesystem did not provide.

Add `--tree` to include the complete hierarchy, recursively sorted by allocated
size. Duplicate hard links remain visible in the tree but contribute zero bytes
after their first occurrence.

When scanning an entire macOS startup volume, the scanner reads
`/usr/share/firmlinks` and skips the mirrored destinations below
`/System/Volumes/Data`. This prevents `/Users`, `/Applications`, `/Library`,
`/private`, and the other APFS firmlink trees from being charged a second time
to `System`. Directory and file identities are also deduplicated by filesystem
device and inode.

For a complete mounted volume, the scanner reconciles the enumerated tree with
the public capacity and available-space values. Allocated space that cannot be
assigned to readable files (including restricted folders, snapshots, and
filesystem metadata) becomes a synthetic `hidden space` node. The JSON summary
exposes `firmlinkMirrorsSkipped`, `fileIdentityDuplicates`,
`volumeAllocatedBytes`, `hiddenSpaceBytes`, and `unreconciledOvercountBytes`.

By default the scanner does not descend into another mounted filesystem. Use
`--cross-filesystems` to allow that. Symbolic links are counted but never
followed.

The JSON result reports file and directory counts, logical and allocated byte
sizes, duplicate hard links, APFS clone files/groups, skipped mount points, and paths that could not be
read. With `--tree`, every node also carries its path, kind, and aggregated size.
Clone nodes include their clone ID and filesystem reference count. Allocated
bytes are not automatically deduplicated because clones may have diverged and
share only some physical extents.

Directories rejected with `EACCES` or `EPERM` are retained in the tree with
`restricted: true` and listed separately in `restrictedDirectories`; the
ordinary error record is preserved as well. This build does not install or
contact a privileged helper. Granting Full Disk Access remains an explicit
user/system decision.

## Current boundary

This runnable tranche implements the unprivileged filesystem engine, its
hierarchical data model, and a native AppKit map/list browser. It does not yet
include the privileged XPC helper or snapshot deletion/thinning. Snapshot size
attribution is experimental because macOS does not publish the observed APFS
`fsctl` ABI.
