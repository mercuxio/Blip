# Blip

A macOS menu bar network monitor. It shows how fast bytes are moving in and out
of your active network interface, and how many have moved this session.

No Dock icon, no window, no account, no telemetry. One line in the menu bar and
a panel when you click it.

Requires macOS 14 (Sonoma) or later. The prebuilt download is Apple silicon
only; on an Intel Mac, build from source — it compiles natively for whatever
machine you build on.

## Install

**Download the release.** Grab `Blip.app.zip` from
[Releases](https://github.com/mercuxio/Blip/releases), unzip it, and drag
`Blip.app` to `/Applications`.

The app is ad-hoc signed, not notarized — I don't pay for an Apple Developer
account. macOS quarantines anything downloaded from the internet that isn't
notarized, so the first launch will be refused with "Blip is damaged and can't
be opened" or "cannot be verified". Clear the quarantine flag once:

```bash
xattr -dr com.apple.quarantine /Applications/Blip.app
```

Then open it normally. If you'd rather not run that on a stranger's binary —
reasonable — build it yourself; it takes about ten seconds.

**Build from source.** Needs Xcode 16 or later installed (not just the Command
Line Tools — SwiftUI's module map isn't in the CLT toolchain).

```bash
git clone https://github.com/mercuxio/Blip.git && cd Blip && make install
```

That builds a release binary, assembles the `.app` bundle, ad-hoc signs it, and
copies it to `/Applications`. `make run` builds and launches without
installing; `make uninstall` removes it. If your Xcode lives somewhere other
than `/Applications/Xcode-beta.app`, override it:

```bash
make install DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## Using it

The menu bar item has two styles, switchable from the gear menu:

- **Rates** — upload above, download below, with arrows. The width is fixed to
  the widest string it can produce, so it never shoves your other menu bar
  items sideways as the numbers change.
- **Sparkline** — a 60-second graph of combined throughput.

Click it for the panel: session totals, the active interface and its local
address, and your public IP (looked up on demand — see Privacy below).

The gear menu also holds:

- **Measure** — *Primary interface* (whatever macOS is currently routing
  through) or *All physical interfaces* summed. Both exclude tunnels and
  bridges, so VPN traffic is counted once, on the NIC underneath, rather than
  twice.
- **Start at login** — registered through `SMAppService`, so it survives moving
  the app around; the toggle reflects what the system actually did, not what
  was asked.
- The app name and version, at the bottom, for when you need to say which
  build you are on.

Beside the gear sit three buttons: reset session totals, buy me a coffee, and
quit.

## How it measures

Counters come from `sysctl net.link.generic.ifdata.<row>.general`
(`IFMIB_IFDATA`), which returns true 64-bit byte counts — verified against
`netstat -ib` to the byte.

The more commonly used `NET_RT_IFLIST2` path is *not* the primary source: on
current macOS it returns values truncated to 32 bits and floored to a 1 KiB
multiple, despite declaring a 64-bit field. Blip reads it once at launch only
to cross-check that `ifmib` hasn't started being sanitized the same way. If it
has, the panel says "Approximate" rather than quietly reporting a fraction of
reality.

Polling is 1 Hz. The process registers zero idle wakeups — macOS coalesces the
timer, so it never spins up an idle core.

## Privacy

Everything except one thing is local. That thing: the **public IP** row queries
`api.ipify.org` (or `api6.ipify.org` for IPv6). It runs when you open the panel
and when you press refresh — never in the background. Any service that tells
you your public IP necessarily sees your public IP; if you'd rather it didn't,
just don't open that row.

Nothing else leaves the machine. There is no analytics, no crash reporting, and
no update check.

## Development

```bash
make build   # swift build -c release
make test    # 25 tests, 5 suites
make app     # assemble .build/Blip.app
make icon    # regenerate Resources/AppIcon.icns from Tools/GenerateIcon.swift
```

The layout is deliberate:

- `Sources/CBlip` — C shim for the sysctl calls. The structs involved
  (`if_data64` and friends) don't import cleanly into Swift.
- `Sources/BlipCore` — everything worth testing, as pure functions where
  possible: counter reading, rate derivation, interface selection, formatting.
- `Sources/Blip` — a thin SwiftUI layer over that. `MenuBarExtra(.window)`.

## License

MIT. See [LICENSE](LICENSE). Use it for whatever you like.

If it's useful to you, [a coffee](https://buymeacoffee.com/benjamintan) is
always welcome — entirely optional.
