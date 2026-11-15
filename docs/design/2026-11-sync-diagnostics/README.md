# Design review: Copy Diagnostics in the sync panel

A review folder for the design-review site: `manifest.json` and the pictures
it names. It covers one small change, the Copy Diagnostics button that #142
added to the sync panel beside Sync Now
(`Influx/Shared/Sync/SyncStatusView.swift`). The button went in without a
design review; this is that review, after the fact (#140).

- **Decided:** sync keeps a journal on the device and the reader can copy it
  ([ADR 0026](../../adr/0026-sync-journal.md)).
- **Open when the round ran:** whether the way to copy it belongs in the
  sync panel beside Sync Now, what it is called, and where it sits.
- **Result (2026-11-11):** column `B`. See
  [feedback-2026-11-11.md](feedback-2026-11-11.md); the panel changed in
  #160.

The rest of this file describes the round as it ran, when `A` was the panel
on main and `B` was a mock-up.

The review's slug is `influx-2026-11-sync-diagnostics`. Its surfaces are
`mac-sync-panel` and `ios-sync-panel`, and its columns are `current`, `A`
and `B`. Votes and notes are kept by those names, so a revision is pushed
again under the same slug with the same names.

## The columns

| Column | What it is | Where it comes from |
| --- | --- | --- |
| `current` | The panel before #142: one button, Sync Now. | `SyncStatusView.swift` from commit `fafd96c`, built into the app at `b616133`. |
| `A` | The panel on main: Copy Diagnostics beside Sync Now. | The app at `b616133` (the button is from #142, `fcf1a30`). |
| `B` | A mock-up: Copy Diagnostics as a quiet line under a rule. | `QuietCopyPanel` in the capture fixture, at `b616133`. Not in the app. |

`B` is there because Copy Diagnostics is a troubleshooting step most
readers never need, and in `A` it weighs the same as Sync Now.

Nothing else that draws the panel (`SyncButton.swift`, `SlipsMark.swift`,
`SyncStatus.swift`, `Broadsheet.swift`) changed between `fafd96c` and
`b616133`, so `current` differs from `A` by that one file.

## How the pictures were made

Captured on 2026-11-10 with Xcode 27.2, on macOS 27.2 and on the iPhone 18
Pro simulator (iOS 27.0), in light and dark.

A development or test build has no iCloud container, so it has no sync
button and no way to open the panel. `capture/SyncPanelCapture.swift` is a
test that opens it anyway:

- It makes a `Sync` over an in-memory store with an example container name
  and never starts it, so nothing loads the sync framework or reaches
  iCloud. It then reports one finished sync and some counts, so the panel
  reads as a device that is up to date.
- On the iPhone it puts the app's own `SyncStatusView` in the system's
  popover, the way `SyncButton` does, hung from a stand-in for the sync
  button on plain paper. The stand-in has the same mark but not the tap,
  which would start a sync. It holds each state for 30 seconds and writes
  the state's name to `status.txt` in the folder it prints, so a screenshot
  of the simulator can be taken while it waits. It also saves its own
  picture of the window, which has no status bar.
- On the Mac it draws the app's own `SyncStatusView` alone, in the test
  process (`cacheDisplay(in:to:)` on the hosting view), on the colour of a
  plain window.

So in every picture the panel is real. On the iPhone the button it hangs
from and the empty paper behind it are stand-ins; in the app the popover
hangs among the buttons at the top of the timeline. On the Mac the popover
is not shown at all: not its rounded shape, its arrow, or the blur material
behind the panel. In the app it hangs from the sync button in the toolbar.

The Mac pictures must stay drawn in-process. Capturing a window or the
screen (the window server, ScreenCaptureKit, `screencapture`) makes macOS
ask whoever is at the Mac to let the test app record the screen, and
nothing in Influx needs that.

The Copied state is on the iPhone only. The fixture waits in a state whose
name ends in `-press`; tapping Copy Diagnostics on the simulator then, and
taking a screenshot within two seconds, catches it. It isn't captured on
the Mac: nothing there taps the button, and a tap would overwrite the
clipboard of the machine drawing the pictures.

## Capturing again

The fixture is not part of the test suite, and lives here so it isn't run
with it. It is copied into the test target only for a capture run, in a
working copy, and is never committed there.

1. Copy `capture/SyncPanelCapture.swift` into `InfluxTests/`, and run
   `xcodegen generate`.
2. Run the app tests for each platform (the `Influx-macOS` and `Influx-iOS`
   schemes). The test prints the folder it writes to. For the iPhone, take
   the screenshots of the simulator while it holds each state, and name
   them `device-<state>.png` beside the fixture's own pictures.
3. `capture/collect.sh A <folder>` for each platform's folder. This fills
   columns `A` and `B` in `images/`, as lossless WebP (it needs `cwebp`).
4. For `current`, put the earlier panel in place with
   `git show fafd96c:Influx/Shared/Sync/SyncStatusView.swift > Influx/Shared/Sync/SyncStatusView.swift`,
   run both again, and `capture/collect.sh current <folder>`.
5. Restore the panel with `git checkout Influx/Shared/Sync/SyncStatusView.swift`
   and delete the copy of the fixture from `InfluxTests/`. `git status`
   should then show changes under this folder only.

Then push the folder to the design-review site with its push command. When
the round closes, its votes and notes are saved here as a dated feedback
file.
