# Generating the protobuf message types

Everything in this package works **except** the protobuf message exchange.
That gap is deliberate: the Android TV remote v2 schema is not published by
Google, and writing field numbers from memory would cost you days of debugging
a schema that was never real. Take them from a working implementation instead.

## Sources

- **tronikos/androidtvremote2** (Python) — the library Home Assistant's
  Android TV Remote integration depends on. Ships `.proto` files for both the
  pairing (6467) and remote (6466) message sets.
- **louis49/androidtv-remote** (Node) — independent implementation of the same
  protocol, useful as a cross-check when a message doesn't parse.

## Steps

```bash
brew install swift-protobuf protobuf     # or build swift-protobuf from source
protoc --swift_out=Sources/ATVKit/Generated pairing.proto remote.proto
```

Then add to `Package.swift`:

```swift
.package(url: "https://github.com/apple/swift-protobuf.git", from: "1.25.0"),
// and in the ATVKit target:
.product(name: "SwiftProtobuf", package: "swift-protobuf"),
```

## Wiring it up

Both ports use the same framing, already implemented in `Framing.swift`:

```swift
// send
let payload = try message.serializedData()
connection.send(content: MessageFramer.frame(payload), completion: .idempotent)

// receive
var framer = MessageFramer()
for message in framer.append(receivedBytes) {
    let decoded = try PairingMessage(serializedBytes: message)
}
```

## Pairing sequence (port 6467)

1. `PairingRequest` — service name + client name
2. `PairingOption` — encoding hex, symbol length 6
3. `PairingConfiguration`
4. Device displays a 6-digit code
5. `PairingSecret` — the code hashed against both certificates' public keys
   (SHA-256 over client modulus + exponent, server modulus + exponent, and the
   code's trailing nibbles)
6. Device confirms; your certificate is trusted permanently

Fill in `AndroidTVAdapter.pair(_:pinProvider:)`. `probe()` already proves the
TLS layer beneath it works, so any failure from here is message-level.

## Remote session (port 6466)

Reconnect on 6466 with the same identity. The device sends configuration and
periodic pings you must answer, then accepts key events. Fill in
`AndroidTVAdapter.connect(_:)` returning a `DeviceSession`.
