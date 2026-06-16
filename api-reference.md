# Plaud Platform API Reference

REST endpoints used by this repo against the Plaud Open Platform.

**Base URL:** `https://platform-us.plaud.ai/developer/api`

> The SDK frameworks (`PlaudDeviceAgent`, `PlaudWiFiAgent`) also talk to this host
> internally — configured via `initSDK(customDomain:)` with the domain only, no
> `https://` prefix (`DeviceManager.swift:92`). Those internal calls (device
> metadata, firmware `version/latest`, etc.) are opaque and not documented here.
> This file covers only the endpoints the app/script call directly over HTTP.

## Authentication

There are three credential types, used by different endpoint groups:

| Credential | How it's obtained | Used for |
| --- | --- | --- |
| **Partner access token** | Basic auth (`client_id:secret_key`) → `/oauth/partner/access-token` | Minting per-user tokens (server-side only) |
| **`user_access_token`** (per-user JWT) | Bearer partner token → `/open/partner/users/access-token` | SDK init + file-upload endpoints (`Authorization: Bearer …`) |
| **`X-Client-Id` + `X-Client-Api-Key`** | Static partner credentials | Transcription (AI) endpoints |

See `CLAUDE.md` / `README.md` for how these map into `PartnerConfig.local.xcconfig`
and the app's Info.plist.

---

## 1. Token retrieval (OAuth)

Implemented in `token-retrieval-script/user-token-script.ts`. The two calls are a
chain: partner token first, then exchange it for a per-user JWT. This is intended
to run **server-side** — the secret key must never ship in the client.

### `POST /oauth/partner/access-token`

Mint a short-lived partner access token.

- **Auth:** `Authorization: Basic base64(client_id:secret_key)`
- **Content-Type:** `application/x-www-form-urlencoded`
- **Body:** none

**Response:**
```json
{
  "access_token": "…",
  "refresh_token": "…",
  "token_type": "Bearer",
  "expires_in": 3600
}
```

### `POST /open/partner/users/access-token`

Exchange the partner token for a per-user JWT (`user_access_token`).

- **Auth:** `Authorization: Bearer <partner access_token>`
- **Content-Type:** `application/json`
- **Body:**
  ```json
  { "user_id": "<your user id>", "expires_in": 86400 }
  ```

**Response:**
```json
{ "access_token": "<user_access_token>", "token_type": "Bearer", "expires_in": 86400 }
```

`access_token` here is the value stored as `USER_ACCESS_TOKEN` and consumed by the
SDK init and the file-upload endpoints below.

---

## 2. File upload (S3 multipart)

Implemented in `PlaudAPIService.swift`; orchestrated by `TranscriptionManager.swift`
(`uploadFile` → `uploadParts` → `completeUpload`). Three steps: request presigned
URLs, PUT each 5 MB chunk straight to S3, then tell the platform to merge them. The
result is a `DownloadUrl` (valid ~24h) that feeds the transcription submit call.

> Chunk size is **5 MB** (`PlaudAPIService.chunkSize`, `PlaudAPIService.swift:18`).

### Step 1 — `POST /open/partner/files/upload/generate-presigned-urls`

- **Auth:** `Authorization: Bearer <user_access_token>`
- **Body:** `{ "filesize": <bytes>, "filetype": "mp3" }`
- **Code:** `PlaudAPIService.generatePresignedURLs` (`:51`)

**Response** (note the PascalCase keys):
```json
{
  "FileId": "…",
  "UploadId": "…",
  "ChunkSize": 5242880,
  "Parts": [ { "PartNumber": 1, "PresignedUrl": "https://…amazonaws.com/…" } ]
}
```

### Step 2 — `PUT <PresignedUrl>` (direct to S3)

- **Auth:** none (the presigned URL is pre-authorized)
- **Body:** raw bytes of the chunk
- **Code:** `PlaudAPIService.uploadPartToS3` (`:70`)
- **Important:** read the `ETag` response header for each part; collect
  `{ "PartNumber": n, "ETag": "…" }` for every chunk.

### Step 3 — `POST /open/partner/files/upload/complete-upload`

- **Auth:** `Authorization: Bearer <user_access_token>`
- **Body:**
  ```json
  {
    "file_id": "<FileId>",
    "upload_id": "<UploadId>",
    "part_list": [ { "PartNumber": 1, "ETag": "…" } ],
    "filetype": "mp3",
    "file_md5": "<hex md5, optional>"
  }
  ```
- **Code:** `PlaudAPIService.completeUpload` (`:113`)

**Response:**
```json
{ "FileId": "…", "FileType": "mp3", "DownloadUrl": "https://…", "FileMd5": "…" }
```

`DownloadUrl` is the input to transcription. Valid for ~24h.

---

## 3. Transcription (AI)

Implemented in `PlaudAPIService.swift`; orchestrated by `TranscriptionManager.swift`
(`submitAndPoll`). Submit a task with a `file_url`, then poll until the status is
terminal.

### Submit — `POST /open/partner/ai/transcriptions/`

- **Auth:** `X-Client-Id` + `X-Client-Api-Key` headers
- **Code:** `PlaudAPIService.submitTranscription` (`:145`)
- **Body:**
  ```json
  {
    "file_url": "<DownloadUrl from complete-upload>",
    "params": {
      "transcribe": { "language": "auto", "model": "plaud-fast-whisper" },
      "vad": { "decode_silence": false },
      "diarization": { "enabled": false, "return_embedding": false }
    }
  }
  ```
  `params` defaults shown above (`PlaudAPIService.swift:160`); pass your own to override.

**Response:** returns a top-level `transcription_id` used for polling.
```json
{ "transcription_id": "…", "status": "PENDING" }
```

### Poll — `GET /open/partner/ai/transcriptions/{transcription_id}`

- **Auth:** `X-Client-Id` + `X-Client-Api-Key` headers
- **Code:** `PlaudAPIService.getTranscriptionResult` (`:177`)
- **Cadence:** app polls every **5s**, up to **60** attempts
  (`TranscriptionManager.pollInterval` / `maxPolls`).

**Status values** (top-level `status`):
`PENDING` · `RECEIVED` · `STARTED` · `PROGRESS` → keep polling;
`SUCCESS` → done; `FAILURE` / `REVOKED` → failed.

**Response on `SUCCESS`** — `data.results` is an array of segments:
```json
{
  "status": "SUCCESS",
  "data": {
    "results": [
      { "speaker_id": "…", "start": 0.0, "end": 3.2, "text": "…", "language": "en" }
    ]
  }
}
```
See `TranscriptionResult` / `TranscriptionData` (`PlaudAPIService.swift:349`) for the
decoded shapes; `TranscriptionData.fullText` concatenates segment text.

---

## Endpoint summary

| Endpoint | Method | Auth | Purpose |
| --- | --- | --- | --- |
| `/oauth/partner/access-token` | POST | Basic `client_id:secret_key` | Mint partner token |
| `/open/partner/users/access-token` | POST | Bearer partner token | Mint per-user JWT |
| `/open/partner/files/upload/generate-presigned-urls` | POST | Bearer user token | Get S3 upload URLs |
| `<S3 PresignedUrl>` | PUT | none (presigned) | Upload one 5 MB chunk |
| `/open/partner/files/upload/complete-upload` | POST | Bearer user token | Merge chunks → DownloadUrl |
| `/open/partner/ai/transcriptions/` | POST | X-Client-Id + X-Client-Api-Key | Submit transcription |
| `/open/partner/ai/transcriptions/{id}` | GET | X-Client-Id + X-Client-Api-Key | Poll transcription result |
</content>
</invoke>
