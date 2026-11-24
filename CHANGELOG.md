# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Pairing: the first connection between a Mac and a TV shows the same 6-digit code on both screens; both users
  confirm it. The TV lists paired Macs and can forget them; the Mac can forget paired TVs (menu or
  `beamly --forget-tvs`).
- `beamly --name` sets the name shown on the TV.
- README screenshots.
- End-to-end encryption: authenticated key exchange and AES-256-GCM for every packet.

### Changed

- **Wire protocol version 2.** Mac and TV apps must be updated together.

### Security

- A TV only accepts streams from Macs its user paired with; streams can no longer be watched or injected on the
  local network.

## [0.9.0] - 2026-11-24

First version prepared for open source.

### Added

- Screen and system audio mirroring from macOS to Android TV over the local network.
- Menu bar app with TV discovery, quality, frame rate, display and audio settings, and "Open at Login".
- `beamly` command-line sender.
- "Play Sound Only on TV": a muted Core Audio process tap keeps the Mac silent while the Mac's volume keys
  control the TV, with an on-screen volume indicator.
- Compose for TV receiver with waiting, connecting, streaming and error screens, English and Vietnamese UI.
- Wire protocol version 1 with a version field in `HELLO`, shared test vectors and a written specification.

### Changed

- Project renamed from Mac2TV to Beamly; the TV advertises `_beamly._tcp`. Existing installs keep their
  permissions because the bundle and application identifiers are unchanged.

### Fixed

- The TV no longer drops a working session when the Mac opens parallel connections (Happy Eyeballs).
- The TV detects a Mac that disappeared without closing the connection (heartbeat timeout).

[Unreleased]: https://github.com/ledhcg/beamly/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/ledhcg/beamly/releases/tag/v0.9.0
