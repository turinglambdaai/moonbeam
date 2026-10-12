# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

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
  is the M1 milestone.
- The pty has no controlling terminal, so Ctrl-C/SIGWINCH delivery is
  best-effort (mirrors the upstream-ecosystem limitation documented in the
  README).
- `/wake` needs a broadcast-capable network (the NAS deployment case).
