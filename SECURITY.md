# Security Policy

## Supported versions

Beamly is pre-1.0. Only the latest release receives security fixes.

| Version | Supported |
|---------|-----------|
| Latest release | ✅ |
| Older releases | ❌ |

## Current security model

Please read this before reporting: the following are **known limitations**, tracked in the
[roadmap](docs/OPEN_SOURCE_PLAN.md#phase-5--security-and-privacy-hardening-blocks-10), not vulnerabilities.

- **No authentication.** While the Beamly app is open on a TV, any device on the same local network can connect to
  port 7878 and display content on it.
- **No encryption.** Screen contents and audio are sent in clear text on the local network.
- Beamly sends nothing outside the local network and has no telemetry.

Reports that show impact beyond these limitations are very welcome, for example: crashes or memory corruption
from malformed packets, code execution, privilege escalation, permission bypasses on macOS, audio left muted, or
leaks of data the user did not choose to share.

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
