# Moonbeam

**把 UU 远程的开箱即用搬到自己的服务器上——自建中继、自有硬件、Linux 一等公民。**

Moonbeam 编排经过验证的开源串流生态（Apollo/Sunshine 主机端 + Moonlight 客户端），补上它一直缺失的那一块：零配置组网。信令、NAT 打洞辅助、中继兜底与远程唤醒，全部跑在你自己的基础设施上——NAS 或任意云服务器——回家的那条路不再取决于任何一家的服务器还开不开门。

[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE) [![built with](https://img.shields.io/badge/built%20with-Racket-9F1D35)](https://racket-lang.org/) ![platform](https://img.shields.io/badge/platform-Windows_%7C_macOS_%7C_Linux-lightgrey)

[English](README.md) · **中文**

## 为什么做

UU 远程演示了远程游戏该有的样子：装上、登录，家里的电脑就在那里——靠网易的组网基建到达，按需唤醒，低延迟串流。但有两件事把这份体验挡在一部分人之外：

- **没有 Linux 客户端。** 官方阵容是 Windows、macOS、iOS 和 Android，Linux 版从 2026 年年中起一直停在"收集需求"。
- **无法自托管。** 那些魔法——打洞、中继、唤醒信令——都在网易的服务器上。这是一个你无法拥有的免费产品，它的存续不由你决定。

与此同时，开源侧的串流质量早已足够好：主机端有 Sunshine 及其增强分支 Apollo，客户端有遍布全平台的 Moonlight，延迟和画质不输任何闭源方案。它缺的恰好是 UU 提供的那部分：组网基建，以及围绕它的零配置体验。

Moonbeam 就是缺的这一层。它刻意**不**重造视频管线——捕获、编码、传输、解码留在上游原生组件里，以独立进程驱动。Moonbeam 拥有的是大脑：编排、配对、唤醒，以及一条跑在你自己硬件上的控制面。

## 工作方式

三件套，一个目标：家里的电脑就在那里。

- **Host 管家** —— 一键装配并配置 Apollo/Sunshine，自动化配对，监控串流会话，按需唤醒主机。Windows 一等公民（Apollo 的按客户端虚拟显示器）、Linux 一等公民（Sunshine 原生采集与 VAAPI/NVENC 编码）、macOS 尽力而为（上游在此最不成熟）。
- **Client**（Windows、macOS、Linux——Linux 一等公民）——局域网发现主机，提供会话面板，以独立进程驱动 Moonlight 客户端。
- **Relay/信令服务器**（单二进制 + Docker）——信令协调、打洞辅助、带宽中继兜底、远程唤醒指令下发。部署在自己的 NAS（常在家的设备跑 Docker 容器，可以直接发魔法包唤醒同网段的机器）或任意云服务器。P2P 优先，中继只是兜底——云上的串流流量费是真金白银。

连接是一条梯子而不是赌运气：局域网与 IPv6 直连优先，其次 UDP 打洞，自建中继只做兜底——每一级都先试更便宜的路径，再花中继的带宽钱。

全平台路线遵循家族标准：桌面三平台先行，iOS/iPadOS/watchOS/Android 客户端等 Rivet 移动宿主就绪后必做。Moonbeam 管理的主机说标准 Moonlight 协议，凡存在直连路径（局域网、IPv6、端口转发）官方 Moonlight 移动客户端即可使用；从手机经中继到家需要带隧道的客户端，随移动线交付——过渡的桥是中继上的 WireGuard 端点（M3），官方客户端经它直连。

## 路线图

- **M0** —— relay 服务器最小版（信令 + 远程唤醒）、一条命令装配 Apollo 的 Host CLI、局域网串流端到端验证。
- **M1** —— Client CLI 与外网链路：打洞优先、中继兜底。"人在天涯也能连上家里"的一刻。
- **M2** —— GUI 壳（macOS / Windows / Linux）与自动化配对。
- **M3** —— 完整唤醒体验（NAS 容器 + 云入口）、会话监控，以及中继上的 WireGuard 端点——给官方移动客户端当桥。
- **M4** —— 家族打包标杆（dmg / msi / deb / rpm / AppImage、更新 feed）与产品主页。
- **M5+** —— 移动端与手表客户端，等 Rivet 移动宿主；视情况在 GPLv3 义务下与主机端深度整合（fork Apollo）。

## 状态

立项于 2026 年 10 月。尚无 release——第一行代码会落在 M0。

## 许可证

MIT。Moonbeam 编排第三方组件但不链接、不分发它们：Sunshine 与 Apollo 为 GPLv3，Moonlight 客户端各有其许可证，它们始终作为独立、未修改的外部进程由用户从上游安装。
