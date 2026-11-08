import Foundation

/// Standalone offline executable, deliberately outside the app source folder.
/// Run on the Mac runner before the iOS SDK build:
/// swiftc ios/CamLink/Camera/PTPCameraReader.swift ios/PTPCodecTests.swift -o /tmp/camlink-ptp-codec-tests
/// /tmp/camlink-ptp-codec-tests
@main
enum PTPCodecChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static var checks = 0

    static func expect(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(description: "FAIL: \(label)") }
        checks += 1
    }

    static func rejects(_ label: String, _ body: () throws -> Void) throws {
        do { try body() }
        catch {
            guard error is PTPReadError else { throw Failure(description: "FAIL: \(label): unexpected error \(error)") }
            checks += 1
            return
        }
        throw Failure(description: "FAIL: \(label): accepted malformed input")
    }

    static func expectResponseError(_ label: String, code: UInt16 = 0x2019, _ body: () throws -> Void) throws {
        do { try body() }
        catch let error as PTPResponseError {
            guard error.code == code else {
                throw Failure(description: "FAIL: \(label): unexpected response code \(error.code)")
            }
            checks += 1
            return
        }
        catch { throw Failure(description: "FAIL: \(label): unexpected error \(error)") }
        throw Failure(description: "FAIL: \(label): accepted error response")
    }

    static func u16(_ values: [UInt16]) -> Data {
        var result = Data()
        for value in values { PTPCodec.append(value, to: &result) }
        return result
    }

    static func u32(_ values: [UInt32]) -> Data {
        var result = Data()
        for value in values { PTPCodec.append(value, to: &result) }
        return result
    }

    static func array16(_ values: [UInt16]) -> Data {
        u32([UInt32(values.count)]) + u16(values)
    }

    static func array32(_ values: [UInt32]) -> Data {
        u32([UInt32(values.count)]) + u32(values)
    }

    static func string(_ value: String) -> Data {
        let units = Array(value.utf16)
        precondition(units.count < 255)
        return Data([UInt8(units.count + 1)]) + u16(units + [0])
    }

    static func container(type: UInt16, code: UInt16, transaction: UInt32 = 0xAABBCCDD, data: Data = Data()) -> Data {
        u32([UInt32(12 + data.count)]) + u16([type, code]) + u32([transaction]) + data
    }

    static func deviceDataset(vendorDescription: String = "LUMIX") -> Data {
        var data = u16([100]) + u32([0x00000006]) + u16([100])
        data += string(vendorDescription)
        data += u16([0])
        data += array16([0x1001, 0x1004, 0x1007, 0x1008, 0x1009, 0x1009])
        data += array16([0x4002, 0x4003])
        data += array16([0x5001])
        data += array16([])
        data += array16([0x3801, 0x3800])
        data += string("Panasonic")
        data += string("DC-S1RM2")
        data += string("1.2")
        data += string("TEST-SERIAL-NOT-EXPOSED")
        return data
    }

    static func objectDataset(name: String = "写真📷.JPG", size: UInt32 = 0xF1234567, format: UInt16 = 0x3801) -> Data {
        var data = u32([0x00010001])
        data += u16([format, 0])
        data += u32([size])
        data += u16([0x3801])
        data += u32([1234, 160, 120, 9520, 6336, 24, 0])
        data += u16([0])
        data += u32([0, 7])
        precondition(data.count == 52)
        data += string(name)
        data += string("20261108T080000")
        data += Data([0]) // PTP's zero-count empty string is valid.
        data += string("") // A one-unit NUL empty string is also valid.
        return data
    }

    static func checkCommands() throws {
        let wire = try PTPCodec.command(operation: 0x1007, transaction: 0x12345678, parameters: [0xFFFFFFFF, 0, 0])
        let expected = Data([
            0x18, 0, 0, 0, 1, 0, 7, 0x10, 0x78, 0x56, 0x34, 0x12,
            0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0
        ])
        try expect(wire == expected, "exact LE command header and three parameters")
        let noParameters = try PTPCodec.command(operation: 0x1001, transaction: 1)
        try expect(noParameters == Data([12, 0, 0, 0, 1, 0, 1, 0x10, 1, 0, 0, 0]), "GetDeviceInfo wire")
        for code in PTPCodec.allowedOperations {
            try expect(try PTPCodec.command(operation: code, transaction: 1).count == 12, "allowed opcode \(code)")
        }
        for code in [UInt16(0x1002), 0x1003, 0x100A, 0x100E, 0x1016, 0x101B, 0x9401, 0xFFFF] {
            try rejects("session/control/delete/vendor opcode \(code)") { _ = try PTPCodec.command(operation: code, transaction: 1) }
        }
        try expect(try PTPCodec.command(operation: 0x1009, transaction: UInt32.max, parameters: [1, 2, 3, 4, 5]).count == 32, "five wire parameters maximum")
        try rejects("six command parameters") { _ = try PTPCodec.command(operation: 0x1009, transaction: 1, parameters: [1, 2, 3, 4, 5, 6]) }
    }

    static func checkReaders() throws {
        var reader = try PTPCodec.Reader(Data([0xFE]) + u16([0xABCD]) + u32([0xFEDCBA98]))
        try expect(try reader.uint8() == 0xFE, "UInt8 decode")
        try expect(try reader.uint16() == 0xABCD, "unaligned LE UInt16 decode")
        try expect(try reader.uint32() == 0xFEDCBA98, "unaligned LE UInt32 decode")
        try expect(reader.isAtEnd, "reader consumes exact bytes")
        try rejects("UInt8 end bounds") { _ = try reader.uint8() }
        for length in 0..<4 {
            try rejects("UInt32 truncated \(length)") {
                var r = try PTPCodec.Reader(Data(repeating: 0, count: length))
                _ = try r.uint32()
            }
        }
        for value in ["", "Panasonic", "日本語", "A📷Z"] {
            var r = try PTPCodec.Reader(string(value))
            try expect(try r.string() == value, "UTF16 round trip \(value)")
            try expect(r.isAtEnd, "UTF16 consumes terminator")
        }
        var empty = try PTPCodec.Reader(Data([0]))
        try expect(try empty.string() == "", "zero length string")
        let invalidStrings: [Data] = [
            Data(), Data([2, 65, 0]), Data([1, 65, 0]),
            Data([2]) + u16([0xD800, 0]), Data([2]) + u16([0xDC00, 0]),
            Data([3]) + u16([0xD800, 65, 0]), Data([3]) + u16([65, 0, 66]),
            Data([3]) + u16([0, 65, 0]), Data([255, 0, 0])
        ]
        for (index, value) in invalidStrings.enumerated() {
            try rejects("malformed UTF16 \(index)") {
                var r = try PTPCodec.Reader(value)
                _ = try r.string()
            }
        }
        var a16 = try PTPCodec.Reader(array16([1, 0xFFFF, 0x8000]))
        try expect(try a16.uint16Array(maxCount: 3) == [1, 0xFFFF, 0x8000], "UInt16 array")
        var a32 = try PTPCodec.Reader(array32([0, 0xFFFFFFFF, 0x80000000]))
        try expect(try a32.uint32Array(maxCount: 3) == [0, 0xFFFFFFFF, 0x80000000], "unsigned UInt32 array")
        try rejects("array16 over count cap") {
            var r = try PTPCodec.Reader(array16([1, 2]))
            _ = try r.uint16Array(maxCount: 1)
        }
        try rejects("array32 over count cap") {
            var r = try PTPCodec.Reader(array32([1, 2]))
            _ = try r.uint32Array(maxCount: 1)
        }
        try rejects("array16 true byte bounds") {
            var r = try PTPCodec.Reader(u32([2]) + u16([1]))
            _ = try r.uint16Array(maxCount: 4096)
        }
        try rejects("array32 true byte bounds") {
            var r = try PTPCodec.Reader(u32([2]) + u32([1]))
            _ = try r.uint32Array(maxCount: 4096)
        }
        try rejects("array count UInt32.max without allocation") {
            var r = try PTPCodec.Reader(u32([UInt32.max]))
            _ = try r.uint32Array(maxCount: PTPCodec.maxHandles)
        }
        try rejects("metadata hard limit") { _ = try PTPCodec.Reader(Data(repeating: 0, count: PTPCodec.metadataLimit + 1)) }
    }

    static func checkDatasets() throws {
        let device = deviceDataset()
        let info = try PTPCodec.deviceInfo(device)
        try expect(info.manufacturer == "Panasonic" && info.model == "DC-S1RM2" && info.version == "1.2", "DeviceInfo offsets and strings")
        try expect(info.operations == PTPCodec.allowedOperations, "DeviceInfo UInt16 arrays and duplicate elimination")
        for length in 0..<device.count {
            try rejects("DeviceInfo truncation \(length)") { _ = try PTPCodec.deviceInfo(Data(device.prefix(length))) }
        }
        try rejects("DeviceInfo trailing bytes") { _ = try PTPCodec.deviceInfo(device + Data([0])) }
        var badDevice = u16([100]) + u32([6]) + u16([100]) + string("") + u16([0])
        badDevice += u32([4097])
        try rejects("DeviceInfo operations count limit") { _ = try PTPCodec.deviceInfo(badDevice) }
        let object = objectDataset()
        let objectInfo = try PTPCodec.objectInfo(object, handle: 56)
        try expect(objectInfo.handle == 56 && objectInfo.name == "写真📷.JPG", "ObjectInfo handle and UTF16 filename")
        try expect(objectInfo.size == Int64(0xF1234567), "ObjectInfo unsigned compressed size")
        try expect(objectInfo.format == 0x3801 && objectInfo.isJPEG, "ObjectInfo JPEG format")
        try expect(objectInfo.width == 9520 && objectInfo.height == 6336, "ObjectInfo fixed 52 byte offsets")
        let unknownSize = try PTPCodec.objectInfo(objectDataset(size: UInt32.max), handle: 1)
        try expect(unknownSize.size == 4_294_967_295, "unknown size sentinel stays unsigned")
        let raw = try PTPCodec.objectInfo(objectDataset(name: "PHOTO.RW2", size: 0, format: 0x3800), handle: 2)
        try expect(!raw.isJPEG && raw.size == 0, "non-JPEG generic format")
        for name in ["PHOTO.JPG", "PHOTO.JpEg"] {
            let genericJPEG = try PTPCodec.objectInfo(objectDataset(name: name, format: 0x3800), handle: 2)
            try expect(genericJPEG.isJPEG, "Android-compatible JPEG filename fallback")
        }
        for length in 0..<object.count {
            try rejects("ObjectInfo truncation \(length)") { _ = try PTPCodec.objectInfo(Data(object.prefix(length)), handle: 56) }
        }
        try rejects("ObjectInfo trailing bytes") { _ = try PTPCodec.objectInfo(object + Data([0]), handle: 1) }
        try expect(try PTPCodec.storageIDs(array32([0x10001, 0x20001])) == [0x10001, 0x20001], "StorageIDs unsigned dataset")
        try expect(try PTPCodec.storageIDs(array32([])).isEmpty, "no exposed stores dataset")
        try expect(try PTPCodec.handles(array32([0, 56, 56, UInt32.max, 77])) == [0, 56, 56, UInt32.max, 77], "ObjectHandles raw parsing")
        try expect(try PTPCodec.uniqueHandles([0, 56, 56, UInt32.max, 77, 56]) == [56, 77], "stable unique handle inventory filters sentinels")
        try rejects("StorageIDs truncated array") { _ = try PTPCodec.storageIDs(u32([1])) }
        try rejects("ObjectHandles truncated array") { _ = try PTPCodec.handles(u32([2]) + u32([56])) }
        try rejects("StorageIDs count cap") { _ = try PTPCodec.storageIDs(u32([4097])) }
        try rejects("ObjectHandles count cap") { _ = try PTPCodec.handles(u32([1_000_001])) }
        try rejects("ObjectHandles trailing bytes") { _ = try PTPCodec.handles(array32([]) + Data([0])) }
    }

    static func checkResponsesAndEvents() throws {
        let ok = container(type: 3, code: 0x2001, transaction: 991, data: u32([56, 77]))
        let response = try PTPCodec.response(ok)
        try expect(response.code == 0x2001 && response.transaction == 991 && response.parameters == [56, 77], "response header and rewritten transaction parsed")
        for code in [UInt16(0x2006), 0x2009, 0x2019] {
            try expect(try PTPCodec.response(container(type: 3, code: code)).code == code, "error response preserved \(code)")
            let error = PTPResponseError(code: code)
            try expect(error.code == code && !(error.errorDescription ?? "").isEmpty, "retryable LocalizedError code \(code)")
        }
        for length in 0..<ok.count {
            try rejects("response truncation \(length)") { _ = try PTPCodec.response(Data(ok.prefix(length))) }
        }
        for type in [UInt16(1), 2, 4] {
            try rejects("wrong response container type \(type)") { _ = try PTPCodec.response(container(type: type, code: 0x2001)) }
        }
        try rejects("response unaligned params") { _ = try PTPCodec.response(container(type: 3, code: 0x2001, data: Data([1]))) }
        try rejects("response too many params") { _ = try PTPCodec.response(container(type: 3, code: 0x2001, data: u32([1, 2, 3, 4, 5, 6]))) }
        try rejects("response trailing bytes") { _ = try PTPCodec.response(ok + Data([0])) }
        var falseLength = ok
        falseLength[0] = 12
        try rejects("response false length") { _ = try PTPCodec.response(falseLength) }
        let event = container(type: 4, code: 0x4002, transaction: UInt32.max, data: u32([56]))
        try expect(event.count == 16, "actual 16-byte event layout")
        let parsed = PTPCodec.event(event)
        try expect(parsed?.code == 0x4002 && parsed?.parameters == [56], "ObjectAdded event handle")
        try expect(PTPCodec.event(container(type: 4, code: 0x400D))?.parameters == [], "zero-param event")
        try expect(PTPCodec.event(container(type: 4, code: 0xC001, data: u32([1, 2, 3])))?.parameters == [1, 2, 3], "vendor event parse is informational only")
        for length in 0..<event.count {
            try expect(PTPCodec.event(Data(event.prefix(length))) == nil, "truncated event \(length)")
        }
        try expect(PTPCodec.event(event + Data([0])) == nil, "event trailing bytes")
        try expect(PTPCodec.event(container(type: 3, code: 0x4002)) == nil, "event wrong type")
        try expect(PTPCodec.event(container(type: 4, code: 0x2001)) == nil, "event wrong code range")
        try expect(PTPCodec.event(container(type: 4, code: 0x4002, data: u32([1, 2, 3, 4]))) == nil, "event max three params")
    }

    static func checkNativeCompletion() throws {
        let ok = container(type: 3, code: 0x2001, transaction: 991)
        // Synthetic, fully parsed DeviceInfo: only the 235/12-byte callback shape
        // comes from the build 37 report. These are not camera raw-trace contents.
        // Its bounded vendor-description field supplies the length, not trailing bytes.
        let device = deviceDataset(vendorDescription: "BUILD37 SHAPE ONLY: SYNTHETIC PTP FIXTURE")
        try expect(device.count == 235 && ok.count == 12, "synthetic build 37 report byte shape, not real trace contents")
        let dataFirst = try PTPCodec.completion(first: device, second: ok, operation: 0x1001, maxBytes: 235)
        try expect(dataFirst.responseSlot == "second", "235-byte DeviceInfo first, 12-byte response second")
        try expect(dataFirst.payload == device, "data-first DeviceInfo payload preserved exactly")
        try expect(dataFirst.response.code == 0x2001 && dataFirst.response.transaction == 991 && dataFirst.response.parameters.isEmpty, "data-first response fields")
        let nativeDevice = try PTPCodec.deviceInfo(dataFirst.payload)
        try expect(nativeDevice.manufacturer == "Panasonic" && nativeDevice.model == "DC-S1RM2" && nativeDevice.version == "1.2" && nativeDevice.operations == PTPCodec.allowedOperations, "normalized data-first DeviceInfo exact dataset decode")

        let responseFirst = try PTPCodec.completion(first: ok, second: device, operation: 0x1001, maxBytes: 235)
        try expect(responseFirst.responseSlot == "first", "legacy response-first callback selected structurally")
        try expect(responseFirst.payload == device, "legacy DeviceInfo payload preserved exactly")
        try expect(try PTPCodec.deviceInfo(responseFirst.payload).model == "DC-S1RM2", "normalized legacy DeviceInfo decode")

        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x04, 0x50, 0x54, 0xFF, 0xD9])
        let wrappedJPEG = container(type: 2, code: 0x1009, transaction: 123, data: jpeg)
        let handleBytes = array32([56, 77, UInt32.max])
        let wrappedHandles = container(type: 2, code: 0x1007, transaction: 123, data: handleBytes)
        let objectBytes = objectDataset()
        let wrappedObjectInfo = container(type: 2, code: 0x1008, transaction: 123, data: objectBytes)
        let busy = container(type: 3, code: 0x2019)
        let tooLarge = Data(repeating: 0, count: PTPCodec.metadataLimit + 13)
        for responseIsFirst in [false, true] {
            let slot = responseIsFirst ? "first" : "second"
            func normalize(_ bytes: Data, operation: UInt16, budget: Int) throws -> PTPCodec.Completion {
                try PTPCodec.completion(first: responseIsFirst ? ok : bytes, second: responseIsFirst ? bytes : ok, operation: operation, maxBytes: budget)
            }
            let empty = try normalize(Data(), operation: 0x1009, budget: 1)
            try expect(empty.payload.isEmpty && empty.responseSlot == slot && empty.response.code == 0x2001, "empty GetObject data with OK in \(slot) slot")
            let wrappedEmpty = try normalize(container(type: 2, code: 0x1009), operation: 0x1009, budget: 1)
            try expect(wrappedEmpty.payload.isEmpty && wrappedEmpty.responseSlot == slot, "wrapped empty GetObject data, response \(slot)")
            for bytes in [jpeg, wrappedJPEG] {
                let object = try normalize(bytes, operation: 0x1009, budget: jpeg.count)
                try expect(object.payload == jpeg && object.responseSlot == slot, "JPEG bytes unchanged after native normalization, input \(bytes.count) bytes, response \(slot)")
            }
            let handles = try normalize(wrappedHandles, operation: 0x1007, budget: handleBytes.count)
            try expect(handles.responseSlot == slot && handles.payload == handleBytes, "wrapped GetHandles normalized, response \(slot)")
            try expect(try PTPCodec.handles(handles.payload) == [56, 77, UInt32.max], "normalized GetHandles fed to exact dataset codec, response \(slot)")
            let objectInfo = try normalize(wrappedObjectInfo, operation: 0x1008, budget: objectBytes.count)
            try expect(objectInfo.responseSlot == slot && objectInfo.payload == objectBytes, "wrapped ObjectInfo normalized, response \(slot)")
            let decodedObject = try PTPCodec.objectInfo(objectInfo.payload, handle: 56)
            try expect(decodedObject.handle == 56 && decodedObject.name == "写真📷.JPG" && decodedObject.size == Int64(0xF1234567) && decodedObject.width == 9520 && decodedObject.height == 6336, "normalized ObjectInfo fed to exact dataset codec, response \(slot)")

            for bytes in [Data(), Data([1]), tooLarge] {
                try expectResponseError("DeviceBusy wins over absent, malformed or oversized payload \(bytes.count) bytes, response \(slot)") {
                    _ = try PTPCodec.completion(first: responseIsFirst ? busy : bytes, second: responseIsFirst ? bytes : busy, operation: 0x1001, maxBytes: 1)
                }
            }
            try expectResponseError("DeviceBusy wins over zero payload budget, response \(slot)") {
                _ = try PTPCodec.completion(first: responseIsFirst ? busy : Data(), second: responseIsFirst ? Data() : busy, operation: 0x1001, maxBytes: 0)
            }
            for bytes in [jpeg, wrappedJPEG] {
                try rejects("native GetObject over budget \(bytes.count) bytes, response \(slot)") {
                    _ = try normalize(bytes, operation: 0x1009, budget: jpeg.count - 1)
                }
            }
            for budget in [0, -1] {
                try rejects("native OK payload invalid budget \(budget), response \(slot)") {
                    _ = try normalize(jpeg, operation: 0x1009, budget: budget)
                }
            }
        }

        let rewritten = container(type: 3, code: 0x2001, transaction: UInt32.max, data: u32([1, 2, 3, 4, 5]))
        let rewrittenCompletion = try PTPCodec.completion(first: wrappedJPEG, second: rewritten, operation: 0x1009, maxBytes: jpeg.count)
        try expect(rewrittenCompletion.responseSlot == "second" && rewrittenCompletion.response.transaction == UInt32.max && rewrittenCompletion.response.parameters == [1, 2, 3, 4, 5] && rewrittenCompletion.payload == jpeg, "32-byte response, five parameters and rewritten transaction independent of data transaction")
        for code in [UInt16(0x2000), 0x2006, 0x2009, 0x2FFF] {
            let reply = container(type: 3, code: code)
            try expectResponseError("non-OK response range code \(code) preserved before payload validation", code: code) {
                _ = try PTPCodec.completion(first: tooLarge, second: reply, operation: 0x1001, maxBytes: 1)
            }
        }
        try rejects("two OK responses are ambiguous, not an empty data phase") {
            _ = try PTPCodec.completion(first: ok, second: ok, operation: 0x1009, maxBytes: 1)
        }
        try rejects("OK and DeviceBusy responses are ambiguous") {
            _ = try PTPCodec.completion(first: ok, second: busy, operation: 0x1009, maxBytes: 1)
        }
        try rejects("two DeviceBusy responses are ambiguous before response-code handling") {
            _ = try PTPCodec.completion(first: busy, second: busy, operation: 0x1009, maxBytes: 1)
        }
        try rejects("missing response in both empty callback slots") {
            _ = try PTPCodec.completion(first: Data(), second: Data(), operation: 0x1009, maxBytes: 1)
        }
        try rejects("neither callback slot is a response") {
            _ = try PTPCodec.completion(first: jpeg, second: wrappedJPEG, operation: 0x1009, maxBytes: jpeg.count)
        }
        var wrongLength = ok
        wrongLength[0] = 16
        let invalidResponses: [(String, Data)] = [
            ("short header", Data(ok.prefix(11))),
            ("declared length mismatch", wrongLength),
            ("command type", container(type: 1, code: 0x2001)),
            ("data type", container(type: 2, code: 0x2001)),
            ("event type", container(type: 4, code: 0x2001)),
            ("code below response range", container(type: 3, code: 0x1FFF)),
            ("code above response range", container(type: 3, code: 0x3000)),
            ("operation code, not response code", container(type: 3, code: 0x1001)),
            ("unaligned parameters", container(type: 3, code: 0x2001, data: Data([1]))),
            ("six parameters exceed 32 bytes", container(type: 3, code: 0x2001, data: u32([1, 2, 3, 4, 5, 6]))),
            ("trailing bytes", ok + Data([0]))
        ]
        for (label, bytes) in invalidResponses {
            try rejects("native malformed response first: \(label)") {
                _ = try PTPCodec.completion(first: bytes, second: Data(), operation: 0x1009, maxBytes: 100)
            }
            try rejects("native malformed response second: \(label)") {
                _ = try PTPCodec.completion(first: Data(), second: bytes, operation: 0x1009, maxBytes: 100)
            }
        }
    }

    static func checkPayloads() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x04, 0x50, 0x54, 0xFF, 0xD9])
        try expect(try PTPCodec.payload(jpeg, operation: 0x1009, maxBytes: jpeg.count) == jpeg, "payload-only JPEG preserved")
        let wrapped = container(type: 2, code: 0x1009, transaction: 999, data: jpeg)
        try expect(try PTPCodec.payload(wrapped, operation: 0x1009, maxBytes: jpeg.count) == jpeg, "matching data container stripped despite transaction rewrite")
        let longJPEG = jpeg + Data(repeating: 0xFF, count: 30)
        try expect(try PTPCodec.payload(longJPEG, operation: 0x1009, maxBytes: longJPEG.count) == longJPEG, "long JPEG not mistaken for header")
        let metadata = array32([56, 77])
        try expect(try PTPCodec.payload(metadata, operation: 0x1007, maxBytes: 100) == metadata, "payload-only metadata preserved")
        try expect(try PTPCodec.handles(PTPCodec.payload(container(type: 2, code: 0x1007, data: metadata), operation: 0x1007, maxBytes: 100)) == [56, 77], "wrapped handles decode")
        let wrongOperation = container(type: 2, code: 0x1008, data: jpeg)
        try expect(try PTPCodec.payload(wrongOperation, operation: 0x1009, maxBytes: 100) == wrongOperation, "wrong opcode header is not stripped")
        let wrongType = container(type: 3, code: 0x1009, data: jpeg)
        try expect(try PTPCodec.payload(wrongType, operation: 0x1009, maxBytes: 100) == wrongType, "wrong type header is not stripped")
        let truncated = Data(wrapped.dropLast())
        try expect(try PTPCodec.payload(truncated, operation: 0x1009, maxBytes: 100) == truncated, "incomplete header-like input preserved rather than partially stripped")
        let trailing = wrapped + Data([1])
        try expect(try PTPCodec.payload(trailing, operation: 0x1009, maxBytes: 100) == trailing, "container plus trailing bytes not stripped")
        try expect(try PTPCodec.payload(container(type: 2, code: 0x1009), operation: 0x1009, maxBytes: 1).isEmpty, "complete empty data phase")
        for length in 0..<12 {
            let bytes = Data(wrapped.prefix(length))
            try expect(try PTPCodec.payload(bytes, operation: 0x1009, maxBytes: 100) == bytes, "short payload prefix \(length) preserved")
        }
        try rejects("JPEG budget after stripping") { _ = try PTPCodec.payload(wrapped, operation: 0x1009, maxBytes: jpeg.count - 1) }
        try rejects("payload-only JPEG budget") { _ = try PTPCodec.payload(jpeg, operation: 0x1009, maxBytes: jpeg.count - 1) }
        try rejects("zero budget") { _ = try PTPCodec.payload(jpeg, operation: 0x1009, maxBytes: 0) }
        try rejects("negative budget") { _ = try PTPCodec.payload(jpeg, operation: 0x1009, maxBytes: -1) }
        let tooLargeMetadata = Data(repeating: 0, count: PTPCodec.metadataLimit + 13)
        try rejects("metadata payload cap") { _ = try PTPCodec.payload(tooLargeMetadata, operation: 0x1001, maxBytes: PTPCodec.metadataLimit) }
        // About 128 MiB, allocated once. Proves maxBytes > hard cap does not bypass it.
        let tooLargeObject = Data(repeating: 0, count: PTPCodec.objectHardLimit + 13)
        try rejects("128 MiB absolute object cap") { _ = try PTPCodec.payload(tooLargeObject, operation: 0x1009, maxBytes: Int.max) }
    }

    static func main() throws {
        try checkCommands()
        try checkReaders()
        try checkDatasets()
        try checkResponsesAndEvents()
        try checkNativeCompletion()
        try checkPayloads()
        print("PTPCodecChecks: \(checks) offline checks passed; no camera operations performed.")
    }
}
