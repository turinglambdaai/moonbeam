# Moonbeam

**Self-hosted remote gaming with the ease of UU Remote — your relay, your hardware, on all three desktops.**

Moonbeam orchestrates the proven open-source streaming stack (Apollo/Sunshine hosts + Moonlight clients) and adds the piece it has always been missing: zero-config networking. Signaling, NAT hole-punching assistance, a relay fallback and wake-on-LAN run on infrastructure you own — a NAS or any cloud box — so the trip home to your gaming PC never depends on someone else's servers.

[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE) [![built with](https://img.shields.io/badge/built%20with-Racket-9F1D35)](https://racket-lang.org/) ![platform](https://img.shields.io/badge/platform-Windows_%7C_macOS_%7C_Linux-lightgrey)

**English** · [中文](README.zh-CN.md)

## Why

UU Remote (by NetEase) shows how remote gaming should feel: install, log in, and your home PC is simply there — reached through NetEase's networking fabric, woken on demand, streamed at low latency. The catch is that the whole experience rests on infrastructure you don't own:

- **No self-hosting.** The magic — hole-punching, relay, wake-on-LAN signaling — lives on NetEase's servers. It is a free product you cannot own: its rules and limits are not negotiable, which platforms get a client is not your call, and its continued existence is not under your control.

Meanwhile the open-source stack already streams superbly: Sunshine and its Apollo fork on the host side, Moonlight clients everywhere, with latency and image quality that rival anything proprietary. What it lacks is exactly the part UU ships: the networking fabric and the zero-config experience around it.

Moonbeam is that missing layer. It deliberately does **not** reinvent the video pipeline — capture, encoding, transport and decoding stay in the upstream native components, driven as external processes. Moonbeam owns the brain: orchestration, pairing, wake-up, a plain terminal lane for the agent era, and a control plane that runs on hardware you own.

## How it works

Three pieces, one goal: your gaming PC is simply there.

- **Host butler** — installs and configures Apollo/Sunshine, automates pairing, monitors streaming sessions, and wakes the machine on demand, on macOS, Windows and Linux alike. Upstream component maturity differs by platform (Apollo's virtual display is Windows-only today; Sunshine's macOS support is the youngest) — stated plainly as upstream facts, never hidden.
- **Client** (macOS, Windows, Linux) — discovers hosts on the LAN, presents a session dashboard, drives Moonlight clients as external processes, and opens a plain terminal to the host over the tunnel — a text lane that stays usable on links too poor for video.
- **Relay & signaling server** (single binary, Docker) — signaling, hole-punching assistance, a bandwidth-relay fallback, and wake-on-LAN dispatch. Deploy it on your own NAS (a Docker container on an always-on home device can send magic packets directly) or any cloud server. P2P comes first; the relay is only the fallback, because relayed game traffic on a cloud bill is real money.

Connectivity is a ladder, not a gamble: LAN and IPv6 direct paths first, UDP hole-punching next, the self-hosted relay only as the fallback — each rung tries the cheaper path before spending relay bandwidth.

The full-platform line follows the family standard: desktop first, with iOS/iPadOS/watchOS/Android clients planned once the Rivet mobile host lands. Moonbeam-managed hosts speak the standard Moonlight protocol, so official Moonlight mobile apps work wherever a direct path exists (LAN, IPv6, port-forwarding); reaching a relayed host from a phone needs a tunnel-capable client, which arrives with the mobile line — the interim bridge is a WireGuard endpoint on your own relay (M3) that official clients connect through.

## Roadmap

- **M0** — relay server minimum (signaling + wake-on-LAN), a host CLI that sets up Apollo in one command, and LAN streaming verified end to end.
- **M1** — client CLI and the external-network path: hole-punching with relay fallback, plus a remote terminal over the tunnel. The "it works from anywhere" moment.
- **M2** — GUI shells (macOS / Windows / Linux) with automated pairing.
- **M3** — the complete wake experience (NAS container + cloud entry), session monitoring, and a WireGuard endpoint on the relay as the bridge for official mobile clients.
- **M4** — family packaging benchmark (dmg / msi / deb / rpm / AppImage, update feeds) and the product site.
- **M5+** — mobile and watch clients, gated on the Rivet mobile host; possibly deeper integration with the host stack (an Apollo fork) under GPLv3 obligations.

## Status

Project kickoff: October 2026. No releases yet — M0 is where the first code will land.

## License

MIT. Moonbeam orchestrates third-party components and does not link or redistribute them: Sunshine and Apollo are GPLv3, Moonlight clients carry their own licenses, and they are always invoked as separate, unmodified external processes installed from upstream.
