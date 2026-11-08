import Foundation

/// Standalone executable; uses the EXACT Foundation reducer used by the app.
/// Prepared here, NOT executed in this sandbox (no Swift compiler/iOS SDK).
/// From repository root, on a Swift-capable Mac/Linux runner:
/// swiftc ios/CamLink/Camera/CameraLifecycle.swift ios/CameraLifecycleTests.swift -o /tmp/camlink-camera-lifecycle-tests
/// /tmp/camlink-camera-lifecycle-tests
/// These tests do not emulate ImageCaptureCore or verify hardware discovery.
@main
enum CameraLifecycleChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    private static var checks = 0

    static func expect(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(description: "FAIL: \(label)") }
        checks += 1
    }

    // Only fake identity inputs are supplied; no copied state-machine logic.
    struct IDs {
        let session = UUID()
        let browser = UUID()
        let camera = UUID()
    }

    static func discovering(_ ids: IDs) throws -> CameraLifecycle {
        var state = CameraLifecycle()
        try expect(state.start(id: ids.session, browserID: ids.browser), "start authorizing")
        try expect(state.authorized(id: ids.session, browserID: ids.browser), "authorize exact browser")
        return state
    }

    static func receiving(_ ids: IDs) throws -> CameraLifecycle {
        var state = try discovering(ids)
        try expect(state.admitDevice(id: ids.session, browserID: ids.browser, deviceID: ids.camera), "single open admission")
        try expect(state.opened(id: ids.session, deviceID: ids.camera, succeeded: true) == .receive, "open enables receiving")
        return state
    }

    static func cachedDiscoveryAndDuplicates() throws {
        let ids = IDs()
        var state = try discovering(ids)
        // The immediate browser.devices list is empty: no didAdd and no admissions.
        let immediateDevices: [UUID] = []
        for device in immediateDevices {
            _ = state.admitDevice(id: ids.session, browserID: ids.browser, deviceID: device)
        }
        try expect(state.session?.phase == .discovering, "empty immediate list keeps discovery alive")
        // A later discovery tick enumerates a cached camera without ANY didAdd.
        var openRequests = 0
        for device in [ids.camera] {
            if state.admitDevice(id: ids.session, browserID: ids.browser, deviceID: device) { openRequests += 1 }
        }
        try expect(openRequests == 1, "cached camera without didAdd issues one open")
        // The native adapter and cached enumeration both use this production gate.
        try expect(!state.admitDevice(id: ids.session, browserID: ids.browser, deviceID: ids.camera), "didAdd after cached enumeration cannot duplicate open")
        try expect(!state.admitDevice(id: ids.session, browserID: ids.browser, deviceID: UUID()), "second camera cannot issue another open")
        try expect(state.session?.phase == .opening, "admitted camera stays opening")
        try expect(!state.acceptsReceivingCallback(id: ids.session, deviceID: ids.camera), "catalog/PTP callbacks cannot receive before open completion")

        var didAddFirst = try discovering(ids)
        try expect(didAddFirst.admitDevice(id: ids.session, browserID: ids.browser, deviceID: ids.camera), "didAdd first admitted")
        try expect(!didAddFirst.admitDevice(id: ids.session, browserID: ids.browser, deviceID: ids.camera), "cached enumeration after didAdd cannot duplicate open")
    }

    static func staleBrowsersAndAuthorization() throws {
        let old = IDs(), current = IDs()
        var state = CameraLifecycle()
        try expect(state.start(id: old.session, browserID: old.browser), "old authorization begins")
        try expect(state.stop(id: old.session) == .released, "stop during permissions releases unopened session")
        try expect(state.start(id: current.session, browserID: current.browser), "fresh browser starts")
        try expect(!state.authorized(id: old.session, browserID: old.browser), "old contents authorization cannot start browser")
        try expect(!state.authorized(id: current.session, browserID: old.browser), "correct token with old browser is rejected")
        try expect(state.authorized(id: current.session, browserID: current.browser), "current exact browser authorization accepted")
        try expect(!state.admitDevice(id: old.session, browserID: old.browser, deviceID: current.camera), "old browser didAdd/cached device rejected")
        try expect(!state.ownsBrowser(id: current.session, browserID: old.browser), "old browser didRemove source guard rejected")
        try expect(state.admitDevice(id: current.session, browserID: current.browser, deviceID: current.camera), "fresh cached device admitted")
        try expect(state.opened(id: current.session, deviceID: current.camera, succeeded: true) == .receive, "fresh session opens")
        try expect(!state.ownsBrowser(id: old.session, browserID: old.browser), "old captured control-authorization browser rejected")
        try expect(state.session?.phase == .receiving, "stale browser/authorization leaves new session receiving")
    }

    static func stopCloseBarrierAndReusedCamera() throws {
        let old = IDs(), current = IDs()
        var state = try receiving(old)
        try expect(state.stop(id: old.session) == .requestClose, "stop requests one asynchronous native close")
        try expect(state.sessionClosing && !state.canStart, "logical stop still exposes close barrier")
        try expect(!state.start(id: current.session, browserID: current.browser), "new-photo start blocked while card session closes")
        try expect(state.stop(id: old.session) == .waiting, "repeated stop cannot request duplicate close")
        try expect(!state.acceptsReceivingCallback(id: old.session, deviceID: old.camera), "stopped callbacks cannot publish data")
        try expect(state.closed(id: old.session, deviceID: old.camera, succeeded: true) == .released, "matching successful close releases barrier")
        try expect(state.canStart && !state.sessionClosing, "confirmed closure permits start")
        try expect(state.start(id: current.session, browserID: current.browser), "new receiving generation starts after close")
        try expect(state.authorized(id: current.session, browserID: current.browser), "new browser authorized")
        // Deliberately reuse the SAME device ID to prove session token isolation,
        // stricter than production's additional fresh per-admission camera ID.
        try expect(state.admitDevice(id: current.session, browserID: current.browser, deviceID: old.camera), "same physical camera identity reused safely")
        try expect(state.opened(id: current.session, deviceID: old.camera, succeeded: true) == .receive, "new owner receives")
        try expect(state.closed(id: old.session, deviceID: old.camera, succeeded: true) == .ignored, "late old close cannot stop new session on same camera")
        try expect(state.opened(id: old.session, deviceID: old.camera, succeeded: true) == .ignored, "late old open cannot activate new session")
        try expect(!state.removed(id: old.session, deviceID: old.camera), "old delegate removal cannot stop reused camera")
        try expect(!state.acceptsReceivingCallback(id: old.session, deviceID: old.camera), "old item/PTP/catalog callbacks rejected")
        try expect(state.acceptsReceivingCallback(id: current.session, deviceID: old.camera), "new immutable owner remains receiving")
        try expect(!state.closeTimedOut(id: old.session), "old timer cannot change newer session")
    }

    static func stopWhileOpening() throws {
        let ids = IDs(), next = IDs()
        var state = try discovering(ids)
        try expect(state.admitDevice(id: ids.session, browserID: ids.browser, deviceID: ids.camera), "open requested")
        try expect(state.stop(id: ids.session) == .waitForOpen, "stop during open does NOT race native close")
        try expect(state.session?.openPending == true && state.session?.closeRequested == false, "retain pending open context/delegate")
        try expect(!state.start(id: next.session, browserID: next.browser), "no restart during pending open cleanup")
        try expect(state.closed(id: ids.session, deviceID: ids.camera, succeeded: true) == .ignored, "unrequested close cannot resolve outstanding open")
        try expect(state.opened(id: ids.session, deviceID: ids.camera, succeeded: true) == .requestClose, "late successful open produces close only")
        try expect(!state.acceptsReceivingCallback(id: ids.session, deviceID: ids.camera), "late open never publishes receiving/catalog state")
        try expect(state.opened(id: ids.session, deviceID: ids.camera, succeeded: true) == .ignored, "duplicate open cannot issue duplicate cleanup close")
        try expect(state.closed(id: ids.session, deviceID: ids.camera, succeeded: true) == .released, "cleanup close resolves original barrier")
        try expect(state.canStart, "next start permitted only after cleanup close")
    }

    static func timeoutRequiresPhysicalRemoval() throws {
        let ids = IDs(), next = IDs()
        var state = try receiving(ids)
        try expect(state.stop(id: ids.session) == .requestClose, "close requested before timeout")
        try expect(state.closeTimedOut(id: ids.session), "close barrier timeout observed")
        try expect(state.session?.phase == .reconnectRequired, "timeout is reconnect-required, NOT closed")
        try expect(!state.canStart && state.sessionClosing, "timeout does not enable start buttons")
        try expect(!state.start(id: next.session, browserID: next.browser), "timeout cannot cause speculative open")
        try expect(state.closed(id: ids.session, deviceID: ids.camera, succeeded: true) == .requireReconnect, "late close after timeout still requires physical reconnect")
        try expect(!state.removed(id: ids.session, deviceID: UUID()), "unrelated removal does not clear barrier")
        try expect(state.removed(id: ids.session, deviceID: ids.camera), "matching physical removal clears uncertain session")
        try expect(state.start(id: next.session, browserID: next.browser), "fresh generation starts after removal")
        try expect(!state.closeTimedOut(id: ids.session), "late old timeout rejected")
    }

    static func timeoutWhileOpening() throws {
        let ids = IDs()
        var state = try discovering(ids)
        try expect(state.admitDevice(id: ids.session, browserID: ids.browser, deviceID: ids.camera), "pending open admitted")
        try expect(state.stop(id: ids.session) == .waitForOpen, "stop retains pending open")
        try expect(state.closeTimedOut(id: ids.session), "pending-open close barrier times out")
        try expect(state.opened(id: ids.session, deviceID: ids.camera, succeeded: true) == .requestClose, "late open after timeout still gets safe native cleanup")
        try expect(state.session?.phase == .reconnectRequired && !state.canStart, "cleanup request does not lift reconnect requirement")
        try expect(state.closed(id: ids.session, deviceID: ids.camera, succeeded: true) == .requireReconnect, "cleanup completion after timeout cannot lift reconnect requirement")
        try expect(state.removed(id: ids.session, deviceID: ids.camera), "physical removal resolves timed-out opening")
    }

    static func errorsAndExternalClose() throws {
        let ids = IDs()
        var openError = try discovering(ids)
        try expect(openError.admitDevice(id: ids.session, browserID: ids.browser, deviceID: ids.camera), "failed-open attempt admitted once")
        try expect(openError.opened(id: ids.session, deviceID: ids.camera, succeeded: false) == .requireReconnect, "open error cannot lead to speculative retry")
        try expect(!openError.canStart, "failed open retains uncertainty barrier")
        try expect(openError.stop(id: ids.session) == .waiting, "stop cannot reopen or duplicate cleanup after open error")
        try expect(openError.removed(id: ids.session, deviceID: ids.camera), "physical removal resolves failed open")

        var closeError = try receiving(ids)
        try expect(closeError.stop(id: ids.session) == .requestClose, "close-error attempt requested")
        try expect(closeError.closed(id: ids.session, deviceID: ids.camera, succeeded: false) == .requireReconnect, "failed close is not proof closed")
        try expect(!closeError.canStart, "failed close blocks starts")
        try expect(closeError.removed(id: ids.session, deviceID: ids.camera), "removal resolves failed close")

        var externalClose = try receiving(ids)
        try expect(externalClose.closed(id: ids.session, deviceID: ids.camera, succeeded: true) == .released, "unsolicited successful current close releases without requesting another close")
        try expect(externalClose.closed(id: ids.session, deviceID: ids.camera, succeeded: true) == .ignored, "duplicate close after release ignored")

        var discoveryStop = try discovering(ids)
        try expect(discoveryStop.stop(id: ids.session) == .released, "stop without native open needs no native close")
        try expect(!discoveryStop.admitDevice(id: ids.session, browserID: ids.browser, deviceID: ids.camera), "late discovery tick after stop cannot open")
    }

    static func expectEnd(_ result: CameraReceiveEnd?, received: Int, pending: Int,
                          failed: Int, clean: Bool, _ label: String) throws {
        guard let result else { throw Failure(description: "FAIL: \(label): missing receipt") }
        try expect(result.received == received, "\(label): received snapshot")
        try expect(result.pending == pending, "\(label): pending snapshot")
        try expect(result.failed == failed, "\(label): failed snapshot")
        try expect(result.clean == clean, "\(label): clean requires confirmed drain/close")
    }

    static func receiveCompletionReceipts() throws {
        var clean = CameraReceiveCompletion()
        clean.requestFinish()
        clean.drained()
        try expect(clean.end(nativeCloseSucceeded: true) == nil, "cannot emit before teardown counter snapshot")
        clean.snapshot(received: 7, pending: 0, failed: 0)
        try expectEnd(clean.end(nativeCloseSucceeded: true), received: 7, pending: 0,
                      failed: 0, clean: true, "requested and drained with successful native close")
        try expect(clean.end(nativeCloseSucceeded: true) == nil, "duplicate native close cannot emit twice")
        clean.markUnclean()
        try expect(clean.end(nativeCloseSucceeded: false) == nil, "removal after completion cannot emit twice")

        var forced = CameraReceiveCompletion()
        forced.markUnclean()
        forced.snapshot(received: 3, pending: 4, failed: 2)
        forced.snapshot(received: 3, pending: 0, failed: 0) // Adapter clears its UI/queue afterward.
        forced.requestFinish()
        forced.drained() // Late/stale drain cannot turn a stopped run into a clean one.
        try expectEnd(forced.end(nativeCloseSucceeded: true), received: 3, pending: 4,
                      failed: 2, clean: false, "force stop preserves pre-clear counters")

        var noDrain = CameraReceiveCompletion()
        noDrain.requestFinish()
        noDrain.snapshot(received: 2, pending: 0, failed: 0)
        noDrain.drained() // Snapshot freezes drain eligibility as well as counters.
        try expectEnd(noDrain.end(nativeCloseSucceeded: true), received: 2, pending: 0,
                      failed: 0, clean: false, "finish intent plus empty queue is not drain evidence")

        var noFinish = CameraReceiveCompletion()
        noFinish.drained()
        noFinish.snapshot(received: 1, pending: 0, failed: 0)
        try expectEnd(noFinish.end(nativeCloseSucceeded: true), received: 1, pending: 0,
                      failed: 0, clean: false, "unsolicited close or PTP end without finish intent")

        var retryAfterError = CameraReceiveCompletion()
        retryAfterError.markUnclean() // Device/download/PTP/authorization error.
        retryAfterError.requestFinish()
        retryAfterError.drained()
        retryAfterError.snapshot(received: 5, pending: 0, failed: 0) // UI retry reset failures.
        try expectEnd(retryAfterError.end(nativeCloseSucceeded: true), received: 5, pending: 0,
                      failed: 0, clean: false, "error is sticky across retry count reset")

        for interrupted in [false, true] {
            var terminal = CameraReceiveCompletion()
            terminal.requestFinish()
            terminal.drained()
            if interrupted { terminal.markUnclean() } // Explicit stop/error after drain.
            terminal.snapshot(received: 6, pending: 0, failed: 0)
            try expectEnd(terminal.end(nativeCloseSucceeded: true), received: 6,
                          pending: 0, failed: 0, clean: !interrupted, "post-drain forced/error stop=\(interrupted)")
        }

        for counts in [(pending: 1, failed: 0), (pending: 0, failed: 1)] {
            var incomplete = CameraReceiveCompletion()
            incomplete.requestFinish()
            incomplete.drained()
            incomplete.snapshot(received: 8, pending: counts.pending, failed: counts.failed)
            try expectEnd(incomplete.end(nativeCloseSucceeded: true), received: 8,
                          pending: counts.pending, failed: counts.failed, clean: false,
                          "remaining pending/failed work vetoes clean")
        }

        var unopened = CameraReceiveCompletion()
        unopened.requestFinish()
        unopened.snapshot(received: 0, pending: 0, failed: 0)
        try expectEnd(unopened.end(nativeCloseSucceeded: false), received: 0, pending: 0,
                      failed: 0, clean: false, "no-device/authorization stop resumes UI without success")
        try expect(unopened.end(nativeCloseSucceeded: false) == nil, "repeated no-device stop emits once")
    }

    static func closeFailureCompletionStaysUnclean() throws {
        for timeout in [false, true] {
            let ids = IDs()
            var state = try receiving(ids)
            var completion = CameraReceiveCompletion()
            completion.requestFinish()
            completion.drained()
            try expect(state.stop(id: ids.session) == .requestClose, "completion test requests native close")
            completion.snapshot(received: 9, pending: 0, failed: 0)
            if timeout {
                try expect(state.closeTimedOut(id: ids.session), "completion test observes close timeout")
            } else {
                try expect(state.closed(id: ids.session, deviceID: ids.camera, succeeded: false) == .requireReconnect,
                           "completion test observes native close failure")
            }
            try expectEnd(completion.end(nativeCloseSucceeded: false), received: 9, pending: 0,
                          failed: 0, clean: false, "drain cannot override close failure/timeout")
            try expect(!state.canStart, "unclean receipt does not release native uncertainty barrier")
            try expect(state.closed(id: ids.session, deviceID: ids.camera, succeeded: true) == .requireReconnect,
                       "late successful native close still requires reconnect")
            try expect(completion.end(nativeCloseSucceeded: true) == nil, "late success cannot revise or duplicate receipt")
            try expect(state.removed(id: ids.session, deviceID: ids.camera), "removal releases failed close barrier")
            try expect(completion.end(nativeCloseSucceeded: false) == nil, "physical removal after error emits no duplicate")
        }
    }

    static func main() throws {
        try cachedDiscoveryAndDuplicates()
        try staleBrowsersAndAuthorization()
        try stopCloseBarrierAndReusedCamera()
        try stopWhileOpening()
        try timeoutRequiresPhysicalRemoval()
        try timeoutWhileOpening()
        try errorsAndExternalClose()
        try receiveCompletionReceipts()
        try closeFailureCompletionStaysUnclean()
        print("CameraLifecycle: \(checks) checks passed (production reducer; no hardware operations)")
    }
}
