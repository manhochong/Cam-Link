import Foundation
#if canImport(ImageCaptureCore)
import ImageCaptureCore
#endif

struct PTPDeviceInformation: Sendable {
    let manufacturer: String
    let model: String
    let version: String
    let operations: Set<UInt16>
}

struct PTPObjectInformation: Sendable {
    let handle: UInt32
    let name: String
    let size: Int64
    let format: UInt16
    let width: UInt32
    let height: UInt32
    var isJPEG: Bool {
        let lowerName = name.lowercased()
        return format == 0x3801 || lowerName.hasSuffix(".jpg") || lowerName.hasSuffix(".jpeg")
    }
}

struct PTPEvent: Sendable {
    let code: UInt16
    let parameters: [UInt32]
}

struct PTPResponseError: LocalizedError, Sendable {
    let code: UInt16
    var errorDescription: String? {
        switch code {
        case 0x2006: return "PTP ParameterNotSupported (0x2006)."
        case 0x2008: return "PTP InvalidStorageID (0x2008)."
        case 0x2009: return "PTP InvalidObjectHandle (0x2009)."
        case 0x2019: return "PTP DeviceBusy (0x2019)."
        default: return String(format: "PTP response error 0x%04X.", Int(code))
        }
    }
}

enum PTPReadError: LocalizedError {
    case malformed(String)
    case limit(String)
    case unsupportedOperation(UInt16)
    case concurrentCommand
    case cancelled
    case timedOut(UInt16)
    case unusable
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let field): return "Malformed or truncated PTP \(field)."
        case .limit(let field): return "PTP \(field) exceeds the permitted size or count."
        case .unsupportedOperation(let code):
            return String(format: "PTP operation 0x%04X is not permitted by this read-only reader.", Int(code))
        case .concurrentCommand: return "A PTP command is already pending; concurrent commands are not allowed."
        case .cancelled: return "PTP read cancelled. Close and reconnect the native camera session before retrying."
        case .timedOut(let code):
            return String(format: "PTP operation 0x%04X timed out. Close and reconnect the native camera session before retrying.", Int(code))
        case .unusable: return "This PTP reader is no longer usable. Close and reconnect the native camera session."
        case .transport(let message): return "Native PTP transport failed: \(message)"
        }
    }
}

/// PTP wire/data codecs are independent of ImageCaptureCore and camera hardware.
enum PTPCodec {
    static let metadataLimit = 4 * 1024 * 1024
    static let objectHardLimit = 128 * 1024 * 1024
    static let maxHandles = 1_000_000
    static let allowedOperations: Set<UInt16> = [0x1001, 0x1004, 0x1007, 0x1008, 0x1009]

    struct Response: Sendable {
        let code: UInt16
        let transaction: UInt32
        let parameters: [UInt32]
    }

    struct Completion: Sendable {
        let response: Response
        let payload: Data
        let responseSlot: String
    }

    /// The native callback has two unlabeled Data values. Identify a response
    /// by its complete type-3 container, never by argument names or byte count
    /// alone. If both buffers look like responses, fail rather than lose data.
    static func completion(first: Data, second: Data, operation: UInt16, maxBytes: Int) throws -> Completion {
        let firstResponse = try? response(first)
        let secondResponse = try? response(second)
        let reply: Response
        let incoming: Data
        let slot: String
        switch (firstResponse, secondResponse) {
        case (.some(let value), .none):
            reply = value
            incoming = second
            slot = "first"
        case (.none, .some(let value)):
            reply = value
            incoming = first
            slot = "second"
        case (.some, .some):
            throw PTPReadError.malformed("ambiguous callback responses")
        case (.none, .none):
            throw PTPReadError.malformed("callback response container")
        }
        guard reply.code == 0x2001 else { throw PTPResponseError(code: reply.code) }
        let incomingPayload = try payload(incoming, operation: operation, maxBytes: maxBytes)
        return Completion(response: reply, payload: incomingPayload, responseSlot: slot)
    }

    static func command(operation: UInt16, transaction: UInt32, parameters: [UInt32] = []) throws -> Data {
        guard allowedOperations.contains(operation) else { throw PTPReadError.unsupportedOperation(operation) }
        guard parameters.count <= 5 else { throw PTPReadError.limit("command parameters") }
        var result = Data()
        append(UInt32(12 + parameters.count * 4), to: &result)
        append(UInt16(1), to: &result)
        append(operation, to: &result)
        append(transaction, to: &result)
        for parameter in parameters { append(parameter, to: &result) }
        return result
    }

    static func response(_ data: Data) throws -> Response {
        guard data.count >= 12, data.count <= 32 else { throw PTPReadError.malformed("response length") }
        var reader = try Reader(data)
        let length = try reader.uint32()
        let type = try reader.uint16()
        let code = try reader.uint16()
        let transaction = try reader.uint32()
        guard UInt64(length) == UInt64(data.count), type == 3,
              (0x2000...0x2FFF).contains(code), (data.count - 12) % 4 == 0 else {
            throw PTPReadError.malformed("response header")
        }
        var parameters: [UInt32] = []
        while !reader.isAtEnd { parameters.append(try reader.uint32()) }
        return Response(code: code, transaction: transaction, parameters: parameters)
    }

    /// A payload-only dataset must not be mistaken for a container. Strip only an
    /// exact, complete type-2 container with this operation; transaction IDs may
    /// be rewritten by the native framework, so they are deliberately not compared.
    /// Nonmatching/incomplete prefixes remain unchanged for the dataset consumer.
    static func payload(_ data: Data, operation: UInt16, maxBytes: Int) throws -> Data {
        guard maxBytes > 0 else { throw PTPReadError.limit("payload budget") }
        let limit = min(maxBytes, objectHardLimit)
        // ImageCaptureCore already buffered this data before calling us. This is
        // a validation cap, not a streaming or driver-memory guarantee.
        guard data.count <= limit + 12 else { throw PTPReadError.limit("payload bytes") }
        if data.count >= 12 {
            let bytes = data.prefix(12)
            var header = try Reader(Data(bytes))
            let length = try header.uint32()
            let type = try header.uint16()
            let code = try header.uint16()
            _ = try header.uint32()
            if type == 2, code == operation, UInt64(length) == UInt64(data.count) {
                guard data.count - 12 <= limit else { throw PTPReadError.limit("payload bytes") }
                return Data(data.dropFirst(12))
            }
        }
        guard data.count <= limit else { throw PTPReadError.limit("payload bytes") }
        return data
    }

    static func event(_ data: Data) -> PTPEvent? {
        // Standard event containers carry at most three UInt32 parameters.
        guard data.count >= 12, data.count <= 24, (data.count - 12) % 4 == 0,
              var reader = try? Reader(data),
              let length = try? reader.uint32(), UInt64(length) == UInt64(data.count),
              let type = try? reader.uint16(), type == 4,
              let code = try? reader.uint16(),
              (0x4000...0x4FFF).contains(code) || (0xC000...0xCFFF).contains(code),
              (try? reader.uint32()) != nil else { return nil }
        var parameters: [UInt32] = []
        while !reader.isAtEnd {
            guard let parameter = try? reader.uint32() else { return nil }
            parameters.append(parameter)
        }
        return PTPEvent(code: code, parameters: parameters)
    }

    static func deviceInfo(_ data: Data) throws -> PTPDeviceInformation {
        var reader = try Reader(data)
        _ = try reader.uint16() // StandardVersion
        _ = try reader.uint32() // VendorExtensionID (information only)
        _ = try reader.uint16() // VendorExtensionVersion
        _ = try reader.string() // VendorExtensionDesc
        _ = try reader.uint16() // FunctionalMode
        let operations = Set(try reader.uint16Array(maxCount: 4096))
        _ = try reader.uint16Array(maxCount: 4096) // EventsSupported
        _ = try reader.uint16Array(maxCount: 4096) // DevicePropertiesSupported
        _ = try reader.uint16Array(maxCount: 4096) // CaptureFormats
        _ = try reader.uint16Array(maxCount: 4096) // ImageFormats
        let manufacturer = try reader.string()
        let model = try reader.string()
        let version = try reader.string()
        _ = try reader.string() // SerialNumber: parsed for bounds, never exposed/logged.
        try reader.requireEnd("DeviceInfo dataset")
        return PTPDeviceInformation(manufacturer: manufacturer, model: model, version: version, operations: operations)
    }

    static func storageIDs(_ data: Data) throws -> [UInt32] {
        var reader = try Reader(data)
        let values = try reader.uint32Array(maxCount: 4096)
        try reader.requireEnd("StorageIDs dataset")
        return values
    }

    static func handles(_ data: Data) throws -> [UInt32] {
        var reader = try Reader(data)
        let values = try reader.uint32Array(maxCount: maxHandles)
        try reader.requireEnd("ObjectHandles dataset")
        return values
    }

    static func objectInfo(_ data: Data, handle: UInt32) throws -> PTPObjectInformation {
        var reader = try Reader(data)
        _ = try reader.uint32() // StorageID
        let format = try reader.uint16()
        _ = try reader.uint16() // ProtectionStatus
        let size = Int64(try reader.uint32()) // ObjectCompressedSize, unsigned on wire
        _ = try reader.uint16() // ThumbFormat
        _ = try reader.uint32() // ThumbCompressedSize
        _ = try reader.uint32() // ThumbPixWidth
        _ = try reader.uint32() // ThumbPixHeight
        let width = try reader.uint32()
        let height = try reader.uint32()
        _ = try reader.uint32() // ImageBitDepth
        _ = try reader.uint32() // ParentObject
        _ = try reader.uint16() // AssociationType
        _ = try reader.uint32() // AssociationDesc
        _ = try reader.uint32() // SequenceNumber; fixed layout ends at byte 52
        let name = try reader.string()
        _ = try reader.string() // CaptureDate
        _ = try reader.string() // ModificationDate
        _ = try reader.string() // Keywords
        try reader.requireEnd("ObjectInfo dataset")
        return PTPObjectInformation(handle: handle, name: name, size: size, format: format, width: width, height: height)
    }

    static func uniqueHandles(_ values: [UInt32]) throws -> [UInt32] {
        var seen = Set<UInt32>()
        var result: [UInt32] = []
        for value in values where value != 0 && value != UInt32.max {
            if seen.insert(value).inserted {
                guard result.count < maxHandles else { throw PTPReadError.limit("inventory handles") }
                result.append(value)
            }
        }
        return result
    }

    static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    static func append(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    /// Bytewise decoding avoids alignment assumptions about Data's storage.
    struct Reader {
        private let bytes: [UInt8]
        private(set) var offset = 0
        var isAtEnd: Bool { offset == bytes.count }
        var remaining: Int { bytes.count - offset }

        init(_ data: Data) throws {
            guard data.count <= metadataLimit else { throw PTPReadError.limit("metadata bytes") }
            bytes = Array(data)
        }

        mutating func uint8() throws -> UInt8 {
            guard remaining >= 1 else { throw PTPReadError.malformed("UInt8") }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func uint16() throws -> UInt16 {
            guard remaining >= 2 else { throw PTPReadError.malformed("UInt16") }
            let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            offset += 2
            return value
        }

        mutating func uint32() throws -> UInt32 {
            guard remaining >= 4 else { throw PTPReadError.malformed("UInt32") }
            var value: UInt32 = 0
            for i in 0..<4 { value |= UInt32(bytes[offset + i]) << (i * 8) }
            offset += 4
            return value
        }

        mutating func string() throws -> String {
            let count = Int(try uint8()) // UTF-16 code units INCLUDING the NUL terminator
            if count == 0 { return "" }
            guard count <= remaining / 2 else { throw PTPReadError.malformed("UTF-16 string length") }
            var units: [UInt16] = []
            for _ in 0..<count { units.append(try uint16()) }
            guard units.last == 0 else { throw PTPReadError.malformed("UTF-16 string terminator") }
            units.removeLast()
            var i = 0
            while i < units.count {
                let unit = units[i]
                guard unit != 0 else { throw PTPReadError.malformed("embedded UTF-16 terminator") }
                if (0xD800...0xDBFF).contains(unit) {
                    guard i + 1 < units.count, (0xDC00...0xDFFF).contains(units[i + 1]) else {
                        throw PTPReadError.malformed("UTF-16 surrogate pair")
                    }
                    i += 2
                } else {
                    guard !(0xDC00...0xDFFF).contains(unit) else { throw PTPReadError.malformed("UTF-16 surrogate pair") }
                    i += 1
                }
            }
            return String(decoding: units, as: UTF16.self)
        }

        mutating func uint16Array(maxCount: Int) throws -> [UInt16] {
            let count = try arrayCount(width: 2, maxCount: maxCount)
            var result: [UInt16] = []
            result.reserveCapacity(count)
            for _ in 0..<count { result.append(try uint16()) }
            return result
        }

        mutating func uint32Array(maxCount: Int) throws -> [UInt32] {
            let count = try arrayCount(width: 4, maxCount: maxCount)
            var result: [UInt32] = []
            result.reserveCapacity(count)
            for _ in 0..<count { result.append(try uint32()) }
            return result
        }

        private mutating func arrayCount(width: Int, maxCount: Int) throws -> Int {
            let count = try uint32()
            guard maxCount >= 0, UInt64(count) <= UInt64(maxCount) else { throw PTPReadError.limit("dataset array count") }
            guard UInt64(count) <= UInt64(remaining / width) else { throw PTPReadError.malformed("dataset array") }
            return Int(count)
        }

        func requireEnd(_ field: String) throws {
            guard isAtEnd else { throw PTPReadError.malformed("\(field) trailing bytes") }
        }
    }
}

#if canImport(ImageCaptureCore)
/// Read-only PTP over a native session owned by CameraCaptureService. This class
/// never opens/closes sessions, enables tethering, or sends vendor/control commands.
@available(macOS 10.15, iOS 13.0, *)
@MainActor
final class PTPCameraReader {
    private let camera: ICCameraDevice
    private let trace: (String) -> Void
    private var nextTransaction: UInt32 = 1
    private var pending: PendingCommand?
    private var unusable = false
    private var useAllStorage = false

    @MainActor
    private final class PendingCommand {
        let transaction: UInt32
        let operation: UInt16
        let started = ProcessInfo.processInfo.systemUptime
        let byteLimit: Int
        let continuation: CheckedContinuation<Data, Error>
        var timeout: Task<Void, Never>?
        var completed = false

        init(transaction: UInt32, operation: UInt16, byteLimit: Int, continuation: CheckedContinuation<Data, Error>) {
            self.transaction = transaction
            self.operation = operation
            self.byteLimit = byteLimit
            self.continuation = continuation
        }
    }

    init(camera: ICCameraDevice, trace: @escaping (String) -> Void) {
        self.camera = camera
        self.trace = trace
    }

    func deviceInfo() async throws -> PTPDeviceInformation {
        let bytes = try await send(0x1001)
        let info = try PTPCodec.deviceInfo(bytes)
        let capabilities = info.operations.sorted().map { String(format: "%04X", Int($0)) }.joined(separator: ",")
        trace("PTP model=\(info.model) capabilities=\(capabilities)")
        return info
    }

    func inventory() async throws -> [UInt32] {
        if useAllStorage { return try await handles(storage: UInt32.max) }
        let stores: [UInt32]
        do {
            stores = try PTPCodec.storageIDs(await send(0x1004)).filter { $0 != 0 && $0 != UInt32.max }
        } catch let error as PTPResponseError where error.code == 0x2006 {
            return try await allStorageFallback(reason: "ParameterNotSupported")
        }
        if stores.isEmpty { return try await allStorageFallback(reason: "no exposed stores") }
        var result: [UInt32] = []
        var seen = Set<UInt32>()
        do {
            for storage in stores {
                for handle in try await handles(storage: storage) where seen.insert(handle).inserted {
                    guard result.count < PTPCodec.maxHandles else { throw PTPReadError.limit("inventory handles") }
                    result.append(handle)
                }
            }
        } catch let error as PTPResponseError where error.code == 0x2006 {
            return try await allStorageFallback(reason: "ParameterNotSupported")
        }
        return result
    }

    func objectInfo(_ handle: UInt32) async throws -> PTPObjectInformation {
        try validateHandle(handle)
        return try PTPCodec.objectInfo(await send(0x1008, parameters: [handle]), handle: handle)
    }

    func object(_ handle: UInt32, maxBytes: Int) async throws -> Data {
        try validateHandle(handle)
        guard maxBytes > 0 else { throw PTPReadError.limit("object byte budget") }
        return try await send(0x1009, parameters: [handle], byteLimit: min(maxBytes, PTPCodec.objectHardLimit), timeoutSeconds: 120)
    }

    /// Terminal cancellation: a driver request may still be outstanding. The
    /// tombstoned pending gate stays in place, and no subsequent send is permitted.
    func cancel() {
        invalidate(with: PTPReadError.cancelled)
    }

    private func validateHandle(_ handle: UInt32) throws {
        guard handle != 0 && handle != UInt32.max else { throw PTPResponseError(code: 0x2009) }
    }

    private func handles(storage: UInt32) async throws -> [UInt32] {
        let bytes = try await send(0x1007, parameters: [storage, 0, 0])
        return try PTPCodec.uniqueHandles(PTPCodec.handles(bytes))
    }

    private func allStorageFallback(reason: String) async throws -> [UInt32] {
        trace("PTP opcode=1007 allStorage fallback=\(reason)")
        let result = try await handles(storage: UInt32.max)
        useAllStorage = true // Cache only after a successful query and dataset parse.
        return result
    }

    private func send(_ operation: UInt16, parameters: [UInt32] = [], byteLimit: Int = PTPCodec.metadataLimit, timeoutSeconds: UInt64 = 20) async throws -> Data {
        guard !unusable else { throw PTPReadError.unusable }
        guard pending == nil else { throw PTPReadError.concurrentCommand }
        if Task.isCancelled {
            invalidate(with: PTPReadError.cancelled)
            throw PTPReadError.cancelled
        }
        let transaction = nextTransaction
        nextTransaction = nextTransaction == UInt32.max ? 1 : nextTransaction + 1
        let command = try PTPCodec.command(operation: operation, transaction: transaction, parameters: parameters)
        let bytes: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                if Task.isCancelled {
                    invalidate(with: PTPReadError.cancelled)
                    continuation.resume(throwing: PTPReadError.cancelled)
                    return
                }
                let gate = PendingCommand(transaction: transaction, operation: operation, byteLimit: byteLimit, continuation: continuation)
                pending = gate
                gate.timeout = Task { @MainActor [weak self, weak gate] in
                    do { try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000) }
                    catch { return }
                    guard let self, let gate, self.pending === gate, !gate.completed else { return }
                    self.invalidate(with: PTPReadError.timedOut(operation))
                }
                // No outgoing data phase is used by any whitelisted operation.
                // Keep native slots unlabeled until the codec validates which
                // is the response; build 37 failed by assuming response-first.
                camera.requestSendPTPCommand(command, outData: nil) { [weak self, weak gate] first, second, error in
                    guard let self, let gate else { return }
                    Task { @MainActor [self, gate] in
                        self.finish(gate, first: first, second: second, error: error)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                // Do not cancel a later request if this task completed before the
                // cancellation hop ran. Each cancellation targets its own gate.
                guard let self, let gate = self.pending, gate.transaction == transaction, !gate.completed else { return }
                self.invalidate(with: PTPReadError.cancelled)
            }
        }
        if Task.isCancelled {
            invalidate(with: PTPReadError.cancelled)
            throw PTPReadError.cancelled
        }
        return bytes
    }

    private func finish(_ gate: PendingCommand, first: Data, second: Data, error: Error?) {
        guard pending === gate, !gate.completed, !unusable else { return } // one-shot; ignore late callbacks
        gate.completed = true
        gate.timeout?.cancel()
        gate.timeout = nil
        pending = nil // The driver callback has arrived; another command is now safe.
        let elapsed = (ProcessInfo.processInfo.systemUptime - gate.started) * 1000
        let firstReply = try? PTPCodec.response(first)
        let secondReply = try? PTPCodec.response(second)
        let firstCode = firstReply.map { String(format: "%04X", Int($0.code)) } ?? "not-response"
        let secondCode = secondReply.map { String(format: "%04X", Int($0.code)) } ?? "not-response"
        trace(String(format: "PTP_NATIVE opcode=%04X firstBytes=%d secondBytes=%d firstResponse=%@ secondResponse=%@ ms=%.0f", Int(gate.operation), first.count, second.count, firstCode, secondCode, elapsed))
        do {
            // Do not hide a transport failure behind "missing response" when
            // the framework supplies empty callback buffers alongside NSError.
            if let error, firstReply == nil, secondReply == nil {
                let native = error as NSError
                throw PTPReadError.transport("domain=\(native.domain) code=\(native.code)")
            }
            let result = try PTPCodec.completion(first: first, second: second,
                operation: gate.operation, maxBytes: gate.byteLimit)
            if let error {
                let native = error as NSError
                throw PTPReadError.transport("domain=\(native.domain) code=\(native.code)")
            }
            // Native ImageCaptureCore may rewrite transaction IDs. Validate
            // the response/code, without comparing to the emitted transaction.
            trace(String(format: "PTP opcode=%04X response=%04X responseTransaction=%u responseSlot=%@ bytes=%d ms=%.0f", Int(gate.operation), Int(result.response.code), result.response.transaction, result.responseSlot, result.payload.count, elapsed))
            gate.continuation.resume(returning: result.payload)
        } catch {
            gate.continuation.resume(throwing: error)
        }
    }

    private func invalidate(with error: PTPReadError) {
        unusable = true
        guard let gate = pending, !gate.completed else { return }
        gate.completed = true
        gate.timeout?.cancel()
        gate.timeout = nil
        let elapsed = (ProcessInfo.processInfo.systemUptime - gate.started) * 1000
        trace(String(format: "PTP opcode=%04X response=abandoned bytes=0 ms=%.0f", Int(gate.operation), elapsed))
        // Keep pending as a tombstone. Neither timeout nor cancellation proves
        // that the native transport stopped; only the owner can reconnect it.
        gate.continuation.resume(throwing: error)
    }
}
#endif
