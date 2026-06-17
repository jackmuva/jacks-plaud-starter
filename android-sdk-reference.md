# Plaud Android SDK Reference

This document describes the **public API** of the precompiled Plaud Android SDK shipped as
`sdk/android/plaud-sdk.aar`. It was reconstructed from the compiled `.aar` (class metadata +
the consumer ProGuard keep-rules), so every symbol below is callable from a host app that
depends on this library.

The library is written in **Kotlin**. Many of the high-level entry points are `suspend`
functions (they take a `Continuation` on the JVM); call them from a coroutine. The low-level
BLE command layer instead uses **callback objects** (`OnRequest` / `OnResponse` / `OnError`).

| Coordinate | Value |
|------------|-------|
| AAR manifest package | `com.plaud.sdk` |
| Public Kotlin package root | `sdk` (and `sdk.penblesdk`, `sdk.audio`, `sdk.firmware`, `sdk.network`, `sdk.permission`) |
| `minSdkVersion` | 21 |
| Native ABIs bundled | `arm64-v8a`, `armeabi-v7a` (Opus + OGG + BLE utils `.so`) |

The two layers, mirroring the iOS split:

| Layer | Entry point | Role |
|-------|-------------|------|
| **High-level facade** | `sdk.NiceBuildSdk` | Recommended entry point. SDK init, partner auth, device bind, file upload, transcription workflows, audio export, WiFi fast transfer, OTA, logs. |
| **Low-level BLE** | `sdk.penblesdk.TntAgent` → `IBleAgent` | Raw BLE transport: scan/connect, recording, file sync, device settings. The facade is built on top of this. |
| **Low-level WiFi** | `sdk.penblesdk.core.IWifiAgent` (via `NiceBuildSdk.getWifiAgent()`) | WiFi fast-transfer transport. |

> **Recommendation:** Build against `NiceBuildSdk` for credentials, cloud, upload and OTA,
> and against `TntAgent` / `IBleAgent` for on-device BLE operations. The frameworks handle
> the handshake, decryption and format conversion for you.

> The AAR is obfuscated — internal fields show up under names like `process_item_data`.
> Those are **not** public API; only the typed accessors and methods listed here are.

---

## Table of contents

1. [NiceBuildSdk — main facade](#1-nicebuildsdk--main-facade)
2. [Initialization & credentials](#2-initialization--credentials)
3. [Partner auth & device binding](#3-partner-auth--device-binding)
4. [Cloud AI — transcription workflows](#4-cloud-ai--transcription-workflows)
5. [Audio export & download](#5-audio-export--download)
6. [WiFi fast transfer (IWifiAgent)](#6-wifi-fast-transfer-iwifiagent)
7. [Firmware / OTA update](#7-firmware--ota-update)
8. [Low-level BLE — TntAgent & IBleAgent](#8-low-level-ble--tntagent--ibleagent)
9. [BLE callbacks — BleAgentListener & AgentCallback](#9-ble-callbacks--bleagentlistener--agentcallback)
10. [Model types & enums](#10-model-types--enums)
11. [Encryption & audio decryption](#11-encryption--audio-decryption)
12. [Permissions](#12-permissions)
13. [Logging](#13-logging)

---

## 1. NiceBuildSdk — main facade

`sdk.NiceBuildSdk` is a Kotlin `object` (singleton — `NiceBuildSdk.INSTANCE` from Java,
`NiceBuildSdk` directly from Kotlin). It is the primary object you interact with.

```kotlin
import sdk.NiceBuildSdk
import sdk.penblesdk.impl.ble.BleAgentListener

NiceBuildSdk.initSdk(
    context = applicationContext,
    appKey = "<partner app key>",
    appSecret = "<partner app secret>",
    bleAgentListener = myBleListener,        // see section 9
    customDomain = "platform-us.plaud.ai",   // domain only, no https://
    partnerToken = userAccessToken           // per-user JWT
)
```

Top-level facade surface:

```kotlin
// Environment / base URL
fun switchEnvironment(env: ServerEnvironment)
fun getCurrentEnvironment(): ServerEnvironment
fun getCurrentBaseUrl(): String
fun getWifiSyncDomain(): String

// Managers (escape hatches)
fun getS3UploadManager(): S3UploadManager
fun getApiService(): ApiService
fun getPartnerApiManager(): PartnerApiManager
fun getWifiAgent(): IWifiAgent

// Session
fun isLoggedIn(): Boolean
fun logout()
fun sendHttpTokenToDevice()
```

---

## 2. Initialization & credentials

```kotlin
fun initSdk(
    context: Context,
    appKey: String,
    appSecret: String,
    bleAgentListener: BleAgentListener,
    hostName: String = "",
    extra: Map<String, Any> = emptyMap(),
    customDomain: String = "",     // domain only, no https:// — e.g. "platform-us.plaud.ai"
    partnerToken: String = ""      // per-user JWT (USER_ACCESS_TOKEN)
)

fun setPartnerToken(token: String)
fun isPartnerDataReady(): Boolean

// suspend — resolve auth + permissions for a user/token:
suspend fun getAuthAndPermission(arg1: String, arg2: String): Any
```

`ServerEnvironment` selects the backend region:

```kotlin
enum class ServerEnvironment(val url: String) {
    CHINA_PROD, US_PROD, US_TEST, COMMON_TEST
}
```

> Like iOS, `customDomain` is **domain-only** (no `https://`). Two auth systems coexist:
> a per-user JWT (`partnerToken`, used for SDK init + S3 upload) and the partner
> `appKey`/`appSecret` pair.

`PartnerApiManager` (from `getPartnerApiManager()`) handles partner-level token + signing:

```kotlin
class PartnerApiManager {
    fun setUserAccessToken(token: String)
    fun getUserAccessToken(): String?
    fun hasUserAccessToken(): Boolean
    fun updateBaseUrl(url: String)
    fun clearToken()

    suspend fun signDeviceSn(deviceType: String, sn: String): Any
    suspend fun verifyDeviceSn(arg1: String, arg2: String, arg3: String): Any
    suspend fun generateRsaKeyPair(): Any
}
```

---

## 3. Partner auth & device binding

These are `suspend` functions on `NiceBuildSdk`:

```kotlin
suspend fun signDeviceSn(deviceType: String, sn: String): Any
suspend fun signAndStoreDeviceSn(deviceType: String, sn: String): Any
suspend fun generateRsaKeyPair(): Any
suspend fun bindDevice(ownerId: String, sn: String, deviceType: String): Any
suspend fun unbindDevice(ownerId: String, sn: String, deviceType: String): Any
```

`signDeviceSnAsync` is a non-suspend convenience that takes a callback:

```kotlin
fun signDeviceSnAsync(deviceType: String, sn: String, callback: (result) -> Unit)
fun ensurePartnerDataReady(callback: (ready) -> Unit)
```

> Supported devices by SN prefix (same as iOS): `881` = NotePro, `883` = NotePinS.

---

## 4. Cloud AI — transcription workflows

The Android facade exposes the workflow API as three `suspend` calls. `submit` takes a JSON
request string; `getWorkflowStatus` / `getWorkflowResult` poll by workflow id.

```kotlin
suspend fun submit(requestJson: String): SubmitResponse
suspend fun getWorkflowStatus(workflowId: String): WorkflowStatusResponse
suspend fun getWorkflowResult(workflowId: String): WorkflowResultResponse
```

Request / response models (`sdk.network.model`):

```kotlin
data class SubmitRequest(
    val workflows: List<*>,
    val metadata: Map<String, *>,
    val version: String
)

data class SubmitResponse(
    val id: String, val ownerId: String, val fileId: String,
    val config: List<*>, val metadataJson: Map<String, *>,
    val version: String, val status: String,
    val totalTasks: Int, val completedTasks: Int,
    val startTime: Long, val updateTime: Long, val endTime: Long
)

data class WorkflowStatusResponse(
    val id: String, val status: String,
    val totalTasks: Int, val completedTasks: Int,
    val startTime: Long, val updateTime: Long, val endTime: Long
)

data class WorkflowResultResponse(
    val id: String, val status: String, val tasks: List<TaskResult>
)
```

Task-parameter helpers:

```kotlin
data class AudioTranscribeParams(
    val fileId: String, val language: String,
    val diarization: Boolean, val extras: Map<String, *>
)

data class AiSummarizeParams(
    val language: String, val templateId: String,
    val prompt: String, val model: String, val startTime: Long
)
```

Other model types in `sdk.network.model`: `Task`, `TaskParams`, `TaskResult`,
`TranscribeResult`, `SummarizeTaskResult` / `SummarizeResultData`, `Segment`, `Topic`,
`RecommendQuestion`, `Workflow`, plus S3 upload models (`GeneratePresignedUrlsRequest/Response`,
`PresignedPart`, `CompletedPart`, `CompleteUploadRequest`).

**Upload before transcription** — `S3UploadManager` (from `getS3UploadManager()`) performs
the multipart S3 upload of a recording:

```kotlin
class S3UploadManager {
    suspend fun uploadFile(
        filePath: String, fileSize: Long, fileName: String,
        contentType: String, sn: String, duration: Long, sessionId: Long,
        scene: Int, channel: Int, onProgress: (Float) -> Unit
    ): Any
    fun uploadFileAsync(
        filePath: String, fileSize: Long, fileName: String,
        contentType: String, sn: String, duration: Long, sessionId: Long,
        scene: Int, channel: Int,
        onProgress: (Float) -> Unit, onSuccess: (result) -> Unit, onFailure: (error) -> Unit
    )
}
```

---

## 5. Audio export & download

The device stores audio in a proprietary Opus format. Export decodes it on the phone into a
standard file. These are **static** methods on `NiceBuildSdk`:

```kotlin
fun exportAudio(
    sessionId: Long, outputFile: File,
    format: AudioExportFormat, channels: Int = 1,
    callback: AudioExporter.ExportCallback
)

fun exportAudioViaWiFi(
    sessionId: Long, outputFile: File,
    format: AudioExportFormat, channels: Int = 1,
    callback: AudioExporter.ExportCallback
)

fun getSupportedExportFormats(): List<AudioExportFormat>
fun isE2eeEncryptedFile(file: File): Boolean
```

```kotlin
enum class AudioExportFormat(val value: Int, val extension: String) {
    PCM, WAV, OPUS          // NOTE: no MP3 on Android (iOS has .mp3)
}

interface AudioExporter.ExportCallback {
    fun onProgress(progress: Int, message: String)
    fun onComplete(outputFile: File)
    fun onError(error: String)
}
```

> **Difference from iOS:** the Android SDK exports `PCM`, `WAV`, `OPUS` only — there is **no
> MP3** export path. iOS additionally supports `.mp3`. If you need MP3 for transcription
> upload, transcode on top of the WAV/PCM output or use the S3 upload with the WAV file.

`AudioExporter` can also be constructed directly for finer control:

```kotlin
class AudioExporter(context: Context) {
    suspend fun exportAudio(file: File, ..., format: AudioExportFormat, ..., channels: Int): Any
    fun exportAudioAsync(file: File, ..., format: AudioExportFormat, ..., channels: Int,
                         callback: ExportCallback)
    fun isE2eeEncrypted(file: File): Boolean
}
```

Use `Channel` constants for the `channels` argument:

```kotlin
object Channel { const val SINGLE; const val STEREO; const val FOUR }
```

---

## 6. WiFi fast transfer (IWifiAgent)

WiFi transfer is ~10× faster than BLE. Get the agent from the facade and drive it with a
callback. Flow: open the device hotspot over BLE (`IBleAgent.openDeviceWifi`) → start the
WiFi transfer with the device's SSID → after `onHandshakeCompleted`, list/download files.

```kotlin
// On NiceBuildSdk:
fun getWifiAgent(): IWifiAgent
fun startWifiTransfer(ssid: String, callback: IWifiAgent.WifiTransferCallback): Boolean
fun stopWifiTransfer(): Boolean
fun isWifiTransferActive(): Boolean

interface IWifiAgent {
    fun startWifiTransfer(ssid: String, callback: WifiTransferCallback): Boolean
    fun stopWifiTransfer(): Boolean
    fun getFileList(): Boolean
    fun downloadFile(sessionId: Long, outputPath: String): Boolean
    fun downloadAllFiles(): Boolean
    fun deleteFiles(sessionIds: List<Long>): Boolean
    fun isTransferActive(): Boolean
    fun getConnectionState(): WifiConnectionState
    fun checkPrerequisites(): Boolean
}

enum class WifiConnectionState {
    NONE, CONNECTING, CONNECTED, HANDSHAKING, READY, DISCONNECTED, ERROR
}
```

`IWifiAgent.WifiTransferCallback`:

```kotlin
interface WifiTransferCallback {
    fun onConnectionStateChanged(state: WifiConnectionState)
    fun onHandshakeCompleted(info: String)
    fun onFileListReceived(files: List<BleFile>)
    fun onTransferProgress(sessionId: Long, progress: Int, speed: Float,
                           transferred: Long, total: Long)
    fun onFileTransferCompleted(sessionId: Long, outputPath: String)
    fun onWifiTransferStopped()
    fun onDeviceBatteryUpdate(level: Int, charging: Boolean, voltage: Float)
    fun onError(code: Int, message: String)
    fun onBatchDownloadStarted(totalFiles: Int)
    fun onBatchDownloadProgress(current: Int, total: Int, currentFile: String)
    fun onBatchDownloadCompleted(completed: Int, failed: Int, results: List<*>)
    fun onFileDeleteCompleted(success: Boolean, sessionId: Int, message: String)
}
```

---

## 7. Firmware / OTA update

`sdk.firmware.FirmwareUpdateManager` drives the three OTA phases. It is a singleton
(`FirmwareUpdateManager.INSTANCE`) but also constructible with a `Context`.

```kotlin
class FirmwareUpdateManager(context: Context) {
    fun checkForUpdate(device: BleDevice, callback: FirmwareUpdateCallback)
    fun downloadFirmware(info: FirmwareUpdateInfo, callback: FirmwareUpdateCallback)
    fun installFirmware(file: File, device: BleDevice,
                        info: FirmwareUpdateInfo, callback: FirmwareUpdateCallback)
    fun cancel()
}

interface FirmwareUpdateCallback {
    fun onUpdateCheckResult(result: Any)          // FirmwareUpdateInfo on success
    fun onDownloadProgress(progress: UpdateProgress)
    fun onDownloadComplete(result: FirmwareDownloadResult)
    fun onInstallProgress(progress: UpdateProgress)
    fun onInstallComplete(result: FirmwareInstallResult)
}
// SimpleFirmwareUpdateCallback is a no-op base class — override only what you need.
```

Supporting types:

```kotlin
data class FirmwareUpdateInfo(
    val versionResponse: DeviceVersionResponse,
    val currentVersion: String,
    val hasUpdate: Boolean,
    val isForceUpdate: Boolean
)

data class UpdateProgress(
    val progress: Int, val message: String, val detail: String,
    val transferPhase: FirmwareTransferPhase
)

data class FirmwareDownloadResult(
    val success: Boolean, val file: File?, val error: String?, val md5Valid: Boolean
)

data class FirmwareInstallResult(val success: Boolean, val error: String?)

enum class FirmwareTransferPhase {
    TRANSFERRING, TRANSFER_COMPLETE_WAITING, DEVICE_RESTARTING,
    UPGRADE_COMPLETE, TRANSFER_FAILED, UPGRADE_FAILED
}

enum class UpdateStatus {
    CHECKING, AVAILABLE, NOT_AVAILABLE, DOWNLOADING, DOWNLOADED,
    INSTALLING, INSTALLED, FAILED
}
```

A lower-level version check is also on the facade:

```kotlin
suspend fun getLatestDeviceVersionNew(arg1: String, arg2: String, arg3: String): Any
```

> OTA restarts the device. As on iOS, suppress BLE auto-reconnect while an update is in
> progress so a competing reconnect doesn't break the flow.

---

## 8. Low-level BLE — TntAgent & IBleAgent

`sdk.penblesdk.TntAgent` is the BLE entry point; `getBleAgent()` returns the `IBleAgent`
command interface.

```kotlin
class TntAgent {
    companion object {
        fun init(context: Context, arg: String): TntAgent
        fun getInstant(): TntAgent
    }
    fun getBleAgent(): IBleAgent
    fun addBleAgentListeners(listener: BleAgentListener): Boolean
    fun needListener(): Boolean
}
```

### IBleAgent

Most commands follow the same shape — an optional `OnRequest` (fired when the command is
sent), an `OnResponse` (the device reply), and an `OnError`:

```kotlin
interface IBleAgent {
    // Connection
    fun scanBle(enable: Boolean, onError: AgentCallback.OnError): Boolean
    fun connectionBLE(device: BleDevice, token: String, userName: String,
                      sn: String, arg1: Long, arg2: Long)
    fun disconnectBle()
    fun isConnected(): Boolean
    fun getSerialNumber(): String
    fun getBleStatus(): BluetoothStatus
    fun getLastConnectedDevice(): BleDevice?
    fun setServiceListener(listener: BleAgentListener)
    fun destroy()
    fun depair(clear: Boolean, onRequest, onResponse, onError)

    // Recording
    fun startRecord(scene: Int, onRequest, onResponse, onError)
    fun stopRecord(arg: Int, onRequest, onResponse, onError)
    fun recordPause(sessionId: Long, arg: Int, onRequest, onResponse, onError)
    fun recordResume(sessionId: Long, arg: Int, onRequest, onResponse, onError)

    // File list / sync / delete
    fun getRecSessions(startSessionId: Long, onRequest, onResponse, onError)
    fun syncFileStart(sessionId: Long, start: Long, end: Long,
                      onRequest, onResponse, onProgress, keepOut, onError)
    fun syncFileStop(onRequest, onResponse, onError)
    fun syncFileDel(sessionId: Long, onRequest, onResponse, onError)
    fun clearRecordFile(onRequest, onResponse, onError)

    // App-side encrypted-file sync (chunked)
    fun syncAppFileInfo(index: Int, sessionId: Long, onRequest, onResponse)
    fun syncAppFileData(index: Int, sessionId: Long, offset: Int, data: ByteArray,
                        onRequest, onResponse)
    fun fileDataCheck(index: Int, crc: Short, onRequest, onResponse)

    // Device status
    fun getState(onRequest, onResponse, onError)
    fun getBattStatus(onRequest, onResponse, onError)
    fun getStorage(onRequest, onResponse, onError)
    fun syncTime(onRequest, onResponse)
    fun getTimeZone(): Int
    fun getTimezoneMin(): Int
    fun getBatteryLevel(): Int
    fun isCharging(): Boolean

    // Settings
    fun setMICGain(value: Int, onRequest, onResponse, onError)
    fun getMICGain(onRequest, onResponse, onError)
    fun setPrivacy(enable: Boolean, onRequest, onResponse)
    fun setUDiskMode(enable: Boolean, onRequest, onResponse)
    fun commonSettings(action: Constants.CommonSettings.ActionType, type: Int,
                       arg1: Long, arg2: Long, onRequest, onResponse, onError)

    // WiFi (BLE-side control + "sync when idle" config)
    fun openDeviceWifi(onRequest, onResponse, onError)
    fun setAutoSync(state: Constants.CommonSwitch, onRequest, onResponse, onError)
    fun getAutoSync(onRequest, onResponse, onError)
    fun getWifiInfo(index: Int, onRequest, onResponse, onError)
    fun setSyncWifi(index: Int, ssid: String, password: String, arg: Int,
                    onRequest, onResponse, onError)
    fun deleteWifiInfo(indices: List<*>, onRequest, onResponse, onError)
    fun getWifiList(onRequest, onResponse, onError)
    fun testWifiInfo(index: Long, onRequest, onResponse, onError)
    fun testWifiResult(index: Long, onRequest, onResponse, onError)
    fun getWifiRssi(list: List<*>, onRequest, onResponse, onError)
    fun getWifiRssiResult(list: List<*>, onRequest, onResponse, onError)
    fun getWifiSyncDomain(onRequest, onResponse, onError)
    fun setWifiSyncDomain(domain: String, onRequest, onResponse, onError)
}
```

(Callback parameters above are `AgentCallback.OnRequest` / `AgentCallback.OnResponse` /
`AgentCallback.OnError`; some sync methods take an additional progress `OnResponse` and an
`ISyncVoiceDataKeepOut`.)

---

## 9. BLE callbacks — BleAgentListener & AgentCallback

`BleAgentListener` is the connection/scan/status event sink (register via
`TntAgent.addBleAgentListeners` or `IBleAgent.setServiceListener`):

```kotlin
interface BleAgentListener {
    fun btStatusChange(sn: String, status: BluetoothStatus)
    fun bleConnectFail(sn: String, reason: Constants.ConnectBleFailed)
    fun scanBleDeviceReceiver(device: BleDevice)
    fun scanFail(reason: Constants.ScanFailed)
    fun handshakeWaitSure(sn: String, timeout: Long)
    fun rssiChange(sn: String, rssi: Int)
    fun mtuChange(sn: String, mtu: Int, success: Boolean)
    fun batteryLevelUpdate(sn: String, level: Int)
    fun chargingStatusChange(sn: String, charging: Boolean)
    fun deviceOpRecordStart(sn: String, rsp: RecordStartRsp)
    fun deviceOpRecordStop(sn: String, rsp: RecordStopRsp)
    fun deviceStatusRsp(sn: String, rsp: GetStateRsp)
}
```

Per-command callbacks (`sdk.penblesdk.entity.AgentCallback`):

```kotlin
interface AgentCallback.OnRequest  { fun onCallback(sent: Boolean) }
interface AgentCallback.OnResponse { fun onCallback(rsp: BaseRspBleBean) }
interface AgentCallback.OnError    { fun onError(error: BleErrorCode) }
```

`OnResponse` delivers a `BaseRspBleBean` subclass — downcast based on the command. The
response beans (in `sdk.penblesdk.entity.bean.ble.response`) include `GetStateRsp`,
`RecordStartRsp`, `RecordStopRsp`, `RecordPauseRsp`, `RecordResumeRsp`, `StorageRsp`,
`BattStatusRsp`, `GetRecSessionsRsp`, `SyncFileHeadRsp` / `SyncFileTailRsp`,
`OpenWifiRsp`, `GetWifiListRsp`, `GetWifiInfoRsp`, `TimeSyncRsp`, `HandShakeRsp`, and more.

Key response beans:

```kotlin
class GetStateRsp(raw: ByteArray) {
    fun getState(): Constants.DeviceStatus
    fun getStateCode(): Long
    fun getSessionId(): Long
    fun getScene(): Int
    fun isPrivacyEnable(): Boolean
    fun isUsbState(): Boolean
    fun isKeyState(): Boolean
    fun hasFindMyToken(): Int
    fun hasSndpKeyState(): Int
    fun hasHttpToken(): Int
}

class RecordStartRsp(raw: ByteArray) {
    fun getSessionId(): Long; fun getStart(): Long
    fun getStatus(): Int; fun getScene(): Int; fun getStartTime(): Long
}

class RecordStopRsp(raw: ByteArray) {
    fun getSessionId(): Long; fun getReason(): Int
    fun isFileExist(): Boolean; fun getFileSize(): Long
}
```

---

## 10. Model types & enums

### BleDevice (`sdk.penblesdk.entity`)

A scanned/connected device (`Parcelable`):

```kotlin
class BleDevice {
    fun getName(): String
    fun getMacAddress(): String
    fun getSerialNumber(): String
    fun getRssi(): Int
    fun getManufacturer(): Constants.Manufacturer
    fun getManufacturerCode(): Int
    fun getProjectCode(): Long
    fun getVersionType(): String
    fun getVersionCode(): Int
    fun getVersionName(): String
    fun getBindInfo(): Int
    fun isBindInfoOk(): Boolean
    fun getPortVersion(): Int
    fun getWiFiName(): String         // hotspot SSID
    fun getWiFiPwd(): String
    fun getAudioChannel(): Int;  fun setAudioChannel(v: Int)
    fun isOggAudio(): Boolean;   fun setOggAudio(v: Boolean)
    fun isNoNsAgc(): Boolean;    fun setNoNsAgc(v: Boolean)
    fun isVadOpen(): Boolean;    fun setVadOpen(v: Boolean)
    fun isNcClose(): Boolean;    fun setNcClose(v: Boolean)
    fun vadSensitivity(): Int;   fun setVadSensitivity(v: Int)
    fun vpuGain(): Int;          fun setVpuGain(v: Int)
    fun micGain(): Int;          fun setMicGain(v: Int)
    fun isJT(): Boolean
}
```

### BleFile (`sdk.penblesdk.entity`)

A recording on the device (`Parcelable`):

```kotlin
class BleFile {
    fun getSessionId(): Long
    fun getFileSize(): Long
    fun getAttribute(): Int
    fun getScene(): Int
    fun getStartTime(): Long
    fun getEndTime(): Long
    fun isMusic(): Boolean
    fun isDeviceLog(): Boolean
    companion object {
        fun calculateOpusOffset(size: Long, channel: Int): Long
        fun calculateOpusDuration(size: Long, channel: Int): Long
        fun calculateOpusFileSize(size: Long): Long
    }
}
```

### Enums

```kotlin
enum class BluetoothStatus(val status: Int) {
    NONE, OFF, TURNING_ON, ON, TURNING_OFF,
    DISCONNECTED, CONNECTING, CONNECTED, DISCONNECTING
    // findStatus(code: Int): BluetoothStatus
}

enum class BleErrorCode(val code: Int, val defaultMessage: String) {
    NO_BASE_PERMISSION, NO_DOWNLOAD_PERMISSION,
    BLUETOOTH_NOT_SUPPORTED, BLUETOOTH_NOT_ENABLED, BLUETOOTH_NOT_CONNECTED,
    OPERATION_TIMEOUT, OPERATION_FAILED, UNKNOWN_ERROR
    // fromCode(code: Int): BleErrorCode
}

enum class Constants.CommonSwitch(val type: Int) { OFF, ON }   // find(type)
enum class Constants.Manufacturer(val manufacturerCode: Long) { MTK, Nordic }  // find(code)
enum class Constants.CommonSettings.ActionType(val code: Int) { READ, SETTING }

enum class Constants.ConnectBleFailed(val errCode: Int, val errMsg: String) {
    SYNC_TIME_FAIL, SN_NOT_MATCH, APP_KEY_NOT_MATCH, HANDSHAKE_FAIL,
    HANDSHAKE_CMD_SEND_FAIL, UUID_IS_EMPTY, TIME_OUT, BLE_CONNECT_FAILED,
    TOKEN_NOT_MARCH, RECORDING_NOW, USER_REFUSE, SSN_FAILED, MODE_NOT_MATCH
}

enum class Constants.ScanFailed(val errCode: Int, val errMsg: String) {
    SCAN_FAILED_ALREADY_STARTED, SCAN_FAILED_APPLICATION_REGISTRATION_FAILED,
    SCAN_FAILED_INTERNAL_ERROR, SCAN_FAILED_FEATURE_UNSUPPORTED
}
```

`Constants` also exposes device-status and OTA/error code constants
(`DEVICE_STATUS_IDLE`, `DEVICE_STATUS_RECORD`, `DEVICE_STATUS_TRANSFER`,
`ERROR_CODE_*`, etc.) and `Constants.DeviceStatus`.

---

## 11. Encryption & audio decryption

End-to-end-encrypted device audio is handled by `sdk.penblesdk.utils.AudioDecryptor`
(all static):

```kotlin
object AudioDecryptor {
    fun decryptAudioFile(input: File, privateKeyPem: String, output: File): String
    fun decryptRsaKey(wrappedKey: ByteArray, privateKeyPem: String): ByteArray
    fun decryptChaCha20(data: ByteArray, key: ByteArray, nonce: ByteArray, counter: Int): ByteArray
    fun isFileEncrypted(file: File): Boolean
    fun getHeader(file: File): PlaudEncryptHeader
}
```

`PlaudEncryptHeader` (parse with `fromFile(File)`):

```kotlin
class PlaudEncryptHeader {
    companion object { const val HEADER_SIZE: Int; const val MAGIC_STRING: String
                       fun fromFile(file: File): PlaudEncryptHeader }
    fun isEncrypted(): Boolean
    fun getVersion(): Int
    fun getCrc(): Long
    fun getUserIdString(): String
    fun getFileType(): Int
    fun getChannel(): Int
    fun getEncryptType(): Int
    fun getDuration(): Long
    fun getCounter(): Long
    fun getNonce(): ByteArray
    fun getSegment(): Long
    fun getAlgParams(): ByteArray
    fun getKeyCipher(): ByteArray
}
```

Other crypto utilities in `sdk.penblesdk.utils`: `SecretUtil`, `DES3Utils`, `CrcUtils`,
`OggOpusParser` / `OggUtils`, `OpusDecode` / `OpusEncode` / `OpusUtils`.
`NiceBuildSdk.isE2eeEncryptedFile(file)` is a convenience wrapper over
`AudioDecryptor.isFileEncrypted`.

---

## 12. Permissions

`sdk.permission.PermissionManager` wraps the runtime BLE/location permission flow:

```kotlin
class PermissionManager(context: Context) {
    fun hasAllPermissions(): Boolean
    fun requestPermissions(activity: Activity, callback: (granted: Boolean) -> Unit)
    fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>,
                                   grantResults: IntArray, callback: (granted: Boolean) -> Unit)
}
```

The AAR's manifest declares these permissions (merged into your app): `INTERNET`,
`ACCESS_NETWORK_STATE`, `WAKE_LOCK`, `BLUETOOTH` / `BLUETOOTH_ADMIN` (≤ API 30),
`BLUETOOTH_SCAN` (with `neverForLocation`) / `BLUETOOTH_CONNECT` (API 31+), and
`ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION` (needed for BLE scanning).

---

## 13. Logging

```kotlin
// On NiceBuildSdk (static):
fun exportLog(context: Context): File          // bundle logs for support
fun cleanupLogs(context: Context)
fun getLogInfo(context: Context): Map<String, *>
```

Internal logging utilities live in `sdk.util` (`Logger`, `FileLoggingTree`,
`LogEncryption`, `EncryptedLogExporter`) built on SLF4J + Logback + Timber.

---

### Notes

- The SDK is **Kotlin**. `suspend` functions (those that take a `Continuation` on the JVM)
  must be called from a coroutine; the async/callback variants (`*Async`) are provided where
  a non-coroutine path exists.
- Native code ships for `arm64-v8a` and `armeabi-v7a` only — there are no x86 binaries, so
  use a physical ARM device or an ARM-image emulator.
- BLE/WiFi callbacks may be delivered on background threads; marshal to the main thread
  before touching UI.
- This reference is reconstructed from the compiled `.aar`. The obfuscated internal fields
  (`process_item_data`, `retrieve_config_value`, …) are deliberately omitted — they are not
  part of the supported API. Parameter names for callback-heavy `IBleAgent` methods are
  inferred from the iOS counterpart and may differ slightly; rely on the parameter *types*
  and order.
- Compare with [`sdk-reference.md`](sdk-reference.md) for the iOS API. The biggest behavioral
  differences: Android has **no MP3 export** (PCM/WAV/OPUS only), and the BLE command layer
  uses explicit `OnRequest`/`OnResponse`/`OnError` callbacks rather than a single delegate
  protocol.
```
