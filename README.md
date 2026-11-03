# Zapper

*Formerly MiRemote.*

Control any Google TV or Android TV (Chromecast with Google TV, Xiaomi Mi Box /
Mi TV, Sony, TCL, Philips, Hisense, Nvidia Shield…) from macOS — menu bar app
plus a CLI for testing each layer.

Protocol details were recovered from a decompilation of the
`com.osfunapps.remoteformibox` Android app; inline comments cite the original
class names.

## Status

| Layer | State |
|---|---|
| mDNS discovery (`_androidtvremote2._tcp`) | done |
| Client certificate + Keychain identity | done |
| TLS with client auth + permissive/pinned verify | done |
| Wake-on-LAN | done |
| Varint length-delimited framing | done |
| Multi-brand adapter protocol | done |
| Menu bar app + global hotkey | done |
| MAC recovery from IPv6 link-local (EUI-64) | done |
| Menu bar GUI (built, running) | done |
| Client certificate via openssl + SecPKCS12Import | done |
| Protobuf message types | **not included** — see `PROTOBUF.md` |

### Verified against real hardware (2026-08-18)

Three Xiaomi TVs on this network, all the same platform (`MiTV-MSSP3`,
codename `machuca`) despite the naming:

| Device | MAC | 6467 pairing | 6466 remote |
|---|---|---|---|
| MDR-MITV-03 | b4:c9:b9:80:b7:96 | OK | OK |
| LG-MITV-02  | b4:c9:b9:80:8e:1c | OK | OK |
| MDR-MITV-05 | b4:c9:b9:80:f9:84 | OK | OK |

All negotiate `TLSv1.2, ECDHE-RSA-AES128-GCM-SHA256` and accept our
self-signed client certificate. Discovery returns names, ports and MACs for
all three. All 16 logic checks pass.

**The device certificate MAC is always the Wi-Fi MAC + 1** (the Bluetooth
MAC): `...b7:96 -> B7:97`, `...8e:1c -> 8E:1D`, `...f9:84 -> F9:85`.
Consistent across all three, which independently confirms the EUI-64
derivation in `MACAddress.swift`.

**Wake-on-LAN sends to two addresses.** Verified by binding a UDP listener on
6466 and capturing the packet: a datagram sent to `255.255.255.255` is
delivered to local sockets, one sent to the directed subnet broadcast
(`192.168.21.255`) is not — so there is no way to confirm locally that the
directed send left the machine. `WakeOnLAN.wake` therefore sends to both. The
captured packet is byte-identical to the expected 102-byte magic packet.

**Certificate subject format varies by firmware.** Two devices use

    CN=atvremote/machuca/machuca/MiTV-MSSP3/B4:C9:B9:80:B7:97

while the third splits it:

    dnQualifier=machuca/machuca/MiTV-MSSP3, CN=atvremote/B4:C9:B9:80:F9:85

Never parse the server certificate subject to identify a device — use the
mDNS instance name. We do not verify or parse it at all.

### Network quirk on these devices

The Mi TVs publish **no IPv4 A record** and both share the mDNS hostname
`Android.local.`, so discovery only ever yields IPv6 link-local addresses and
they never appear in the ARP cache. `MACAddress.fromIPv6LinkLocal` recovers the
hardware MAC from the EUI-64 interface identifier instead:

    fe80::b6c9:b9ff:fe80:f984%en0  ->  b4:c9:b9:80:f9:84

Wake-on-LAN is a broadcast, so it needs only that MAC plus this Mac's own
subnet broadcast (`MACAddress.localBroadcastAddress()`).

`pair()` and `connect()` throw `.notImplemented` until the protobuf types are
generated. Discovery, wake, and the TLS probe work without them — and wake is
the feature you actually wanted most.

## Quick start

```bash
./Scripts/make-app.sh
open build/Zapper.app        # menu bar app — look for the TV icon
./build/zapper discover      # CLI
```

**No external dependencies.** The client certificate is minted once with
`openssl` and imported via `SecPKCS12Import`, rather than pulling in
swift-certificates + swift-crypto + BoringSSL for a one-time operation. That
also means the build works without SwiftPM, which matters here (see Toolchain).

## Requirements

macOS 13+, Swift 6.

> **Fix the toolchain first.**
> `/Library/Developer/CommandLineTools/usr/include/swift/` contains two
> modulemaps that both define module `SwiftBridging`:
> `module.modulemap` (stale, Aug 2023) and `bridging.modulemap` (current,
> Apr 2025). The duplicate makes every `import Foundation` fail, so nothing
> compiles — not even Apple's own `swift package init` template.
>
> ```bash
> sudo mv /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap \
>         /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap.disabled
> ```
>
> **Second, stale `.private.swiftinterface` files break SwiftPM.** Four files
> dated Feb 2024 sit beside Apr 2025 siblings; swiftc prefers the private one,
> compiles against the old `Package.init` signature, and the linker then can't
> find that symbol in the current dylib.
>
> ```bash
> sudo find /Library/Developer/CommandLineTools/usr/lib/swift/pm \
>      -name "*.private.swiftinterface" -exec mv {} {}.disabled \;
> ```
>
> Both are stale leftovers from a CLT upgrade over an old install. If SwiftPM
> still errors, reinstall cleanly:
> `sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install`

## The menu bar app

```bash
./Scripts/make-app.sh          # builds build/Zapper.app and build/zapper
open build/Zapper.app
```

The script exists because a `MenuBarExtra` app needs a real bundle with
`LSUIElement=1` to appear in the menu bar at all — `swift run` gives you a bare
executable with no `Info.plist`. It also writes `NSBonjourServices` and
`NSLocalNetworkUsageDescription`, which macOS requires before it will let the
app browse mDNS, and ad-hoc signs so the Local Network prompt appears. No Xcode
required.

The menu contains a device picker, a **Turn on TV** button, a D-pad with volume
and navigation, Discover, and Test connection. The D-pad will report
`notImplemented` until the protobuf types are generated; everything else works.

Global hotkey: **⌃⌥⌘T** turns the TV on from anywhere.

Ordinary hotkeys use Carbon's `RegisterEventHotKey` and need **no** special
permission. Only intercepting the *media* keys (F7/F8/F9) would require
`CGEventTap` plus Accessibility permission — not wired up yet.

## The CLI

```bash
swift run zapper discover           # find devices on the LAN
swift run zapper probe 192.168.1.x  # TLS handshake against port 6467
swift run zapper wake aa:bb:cc:dd:ee:ff
swift run zapper identity           # create / show the client certificate
swift test                            # unit tests, no network needed
```

`probe` is the milestone: if the handshake succeeds, cert generation, Keychain
identity, and TLS client auth all work, and everything left is message parsing.

## Turning on the TV

The Mi Box is a *source* device — it has no HDMI inputs and cannot switch your
TV's input. The Android app solves this with the phone's IR blaster, which a
Mac doesn't have.

Use **HDMI-CEC** instead: when the box wakes it sends a CEC "One Touch Play",
which powers the TV on *and* switches it to the box's input. Enable CEC on the
TV first — Samsung *Anynet+*, LG *SimpLink*, Sony *Bravia Sync*, Xiaomi/TCL
just *CEC*. It's usually off by default.

Test it with the physical remote before writing any more code.

## Layout

```
Sources/ATVKit/          protocol core (no UI)
  Models.swift           Device, RemoteCommand, AdapterKind, WakeProfile
  Identity.swift         RSA keypair -> self-signed cert -> Keychain -> SecIdentity
  Transport.swift        NWParameters with client auth + verify block
  Discovery.swift        NWBrowser mDNS + ARP MAC lookup
  Wake.swift             magic packet, port 6466, 500 ms settle
  Framing.swift          varint length-delimited framing
  DeviceAdapter.swift    the per-brand protocol
  AndroidTVAdapter.swift Android TV v2

Sources/ZapperApp/       SwiftUI menu bar app
Sources/zapper/          CLI
Scripts/make-app.sh      bundles the .app without Xcode
```

## Next steps

1. Fix the toolchain, run `swift test`
2. `zapper discover`, then `zapper probe <ip>`
3. Generate protobuf types (`PROTOBUF.md`), implement `pair()` / `connect()`
4. Tailscale for control from outside the LAN
5. Second adapter — Tizen / webOS / Bravia / SmartCast

## Testing the TLS layer without Swift

Useful when something stops working and you want to know whether it's your code
or the network. Note the escaped slashes — openssl treats `/` in `-subj` as a
field separator:

```bash
openssl req -x509 -newkey rsa:2048 -keyout k.pem -out c.pem -days 3650 -nodes \
  -subj "/CN=atvremote\/MacBookPro\/MacBookPro\/MacBookPro18_3\/$(uuidgen)"

openssl s_client -connect "[fe80::...%en0]:6467" -cert c.pem -key k.pem -tls1_2
```

A successful handshake plus `Verify return code: 18 (self-signed certificate)`
is the expected, healthy result.
