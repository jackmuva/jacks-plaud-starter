# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Public distribution repo for the Plaud SDK (B2B partner integration with Plaud recording devices). Four parts:

- `sdk/` — **Precompiled binaries only** (iOS `.framework`s + Android `.aar`). There is no SDK source here; treat these as opaque dependencies.
- `plaud-template-app/ios/` — Full iOS reference app demonstrating every SDK feature (BLE connect, recording, file sync, WiFi fast transfer, OTA, transcription).
- `next-backend/` — Next.js token-minting backend exposing `POST /api/user-token`; the iOS app's preferred way to obtain per-user JWTs at runtime.
- `token-retrieval-script/` — Small TypeScript CLI that mints a per-user JWT (`USER_ACCESS_TOKEN`) via the partner OAuth flow. Same flow as `next-backend`, run from the terminal.

`next-backend/src/lib/plaud.ts` and `token-retrieval-script/user-token-script.ts` implement the **same two-step OAuth flow and are kept in sync** — change both when you touch the token logic.

SDK API reference docs live at the repo root: `ios-sdk-reference.md`, `android-sdk-reference.md`, `api-reference.md`. There are no automated tests in this repo.

## Commands

### iOS Template App

The `.xcodeproj` is **generated** (and gitignored) — never hand-edit `project.pbxproj`; change `project.yml` and regenerate:

```bash
cd plaud-template-app/ios
xcodegen generate          # project.yml → PlaudTemplateApp.xcodeproj
```

Build/run from Xcode against a **physical device only** — SDK frameworks are arm64 device builds; the simulator is not supported. CLI build check:

```bash
xcodebuild -project PlaudTemplateApp.xcodeproj -scheme PlaudTemplateApp -destination 'generic/platform=iOS' build
```

`project.yml` has a `postGenCommand` perl hack that pins the pbxproj to `objectVersion 56` / Xcode 14 compatibility — don't remove it.

### Next backend (token minting)

```bash
cd next-backend
npm install
npm run dev                # http://localhost:3000 — landing page is a test form for /api/user-token
npm run build              # production build
npm run lint               # eslint (flat config)
```

Requires `.env` / `.env.local` (gitignored) with `PLAUD_CLIENT_ID`, `PLAUD_SECRET_KEY`. The endpoint `POST /api/user-token` takes `{ user_id }` and returns `{ access_token, expires_in }`. Node.js runtime is pinned (`route.ts`) because the Basic-auth header is built with `Buffer`. Deploy to Vercel, then point the iOS app's `USER_TOKEN_BACKEND_URL` at it.

### Token retrieval script

```bash
cd token-retrieval-script
npm install
npm start                  # runs tsx user-token-script.ts; prints user access token to stdout
```

Requires `.env` (gitignored) with `PLAUD_CLIENT_ID`, `PLAUD_SECRET_KEY`, `PLAUD_USER_ID`. Flow (both this and `next-backend`): Basic-auth `POST /oauth/partner/access-token` → Bearer `POST /open/partner/users/access-token`. Base URL: `https://platform-us.plaud.ai/developer/api`.

## Credentials

`PartnerConfig.xcconfig` holds placeholders; real values go in `PartnerConfig.local.xcconfig` (gitignored, `#include?`d last so it overrides). Keys flow xcconfig → Info.plist (`USER_ACCESS_TOKEN`→`UserAccessToken`, `PLAUD_CLIENT_ID`→`PlaudClientId`, `PLAUD_API_KEY`→`PlaudApiKey`, `USER_TOKEN_BACKEND_URL`→`UserTokenBackendURL`) and are read from the bundle at runtime.

Two separate auth systems:
- `USER_ACCESS_TOKEN` (per-user JWT) — SDK init (`PlaudDeviceAgent.shared.initSDK`) and S3 file-upload endpoints (Bearer).
- `PLAUD_CLIENT_ID` + `PLAUD_API_KEY` — transcription API only (`X-Client-Id` / `X-Client-Api-Key` headers).

**Preferred token path is runtime, not baked-in:** if `USER_TOKEN_BACKEND_URL` is set, `TokenManager` (`Managers/TokenManager.swift`) fetches a fresh JWT from `POST {url}/api/user-token` with `{ user_id: identifierForVendor }` (called from `DeviceManager` before SDK init). The static `USER_ACCESS_TOKEN` xcconfig value is the fallback when the backend URL is not configured.

## Template app architecture

Swift / UIKit (programmatic, no storyboards), MVVM + Combine, iOS 14+.

**Manager layer wraps the SDK** — UI never talks to `PlaudDeviceAgent` directly. Each manager is a singleton implementing a protocol (`DeviceManagerProtocol` etc.), with mock counterparts in `Managers/Mock/` for UI development without hardware:

- `DeviceManager` — sole `PlaudDeviceAgentProtocol` delegate; scan/connect/bind, auto-reconnect, multi-device switching, OTA. Key callbacks: `bleScanResult`, `bleConnectState` (1=connected/0=disconnected), `bleBind`, `blePenState` (handshake done).
- `RecordingManager` — recording state + live PCM waveform (`blePcmData` 640-byte 16kHz mono chunks → `JXRecordVolumer` dB; 100ms render timer decoupled from BLE jitter).
- `SyncManager` — on connect: `getFileList()` → `exportAudio(format: .mp3)` → `deleteFile()`. MP3 is deliberate: playable by AVAudioPlayer *and* accepted by the transcription upload. After sync, files live on the phone only.
- `TranscriptionManager` + `PlaudAPIService` — S3 multipart upload (`generate-presigned-urls` → PUT parts → `complete-upload`), then `POST /open/partner/ai/transcriptions/`, poll GET every 3s until `task_status == "COMPLETED"`.

**Launch routing** (`SceneDelegate`): paired devices + userId in `RecordingStore` → `MainTabBarController` (auto-reconnect in background); otherwise onboarding (`WelcomeViewController`).

**Multi-device / reconnect invariants:**
- BLE supports one connection at a time; switching devices disconnects current then scans for the target SN. `RecordingStore` (UserDefaults persistence) tracks `pairedDeviceSNs` + `activeDeviceSN`.
- Auto-reconnect: scan 2s after `sceneDidBecomeActive`, plus a 30s-interval timer (max 10 attempts). The `isOTAInProgress` flag suppresses auto-reconnect during firmware update — OTA restarts the device, and a competing reconnect breaks the flow.

**WiFi fast transfer** (~10x BLE): `setDeviceWiFi(open: true)` → in `bleWiFiOpen` callback hand the BLE device to `PlaudWiFiAgent` → `connectWifi` → after `wifiHandshake(status: 0)`, `exportAudioViaWiFi`. Requires the Hotspot Configuration entitlement (declared in `project.yml`).

Supported devices by SN prefix: `881` = NotePro, `883` = NotePinS.

## Gotchas

- This `CLAUDE.md`, `.claude/`, and `product-spec.md` are gitignored — internal-only in a public repo. Don't commit them or reference them in public-facing docs.
- The README is the public integration guide; if you change SDK-facing behavior in the template app, keep README code snippets in sync.
- `customDomain` for `initSDK` is domain-only (no `https://` prefix), e.g. `platform-us.plaud.ai`.
