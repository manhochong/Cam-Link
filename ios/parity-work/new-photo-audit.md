# Build 41 new-photo mode: focused read-only audit

**Audited 2026-11-08. No application source changes, Git operations, browser operations, or camera operations were performed.** Scope: iOS `CameraCaptureService`, `PTPPhotoReceiver`, `PTPCameraReader`; Android `CaptureService`, `Ptp`, and baseline queue; only the relevant receiving-mode UI callers.

## 1. Conclusion from the newly supplied failure report

The parent supplied this concrete build 41 new-photo report during the audit:

- `cameraName` empty; `browsing=true`, `connected=false`, `catalogReady=false`.
- `START` at 10:57:23, `CAMERA_PERMISSION 3`, `CONTENTS_AUTH Authorized`.
- `DISCOVERY_TIMEOUT` at 10:57:39.
- **No `DEVICE`, `SESSION_OPEN`, PTP authorization, baseline, object query, or download entries.**

This failure is **before camera discovery/open**, not a demonstrated new-photo baseline, handle-polling, JPEG-validation, or PC-delivery failure. The report establishes that the app did not accept a device through its `open(_:)` path. It does not establish why ImageCaptureCore supplied no accepted device, whether the camera stayed physically connected after card import, or whether it was unplugged/replugged.

The highest-priority minimal repair is the discovery/session lifecycle: **a fresh `ICDeviceBrowser` per receiving generation, rejecting stale-browser callbacks, reconciling `browser.devices` after start and while discovering, and preventing restart until the previous native session has actually closed.** Keep build 41's working PTP reader/receiver and JPEG path unchanged for this repair.

## 2. Confirmed code-level defects/gaps versus unproved incident causes

References below use line numbers of the files read during this audit; the shared repository may subsequently change.

### A. Discovery restart relies entirely on a new `didAdd` callback

`CameraCaptureService.swift:35, 62–69` creates/configures **one immutable browser for the service's entire lifetime**. `startBrowsing():72–138` starts that same browser; `stopBrowsing():163–186` stops it. Nothing enumerates `browser.devices`. The only path to `open(_:)` is `deviceBrowser(_:didAdd:moreComing:):542–546`.

**Confirmed code gap:** after restart, an already-present/cached camera cannot be opened unless a `didAdd` callback is emitted and accepted again. The timer at 206–227 only waits for a callback and publishes `DISCOVERY_TIMEOUT`; it does not reconcile cached devices.

**Incident hypothesis, not established framework behavior:** stop/start of the reused browser with a still-attached camera may retain discovery state and not replay the expected add callback. This matches the new report's phase exactly, but the report alone does not prove browser caching or exclude a physical/OS discovery problem.

### B. Browser delegate callbacks have no source-browser/generation identity check

At 542–550, both browser delegate methods receive a `browser` argument but ignore its identity. The add callback hops into a `Task` and checks only `browsing` and `camera == nil`; the remove callback checks device identity later in `removed(_:)`.

**Confirmed stale-callback defect:** a delayed add from an old discovery run can become the camera of a later run. A delayed old-browser removal can also stop a later run if the same camera object is reused. The existing generation token protects permission, raw-receiver, and native-download closures, **not these browser callbacks**.

With a single browser object, browser identity alone cannot distinguish two uses of that browser. Fresh browser ownership plus source identity/session-token validation closes this gap.

### C. Logical stop exposes restart before asynchronous native close finishes

`stopBrowsing():163–186` changes `generation`, cancels the raw receiver, stops the browser, clears `camera`, and sets `browsing=false` **before** `oldCamera?.requestCloseSession()` finishes. It stores no closing context/barrier. The UI immediately exposes both start-mode buttons whenever `!camera.browsing` (`RootView.swift:222–230`). `open(_:)` immediately calls `requestOpenSession()` (`229–237`) without waiting for an earlier close.

Native session delegates at 561–584 check camera object identity and, for open, `browsing`; they carry no immutable session identity. Example admitted by the code:

1. Session A stops; its camera close is still outstanding.
2. Session B starts and accepts the same `ICCameraDevice` instance.
3. A's delayed close completion sees `device === self.camera` and calls `stopBrowsing()` on B.

An old open completion or a delegate callback already waiting for its MainActor hop can similarly be treated as current. New opens may also be requested while the old close is pending.

**Confirmed lifecycle synchronization defect; not confirmed cause of this particular report.** The new report has no `DEVICE` for B, so it does **not** demonstrate the late-close-after-B-open example. An outstanding close might affect rediscovery, but that remains an incident hypothesis.

Simply capturing `self.generation` when a late callback finally arrives is insufficient: it may already be B's generation. The callback needs an immutable owning-session context, and the old close must be a real barrier.

### D. No confirmed in-place UI mode mutation defect

`mode` is mutable published state (`CameraCaptureService.swift:32`), while the PTP receiver snapshots it as `let mode` (`PTPPhotoReceiver.swift:19, 60–65`). Mutating the service mode during live reception would not rearm a baseline or change the receiver's mode. However, the audited UI only assigns `.newPhotos`/`.card` when `!browsing`; it then calls `startBrowsing()` (`RootView.swift:222–230`). There is no demonstrated live-mode-switch caller. **Do not label the receiver's snapshot as the observed failure.**

## 3. Minimal safe lifecycle repair proposal

This is a proposal, not an applied patch.

### Ownership and guards

Replace the lifelong `private let browser` with generation-owned browsing state. A small context should contain an immutable session ID, its browser, optional camera, and phase (`authorizing`, `discovering`, `opening`, `receiving`, `closing`, `closed`). Retain an old closing context until closure is confirmed; do not discard the only object capable of recognizing its completion.

For each actual start:

1. If an old camera is closing/opening-to-be-closed, refuse or queue the requested mode rather than opening another session. Present “closing previous camera session”; do not silently start a second run.
2. Once the close barrier is clear, allocate a **new `ICDeviceBrowser`**, assign its delegate and the existing local-camera mask, and install its context as current.
3. Capture both the session token **and that exact browser instance** through camera-permission and contents-authorization continuations. Start the captured browser, not whatever a mutable `self.browser` points to later.
4. After `start()`, reconcile the captured browser's `devices` through the same `open` admission path as `didAdd`. While still discovering, also reconcile it on the existing timer: the immediate list may not yet be populated.
5. Add/remove callbacks must first match `sourceBrowser === currentContext.browser` and the owning generation/phase on the MainActor. `open` remains single-admission: current discovery context, no accepted/opening camera, and no previous close pending. An enumeration/add race must emit only one open request.
6. Use an immutable per-session delegate adapter/context for camera callbacks as well. Capture that context before asynchronous actor hops. Old session callbacks may update/complete **only their own closing context**, never the new session.
7. Request control authorization from the current context's same browser; retain the existing token/camera/selected-transport checks in `authorizePTPFallback()`.

### Stop and close barrier

Preserve today's important order: invalidate active receiving callbacks and cancel/poison PTP **before** asking Apple to close its native session. Stop discovery and timers. Separate “not receiving” from “safe to reopen.”

If a camera was opened, retain its closing context and await its matching native close completion/removal. If an open request is still in flight when stop is requested, retain that opening context and close it after its matching successful open completion; do not assume that requesting close while open is outstanding proves both operations are finished. A matching close completion resolves only that context; it must not call the current service's general stop routine and accidentally close a newer run.

Disable start buttons while closing, or retain one explicit pending start/mode and execute it only after the barrier resolves. If close cannot be confirmed within a bounded timeout, show a reconnect-needed error; **do not treat timeout as proof the camera session is closed** or issue speculative repeated opens.

Minimal diagnostic additions: browser/session ID, browser start/stop, cached-device count, callback accepted/ignored reason, open requested/completed, close requested/completed, and close-barrier timeout. No image bytes, receiver credentials, or pairing codes.

### Preserve build 41's working transport

Do not reset/reuse an abandoned `PTPCameraReader`. Its `cancel()` and tombstoned pending command intentionally reject further sends (`PTPCameraReader.swift:451–455, 473–475, 523–528, 557–568`). A new native session receives a new reader/receiver only after the old close barrier is clear.

Do not relax JPEG/MPF validation, change handle filters, or add vendor commands in this lifecycle fix. Keep the sticky `ptpSelected` exclusivity checks: once PTP is selected, native enqueue/download is blocked (`CameraCaptureService.swift:47–50, 253–265, 279–280, 356–357, 385–386`). The receiver keeps a single command pump. This repair needs no camera-property mutation, shutter, delete, tether-enabling, raw OpenSession/CloseSession, or private/vendor operations. Native ImageCaptureCore continues owning camera session management.

## 4. Baseline/polling audit: relevant facts, not this report's failure phase

### Working card report

The locally available `/home/ubuntu/upload/pasted_content_5.txt` is **card mode**, build 41, DC-S1RM2 firmware 1.6. It shows complete empty native catalog, authorized PTP fallback, successful all-storage fallback, and an initial **empty PTP baseline**. Later inventories grow to 8, 10, and 12 objects; five distinct JPEG handles `1377371248…1377371252` are validated/downloaded, with RAW/folders ignored and no receiver failures.

The Panasonic `C1xx` events are logged. The PTP receiver consumes only standard `0x4002` ObjectAdded (`PTPPhotoReceiver.swift:84–89`), so the successful five JPGs demonstrate **inventory reconciliation**, not reliance on Panasonic event parameters. The reader caches all-storage fallback only after a successful parse (`PTPCameraReader.swift:416–438, 461–470`). Idle-only two-second polling is mode-independent (`PTPPhotoReceiver.swift:72–99, 228–258`).

For exactly that same empty baseline and subsequently distinct handles, new-photo mode's baseline exclusion set is also empty; all five later JPG handles remain eligible. There is no code branch that suppresses all future inventory handles merely because the mode is `.newPhotos`.

### Populated native catalog prevents PTP fallback

At `CameraCaptureService.swift:253–276`, PTP is selected **only if the completed native inventory is entirely empty**, not merely has zero JPGs. A populated native catalog causes new-photo mode to baseline those native items. Thereafter the service repeatedly rereads native `mediaFiles`/`contents`; PTP events only trigger native ingestion if PTP was not selected (`206–220, 279–284, 619–628`).

**Confirmed selection behavior, conditional limitation:** if native discovery exposes old files but never updates after new captures, there is no PTP escape path. It is not a general defect when native catalogs update normally. The newly supplied report never reached a catalog, so this cannot explain it.

If a future post-discovery report proves this separate condition, the safe small remedy is explicit/supported-device **PTP-only new-photo selection at complete native readiness, before any native download is queued or active**, with control authorization and the existing read-only operation check. Stay sticky PTP for that session. Do not run native polling/download alongside raw PTP, infer completeness from vendor events, or automatically switch an in-flight native queue to PTP. This is a separate patch, not needed to address the present pre-discovery failure.

### Pending events during baseline have a precise cutoff consequence

Before baseline completion, ObjectAdded handles go into `pendingEvents` (`PTPPhotoReceiver.swift:84–89`). On new-photo baseline completion, **every inventory handle is first inserted into `handled`**, then pending events are enqueued through a filter that excludes handled handles (`167–170, 247–257`). Thus a pending event whose handle is in the completed baseline is suppressed forever within that session; a pending event absent from that inventory remains eligible.

This is a confirmed set-operation consequence, **not automatically a confirmed bug**. It is consistent with a “do not shoot until ready; complete inventory defines the cutoff” policy. It loses a shot if the promised cutoff is instead connection/start time and the camera exposes that new shot during baseline scanning. Initial ObjectAdded callbacks may also describe old catalog objects, so blindly subtracting all pending events from the baseline would risk importing pre-existing photos. Declare/test the cutoff before altering this logic. The present failure has no camera/event/baseline activity.

A short offline Python set model reproduced: empty baseline leaves all five later handles eligible in both modes; baseline `{10,11,12}` plus pending event `{12}` queues nothing; baseline `{10,11}` plus pending event `{12}` queues `12`. This is not an executed Swift/device test.

## 5. Android comparison limited to this question

Android chooses the requested mode before starting (`CaptureService.java:44–66`), performs the complete inventory before `ready=true`/`startEvents()` (`97–129`), and filters events/scans against its baseline (`ReceiveQueue.java:15, 27`; `CaptureService.java:377–393`). It also continues inventory reconciliation. PTP transactions are synchronized (`Ptp.java:50, 112`).

Its UI prevents new starts while `CaptureService.running`, and that flag remains true until session/USB cleanup completes (`CaptureService.java:173–199`; `MainActivity.java:156, 192`). It therefore has a useful explicit cleanup barrier that iOS currently lacks; it does not use the iOS discovery-browser replay mechanism.

Do not copy Android vendor event-poll commands into the iOS repair. Android also forces card mode when resuming an unfinished card import (`CaptureService.java:83–84`); that is a separate policy, not evidence about this iOS failure.

## 6. Pure Swift tests outside UIKit: feasible and recommended

**Yes.** A Foundation-only lifecycle/baseline reducer can be exercised as a standalone Swift executable, analogous to existing `ios/PTPCodecTests.swift`. `project.yml:17–20` includes only the `CamLink` source folder; an offline test outside it is not automatically part of the app.

Current `PTPPhotoReceiver.swift` imports Foundation but directly names `CameraCaptureService.ReceiveMode`, concrete `PTPCameraReader`, and capture validation helpers. It is not independently portable just by omitting UIKit from the test file. For production logic coverage rather than a copied model:

- Extract the small mode/baseline and generation/phase decisions into Foundation-only value types/reducers.
- Inject a minimal read-only reader protocol and a fake/manual callback scheduler for asynchronous integration tests where needed. The actual ImageCaptureCore adapter remains in the app.
- Keep wire request identity/one-shot completion gates testable separately from native APIs; hardware callback-slot assumptions remain covered by existing codec fixtures, not live operations.

Minimum lifecycle test matrix:

| Scenario | Required result |
|---|---|
| Card session stops; new-photo start requested before close callback | No second open; start is disabled/queued until matching old close |
| Stop while old open request is outstanding; open later succeeds | Old context is closed; no receiving/read commands published into new run |
| Old close callback arrives while newer context exists | Only its own closing context resolves; new run is not stopped |
| Old browser add/remove arrives after fresh browser starts | Ignored by source browser/context identity |
| Old contents/control authorization completion arrives after stop/start | Cannot start/select/read through the new browser |
| No add callback, current fresh browser has a cached camera | Reconciliation admits exactly one open |
| Immediate device list empty, later discovery tick has a camera | Later reconciliation opens it |
| `didAdd` and cached enumeration contain the same camera | Exactly one open request |
| Close-barrier timeout | Explicit reconnect-needed state, no unsafe new open |
| Abandoned old PTP command returns after cancellation | No state/JPEG publication and no old-reader reuse |
| Fresh new-photo baseline has old handles, later scan adds one handle | Only the newly added handle becomes eligible |
| Baseline is empty; only informational vendor events arrive; later handle scan grows | New handles become eligible without vendor commands |
| ObjectAdded overlaps/is absent from baseline | Assert the declared ready-time cutoff and dedup behavior |
| Native/PTP transport selected | Never emit both native download and raw-read effects in the same session |

No Swift compiler/runtime was found in this sandbox, so no Swift executable was built or run. A reducer test verifies lifecycle decision logic, not that iPadOS emits discovery callbacks; the minimal on-device acceptance check remains card→stop→new-photo without unplugging, plus unplug/replug, and diagnostics confirming a fresh browser and close barrier before `DEVICE`/`SESSION_OPEN`.

## 7. Source snapshot fingerprints

These identify the exact versions audited without using Git:

| File | SHA-256 |
|---|---|
| `ios/CamLink/Camera/CameraCaptureService.swift` | `92fbe5b9dd8065655014a099f0c86ea5c378d308fb3c69b899fad1b17818aaed` |
| `ios/CamLink/Camera/PTPPhotoReceiver.swift` | `8b61c3c248758fb684110b0397f51bd2d6c833e453cae3c3c1483963756dd7ad` |
| `ios/CamLink/Camera/PTPCameraReader.swift` | `b3bc74bb1898e2ef7f721db3659c7bb1594ba968bffee03d45a1545ce9312ee2` |
| `ios/CamLink/RootView.swift` | `b7da7901ebaced219ecaf5b7196df72e22d98746648a0ce688dfd10310d88902` |
| `app/src/main/java/hk/camlink/usb/CaptureService.java` | `f04c1db2786375776f9a59965ba81672736de7b626f063c843742d895fbfdf5b` |
| `app/src/main/java/hk/camlink/usb/Ptp.java` | `7f33290eef1069bd3f8750c996bb2012132021e9f28a08b6bc099a4ed7a986c9` |
| `app/src/main/java/hk/camlink/usb/ReceiveQueue.java` | `9d67300ed472b97ca174a0d566ca84b2c63626d68e7dbb448ffaa9a8f622927b` |
| `/home/ubuntu/upload/pasted_content_5.txt` | `9222dfe5414b8f738d467a38eac3684d852566a93f3f2d3a9c9f5244df5ed440` |

The new-photo failure evidence was supplied as the parent's report summary; its full file was not available under `/home/ubuntu/upload` at audit time. It is clearly distinguished above from the locally inspected successful card report.
