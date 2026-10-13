# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added — M2 (first slice): the desktop-view lane

- Host `setup` command: detects Apollo/Sunshine and Moonlight installs,
  verifies the upstream apps config (parses apps.json, reports Desktop
  entry), and prints a deterministic JSON status. Opt-in `--install` carries
  the platform install command (macOS: LizardByte homebrew cask; Linux:
  apt/flatpak). Apollo stays a manual download from its GitHub releases.
- Client `view` command: builds a launch plan for the desktop-view lane —
  resolves the host's LAN address from the pairing entry, detects the local
  Moonlight (qt or embedded), and prints the plan as JSON; `--go` launches
  the stream (office-grade, via the upstream Moonlight client).
- Requires a LAN path for now (pair once on the LAN); relayed desktop view
  lands with the M2 direct-path rungs (IPv6, UDP hole-punching). GUI shells
  are the second half of M2.

### Added — M1: the text lane, anywhere

- Relay splice tunnel: the host and the client both dial OUT to the relay,
  which welds their connections into one dumb byte pipe — no port forwarding,
  works behind any NAT that allows outbound TCP. A framed GO handshake keeps
  the host from racing the relay for the first bytes.
- Client routing ladder: stored LAN address first under a hard 1.5 s deadline
  (connect + handshake), relay tunnel as fallback. Pairing works through the
  relay too (`moonbeam pair --via`).
- Detachable terminal sessions: `bye` or a dropped connection leaves the
  shell running; `sh --resume <id>` reattaches with the environment intact
  (断线继承, benchmarked against UU Remote).
- Host uplink pool with automatic reconnect; the host advertises relay
  reachability through `/lookup`.

### Known M1 limits

- Tunnel traffic is token-authenticated but not yet encrypted — end-to-end
  TLS is the next hardening step.
- UDP hole-punching is deferred to M2, together with the video stack that
  makes it worth the complexity; until then the text lane rides the relay
  (kilobits, not megabits) and direct IPv6 works wherever both ends have it.

### Added — M0: the text lane on the LAN

- Frame protocol (`proto`): versioned, length-prefixed frames — JSON control
  messages plus raw data frames for terminal IO and file chunks.
- Host daemon (`host`): PIN pairing with a persisted token (0600), `exec` with
  deterministic JSON verdicts and honest exit codes, terminal sessions over a
  pipe or a real pseudo-terminal (posix_openpt, no in-process fork), and file
  put/get with SHA-1 verification. macOS and Linux; Windows host is M1+.
- Client CLI (`client`): `pair`, `run` (the agent workhorse), `sh`
  (`--command` for agents, interactive passthrough for humans), `put`, `get`.
- Relay server (`relay`): `/health`, `/register`, `/lookup` signaling and
  `/wake` with raw-socket SO_BROADCAST wake-on-LAN, shared-token auth;
  dependency-free single-file HTTP, with a Dockerfile for NAS deployment.
- Tests: unit coverage for protocol and WoL packets, a loopback end-to-end
  suite (pairing, exec, terminal, file round-trip, relay endpoints, auth
  rejection) and a pty TTY sanity check. CI on macOS, Ubuntu and Windows
  (host/pty pieces self-skip on Windows).

### Known M0 limits

- LAN only: external-network access (UDP hole-punching with relay fallback)
  is the M1 milestone. [Shipped in M1 as the relay splice tunnel; UDP
  hole-punching itself moved to M2 — see above.]
- The pty has no controlling terminal, so Ctrl-C/SIGWINCH delivery is
  best-effort (mirrors the upstream-ecosystem limitation documented in the
  README).
- `/wake` needs a broadcast-capable network (the NAS deployment case).
