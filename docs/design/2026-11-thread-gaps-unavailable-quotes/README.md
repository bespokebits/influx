# Design review: missing posts in threads and unavailable quotes

A review folder for the design-review site: `manifest.json` and the
pictures it names (#201). It covers two things the reader can't see today:

- **Missing posts in a thread.** A thread can come back with gaps
  (`PostThread.gaps`): the service knows posts belong in it and didn't send
  them, among the earlier posts or the later ones, because they were
  deleted, are private, blocked or unreachable, or weren't collected. The
  thread view (`Influx/Shared/Thread/ThreadScreen.swift`) draws none, so
  the thread reads as complete.
- **A quote of an unavailable post.** A rich post can quote
  `{url, unavailable: true}`, and Bluesky and Mastodon have unavailable
  quotes too. The app keeps no quote for them, so the row shows nothing.
  The thread view draws no quote card at all, for any quote.

Both came with rich posts (#199, [ADR 0031](../../adr/0031-sammy-rich-feeds.md)),
and the design is meant for every service.

- **Decided:** both must exist. A gap says so for each reason, in each
  position. An unavailable quote says the quoted post is unavailable and
  offers its address. In the timeline its box has a fixed height, set by
  the text size alone, so a row's height stays final before it is shown and
  the row is still one bitmap.
- **Chosen (2026-11-14):** `C` for missing posts and `B` for unavailable
  quotes; see [feedback-2026-11-14.md](feedback-2026-11-14.md). Built in #234.

The review's slug is `influx-thread-gaps-unavailable-quotes`. Its surfaces
are `ios-thread-gaps`, `ios-row-unavailable-quote`,
`ios-thread-unavailable-quote` and the same three with `mac-`. Its columns
are `current`, `A`, `B` and `C`. Votes and notes are kept by those names,
so a revision is pushed again under the same slug with the same names.

## The columns

The three options use one idea on both surfaces, from lightest to heaviest.

| Column | Gap in a thread | Unavailable quote |
| --- | --- | --- |
| `current` | Nothing drawn. | Nothing drawn; the thread view has no quote card. |
| `A` · a quiet line | An italic sentence per reason, with an ellipsis, between rules. | One line: "Quoted post unavailable · example.com". |
| `B` · a hairline frame | A dashed frame per reason where a post would be: symbol, title, detail. | The quote card's hairline box, with an italic line and the site. |
| `C` · a washed note | A note on the wash colour: heading, a sentence per reason, and a link to the whole thread on its site. | A washed slip: symbol, "Quoted post unavailable" and the address. |

A gap doesn't say where in its list it falls, or how many posts it stands
for, so every option puts it at the edge of its list (above the first
earlier post, below the last later one) and says "some posts".

In the timeline each option's height is fixed: A is one meta line; B is
the card's padding, one line of the quote's text size and one meta line; C
is the padding and two meta lines. Every line is cut short, never wrapped.

## How the pictures were made

Captured on 2026-11-13 from the app at `521082c`, with Xcode 27, on macOS
27 and on the iPhone 18 Pro simulator (iOS 27), in light and dark. The
posts are made up, on example.com, example.net and example.org addresses.

`capture/ThreadGapsCapture.swift` is a test that draws every picture:

- **Current** is the app's own code. Timeline rows are drawn by
  `RowLayout` and `RowRenderer`, the bitmaps the timeline's cells show,
  stacked; the toolbar and sidebar are not in them. The thread is the app's
  `ThreadScreen`, reading the made-up thread through `SampleConnector`, the
  stand-in connector sample runs use. `capture/sample-connector.patch` lets
  the test hand it that thread; nothing else in the app changes.
- **A, B and C** are mock-ups. A row is the app's own bitmap, drawn with
  its geometry moved to make room for the box where a quote card goes, and
  the box drawn into the room in the row's fonts and colours. A thread is a
  copy of the thread view's layout with the gap and the quote card added.
- On the iPhone each thread is in a page sheet over paper, as the timeline
  opens it, drawn from the window (`drawHierarchy`), so there is no status
  bar. On the Mac the thread is drawn alone at the sheet's ideal size, in
  the test process (`cacheDisplay(in:to:)`): the sheet's title bar and Done
  button belong to the window and are not drawn.

The Mac pictures must stay drawn in-process. Capturing a window or the
screen (the window server, ScreenCaptureKit, `screencapture`) makes macOS
ask whoever is at the Mac to let the test app record the screen, and
nothing in Influx needs that.

## Capturing again

The fixture is not part of the test suite, and lives here so it isn't run
with it. It is copied into the test target only for a capture run, in a
working copy, and is never committed there.

1. Copy `capture/ThreadGapsCapture.swift` into `InfluxTests/`, apply
   `git apply docs/design/2026-11-thread-gaps-unavailable-quotes/capture/sample-connector.patch`,
   and run `xcodegen generate`.
2. Run the app tests for each platform (the `Influx-macOS` and `Influx-iOS`
   schemes). The test prints the folder it writes to.
3. `capture/collect.sh <folder>` for each platform's folder, to fill
   `images/` as lossless WebP (it needs `cwebp`), then
   `node build-manifest.mjs` to write `manifest.json`.
4. Revert the patch with `git checkout Influx/Shared/SampleConnector.swift`
   and delete the copy of the fixture from `InfluxTests/`. `git status`
   should then show changes under this folder only.

Then push the folder to the design-review site with its push command. When
the round closes, its votes and notes are saved here as a dated feedback
file.
