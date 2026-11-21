# Getting builds onto devices when TestFlight can't take them

In November 2026 the developer account moved from an individual membership to
an organization. While that move runs, Apple turns off most of what the
membership gives: TestFlight takes no new builds, and Xcode Cloud and parts of
App Store Connect stop answering. It can last weeks. Influx and a sibling app
on the same account lost TestFlight at the same time. These are the lessons,
so the next outage costs an hour, not a day.

## What the outage looks like

- The App Store Connect API answers `404 NOT_FOUND` ("The specified resource
  does not exist") for the Xcode Cloud product and its workflows, which it
  read the same morning. Nothing changed on our side. A 404 on ids you didn't
  change means the account, not the code.
- Reads that don't touch Xcode Cloud still work, such as finding the app or
  its testers' group (`testflight.mjs preview-setup`, #287).
- An archive still builds and signs, but the export for upload fails with
  `No Account for Team` and `No signing certificate "iOS Distribution"`.
- Apple can't register a new device or make a new profile meanwhile.

When you see these, stop re-running Xcode Cloud and upload jobs: each run
costs a build number and shows nothing new. Switch to local builds.

## What still works, and how to keep it working

The development certificate in the build machine's login keychain, and the
development profiles Xcode has already downloaded, keep signing until they
expire. Everything else depends on what was set up before the outage. So, at
any time:

- **Keep a development profile for every bundle ID that must reach a device**:
  each app, and each app extension it embeds. A missing one can't be made
  during an outage, and the target that needs it can't be built.
- **Register every test device before you need it**, the test Mac as well as
  the test iPhone. A Mac app signed with a profile that doesn't list that Mac
  won't open there.
- **Keep the profile's entitlements equal to the app's.** Influx Preview's
  development profiles carry iCloud (Production and Development), the keychain
  groups, App Attest, associated domains and push, so a local build syncs and
  signs in like a TestFlight one. `scripts/local-device-build.sh` prints the
  profile's expiry date with every build.

Without a profile, a Mac app can still be signed with the development
certificate alone, but it loses every entitlement Apple restricts: the
application identifier (and with it the data-protection keychain), keychain
groups, iCloud, push and associated domains. Only a team-prefixed app group
remains. An app has to check its own entitlements at run time to survive
that, so treat it as a last resort.

## Build the app testers already use

Local builds are Influx Preview, not Influx. Preview has its own bundle ID and
shares the reader's iCloud data and sign-ins on purpose (ADR 0042). A local
Preview replaces a TestFlight Preview on the device and keeps its data,
because the bundle ID and team are the same. The next TestFlight Preview
installs over it.

Never development-sign the production app (Influx, Release) onto a device. It
would replace the reader's TestFlight app, and its field performance reports
(ADR 0034) would then describe a build nobody else runs.

## Build numbers

A local build needs a number that rises with every build and is lower than the
next TestFlight build, so TestFlight installs over it. The UTC minute
(YYMMDDHHMM) does both, which is why the local and Preview scripts share it. If
a server refuses builds below a minimum, check the number against it too.

## Signing and handing the build over

- **Build in a session on the build machine, not over SSH.** Signing reads the
  login keychain of the signed-in session. On the same machine, signing over
  SSH once crashed `securityd`, and its disk-space guard refuses archives
  started over SSH.
- **iPhone.** `xcrun devicectl device install app` installs on a paired iPhone
  over the network. The phone needs Developer Mode on.
- **Mac.** Zip the app with `ditto -c -k --keepParent`, which keeps the
  signature intact. On the test Mac, unpack it with `ditto -x -k`, clear the
  quarantine flag (`xattr -dr com.apple.quarantine`), check it with
  `codesign --verify --deep --strict`, then open it. If it won't open, check
  that the Mac's provisioning UDID (`system_profiler SPHardwareDataType`) is in
  the profile.
- **Push.** A development-signed app gets a sandbox push token. CloudKit sorts
  that out itself; any server of our own that sends pushes by token must send
  these to Apple's sandbox gateway.

## When TestFlight is back

Build Preview through `scripts/preview-testflight.sh` again. Its first upload
installs over the local build on both devices. Keep `local-device-build.sh`:
it is also the quickest way to try a build on a device before it goes to
testers.
