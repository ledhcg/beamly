# Beamly Wire Protocol

Version **1**. This document is normative: the macOS sender (`macos/Sources/BeamlyKit/Protocol.swift`) and the
Android TV receiver (`android/app/src/main/java/app/beamly/tv/net/Protocol.kt`) must both follow it.
Byte-level fixtures live in [`protocol/test-vectors/packets.json`](../protocol/test-vectors/packets.json) and are
checked by both test suites.

The key words MUST, MUST NOT, SHOULD and MAY are used as described in RFC 2119.

## 1. Discovery

- The receiver advertises a DNS-SD service of type `_beamly._tcp` on the local network while its app is in the
  foreground. The instance name is the TV's user-visible device name.
- The default TCP port is `7878`.
- Senders MAY also connect to an address and port entered by the user.

## 2. Transport

- One TCP connection per session. The sender opens it; the receiver accepts.
- The receiver keeps **one active session**. A new connection replaces the active one, but only after the new
  connection has delivered at least one byte (see §4). This prevents parallel connection attempts made by the
  sender's networking stack ("Happy Eyeballs") from tearing down a working session.
- Version 1 is unauthenticated and unencrypted. See [SECURITY.md](../SECURITY.md).

## 3. Framing

Every message is a packet. All integers are big-endian unless stated otherwise.

| Offset | Size | Field | Description |
|-------:|-----:|-------|-------------|
| 0 | 4 | `length` | Payload length in bytes, `0 ≤ length ≤ 33,554,432` (32 MiB) |
| 4 | 1 | `type` | Packet type (§5) |
| 5 | 8 | `ptsMicros` | Presentation timestamp in microseconds, or 0 |
| 13 | `length` | `payload` | Type-specific payload |

- A receiver MUST end the session with a protocol error when `length` is out of range.
- A receiver MUST ignore packets whose `type` it does not know. New features add new types.
- Existing types MUST NOT change meaning or layout without incrementing the protocol version.

## 4. Session lifecycle

1. The sender connects and MUST send `HELLO` as the first packet.
2. The receiver compares `HELLO.protocolVersion` with its own version. If they differ, it MUST end the session
   and SHOULD tell the user to update.
3. The sender streams `CONFIG`, `KEY_FRAME`, `FRAME`, `AUDIO` and `VOLUME` packets.
4. The sender MUST send `PING` at least once per second.
5. To stop, the sender SHOULD send `BYE` and then close the connection.
6. The receiver MUST treat **4 seconds** without any packet as a lost connection. Receivers MUST NOT rely on TCP
   FIN alone: it is not reliably delivered when the sending process exits.

## 5. Packet types

| Type | Name | Payload |
|-----:|------|---------|
| 0 | `CONFIG` | `u16 width, u16 height, u16 spsLength, sps[spsLength], u16 ppsLength, pps[ppsLength]` |
| 1 | `KEY_FRAME` | One H.264 access unit in Annex-B format that contains an IDR picture |
| 2 | `FRAME` | One H.264 access unit in Annex-B format |
| 3 | `AUDIO` | PCM, signed 16-bit little-endian, 48,000 Hz, 2 channels, interleaved |
| 4 | `BYE` | Empty |
| 5 | `PING` | Empty |
| 6 | `HELLO` | `u16 protocolVersion`, then the sender's device name as UTF-8 (no terminator) |
| 7 | `VOLUME` | `f32 volume, f32 gain, u8 muted` (IEEE 754 single precision, big-endian) |

### Video (`CONFIG`, `KEY_FRAME`, `FRAME`)

- H.264 High profile or lower, no B-frames (frames are decoded in transmission order).
- The sender MUST send `CONFIG` before the first `KEY_FRAME` and SHOULD repeat it before every key frame.
  A receiver MAY recreate its decoder when the configuration changes.
- `sps` and `pps` are raw NAL units without start codes.
- The sender MUST send a key frame at least every 2 seconds, so a receiver that drops frames or recreates its
  decoder recovers quickly.
- `ptsMicros` is the sender's capture time. Receivers MUST NOT use it as a display deadline; frames are rendered
  as soon as they are decoded.
- Video frames are only sent when the screen changes. Silence on the video channel is not an error.

### Audio (`AUDIO`)

- The format is fixed for protocol version 1. Packet sizes vary (typically 10–25 ms of audio).
- Receivers SHOULD bound their playback queue and drop the oldest audio when it grows beyond ~120 ms, to absorb
  clock drift between the two devices without accumulating latency.

### Volume (`VOLUME`)

- `volume` is the position of the sender's volume slider in `[0, 1]`, for display.
- `gain` is the linear amplitude factor in `[0, 1]` that reproduces the sender's loudness curve; receivers apply
  it to playback. Values outside `[0, 1]` MUST be clamped.
- When `muted` is non-zero the receiver MUST play silence regardless of `gain`.
- The sender sends `VOLUME` once after connecting and again whenever the volume, mute state or default output
  device changes. Receivers SHOULD show a volume indicator for changes after the first one.

## 6. Versioning

| Version | Changes |
|--------:|---------|
| 1 | Initial version: framing, types 0–7, version field in `HELLO`, service type `_beamly._tcp`. |

## 7. Changing the protocol

1. Update this document, including the version table.
2. Update `protocol/generate_test_vectors.py` and regenerate `protocol/test-vectors/packets.json`.
3. Update both implementations and their tests in the same pull request.
