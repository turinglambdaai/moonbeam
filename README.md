# Moonbeam

**Self-hosted remote gaming with the ease of UU Remote — your relay, your hardware, Linux first-class.**

Moonbeam orchestrates the proven open-source streaming stack (Apollo/Sunshine hosts + Moonlight clients) and adds the piece it has always been missing: zero-config networking. Signaling, NAT hole-punching assistance, a relay fallback and wake-on-LAN run on infrastructure you own — a NAS or any cloud box — so the trip home to your gaming PC never depends on someone else's servers.

[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE) [![built with](https://img.shields.io/badge/built%20with-Racket-9F1D35)](https://racket-lang.org/) ![platform](https://img.shields.io/badge/platform-Windows_%7C_macOS_%7C_Linux-lightgrey)

**English** · [中文](README.zh-CN.md)

## Why

UU Remote (by NetEase) shows how remote gaming should feel: install, log in, and your home PC is simply there — reached through NetEase's networking fabric, woken on demand, streamed at low latency. Two things keep that experience out of reach for part of its audience:

- **No Linux client.** The official lineup is Windows, macOS, iOS and Android; a Linux version has been "collecting feedback" since mid-2026.
- **No self-hosting.** The magic — hole-punching, relay, wake-on-LAN signaling — lives on NetEase's servers. It is a free product you cannot own, and its continued existence is not under your control.

Meanwhile the open-source stack already streams superbly: Sunshine and its Apollo fork on the host side, Moonlight clients everywhere, with latency and image quality that rival anything proprietary. What it lacks is exactly the part UU ships: the networking fabric and the zero-config experience around it.

Moonbeam is that missing layer. It deliberately does **not** reinvent the video pipeline — capture, encoding, transport and decoding stay in the upstream native components, driven as external processes. Moonbeam owns the brain: orchestration, pairing, wake-up, and a control plane that runs on hardware you own.

## How it works

Three pieces, one goal: your gaming PC is simply there.

- **Host butler** (Windows, macOS, Linux) — installs and configures Apollo/Sunshine, automates pairing, manages virtual displays, monitors streaming sessions, and wakes the machine on demand.
- **Client** (Windows, macOS, Linux — Linux first-class) — discovers hosts on the LAN, presents a session dashboard, and drives Moonlight clients as external processes.
- **Relay & signaling server** (single binary, Docker) — signaling, hole-punching assistance, a bandwidth-relay fallback, and wake-on-LAN dispatch. Deploy it on your own NAS (a Docker container on an always-on home device can send magic packets directly) or any cloud server. P2P comes first; the relay is only the fallback, because relayed game traffic on a cloud bill is real money.

The full-platform line follows the family standard: desktop first, with iOS/iPadOS/watchOS/Android clients planned once the Rivet mobile host lands. In the meantime Moonbeam-managed hosts speak the standard Moonlight protocol, so the official Moonlight mobile apps work against them from day one.

## Roadmap

- **M0** — relay server minimum (signaling + wake-on-LAN), a host CLI that sets up Apollo in one command, and LAN streaming verified end to end.
- **M1** — client CLI and the external-network path: hole-punching with relay fallback. The "it works from anywhere" moment.
- **M2** — GUI shells (macOS / Windows / Linux) with automated pairing.
- **M3** — the complete wake experience (NAS container + cloud entry) and session monitoring.
- **M4** — family packaging benchmark (dmg / msi / deb / rpm / AppImage, update feeds) and the product site.
- **M5+** — mobile and watch clients, gated on the Rivet mobile host; possibly deeper integration with the host stack (an Apollo fork) under GPLv3 obligations.

## Status

Project kickoff: October 2026. No releases yet — M0 is where the first code will land.

## License

MIT. Moonbeam orchestrates third-party components and does not link or redistribute them: Sunshine and Apollo are GPLv3, Moonlight clients carry their own licenses, and they are always invoked as separate, unmodified external processes installed from upstream.
