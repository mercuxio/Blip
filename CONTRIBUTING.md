# Contributing to Blip

## Building and testing

```bash
make build
make test
```

The Makefile exports `DEVELOPER_DIR`, and that is the whole reason the project
builds without Xcode project files. Pointed at a full Xcode, `swift build` uses
the default build system; without it SwiftPM picks up the Command Line Tools
toolchain, which cannot find SwiftUI and needs the deprecated
`--build-system native` flag instead.

The default points at `/Applications/Xcode-beta.app`. If your Xcode is
elsewhere, set the variable rather than editing the file:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test
```

Calling `swift test` directly works only if you export it yourself first.

**Swift 6.2 or newer is required.** `NetworkMonitor` uses `isolated deinit`
(SE-0371), which arrived in 6.2. On an older toolchain the compiler accepts the
`isolated` keyword and then rejects the body, complaining that main-actor
properties cannot be referenced from a nonisolated context — an error that names
the properties and never mentions your Swift version.

There are no package dependencies, and there should not be any. `swift-testing`
comes from the toolchain, not from SPM.

## Where the logic goes

`BlipCore` holds everything decidable, as pure functions over values, and it is
where the tests live. The `Blip` target is a SwiftUI shim that should contain no
logic worth asserting.

`AppInfo` shows why this split earns its keep: a `swift test` process has no
Info.plist, so `Bundle.main` returns nothing for every key. Reading the bundle
inside the view would have made the missing-field behaviour untestable in
exactly the environment where it happens. Splitting it into a pure function over
optionals plus a one-line bundle read made both halves checkable.

`CBlip` exists because `if_data64` and the nested unions in libproc's structures
do not import cleanly into Swift. Keep it to the smallest possible shim.

## The counter source is not an implementation detail

Byte counts come from `sysctl net.link.generic.ifdata.<row>.general`
(`IFMIB_IFDATA`), which returns true 64-bit values. The obvious alternative,
`NET_RT_IFLIST2`, is 32-bit-truncated and floored to 1 KiB on current macOS, so
it silently wraps on a busy interface and rounds away small transfers.

`iflist2` is still read once at launch, only to cross-check `ifmib`. If the two
agree exactly on 1 KiB boundaries, `ifmib` is being sanitized too and the panel
says **Approximate**. That check looks redundant and is not — deleting it would
turn a visible warning into wrong numbers presented as right.

## Packaging

`make zip` uses `ditto`, never `zip`. Part of a bundle's code signature lives in
extended attributes, which `zip` drops; the unzipped copy then fails signature
validation and is killed on launch. That failure never reproduces on the machine
that built it, only on the downloader's.

The bundle is ad-hoc signed (`codesign -s -`). This satisfies the hardened
runtime, which would otherwise kill an unsigned SwiftUI app on Apple silicon,
but it is not notarization: downloads are quarantined until the user clears the
flag. See the README.

SwiftPM builds for the host architecture only. A release built on Apple silicon
is arm64-only — check with `lipo -archs` before claiming otherwise.

## The network boundary

`https://api.ipify.org` (and `api6.ipify.org` for IPv6) is the only thing this
app ever contacts. Nothing is sent with the request and nothing is logged.

The gate is that the panel must have been opened at least once. Before that
Blip issues no request at all — not at launch, not on a timer, not on a network
change. After it, the lookup is allowed to run unattended: on a change of
primary interface, and on a failure backoff starting at 15 seconds, doubling to
a 15-minute ceiling. Both are deliberate. Waking races the interface coming
back up, so the first attempt after a wake routinely fails on a network that is
healthy two seconds later; and `PanelView`'s `onAppear` is not guaranteed to
fire on every panel open — the hosting controller outlives any one open — so
there is no reliable "next open" to defer the re-ask to.

Any change that adds an endpoint, that fetches before the first panel open, or
that tightens the backoff, needs to be argued for in the pull request rather
than slipped in.
