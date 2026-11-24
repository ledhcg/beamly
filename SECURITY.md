# Security Policy

## Supported versions

Beamly is pre-1.0. Only the latest release receives security fixes.

| Version | Supported |
|---------|-----------|
| Latest release | ✅ |
| Older releases | ❌ |

## Current security model

Beamly protects the stream between a Mac and a TV on the same local network (protocol version 2, see
[docs/PROTOCOL.md](docs/PROTOCOL.md#2-security-model)):

- **Mutual authentication.** Both devices have a long-term P-256 identity key. A TV only accepts Macs its user paired
  with, and a Mac only streams to TVs its user paired with. Pairing compares a 6-digit code on both screens; a
  network attacker succeeds with probability 10⁻⁶ per attempt, and every attempt must be approved on both devices.
- **Confidentiality and integrity.** Every session derives fresh keys (ephemeral ECDH, HKDF-SHA256) and encrypts
  every packet with AES-256-GCM. Tampered, replayed or reordered records end the session.
- **Forward secrecy.** Recorded sessions stay confidential if an identity key leaks later.
- **Local only.** Beamly sends nothing outside the local network and has no telemetry.

Known limitations (not vulnerabilities):

- Identity keys are stored as files readable by the owning account (Mac) or the app (TV), not in a hardware
  keystore. Anyone who controls your account or the TV app's storage can impersonate that device.
- An attacker on the network can see that a Beamly session takes place and can disrupt it (denial of service).
- Pairing security relies on users actually comparing the codes.

Reports of anything beyond these limitations are very welcome, for example: bypassing pairing, decrypting or
injecting traffic, crashes or memory corruption from malformed packets, code execution, privilege escalation,
permission bypasses on macOS, audio left muted, or leaks of data the user did not choose to share.

## Reporting a vulnerability

**Do not open a public issue.** Use GitHub's private vulnerability reporting:
**Security → Report a vulnerability** on the repository page.

Please include the affected version, platform, reproduction steps or a proof of concept, and the impact you
observed.

## What to expect

| Step | Target time |
|------|-------------|
| Acknowledgement | 3 business days |
| Initial assessment | 10 business days |
| Fix or mitigation for confirmed issues | 90 days, coordinated with the reporter |

We credit reporters in the release notes unless they prefer to stay anonymous.
