# Beamly Wire Protocol

Version **2**. This document is normative: the macOS sender (`macos/Sources/BeamlyKit/`) and the Android TV
receiver (`android/app/src/main/java/app/beamly/tv/net/`) must both follow it. Byte-level fixtures live in
[`protocol/test-vectors/`](../protocol/test-vectors) and are checked by both test suites.

The key words MUST, MUST NOT, SHOULD and MAY are used as described in RFC 2119.

## 1. Discovery

- The receiver advertises a DNS-SD service of type `_beamly._tcp` on the local network while its app is in the
  foreground. The instance name is the TV's user-visible device name.
- The default TCP port is `7878`.
- Senders MAY also connect to an address and port entered by the user.

## 2. Security model

- Every device has a long-term **identity key**: an ECDH key pair on NIST P-256. Public keys are encoded as
  65-byte uncompressed points (`0x04 || X || Y`, SEC 1 / X9.63).
- A receiver only accepts media from senders it has **paired** with, and a sender only streams to receivers it
  has paired with. Pairing compares a 6-digit code on both screens (§6).
- Every session derives fresh keys from the identity keys and per-session **ephemeral keys** (§7): both peers are
  authenticated, and recorded traffic stays confidential if identity keys leak later (forward secrecy).
- After the handshake, every packet — media, audio, volume and heartbeats, including their type — is encrypted
  and authenticated with AES-256-GCM (§8).

Out of scope: a compromised device; denial of service by flooding (an attacker can always disrupt a LAN);
hiding the fact that a Beamly session takes place.

## 3. Transport

- One TCP connection per session. The sender opens it; the receiver accepts.
- The receiver keeps **one active session**. A new connection replaces the active one only after the new
  connection has delivered at least one byte, so parallel connection attempts by the sender's networking stack
  ("Happy Eyeballs") cannot tear down a working session.

## 4. Framing

### 4.1 Plaintext packets (handshake only)

All integers are big-endian unless stated otherwise.

| Offset | Size | Field | Description |
|-------:|-----:|-------|-------------|
| 0 | 4 | `length` | Payload length in bytes, `0 ≤ length ≤ 33,554,432` (32 MiB) |
| 4 | 1 | `type` | Packet type (§5) |
| 5 | 8 | `ptsMicros` | Presentation timestamp in microseconds, or 0 |
| 13 | `length` | `payload` | Type-specific payload |

### 4.2 Encrypted records (after `SESSION_START`)

| Offset | Size | Field |
|-------:|-----:|-------|
| 0 | 4 | `length` of `ciphertext`, `16 ≤ length ≤ 33,554,432 + 25` |
| 4 | `length` | `ciphertext`: AES-256-GCM of `u8 type, u64 ptsMicros, payload`, followed by the 16-byte tag |

- Each direction has its own key (§7) and a 64-bit record counter starting at 0. The 12-byte GCM nonce is
  `0x00000000 || counter` (big-endian). Counters MUST NOT wrap; there is no additional authenticated data.
- A record that fails authentication MUST end the session.

### 4.3 General rules

- A receiver MUST end the session with a protocol error when a length is out of range.
- After the handshake, receivers MUST ignore packet types they do not know. New features add new types.
- Existing types MUST NOT change meaning or layout without incrementing the protocol version.

## 5. Packet types

| Type | Name | Direction | Phase | Payload |
|-----:|------|-----------|-------|---------|
| 0 | `CONFIG` | Mac → TV | encrypted | `u16 width, u16 height, u16 spsLength, sps, u16 ppsLength, pps` |
| 1 | `KEY_FRAME` | Mac → TV | encrypted | One H.264 access unit (Annex-B) containing an IDR picture |
| 2 | `FRAME` | Mac → TV | encrypted | One H.264 access unit (Annex-B) |
| 3 | `AUDIO` | Mac → TV | encrypted | PCM, signed 16-bit little-endian, 48,000 Hz, 2 channels, interleaved |
| 4 | `BYE` | Mac → TV | encrypted | Empty |
| 5 | `PING` | Mac → TV | either | Empty |
| 6 | `HELLO` | Mac → TV | plaintext | `u16 protocolVersion, u8[16] deviceId, u8[65] identityKey, u8[65] ephemeralKey, UTF-8 name` |
| 7 | `VOLUME` | Mac → TV | encrypted | `f32 volume, f32 gain, u8 muted` (IEEE 754, big-endian) |
| 8 | `SERVER_HELLO` | TV → Mac | plaintext | `u8 flags, u8[65] identityKey, u8[65] ephemeralKey, UTF-8 name` |
| 9 | `PAIR_START` | Mac → TV | plaintext | Empty |
| 10 | `PAIR_COMMIT` | TV → Mac | plaintext | `u8[32] commitment` |
| 11 | `PAIR_NONCE` | both | plaintext | `u8[32] nonce` |
| 12 | `PAIR_CONFIRM` | both | plaintext | `u8 accepted` (1 = the user confirmed the code, 0 = rejected) |
| 13 | `SESSION_START` | Mac → TV | plaintext | Empty. The last plaintext packet in both directions |
| 14 | `READY` | TV → Mac | encrypted | Empty. The TV accepted the session |
| 15 | `REJECT` | TV → Mac | plaintext | `u8 reason`: 1 = not paired, 2 = pairing declined, 3 = pairing timed out |

`SERVER_HELLO.flags` bit 0: the TV has this Mac's identity key in its paired list. Other bits are reserved (0).

## 6. Handshake and pairing

```
Mac                                              TV
 HELLO(version, deviceId, IDm, EPm, name)  ───►
                                            ◄─── SERVER_HELLO(flags, IDt, EPt, name)
 ── if the TV does not know IDm, or the Mac does not trust IDt: pairing ──
 PAIR_START                                ───►
                                            ◄─── PAIR_COMMIT(C = HMAC-SHA256(Nt, "beamly-pair-commit" ‖ IDt ‖ IDm))
 PAIR_NONCE(Nm)                            ───►
                                            ◄─── PAIR_NONCE(Nt)
 verify C; both show code(IDm, IDt, Nm, Nt) and ask the user to compare
 PAIR_CONFIRM(1)                           ◄──►  PAIR_CONFIRM(1)
 both store the peer's identity key
 ── end of pairing ──
 SESSION_START                             ───►
 (encrypted from here on, both directions)  ◄─── READY
 CONFIG, KEY_FRAME, AUDIO, VOLUME, PING, …  ───►
```

1. The sender MUST send `HELLO` first. If `protocolVersion` differs from its own, the receiver MUST end the
   session and SHOULD tell the user to update.
2. The receiver answers with `SERVER_HELLO`.
3. If the receiver does not know the sender's identity key **or** the sender does not trust the receiver's identity
   key, the sender starts pairing with `PAIR_START`. Otherwise it sends `SESSION_START`.
4. Pairing (*numeric comparison*, as in Bluetooth Secure Simple Pairing):
   - The receiver picks a random 32-byte `Nt` and sends the commitment `C` before it sees `Nm`, so an attacker in
     the middle cannot choose its nonce after seeing the other side's.
   - The sender sends a random 32-byte `Nm`; the receiver replies with `Nt`; the sender MUST verify `C`.
   - Both compute `code = uint32(SHA-256("beamly-pair-code" ‖ IDm ‖ IDt ‖ Nm ‖ Nt)[0..4]) mod 1,000,000`,
     shown as six digits, and ask their user to confirm that both screens show the same code.
   - Each side sends `PAIR_CONFIRM` with its user's answer. Pairing succeeds only when **both** sides accepted;
     then each stores the peer's identity key. An attacker in the middle succeeds with probability 10⁻⁶ per
     attempt, and every attempt requires the user to approve a code on both screens.
   - The receiver MUST give up after 120 seconds and send `REJECT(3)`; a declined pairing sends `REJECT(2)`.
5. On `SESSION_START`, the receiver MUST send `REJECT(1)` and close unless the sender's identity key is paired.
   Both sides derive the session keys (§7). The receiver sends an encrypted `READY`; the sender starts streaming
   only after receiving it.
6. `PING` MAY be sent in plaintext during the handshake (pairing waits for users) and is encrypted afterwards.

Strings in the formulas are ASCII without terminator; `‖` is concatenation.

## 7. Session keys

```
ss1 = ECDH(EPm, EPt)          # ephemeral – ephemeral
ss2 = ECDH(IDm, EPt)          # authenticates the Mac
ss3 = ECDH(EPm, IDt)          # authenticates the TV
salt = SHA-256(HELLO payload ‖ SERVER_HELLO payload)
okm  = HKDF-SHA256(ikm = ss1 ‖ ss2 ‖ ss3, salt, info = "beamly v2 session", length = 64)
keyMacToTv = okm[0..32],  keyTvToMac = okm[32..64]
```

ECDH outputs are the 32-byte X coordinate of the shared point. Ephemeral keys MUST be fresh for every
connection and discarded when it ends.

## 8. Session lifecycle

1. The sender MUST send `PING` at least once per second.
2. To stop, the sender SHOULD send `BYE` and then close the connection.
3. The receiver MUST treat **4 seconds** without any packet as a lost connection. Receivers MUST NOT rely on TCP
   FIN alone: it is not reliably delivered when the sending process exits.

## 9. Media

### Video (`CONFIG`, `KEY_FRAME`, `FRAME`)

- H.264 High profile or lower, no B-frames (frames are decoded in transmission order).
- The sender MUST send `CONFIG` before the first `KEY_FRAME` and SHOULD repeat it before every key frame.
  A receiver MAY recreate its decoder when the configuration changes.
- `sps` and `pps` are raw NAL units without start codes.
- The sender MUST send a key frame at least every 2 seconds.
- `ptsMicros` is the sender's capture time. Receivers MUST NOT use it as a display deadline.
- Video frames are only sent when the screen changes. Silence on the video channel is not an error.

### Audio (`AUDIO`)

- The format is fixed. Packet sizes vary (typically 10–25 ms of audio).
- Receivers SHOULD bound their playback queue and drop the oldest audio when it exceeds ~120 ms.

### Volume (`VOLUME`)

- `volume` is the sender's volume slider position in `[0, 1]`, for display.
- `gain` is the linear amplitude factor in `[0, 1]` that reproduces the sender's loudness curve. Values outside
  `[0, 1]` MUST be clamped. When `muted` is non-zero the receiver MUST play silence.
- Sent once after the session starts and whenever the volume, mute state or output device changes.

## 10. Versioning

| Version | Changes |
|--------:|---------|
| 1 | Initial version: plaintext framing, types 0–7, version field in `HELLO`, service type `_beamly._tcp`. |
| 2 | Identity keys, pairing by numeric comparison, authenticated key exchange, AES-256-GCM records; types 8–15; new `HELLO` layout. |

## 11. Changing the protocol

1. Update this document, including the version table.
2. Update the fixture generators in `protocol/` and regenerate `protocol/test-vectors/`.
3. Update both implementations and their tests in the same pull request.
