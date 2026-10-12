# Moonbeam

**Self-hosted remote access for the agent era — your machines, your relay, on all three desktops.**

Moonbeam keeps you — and your agents — connected to your own machines from anywhere: a remote terminal, file transfer and on-demand desktop view over a tunnel you own, with wake-on-LAN and self-hosted signaling/relay. Deploy the server piece on your NAS or any cloud box; the path home never depends on someone else's servers.

[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE) [![built with](https://img.shields.io/badge/built%20with-Racket-9F1D35)](https://racket-lang.org/) ![platform](https://img.shields.io/badge/platform-Windows_%7C_macOS_%7C_Linux-lightgrey)

**English** · [中文](README.zh-CN.md)

## Why

The agent era changed where work happens: your code, your jobs and your coding agents run on machines that are somewhere else — at home, at the office, under the desk. What you need is to get back to them instantly: a terminal that survives bad links, files that move without ceremony, a screen to look at when you must, and a machine that wakes when you arrive.

Consumer tools like NetEase's UU Remote prove this experience exists: install, log in, and your PC is simply there. But the whole experience rests on infrastructure you don't own:

- **No self-hosting.** The magic — hole-punching, relay, wake-on-LAN signaling — lives on the vendor's servers. It is a free product you cannot own: its rules and limits are not negotiable, which platforms get a client is not your call, and its continued existence is not under your control.

Moonbeam is that experience, taken back: a control plane that runs on hardware you own. Deliberately, it does **not** reinvent the video pipeline — desktop view rides the proven open-source streaming stack (Apollo/Sunshine hosts, Moonlight clients, driven as external processes). Moonbeam owns the rest, and the rest is the product: the tunnel, the terminal lane, file transfer, wake-up, pairing, orchestration.

Gaming is not a design target. The streaming stack delivers it as a side effect; Moonbeam optimizes for the office-and-agent lane — text first, video on demand.

## How it works

Three pieces, one goal: your machines are simply there.

- **Host butler** — a resident daemon on macOS, Windows and Linux: tunnels, terminal sessions, file transfer, wake-on-demand, and on-demand desktop view powered by Apollo/Sunshine (installed and configured for you; upstream maturity differs by platform — e.g. Apollo's virtual display is Windows-only today — stated plainly, never hidden).
- **Client** (macOS, Windows, Linux) — discovers hosts on the LAN, drives the tunnel, and carries the text lane: a remote terminal (multi-session, reconnect-safe, TUI-friendly) and file transfer that stay usable on links too poor for video. When you need eyes, desktop view launches Moonlight clients as external processes.
- **Relay & signaling server** (single binary, Docker) — signaling, hole-punching assistance, a bandwidth-relay fallback, and wake-on-LAN dispatch. Deploy it on your own NAS (an always-on home device can send magic packets directly) or any cloud server. P2P comes first and the relay is only the fallback — and the text lane barely touches it: a terminal session costs kilobits, not megabits.

Everything is scriptable first — a stable CLI with deterministic output — so an agent drives Moonbeam as easily as you do.

Connectivity is a ladder, not a gamble: LAN and IPv6 direct paths first, UDP hole-punching next, the self-hosted relay only as the fallback — each rung tries the cheaper path before spending relay bandwidth.

The full-platform line follows the family standard: desktop first, with iOS/iPadOS/watchOS/Android clients planned once the Rivet mobile host lands. Moonbeam hosts speak the standard Moonlight protocol for desktop view, so official Moonlight mobile apps work wherever a direct path exists (LAN, IPv6, port-forwarding); the interim bridge is a WireGuard endpoint on your own relay (M3) that official clients connect through.

## Quick start (M0 — LAN text lane)

Requires Racket 9+ (host daemon: macOS/Linux for now).

```bash
git clone https://github.com/turinglambdaai/moonbeam.git
cd moonbeam
raco pkg install --auto --name moonbeam --link racket

# on the machine you want to reach:
racket racket/moonbeam/host.rkt start             # prints a pairing PIN

# on your machine:
racket racket/moonbeam/client.rkt pair <host> 49090 --pin <NNNNNN>
racket racket/moonbeam/client.rkt run <host> echo hello       # agent workhorse: JSON verdict, real exit code
racket racket/moonbeam/client.rkt sh <host> --command uptime  # terminal lane
racket racket/moonbeam/client.rkt put <host> ./file.txt       # file transfer
```

## Roadmap

- **M0** — relay server minimum (signaling + wake-on-LAN), host daemon and client CLI, and the text lane verified end to end on LAN: terminal + file transfer. No video stack involved yet.
- **M1** — the external-network path: hole-punching with relay fallback, so the text lane works from anywhere. The "it works from anywhere" moment.
- **M2** — desktop view: the host CLI installs and configures Apollo/Sunshine, the client drives Moonlight as an external process — office-grade, not esports-tuned. GUI shells (macOS / Windows / Linux) with automated pairing.
- **M3** — the complete wake experience (NAS container + cloud entry), session monitoring, a privacy screen for the host, a wireless second screen via Apollo's per-client virtual display, and a WireGuard endpoint on the relay as the bridge for official mobile clients.
- **M4** — family packaging benchmark (dmg / msi / deb / rpm / AppImage, update feeds) and the product site.
- **M5+** — mobile and watch clients, gated on the Rivet mobile host; possibly deeper integration with the host stack (an Apollo fork) under GPLv3 obligations.

## Status

Project kickoff: October 2026. The M0 text lane — pairing, exec, terminal and file transfer over the LAN — is implemented and tested, and the relay ships health/signaling/wake endpoints. External-network access (hole-punching with relay fallback) lands in M1; the desktop-view stack in M2.

## License

MIT. Moonbeam orchestrates third-party components and does not link or redistribute them: Sunshine and Apollo are GPLv3, Moonlight clients carry their own licenses, and they are always invoked as separate, unmodified external processes installed from upstream.
