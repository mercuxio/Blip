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

### The menu bar item is hand-built, and that is a measured decision

`MenuBarExtra` is the idiomatic way to do this and Blip used it until it was
profiled. It hosts its label in an `NSHostingView`, so every change to the
readout costs an Auto Layout solve (`systemLayoutSizeFittingSize:`) and a width
re-negotiation (`-[NSStatusItem _adjustLength]`) before anything is drawn — to
re-derive a width that provably cannot change, since both readout styles render
to a constant-width image. A three-way probe updating a status item at 1 Hz:

    MenuBarExtra (SwiftUI label)      1.47% CPU
    NSStatusItem, variable length     1.24% CPU
    NSStatusItem, fixed length        0.96% CPU

In Blip itself the win is real but smaller than that suggests: both builds run
side by side on the same traffic came out at **1.83% → 1.55%, 15%**. Quote that
number, not the probe's 35%.

So `StatusItemController` owns an `NSStatusItem` created at a **fixed** length
and assigns `button.image` directly. The panel is still SwiftUI, hosted in an
`NSPopover`. Do not "modernise" this back to `MenuBarExtra`.

What remains is not reachable from here. AppKit keeps mirror copies of a status
item ("replicants") and re-captures each through `CALayer renderInContext:` on
every content change — a full offscreen bitmap re-render, not a blit. A control
build identical to Blip but for a frozen status item image measures **0.07%**,
so essentially everything Blip costs is this redraw, and none of it is Blip's
own work. That cost
is charged **per content change, not per poll**, which is why `StackedRates` and
`Sparkline` cache on their rendered output and why `NetworkMonitor.tick` assigns
`reading` only when it differs. Do not remove those guards.

### Poll rate and redraw rate are deliberately different

`NetworkMonitor` polls at 1 Hz because session totals have to be exact.
`StatusItemController.redrawInterval` repaints at half that, because the repaint
is the only part AppKit charges for and the cost is per repaint. The saving is
linear in that interval and is paid in latency — the readout may lag by up to
one interval — never in accuracy. Raising it further is the one remaining lever
if this ever needs to get cheaper again.

The throttle *defers*, it does not drop. Dropping an early update would mean the
last tick before a link goes quiet never reaches the menu bar, leaving a stale
rate on screen forever. A preference change bypasses the throttle entirely, so
switching display style still looks instant.

Note the cache hit rate is low by nature — measured against 150 s of real
traffic, the rendered strings change on 39 ticks out of 40. Rounding the
displayed rate to coarser buckets to recover hits is the obvious next idea and
does not work: rates swing over an order of magnitude second to second, and the
two rows vary independently, so the readout changes unless *both* hold still.
Even a ±100% deadband — letting the number be wrong by 2× — still changes on 80%
of ticks. The guards earn their keep on a genuinely silent link, not on a merely
quiet one.

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
