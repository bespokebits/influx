# Contributing

Thanks for your interest in Influx. It's a small project with strong opinions,
so please open an issue before starting anything larger than a small fix.
That way we can agree on the approach before you spend time on it.

## Building

You need a Mac with Xcode 27 or later (iOS and macOS 27 SDKs) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate && open Influx.xcodeproj   # then the Influx-iOS or Influx-macOS scheme
```

To sign with your own Apple team, create `Configs/DevelopmentTeam.local.xcconfig`
containing `DEVELOPMENT_TEAM = <your team ID>`. It's gitignored. Never commit
`Influx.xcodeproj`; it's generated from `project.yml`.

## Checking a change

```bash
scripts/verify.sh            # the full baseline; on a Mac it also runs both app schemes' tests
(cd InfluxKit && swift test)   # the non-UI package on its own
```

`InfluxKit` holds everything that isn't UI and must build and test on Linux, so
it can't import UIKit, AppKit or SwiftUI.

## Rules worth knowing

- **Scrolling comes first.** Row heights are final before display, rows are
  drawn off the main thread, nothing is inserted above the viewport, and there
  are no state writes per scroll event. A change that adds scroll hitches
  won't be merged.
- **Dependencies are rare.** A new third-party package needs a strong reason,
  given in its pull request, and its pinned release must be at least 14 days
  old (CI checks it).
- **Swift 6 language mode** with strict concurrency; tests use Swift Testing.
- The timeline is **oldest-first only**. Please don't propose a sort toggle.

## Pull requests

- Link the issue (`Fixes #N` or `Refs #N`) and say how you tested the change,
  including the device or simulator.
- Keep each PR to one change. Every PR gets an automated review, plus a
  secret scan and a security scan.
- Never commit secrets, `.env` files, signing material or personal details.
  `scripts/verify.sh rules` checks for the common forms (private host names
  and addresses, home-directory paths, email addresses).

## Licensing of contributions

Influx is licensed under the [GNU General Public License v3.0](LICENSE). By
opening a pull request, you agree that:

- your contribution is licensed to everyone under GPL-3.0, like the rest of
  Influx; and
- you also grant Bespoke Bits a perpetual, worldwide, non-exclusive,
  royalty-free licence to use, change and distribute your contribution under
  other terms. This is what lets Bespoke Bits ship Influx on Apple's App Store,
  whose terms don't fit GPL-3.0.

You keep the copyright in your work. You confirm that the contribution is your
own, or that you have the right to submit it on these terms.

## Reporting security issues

See [SECURITY.md](SECURITY.md). Please don't open a public issue.
