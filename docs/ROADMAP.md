# Roadmap

The living task tracker. Work happens here: phases break down into small tasks, done one by
one. Claude keeps statuses current as work proceeds - marking tasks in progress / done /
blocked only when they actually change, no filler.

## Status convention

- `- [ ]` not started
- `- [ ]` ... `(in progress)` - actively being worked
- `- [x]` done
- `- [ ]` ... `(blocked: reason)` - waiting on something

Each phase ends at a **provable milestone** - something you can point at and say "this works."

## Focus order

**App first - get a user able to actually use it. Notifications come later.** The scariest
technical risk (push plumbing) is deferred in favor of shipping something usable: connect, log
in, see cameras, browse events, watch video. The reordering is deliberate; see
`docs/DECISIONS.md` if revisiting.

---

## P0 - Scaffolding & decisions
- [x] Repo, git, `.gitignore`, license
- [x] SwiftUI app builds from template
- [x] Core planning docs (VISION done; DECISIONS and LEARNINGS are living docs, filled in as decisions/gotchas actually arise)
- [x] Apple Developer account (paid team `LL6476HKHT`, signing + provisioning already working)
- [x] Build & run on a physical device

_Milestone: project builds and runs on a device; docs establish the plan._

## P1 - Connect & authenticate
Foundation everything else builds on.
- [x] Shared API client (base URL, JSON decoding, cookie/JWT handling, error handling) - C1: `FrigateClient` actor + `Endpoint`/`APIError`/`CredentialProviding`/`InsecureTrustDelegate`; `FrigateTests` green (10 tests)
- [ ] Server setup screen: enter Frigate URL + connection test
- [ ] Handle http/https and self-signed certs (explicit trust)
- [ ] Detect auth mode - support both auth-enabled and auth-disabled Frigate
- [ ] Login screen (username / password)
- [ ] `POST /api/login`, capture JWT cookie
- [ ] Store token/credential in Keychain (shared App Group access group)
- [ ] Silent 401 re-login + retry; honor refreshed `Set-Cookie`
- [ ] Persist server config; auto-connect on relaunch

_Milestone: add your Frigate, log in (or connect with auth off), stay logged in across restarts._

## P2 - Camera grid
- [ ] App shell / navigation (Cameras, Events)
- [ ] Fetch `/api/config`, parse camera list
- [ ] Camera grid of snapshot tiles
- [ ] Auto-refresh snapshots every few seconds
- [ ] Tap camera to open a larger snapshot / detail view
- [ ] Minimal Settings: server info, connection status, log out

_Milestone: see all your cameras, updating._

## P3 - Events timeline
- [ ] Fetch event/review list with thumbnails
- [ ] Filters (camera, label, time range)
- [ ] Event detail screen (snapshot)
- [ ] Clip playback via AVPlayer (mp4 - the easy video)
- [ ] Pagination / infinite scroll

_Milestone: browse events and play their clips._

## P4 - Live video
- [ ] Define the `LivePlayer` interface
- [ ] `HLSPlayer` implementation (AVPlayer + HLS)
- [ ] Single-camera fullscreen live view
- [ ] Wire live view into the camera detail screen
- [ ] Reconnect / clean teardown handling

_Milestone: watch a live camera._

---

## P5 - Notifications
Notifier sidecar + relay + push registration; rich notifications with snapshot.
_Milestone: a Frigate event produces a notification with image on a real iPhone._

## P6 - Seamless onboarding
QR pairing, mDNS discovery, in-app config synced to the notifier.
_Milestone: set the whole thing up in ~3 taps, no YAML._

## P7 - Packaging
HA add-on + Docker for the notifier; bring-your-own-push escape hatch.
_Milestone: a new user installs from a documented, supported path._

## P8 - Parity extras
Recordings timeline, PTZ, two-way audio, quiet hours, WebRTC low-latency live, full settings.
_Milestone: feature parity with the PWA._

---

## To verify against a real Frigate (as we build P1-P3)
- JWT cookie name and refresh behavior (`session_length` / `refresh_time`)
- Whether Frigate has long-lived API keys / personal access tokens to store instead of a password
- Exact snapshot / clip URL shapes and the events vs reviews endpoints
