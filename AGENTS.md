# AGENTS.md

Guidance for AI coding agents working in this Plaud SDK distribution repo. Compact, high-signal only — verify against the executable sources (configs, scripts) when in doubt.

## What this repo is

Public distribution repo for the Plaud SDK (B2B partner integration with Plaud recording devices). Four independently-useful parts:

- `sdk/` — **Precompiled binaries only** (iOS `.framework`s + Android `.aar`). No source. Treat as opaque dependencies; never modify.
- `plaud-template-app/ios/` — Full iOS reference app demonstrating every SDK feature (BLE connect, recording, file sync, WiFi fast transfer, OTA, transcription).
- `token-retrieval-script/` — Standalone TypeScript CLI that fetches a per-user JWT (`USER_ACCESS_TOKEN`) via the partner OAuth flow.
- `next-backend/` — Next.js 16 app exposing `POST /api/user-token` to mint user access tokens server-side (same OAuth flow as the script). Backend reference for partners who don't want to shell out to the CLI.
- Root `*-sdk-reference.md` / `api-reference.md` — reconstructed public API docs for the precompiled SDKs; the public integration guide is `README.md`.

There are **no automated tests** in this repo. There is no root-level build, lint, or typecheck — each part has its own toolchain below.

## Credentials

`PartnerConfig.xcconfig` (iOS, tracked) holds placeholders; real values go in `PartnerConfig.local.xcconfig` (gitignored, `#include?`d last so it overrides). Keys flow xcconfig → Info.plist (`USER_ACCESS_TOKEN`→`UserAccessToken`, `PLAUD_CLIENT_ID`→`PlaudClientId`, `PLAUD_API_KEY`→`PlaudApiKey`, `PARTNER_TOKEN`→`PartnerToken` deprecated alias of `USER_ACCESS_TOKEN`) and are read from the bundle at runtime.

Two **separate** auth systems — don't mix them:
- `USER_ACCESS_TOKEN` (per-user JWT) — SDK init (`PlaudDeviceAgent.shared.initSDK`) and S3 file-upload endpoints (Bearer). Minted from the partner OAuth flow below.
- `PLAUD_CLIENT_ID` + `PLAUD_API_KEY` — transcription API only (`X-Client-Id` / `X-Client-Api-Key` headers).

### Partner OAuth flow (to mint `USER_ACCESS_TOKEN`)

Two-step, base URL `https://platform-us.plaud.ai/developer/api`:
1. `POST /oauth/partner/access-token` — Basic auth `PLAUD_CLIENT_ID:PLAUD_SECRET_KEY`, `application/x-www-form-urlencoded`.
2. `POST /open/partner/users/access-token` — Bearer partner token, JSON body `{ user_id, expires_in }`.

Implemented twice (kept in sync intentionally): `token-retrieval-script/user-token-script.ts` (CLI, prints token to stdout, needs `.env` with `PLAUD_CLIENT_ID` + `PLAUD_SECRET_KEY` + `PLAUD_USER_ID`) and `next-backend/src/lib/plaud.ts` (`mintUserToken()`, needs `next-backend/.env` with `PLAUD_CLIENT_ID` + `PLAUD_SECRET_KEY`; `user_id` comes from the request body).

## Commands

### iOS Template App

The `.xcodeproj` is **generated** (and gitignored) — never hand-edit `project.pbxproj`; change `project.yml` and regenerate:

```bash
cd plaud-template-app/ios
xcodegen generate                     # project.yml → PlaudTemplateApp.xcodeproj
```

Build/run from Xcode against a **physical device only** — SDK frameworks are arm64 device builds; the simulator is not supported. CLI build check:

```bash
xcodebuild -project PlaudTemplateApp.xcodeproj -scheme PlaudTemplateApp -destination 'generic/platform=iOS' build
```

`project.yml` `postGenCommand` perl hack pins the pbxproj to `objectVersion 56` / Xcode 14 compatibility — don't remove it. `project.yml` references SDK frameworks via relative paths `../../sdk/ios/...`, so generate from `plaud-template-app/ios/`.

### Token retrieval script (Node/TypeScript via tsx)

```bash
cd token-retrieval-script
npm install
npm start                             # runs tsx user-token-script.ts; prints user access token to stdout
```

Requires `.env` (gitignored) with `PLAUD_CLIENT_ID`, `PLAUD_SECRET_KEY`, `PLAUD_USER_ID`. No `lint`/`typecheck` scripts — only `start`. TypeScript types are checked at runtime by `tsx` only.

### next-backend (Next.js 16, React 19, TypeScript, Tailwind v4)

```bash
cd next-backend
npm install
npm run dev                            # http://localhost:3000 — UI form POSTs to /api/user-token
npm run build                          # production build
npm run lint                           # eslint (flat config in eslint.config.mjs)
```

Requires `next-backend/.env` (gitignored via `.env*`) with `PLAUD_CLIENT_ID` + `PLAUD_SECRET_KEY`. The `user-token` route is `runtime = "nodejs"` (uses `Buffer` for Basic auth) — don't switch it to edge. TypeScript `@/*` path alias maps to `./src/*`. `page.tsx` calls the API via internal HTTP (`${proto}://${host}/api/user-token`) so `force-dynamic` rendering is required.

## Template app architecture (iOS)

Swift / UIKit (programmatic, no storyboards), MVVM + Combine, iOS 14+. **Manager layer wraps the SDK** — UI never talks to `PlaudDeviceAgent` directly. Each manager is a singleton implementing a protocol (`DeviceManagerProtocol` etc.), with mock counterparts in `Managers/Mock/` for UI development without hardware:

- `DeviceManager` — sole `PlaudDeviceAgentProtocol` delegate; scan/connect/bind, auto-reconnect, multi-device switching, OTA. Key callbacks: `bleScanResult`, `bleConnectState` (1=connected/0=disconnected), `bleBind`, `blePenState` (handshake done).
- `RecordingManager` — recording state + live PCM waveform (`blePcmData` 640-byte 16kHz mono chunks → `JXRecordVolumer` dB; 100ms render timer decoupled from BLE jitter).
- `SyncManager` — on connect: `getFileList()` → `exportAudio(format: .mp3)` → `deleteFile()`. MP3 is deliberate: playable by AVAudioPlayer *and* accepted by the transcription upload. After sync, files live on the phone only.
- `TranscriptionManager` + `PlaudAPIService` — S3 multipart upload (`generate-presigned-urls` → PUT parts → `complete-upload`), then `POST /open/partner/ai/transcriptions/`, poll GET every 3s until `task_status == "COMPLETED"`.

**Launch routing** (`SceneDelegate`): paired devices + userId in `RecordingStore` → `MainTabBarController` (auto-reconnect in background); otherwise onboarding (`WelcomeViewController`).

**Multi-device / reconnect invariants** (these are load-bearing — breaking them causes silent reconnect failures):
- BLE supports one connection at a time; switching devices disconnects current then scans for the target SN. `RecordingStore` (UserDefaults persistence) tracks `pairedDeviceSNs` + `activeDeviceSN`.
- Auto-reconnect: scan 2s after `sceneDidBecomeActive`, plus a 30s-interval timer (max 10 attempts). The `isOTAInProgress` flag suppresses auto-reconnect during firmware update — OTA restarts the device, and a competing reconnect breaks the flow.

**WiFi fast transfer** (~10x BLE): `setDeviceWiFi(open: true)` → in `bleWiFiOpen` callback hand the BLE device to `PlaudWiFiAgent` → `connectWifi` → after `wifiHandshake(status: 0)`, `exportAudioViaWiFi`. Requires the Hotspot Configuration entitlement (declared in `project.yml`).

Supported devices by SN prefix: `881` = NotePro, `883` = NotePinS.

## Gotchas

- This `AGENTS.md`, `CLAUDE.md`, `.claude/`, and `product-spec.md` are gitignored on purpose — they are internal-only notes in a public repo. Don't commit them, don't reference them in `README.md` or other public-facing docs.
- When changing SDK-facing behavior in the template app, keep `README.md` code snippets in sync — README is the public integration guide and partners copy from it.
- `customDomain` for `initSDK` is **domain-only** (no `https://` prefix), e.g. `platform-us.plaud.ai`. Including the scheme will break SDK init silently.
- The precompiled SDK frameworks and AAR are proprietary (separate license from the Apache-2.0 app code in `plaud-template-app/`); never try to rebuild or relicense them.
- `PartnerConfig.local.xcconfig`, `token-retrieval-script/.env`, and `next-backend/.env*` contain real secrets — never commit, never log, never paste into public docs.