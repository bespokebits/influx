# Influx

<img src="Influx/iOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png" alt="Influx app icon: three coloured slips dropping into an ink tray" width="128" align="right">

**One universal timeline for everything you follow.** Influx is a reader for
iPhone and Mac that merges RSS feeds, Bluesky and Mastodon into a single
timeline.

- **Built for completionists.** Influx reads top to bottom, oldest first, and
  remembers exactly where you stopped, on every device, through iCloud. A post
  that arrives late, say from a feed that was down, lands where you are now
  rather than above you, so nothing slips past.
- **Built for performance.** Scrolling stays smooth across thousands of posts
  at 120 Hz. Every row is laid out and drawn before it reaches the screen.

Influx is in early development.

## What it does

- **Three services, one timeline.** RSS (with OPML import), Bluesky and
  Mastodon, with as many accounts on each as you like. A post that reaches you
  twice, such as a boost from two people you follow or a Bluesky post bridged
  to the fediverse, shows once.
- **Catching up.** New posts arrive below you, and the timeline only follows
  the live edge when you're already there. An unread pill shows how much is
  left.
- **Synced through iCloud.** Subscriptions, saved views and filters sync along
  with your place. Sign-ins go through iCloud Keychain.
- **Saved views and filters.** Build views over any mix of sources, and hide
  posts by keyword or regular expression, everywhere or in one view.
- **Bookmarks.** Like, boost and bookmark posts, open the whole thread, and
  find everything you've saved in one Bookmarks view.
- **Media that behaves.** Link cards, quote posts and images are sized before
  they appear, and videos never autoplay.

## How it's built

| Part | What it holds |
| --- | --- |
| `InfluxKit/` | Everything that isn't UI: connectors, the store, sync merge rules, timeline logic. It builds and tests on Linux too. |
| `Influx/Shared`, `Influx/iOS`, `Influx/macOS` | The apps: a SwiftUI shell around the platform collection views. |
| `server/oauth-worker/` | The small Cloudflare Worker behind Bluesky sign-in. |

Swift 6 with strict concurrency, Swift Testing, and one third-party package
([GRDB](https://github.com/groue/GRDB.swift)).

## Building

You need a Mac with Xcode 27 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate && open Influx.xcodeproj   # then the Influx-iOS or Influx-macOS scheme
scripts/verify.sh                            # the full check, including both apps' tests
(cd InfluxKit && swift test)                 # the package on its own
```

## Contributing

Issues and ideas are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md)
first, and open an issue before starting anything larger than a small fix.
Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## License

Influx is licensed under the [GNU General Public License v3.0](LICENSE).
Contributions are welcome under the terms in [CONTRIBUTING.md](CONTRIBUTING.md).
