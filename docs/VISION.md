# Vision

A native iOS/iPadOS app that ports the [Frigate](https://frigate.video) PWA - live view,
events/reviews, snapshots, clips, recordings - keeping the same logic and simplifying where
possible, paired with a notifier/relay system that delivers push notifications to the app.

## Priority

**Move fast, keep setup seamless for end users.** Frigate is already hard to set up;
notifications must be as close to zero-config as possible. Every design choice is weighed
against that goal.

## What we are building

- **A native client**, not a wrapper. The Frigate PWA is React, but the genuinely hard parts -
  low-latency video, background behavior, rich notifications, extensions - are exactly the
  native parts, so a native Swift/SwiftUI app is the right call. The PWA has very little
  business logic of its own; the logic lives in Frigate. Porting is mostly rebuilding the UI
  plus the video players. The Frigate repo's `web/` folder is the reference implementation for
  every endpoint and query.
- **Notifications that work anywhere.** Alerts flow through a small cloud relay, so they arrive
  on cellular and away from home, completely independent of the user's remote-access setup.
  This decoupling is a core win, not an afterthought.

## System overview

```
Frigate --> MQTT/webhook --> notifier --> relay --> APNs/FCM --> iPhone (app)
                                                          |
iPhone app <--- HTTP API / HLS / snapshots / clips <--- Frigate
```

Three components:

- **App** (SwiftUI) - client over Frigate's HTTP API + WebSocket + go2rtc streams.
- **Notifier** (sidecar) - reads Frigate events (MQTT or webhook), forwards to the relay. Ships
  with zero-config defaults and auto-learns cameras; users never edit a config file.
- **Relay** (small cloud service) - holds push credentials, maps users to device tokens,
  forwards to APNs/FCM. Can be self-hosted by power users. Precedent: Home Assistant + Nabu
  Casa Cloud push relay.

## Seamless onboarding (target: 3 taps, no accounts/keys/YAML)

1. Install the notifier (an HA Add-on for the Home Assistant crowd, or a ~5-line Docker Compose
   block). It auto-connects to the same MQTT broker Frigate uses.
2. Open the app and **scan a QR code** that encodes the relay endpoint + a one-time pairing
   secret + the local Frigate URL. The app registers its push token, learns Frigate's address,
   and stores auth.
3. Alerts start arriving immediately with good defaults; refine per-camera in the app.

Supporting touches: mDNS/Bonjour discovery (`_frigate-notifier._tcp`) so the app auto-finds the
notifier on the LAN, and a per-user token that rides in the webhook URL so setup is copy-paste
or fully automated by the add-on.

## Beyond v1

- **WebRTC** sub-second live view as a drop-in behind the `LivePlayer` interface (HLS ships
  first).
- **Feature parity** with the PWA: recordings timeline, PTZ, two-way audio, quiet hours, full
  settings.
- **Upstream contribution** of a generic outbound webhook to Frigate that benefits the whole
  community (Home Assistant, Node-RED, Discord/Slack/Telegram, ntfy) and happens to enable this
  app - framed around the community, never around the app.

See `docs/DECISIONS.md` for the reasoning behind each choice and `docs/ROADMAP.md` for the
phased plan.
