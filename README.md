<p align="center">
  <img src="branding/icon_1024.png" width="128" alt="Choritsu icon — two offset sine waves on sumi ink: a cream wave carrying two EQ band nodes, shadowed by a 利休-green afterimage">
</p>

<h1 align="center">Choritsu · 調律</h1>

<p align="center">
  <b>A lossless sample-rate switcher + parametric EQ for Apple Music on macOS.</b><br>
  Keeps playback bit-perfect by matching your output device to the track, then —
  only if you ask — tunes your headphones to their AutoEQ target curve.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-blue" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-5-orange" alt="Swift 5">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

---

**Choritsu** is a free, open-source macOS menu-bar app that keeps **Apple Music bit-perfect**: it automatically switches your output device's **sample rate** to match whatever the current track is decoding — 44.1, 48, 88.2, 96, 176.4, 192 kHz — the same idea as [LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher), rebuilt for macOS 26. On top of that it adds an optional multi-band **parametric equalizer (PEQ)** for headphones and speakers, with **AutoEQ** import. No virtual audio driver, no admin rights, nothing left running in the background.

> If you've ever searched for an *Apple Music lossless sample-rate switcher* or a way to run a *system-wide-feeling EQ on Apple Music without a driver* — that's what this is, in one quiet panel.

## A look

<p align="center">
  <img src="docs/eq.png" width="860" alt="Choritsu with the parametric EQ panel open: a Sennheiser HD600 AutoEQ preset imported, the response curve drawn over a live spectrum, draggable band points, and per-band frequency/gain/Q boxes">
</p>

<p align="center">The EQ docks to the right of the main panel as one continuous popover.</p>

| Now playing | Output device | Source-matched rate |
|:---:|:---:|:---:|
| <img src="docs/main.png" width="230" alt="Now playing panel with artwork, transport, the sample-rate card showing 48 kHz in sync, and the output device with a volume slider"> | <img src="docs/devices.png" width="230" alt="Output device picker listing Mi Monitor, E50 II, BlackHole 16ch and BlackHole 2ch"> | <img src="docs/rates.png" width="230" alt="Sample-rate override dropdown listing 44.1 through 352.8 kHz"> |

## Why I built it

I listen to Apple Music, and I care about how my headphones and monitors actually sound — so I correct them with [AutoEQ](https://github.com/jaakkopasanen/AutoEq) target curves. Two things kept bothering me. macOS quietly resamples whenever the track's sample rate and the output device's rate disagree, so you lose bit-perfect playback without ever being told. And there was no *elegant* way to run a parametric EQ that simply follows the music — every option meant a virtual driver, an admin install, or leaving the player.

**調律** (*chōritsu*) is the Japanese word for tuning an instrument. This app does that for my listening chain: it keeps the output device locked to whatever Apple Music is really decoding — 44.1 up to 192 kHz, within a second of the track changing — and then, only if I ask, lays a multi-band parametric EQ on top so my HD600s and speakers land on their target curve. No kernel extension, no admin rights, nothing left running in the background.

It's a menu-bar app, and it tries to disappear into the desktop: washi paper, sumi ink, and a single 利休 green-gold accent.

## What it does

- **Lossless sample-rate switching** — matches the default output device to the current Apple Music track (44.1 / 48 / 88.2 / 96 / 176.4 / 192 kHz), debounced so it never flaps mid-track. The panel shows source → output, locked / estimating / unknown. This is the core LosslessSwitcher-style behaviour, so playback stays bit-perfect.
- **Headphone & speaker parametric EQ** — a multi-band PEQ applied to Apple Music through a *muted* Core Audio process tap (no driver, no admin rights). Import an AutoEQ `ParametricEQ.txt`, drag the response curve, scroll to set Q, watch the live spectrum, and keep a profile per pair of headphones. Opt-in, and clearly marked non-bit-perfect while active. EQ coefficients are recomputed on every rate change, so a correction stays correct from 44.1 to 192 kHz.
- **Now playing** — artwork, title, artist, album, and a live progress bar.
- **Transport** — play / pause, previous, next, from the menu bar.
- **Manual rate override** — every rate the device supports, like Audio MIDI Setup; picking a conflicting one bows out of auto-switch instead of fighting it.
- **Output device picker & volume** — switch the system default output and ride its hardware volume, all over Core Audio.
- **Native Liquid Glass UI** — real macOS 26 `glassEffect` materials, in a *wabi-sabi* palette.
- **Localized** — 調律 (Japanese / Traditional Chinese), 调律 (Simplified Chinese); the EQ panel is localized for ja / zh-Hans / zh-Hant.

## How it works

macOS never exposed a supported API for "the sample rate of the currently playing track", so Choritsu infers it and cross-checks three sources, in order of trust:

1. **Core Audio log stream** — `coreaudiod` logs the decoded format of the active stream; Choritsu tails the unified log, quantizes candidates to standard rates, and locks one only after weighted evidence accumulates. The lock resets when the track changes.
2. **MediaRemote** (private framework) — now-playing metadata. Restricted for third-party apps on recent macOS, so it is best-effort.
3. **AppleScript to Music.app** — the reliable fallback for metadata, playback state, artwork, and transport commands.

Device control (nominal sample rate, default device, volume) is plain Core Audio HAL property access — no kernel extensions, no audio drivers, nothing in the signal path. Choritsu only ever changes the same setting you could change in Audio MIDI Setup.

The **EQ** is the one part that touches audio, and only when you switch it on: it creates a *muted* Core Audio process tap on Apple Music (the macOS 14.4+ tap API) plus a private aggregate device, runs a biquad cascade at the device's current sample rate, and renders the result to your output device. Still no driver, still no admin rights. While it is active, playback is no longer bit-perfect — and the panel says so.

## The palette

<p align="center"><img src="docs/palette.svg" width="560" alt="Wabi-sabi palette — 利休 green-gold accent, 藍鼠 indigo spectrum, 苔 moss in-sync, on sumi ink and washi paper"></p>

The design language is *wabi-sabi* (侘寂): washi paper, sumi ink, a muted **利休** (Rikyū) green-gold accent, and a vermilion seal. The accent fills as the EQ comes alive; the spectrum behind the curve is a smoky **藍鼠** indigo; "in sync" glows a quiet **苔** moss.

## Requirements

- macOS 26 Tahoe or later (the UI is built on Liquid Glass `glassEffect` APIs)
- Apple Music app (subscription or local library)
- Xcode 26+ to build from source

## Build

```bash
git clone https://github.com/jcongaku/apple-music-lossless-eq.git
cd apple-music-lossless-eq
open SampleRateSwitcher.xcodeproj   # ⌘R to build & run
```

On first run, macOS asks to control **Music** (Automation) and to access **Media & Apple Music**. Turning on the EQ adds a one-time **audio recording** prompt (the process tap).

## Permissions

| Permission | Why |
|---|---|
| Automation → Music | Read the current track and artwork; play / pause / skip |
| Media & Apple Music | Now-playing metadata via MusicKit |
| Audio recording | The muted process tap that lets the EQ see Apple Music's output (only when EQ is on) |

The only network request Choritsu makes is the update check: once per launch it fetches
`api.github.com/repos/jcongaku/apple-music-lossless-eq/releases/latest` to compare the newest
release tag against the running version. It is an unauthenticated GET to a public endpoint —
no account, no identifier, and no data about you or your library is sent. If a newer release
exists, the ⋯ menu offers to open its page; Choritsu never downloads or installs anything by
itself. No analytics, nothing else leaves your machine.

## The name and the icon

**調律** (*chōritsu*) is the Japanese word for tuning an instrument — what a piano technician does, and what this app does to your listening chain. In classical East Asian music theory the twelve-tone system is literally called 十二律, "the twelve ritsu".

The icon drops the literal kanji for something you can read at a glance: **two offset sine waves** on sumi ink. The cream wave is the signal — with two draggable EQ band nodes riding its crest and trough — and the **利休**-green wave behind it is its *afterimage*: the output trailing the source as the sample rate shifts. One mark for both halves of the app, the EQ and the rate-sync, and the same mark sits in the app's top-left corner.

The icon ships as a hand-authored Icon Composer `.icon` bundle (`AppIcon.icon`) with the two waves on separate layers, so the system parallaxes them into real Liquid Glass depth. `branding/render_icon.swift` regenerates the bitmaps from code.

## Acknowledgements

- **[LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher)** by Vincent Neo — the project that proved automatic sample rate switching for Apple Music was possible, and the direct inspiration for Choritsu. If you are on an older macOS, go use it; it is excellent.
- **[AutoEQ](https://github.com/jaakkopasanen/AutoEq)** by Jaakko Pasanen — the headphone target-curve corrections Choritsu imports.
- [IconKit](https://github.com/rozd/icon-kit) — whose typed model of the `.icon` format documented what Apple has not.

## 中文简介

**调律（Choritsu）** 是一个免费、开源的 macOS 菜单栏小工具：让 **Apple Music 保持 bit-perfect 无损播放**——自动把输出设备的**采样率**切换到当前曲目正在解码的真实采样率（44.1 / 48 / 88.2 / 96 / 176.4 / 192 kHz，换曲一秒内跟上），思路和 [LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher) 一样，为 macOS 26 重写；并且可以在需要时叠加一个多段**参数均衡器（PEQ）**，支持导入 **AutoEQ** 耳机校正预设。无需虚拟声卡驱动、无需管理员权限。

> 如果你在找「Apple Music 无损采样率自动切换」或「不用装驱动就能给 Apple Music 上均衡器」的方案——就是它。

我自己是 Apple Music 用户，也是个 HiFi 玩家——平时用 AutoEQ 的目标曲线校正耳机和音箱。一直有两件事让我别扭：当曲目采样率和输出设备不一致时，macOS 会悄悄重采样、丢掉 bit-perfect；而想给 Apple Music 上一个**跟随音源**的参数均衡，又总要装虚拟驱动、要管理员权限，不够优雅。

EQ 通过对 Apple Music 的**静音 process tap** 实现：支持导入 AutoEQ 预设、拖动响应曲线、滚轮调 Q、实时频谱、按耳机存档；切换采样率时系数会重算，所以校正在任何采样率下都正确（开启后即非 bit-perfect，面板会明确标注）。界面基于 macOS 26 原生 Liquid Glass 材质，设计语言为**侘寂**（wabi-sabi）：和纸、墨色、利休色（暗绿金）与朱印。需要 macOS 26+。

## License

[MIT](LICENSE)
