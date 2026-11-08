import Foundation

/// Production admission/close-barrier decisions, independent of ImageCaptureCore.
/// The native adapter supplies immutable browser/session/device-admission IDs.
/// A timeout is deliberately NOT evidence that an Apple-owned session closed.
struct CameraLifecycle {
    enum Phase: String {
        case authorizing, discovering, opening, receiving
        case closingOpening, closing, reconnectRequired
    }

    struct Session: Equatable {
        let id: UUID
        let browserID: UUID
        var phase: Phase = .authorizing
        var deviceID: UUID?
        var openPending = false
        var closeRequested = false
    }

    enum StopAction: Equatable {
        case ignored, released, waitForOpen, requestClose, waiting
    }
    enum OpenAction: Equatable {
        case ignored, receive, requestClose, requireReconnect
    }
    enum CloseAction: Equatable {
        case ignored, released, requireReconnect
    }

    private(set) var session: Session?
    var canStart: Bool { session == nil }
    var sessionClosing: Bool {
        guard let phase = session?.phase else { return false }
        return phase == .closingOpening || phase == .closing || phase == .reconnectRequired
    }

    @discardableResult
    mutating func start(id: UUID, browserID: UUID) -> Bool {
        guard canStart else { return false }
        session = Session(id: id, browserID: browserID)
        return true
    }

    func ownsBrowser(id: UUID, browserID: UUID) -> Bool {
        session?.id == id && session?.browserID == browserID
    }

    @discardableResult
    mutating func authorized(id: UUID, browserID: UUID) -> Bool {
        guard ownsBrowser(id: id, browserID: browserID), session?.phase == .authorizing else { return false }
        session?.phase = .discovering
        return true
    }

    /// Both didAdd and browser.devices reconciliation call this SAME gate.
    /// A second device, a duplicate add, or a stale browser cannot issue an open.
    @discardableResult
    mutating func admitDevice(id: UUID, browserID: UUID, deviceID: UUID) -> Bool {
        guard ownsBrowser(id: id, browserID: browserID), session?.phase == .discovering,
              session?.deviceID == nil else { return false }
        session?.deviceID = deviceID
        session?.openPending = true
        session?.phase = .opening
        return true
    }

    func ownsDevice(id: UUID, deviceID: UUID) -> Bool {
        session?.id == id && session?.deviceID == deviceID
    }

    func acceptsReceivingCallback(id: UUID, deviceID: UUID) -> Bool {
        ownsDevice(id: id, deviceID: deviceID) && session?.phase == .receiving
    }

    mutating func stop(id: UUID) -> StopAction {
        guard session?.id == id, let phase = session?.phase else { return .ignored }
        switch phase {
        case .authorizing, .discovering:
            session = nil // No native open was ever requested.
            return .released
        case .opening:
            session?.phase = .closingOpening
            return .waitForOpen // Do not race requestCloseSession with pending open.
        case .receiving:
            session?.phase = .closing
            session?.closeRequested = true
            return .requestClose
        case .closingOpening, .closing, .reconnectRequired:
            return .waiting
        }
    }

    mutating func opened(id: UUID, deviceID: UUID, succeeded: Bool) -> OpenAction {
        guard ownsDevice(id: id, deviceID: deviceID), session?.openPending == true,
              let phase = session?.phase else { return .ignored }
        session?.openPending = false
        guard succeeded else {
            // An open error does not justify a speculative new open of this device.
            session?.phase = .reconnectRequired
            return .requireReconnect
        }
        switch phase {
        case .opening:
            session?.phase = .receiving
            return .receive
        case .closingOpening, .reconnectRequired:
            if phase == .closingOpening { session?.phase = .closing }
            session?.closeRequested = true
            return .requestClose // Late successful open is cleanup only, never receive.
        default:
            return .ignored
        }
    }

    mutating func closed(id: UUID, deviceID: UUID, succeeded: Bool) -> CloseAction {
        guard ownsDevice(id: id, deviceID: deviceID), let phase = session?.phase,
              phase == .receiving || session?.closeRequested == true else { return .ignored }
        guard succeeded, phase != .reconnectRequired else {
            session?.phase = .reconnectRequired
            return .requireReconnect
        }
        session = nil
        return .released
    }

    @discardableResult
    mutating func closeTimedOut(id: UUID) -> Bool {
        guard session?.id == id,
              session?.phase == .closingOpening || session?.phase == .closing else { return false }
        session?.phase = .reconnectRequired
        return true
    }

    /// Matching native removal is physical disconnection, unlike a timeout.
    /// Old-session removal (even for the same reused ICCameraDevice) is ignored.
    @discardableResult
    mutating func removed(id: UUID, deviceID: UUID) -> Bool {
        guard ownsDevice(id: id, deviceID: deviceID) else { return false }
        session = nil
        return true
    }
}
