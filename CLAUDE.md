# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Native SwiftUI client for [Frigate](https://frigate.video) (the NVR/camera system), plus a
notifier + relay that delivers push notifications to the app. Guiding priority: **move fast,
keep setup seamless**. For the full product vision, architecture, and onboarding flow, read
`docs/VISION.md`; for the reasoning behind the rules below, `docs/DECISIONS.md`.

Three components: **App** (this repo's `app/`), **notifier** (sidecar reading Frigate events),
**relay** (cloud service owning push credentials). Only the App exists so far.

**Reference implementation:** the real Frigate repo (app, server, PWA) is checked out locally at
`~/Documents/frigate`. When docs fall short, read the source - `web/` is the PWA (how it calls
the API, which endpoints/params exist, how live streams are negotiated) and the Python server
is the API's ground truth. It is the definitive answer for endpoint shapes and parameters.

## Current state

Early scaffolding. `app/` is a fresh SwiftUI Xcode template (`FrigateApp.swift`,
`ContentView.swift` - still "Hello, world!"). Notifier and relay do not exist yet. `docs/` holds
the planning material - read it before starting feature work.

## Build & run

Xcode project: `app/Frigate.xcodeproj` (shared scheme `Frigate`, bundle id `com.sagarp.Frigate`,
iOS 26.5 target, Swift 5, iPhone/iPad/Vision). Dependencies via SwiftPM; none yet. Development
happens in Xcode 26.6.

CLI builds need Xcode selected as the active developer dir first (the machine may default to
CommandLineTools): `sudo xcode-select -s /Applications/Xcode.app`.

```bash
# Build for simulator
xcodebuild -project app/Frigate.xcodeproj -scheme Frigate \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# Test (no test target exists yet - add one before this is useful)
xcodebuild -project app/Frigate.xcodeproj -scheme Frigate \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

## Rules that shape the code

Do not casually reverse these (reasoning in `docs/DECISIONS.md`):

- **Live view behind a thin `LivePlayer` interface.** Ship `HLSPlayer` (native AVPlayer) only
  for v1; `WebRTCPlayer` slots in later as a drop-in. Never WebRTC a grid - low-res HLS for the
  grid, one WebRTC peer only for the focused camera.
- **Relay owns push credentials** - users never touch APNs/FCM. Prefer FCM topics (app
  self-subscribes; no device-token registry).
- **Config lives in the app UI, not YAML.** No notifier config file for users to edit; toggles
  sync back to the notifier via the relay.
- **Auth token in the Keychain**, in a **shared App Group access group** (the Notification
  Service Extension runs in a separate process - otherwise notifications arrive but snapshots
  fail). On 401, silently re-run `/api/login` and retry.
- **Rich notifications** need a Notification Service Extension + `mutable-content: 1`; fetch the
  snapshot from the user's own Frigate, not through the relay.
- **Upstream Frigate contributions** must be vendor-neutral and never mention the app/relay/
  FCM/APNs.

## Working process

`docs/ROADMAP.md` is the living task tracker and the primary working doc - tasks are broken
down there and worked one by one. **Keeping it current is part of the job:** when you start a
task mark it in progress, when you finish mark it done, and note a blocker if one appears. Only
touch a task's status when it actually changes - do not pad the doc with churn or restate work
that hasn't moved. The current focus is the **App** (get a user able to actually use it);
notifications come later.

## Docs

`docs/` is the source of truth for intent and history; keep it current. `VISION.md` (what/why),
`DECISIONS.md` (ADRs + reasoning), `ROADMAP.md` (living task tracker + progress),
`LEARNINGS.md` (gotchas), `components/app.md` (app internals).
