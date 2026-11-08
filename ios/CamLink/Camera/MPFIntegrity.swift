import Foundation

/// A deliberately narrow MPF 0100 / JPEG multi-picture index reader.
/// Offsets after entry zero are relative to the MP header's TIFF byte-order field.
/// Index metadata is bounded to its APP2 segment, never to the whole file.
/// This parser does not decode, rewrite, trim, or hash any image bytes.
enum MPFIntegrity {
    struct ImageRange: Sendable {
        let start: Int
        let length: Int
        let attribute: UInt32
        var end: Int { start + length } // Construction checks this addition.
    }

    struct Layout: Sendable {
        /// Index order, not file-offset order. Entry zero is always the primary.
        let images: [ImageRange]
    }

    enum Failure: Error, LocalizedError, Sendable, Equatable {
        case malformedHeader, duplicateIndex, malformedTIFF, malformedIFD
        case missingTag, duplicateTag, unsupportedVersion, invalidImageCount
        case invalidEntryTable, unsupportedFormat, invalidDependency
        case invalidPrimary, invalidRange, overlappingImages, excessiveUnindexedData
        case imageNotExactJPEG

        var errorDescription: String? {
            switch self {
            case .malformedHeader: return "MPF 的 JPG 標記區段無效或遭截斷"
            case .duplicateIndex: return "MPF 含重複索引"
            case .malformedTIFF: return "MPF TIFF 標頭或指標無效"
            case .malformedIFD: return "MPF IFD 結構或中繼資料範圍無效"
            case .missingTag: return "MPF 缺少必要索引標籤"
            case .duplicateTag: return "MPF 含重複必要標籤"
            case .unsupportedVersion: return "MPF 版本不受支援"
            case .invalidImageCount: return "MPF 影像數量必須為 2 至 8"
            case .invalidEntryTable: return "MPF 影像索引表無效"
            case .unsupportedFormat: return "MPF 影像格式或保留旗標不受支援"
            case .invalidDependency: return "MPF 影像相依索引無效"
            case .invalidPrimary: return "MPF 主影像與 JPG 範圍不一致"
            case .invalidRange: return "MPF 影像範圍超出檔案或驗證上限"
            case .overlappingImages: return "MPF 影像範圍重疊"
            case .excessiveUnindexedData: return "MPF 未索引資料超過 64 KiB"
            case .imageNotExactJPEG: return "MPF 索引範圍不是精確完整的 JPG"
            }
        }
    }

    /// Returns nil only when there is no MPF-magic APP2 before the first SOS.
    /// primaryBytes must come from JPEGIntegrity.inspect(data).eoiIndex + 2.
    /// Each declared range is structurally inspected here; callers must also
    /// fully ImageIO-decode every range and hash/save the original complete data.
    static func parse(_ data: Data, primaryBytes: Int) throws -> Layout? {
        let layout: Layout? = try data.withUnsafeBytes { raw in
            guard let segment = try findIndex(raw) else { return nil }
            guard data.count <= JPEGIntegrity.maximumBytes,
                  primaryBytes >= 4, primaryBytes <= data.count else {
                throw Failure.invalidRange
            }
            return try readIndex(raw, segment: segment, primaryBytes: primaryBytes)
        }
        guard let layout else { return nil }
        for image in layout.images {
            // dropFirst/prefix work even when the supplied Data has nonzero indices.
            let bytes = Data(data.dropFirst(image.start).prefix(image.length))
            do {
                let jpeg = try JPEGIntegrity.inspect(bytes)
                guard jpeg.eoiIndex == image.length - 2, jpeg.trailingBytes == 0 else {
                    throw Failure.imageNotExactJPEG
                }
            } catch {
                throw Failure.imageNotExactJPEG
            }
        }
        return layout
    }

    private struct Segment {
        let base: Int
        let end: Int
    }

    /// Walk JPEG header markers by their declared lengths; never search EXIF,
    /// entropy-coded bytes, or an unindexed suffix for a magic byte sequence.
    private static func findIndex(_ raw: UnsafeRawBufferPointer) throws -> Segment? {
        guard raw.count >= 2, raw[0] == 0xFF, raw[1] == 0xD8 else {
            throw Failure.malformedHeader
        }
        var position = 2
        var found: Segment?
        while position < raw.count {
            guard raw[position] == 0xFF else { throw Failure.malformedHeader }
            while position < raw.count, raw[position] == 0xFF { position += 1 }
            guard position < raw.count else { throw Failure.malformedHeader }
            let marker = raw[position]
            position += 1
            if marker == 0xD9 { return found }
            if marker == 0x01 { continue }
            guard (0xC0...0xFE).contains(marker), marker != 0xD8,
                  marker != 0xC8, !(0xD0...0xD7).contains(marker),
                  raw.count - position >= 2 else { throw Failure.malformedHeader }
            let length = Int(raw[position]) * 256 + Int(raw[position + 1])
            guard length >= 2, length <= raw.count - position else {
                throw Failure.malformedHeader
            }
            let payload = position + 2
            let end = position + length
            if marker == 0xE2, end - payload >= 4,
               raw[payload] == 0x4D, raw[payload + 1] == 0x50,
               raw[payload + 2] == 0x46, raw[payload + 3] == 0 {
                guard found == nil else { throw Failure.duplicateIndex }
                found = Segment(base: payload + 4, end: end)
            }
            if marker == 0xDA { return found }
            position = end
        }
        if found != nil { throw Failure.malformedHeader }
        return nil
    }

    private struct Reader {
        let raw: UnsafeRawBufferPointer
        let base: Int
        let count: Int
        let littleEndian: Bool

        func contains(_ offset: Int, _ length: Int) -> Bool {
            offset >= 0 && length >= 0 && offset <= count && length <= count - offset
        }
        func u16(_ offset: Int) throws -> UInt16 {
            guard contains(offset, 2) else { throw Failure.malformedTIFF }
            let a = UInt16(raw[base + offset]), b = UInt16(raw[base + offset + 1])
            return littleEndian ? a | (b << 8) : (a << 8) | b
        }
        func u32(_ offset: Int) throws -> UInt32 {
            guard contains(offset, 4) else { throw Failure.malformedTIFF }
            var result: UInt32 = 0
            for i in 0..<4 {
                let shift = littleEndian ? i * 8 : (3 - i) * 8
                result |= UInt32(raw[base + offset + i]) << shift
            }
            return result
        }
    }

    private static func readIndex(_ raw: UnsafeRawBufferPointer, segment: Segment,
                                  primaryBytes: Int) throws -> Layout {
        guard segment.end - segment.base >= 8 else { throw Failure.malformedTIFF }
        let first = raw[segment.base], second = raw[segment.base + 1]
        guard (first == 0x49 && second == 0x49) || (first == 0x4D && second == 0x4D) else {
            throw Failure.malformedTIFF
        }
        let reader = Reader(raw: raw, base: segment.base, count: segment.end - segment.base,
                            littleEndian: first == 0x49)
        guard try reader.u16(2) == 42 else { throw Failure.malformedTIFF }
        let ifd = Int(try reader.u32(4))
        guard ifd >= 8, reader.contains(ifd, 2) else { throw Failure.malformedIFD }
        let entries = Int(try reader.u16(ifd))
        guard (3...256).contains(entries), reader.contains(ifd, 2 + entries * 12 + 4) else {
            throw Failure.malformedIFD
        }
        let ifdEnd = ifd + 2 + entries * 12 + 4
        let nextIFD = Int(try reader.u32(ifdEnd - 4))
        // An attributes IFD may follow. It is not needed to establish image ranges.
        if nextIFD != 0, !(nextIFD >= 8 && reader.contains(nextIFD, 2)) {
            throw Failure.malformedIFD
        }
        var tags: [UInt16: Int] = [:]
        for index in 0..<entries {
            let entry = ifd + 2 + index * 12
            let tag = try reader.u16(entry)
            let type = try reader.u16(entry + 2)
            let count = try reader.u32(entry + 4)
            // Check all standard TIFF value pointers, including optional tags.
            let widths: [UInt16: UInt64] = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1,
                                          7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4]
            guard let width = widths[type], count > 0 else { throw Failure.malformedIFD }
            let byteCount = UInt64(count) * width
            if byteCount > 4 {
                let offset = Int(try reader.u32(entry + 8))
                guard byteCount <= UInt64(reader.count), offset >= 8,
                      reader.contains(offset, Int(byteCount)),
                      offset >= ifdEnd || offset + Int(byteCount) <= ifd else {
                    throw Failure.malformedIFD
                }
            }
            if tag == 0xB000 || tag == 0xB001 || tag == 0xB002 {
                guard tags[tag] == nil else { throw Failure.duplicateTag }
                tags[tag] = entry
            }
        }
        guard let version = tags[0xB000], let number = tags[0xB001],
              let table = tags[0xB002] else { throw Failure.missingTag }
        guard try reader.u16(version + 2) == 7, try reader.u32(version + 4) == 4,
              raw[segment.base + version + 8] == 0x30,
              raw[segment.base + version + 9] == 0x31,
              raw[segment.base + version + 10] == 0x30,
              raw[segment.base + version + 11] == 0x30 else {
            throw Failure.unsupportedVersion
        }
        guard try reader.u16(number + 2) == 4, try reader.u32(number + 4) == 1 else {
            throw Failure.invalidImageCount
        }
        let imageCount = Int(try reader.u32(number + 8))
        guard (2...8).contains(imageCount) else { throw Failure.invalidImageCount }
        guard try reader.u16(table + 2) == 7,
              try reader.u32(table + 4) == UInt32(16 * imageCount) else {
            throw Failure.invalidEntryTable
        }
        let tableOffset = Int(try reader.u32(table + 8))
        guard tableOffset >= 8, reader.contains(tableOffset, 16 * imageCount),
              tableOffset >= ifdEnd || tableOffset + 16 * imageCount <= ifd else {
            throw Failure.invalidEntryTable
        }
        var images: [ImageRange] = []
        for index in 0..<imageCount {
            let entry = tableOffset + index * 16
            let attribute = try reader.u32(entry)
            let size = UInt64(try reader.u32(entry + 4))
            let offset = UInt64(try reader.u32(entry + 8))
            // MP format bits 24...26 must denote JPEG; bits 27...28 are reserved.
            guard attribute & 0x1F000000 == 0 else { throw Failure.unsupportedFormat }
            for location in [entry + 12, entry + 14] {
                let dependency = Int(try reader.u16(location))
                guard dependency <= imageCount, dependency == 0 || dependency != index + 1 else {
                    throw Failure.invalidDependency
                }
            }
            if index == 0 {
                guard offset == 0, size == UInt64(primaryBytes),
                      attribute & 0x00FFFFFF == 0x00030000 else { throw Failure.invalidPrimary }
            } else if attribute & 0x00FFFFFF == 0x00030000 {
                throw Failure.invalidPrimary
            }
            let (start, startOverflow) = index == 0 ? (UInt64(0), false)
                : UInt64(segment.base).addingReportingOverflow(offset)
            let (end, endOverflow) = start.addingReportingOverflow(size)
            guard !startOverflow, !endOverflow, size >= 4,
                  size <= UInt64(JPEGIntegrity.maximumBytes), end <= UInt64(raw.count),
                  index == 0 || start >= UInt64(primaryBytes) else { throw Failure.invalidRange }
            images.append(ImageRange(start: Int(start), length: Int(size), attribute: attribute))
        }
        var cursor = 0
        var unindexed = 0
        for image in images.sorted(by: { $0.start < $1.start }) {
            guard image.start >= cursor else { throw Failure.overlappingImages }
            let gap = image.start - cursor
            guard gap <= JPEGIntegrity.maximumPaddingBytes else { throw Failure.excessiveUnindexedData }
            unindexed += gap
            cursor = image.end
        }
        let tail = raw.count - cursor
        guard tail <= JPEGIntegrity.maximumPaddingBytes,
              unindexed + tail <= JPEGIntegrity.maximumPaddingBytes else {
            throw Failure.excessiveUnindexedData
        }
        // These bounded gaps/tail are opaque MPF-unindexed data, NOT zero padding.
        return Layout(images: images)
    }
}
