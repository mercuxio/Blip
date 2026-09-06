# Changelog

All notable changes to Blip are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- The public IP no longer stalls on "Looking up…" after the machine wakes.
  Waking makes the primary interface go away and come back, which cleared the
  address on the assumption that the next panel open would fetch it again — but
  the panel's `onAppear` fires once for the life of the menu bar view, not on
  every open, so nothing ever did. Only the refresh button recovered it.
- A failed lookup is now retried on a backoff (15 seconds, doubling to a
  15-minute ceiling) rather than staying failed until asked again. Waking races
  the interface coming back up, so the first attempt after a wake often fails on
  a network that is fine moments later.
- The panel no longer keeps the height of its tallest-ever contents. Losing a
  row left the window at its previous size with the content centred in it, which
  read as unexplained padding above and below.
- A cancelled lookup left its task handle set, which would have refused every
  later lookup for the life of the process. Only reachable at teardown, so it
  was never observable.

### Changed

- The public IP lookup may now run with the panel closed: on a change of primary
  interface, and on the retry backoff above. It still never runs before the
  panel has been opened at least once, so a Blip that is never opened contacts
  nothing. See Privacy in the README.
- `Package.swift` declares Swift 6.2, which is what the code has required since
  it started using `isolated deinit`. It previously declared 6.0 and failed to
  compile on it.

## [1.0.0] — 2026-09-03

First public release.

- Menu bar item in two styles: **Rates**, with in and out on separate lines at a
  fixed width so it never shoves neighbouring items sideways, and **Sparkline**,
  a 60-second graph of combined throughput.
- Click-through panel: session totals, the active interface with its local
  addresses, and the public IP, looked up on demand rather than on a timer.
- **Measure** — primary interface, or all physical interfaces summed. Both
  exclude tunnels and bridges, so VPN traffic is counted once on the NIC
  underneath rather than twice.
- **Start at login** via `SMAppService`; the toggle reflects what the system
  actually did, not what was asked of it.
- Counters read from `IFMIB_IFDATA`, which is true 64-bit, with a launch-time
  cross-check against `NET_RT_IFLIST2`. If the two agree exactly on 1 KiB
  boundaries the values are being sanitized, and the panel says **Approximate**
  instead of quietly reporting rounded numbers.
- No Dock icon, no window, no account, no telemetry.

### The download was rebuilt on 2026-09-06

The `v1.0.0` asset was replaced in place rather than re-tagged. If you
downloaded before that date, the copy you have differs from the current one in
two ways:

- The settings dropdown now ends with the app name and version. It previously
  showed nothing to identify the build.
- `CFBundleShortVersionString` was `1.0`, which did not match the `v1.0.0` tag
  it shipped under. It is now `1.0.0`.

Nothing about how traffic is measured changed.

## [0.1.0] — never published

Developed in this repository as **InOut**, under the bundle identifier
`com.local.InOut`, and never released. Renamed to Blip before the first public
build. A copy of InOut registered as a login item is not recognised by any Blip
build and should be disabled from the old app before deleting it.
