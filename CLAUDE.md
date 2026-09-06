# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Blip is a macOS menu bar app showing total network ingress/egress for the
active interface, with a click-through panel for local and public IPs. No Dock
icon, no window, no telemetry.

## Commands

```bash
make build      # swift build -c release
make test       # 28 tests, 6 suites
make app        # assemble and ad-hoc sign .build/Blip.app
make run        # kill any running copy, build, launch
make install    # replace /Applications/Blip.app
make zip        # the release artifact
```

Run one test or suite by name — the suite is swift-testing, not XCTest:

```bash
swift test --filter "RateTracker"
```

**`DEVELOPER_DIR` must point at a full Xcode, not the Command Line Tools.** The
Makefile defaults it to `/Applications/Xcode-beta.app/Contents/Developer` and
exports it, so `make` targets work unattended; a bare `swift build` in a shell
without it picks up the CLT toolchain, which cannot find SwiftUI without the
deprecated `--build-system native` flag. Override from the environment (`?=`)
rather than editing the Makefile.

The package declares **Swift 6.2**, which is a real floor: `NetworkMonitor` uses
`isolated deinit` (SE-0371). On an older toolchain the error names the deinit's
properties rather than the toolchain, so it misreads as an actor-isolation bug.

## Architecture

Three targets, and the split is load-bearing:

- **`CBlip`** — C shim. Exists only because `if_data64` does not import cleanly
  into Swift. Uses `sysctl` and nothing else.
- **`BlipCore`** — all logic worth testing, pure functions where possible. This
  is where new logic belongs.
- **`Blip`** — a thin SwiftUI shim. Deliberately thin, because `swift test`
  cannot reach it. Anything non-trivial here is untestable by construction, so
  push it down into `BlipCore`.

### Counter accuracy is the point of the app

Counters come from `IFMIB_IFDATA` (`net.link.generic.ifdata.<row>.general`),
which is true 64-bit. `NET_RT_IFLIST2` — the path most examples use — is read
**once at launch as a cross-check only**: on current macOS it returns values
truncated to 32 bits and floored to a 1 KiB multiple despite declaring a 64-bit
field. If the two paths agree exactly on 1 KiB boundaries, `ifmib` is being
sanitized too and the panel says "Approximate" rather than quietly reporting a
fraction of reality. Do not "simplify" this to the `IFLIST2` path.

`InterfaceCounters.isPhysical` excludes `utun`, `awdl`, `bridge` and friends by
name prefix. That list is the double-counting fix, not cosmetic filtering: VPN
traffic crosses both the tunnel and the NIC underneath, so summing every
non-loopback interface reports it twice.

### MenuBarExtra(.window) has two traps, both hit already

- **`.onAppear` on the content view fires once for the life of that view**, not
  on each panel open. Anything scheduled "for the next open" never runs.
- **The hosting `NSPanel` grows to fit but never shrinks.** A section losing a
  row leaves the window at its tallest-ever size with content centred in it.
  `PanelView` measures its *ideal* height (`.fixedSize`, so the measurement is
  independent of the window being measured in and cannot oscillate) and sets the
  window frame directly through `NSViewRepresentable`.

### The network boundary

`api.ipify.org` / `api6.ipify.org` is the only thing this app ever contacts.
The gate is that the panel must have been opened at least once; before that
Blip issues no request at all. After it, the lookup may run unattended — on a
change of primary interface, and on a failure backoff. Adding an endpoint,
fetching before the first panel open, or tightening the backoff needs to be
argued for in the PR rather than slipped in. See CONTRIBUTING.

## Packaging

The bundle is assembled by hand because SwiftPM cannot emit a `.app`. It is
**ad-hoc signed** (`codesign -s -`), which satisfies the hardened runtime but is
not notarization — there are no entitlements and no sandbox. `make zip` uses
`ditto`, never `zip`: part of a bundle's signature lives in extended attributes
that `zip` drops, and the resulting failure reproduces only on the downloader's
machine.

SwiftPM builds for the host architecture only. A release built on Apple silicon
is arm64-only — check with `lipo -archs` before claiming otherwise.
