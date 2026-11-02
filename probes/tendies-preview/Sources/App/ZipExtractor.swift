//
//  ZipExtractor.swift
//  TendiesPreview (Phase 0 probe)
//
//  Minimal, dependency-free ZIP reader for .tendies packages.
//
//  .tendies files are plain zip archives whose entries mix STORE (0) and
//  DEFLATE (8). CocoWall extracts them through its Rust core
//  (al_zip_extract_all), which this probe deliberately does NOT reuse —
//  the probe must stay a standalone project. The central-directory walk
//  below mirrors the pure-Swift reader already proven in CocoWall's
//  AppViewModel.zipCentralDirectoryNames; inflation uses the system
//  Compression framework (COMPRESSION_ZLIB == raw DEFLATE, RFC 1951,
//  which is exactly what zip method 8 stores). No third-party code.
//

import Compression
import Foundation

enum ZipExtractor {

    struct Entry {
        let name: String
        let method: UInt16
        let flags: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    enum ZipError: Error, CustomStringConvertible {
        case notAZip(String)
        case unsupportedEntry(String)
        case inflateFailed(String)

        var description: String {
            switch self {
            case .notAZip(let m): return "not a zip: \(m)"
            case .unsupportedEntry(let m): return "unsupported entry: \(m)"
            case .inflateFailed(let m): return "inflate failed: \(m)"
            }
        }
    }

    // MARK: - Central directory (mirrors CocoWall's proven reader)

    /// Parse the central directory of the zip at `url`.
    /// Returns nil for unreadable archives and for zip64 (sentinel values),
    /// matching CocoWall's behaviour of bailing out instead of guessing.
    static func centralDirectory(of data: Data) -> [Entry]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { return nil }

        // Find End-Of-Central-Directory by scanning the tail backwards
        // (comment can be up to 65535 bytes).
        let tailLen = min(65_557, bytes.count)
        var eocd: Int? = nil
        var i = bytes.count - 22
        let floor = bytes.count - tailLen
        while i >= floor {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard let e = eocd else { return nil }

        func u16(_ o: Int) -> Int { Int(bytes[o]) | (Int(bytes[o + 1]) << 8) }
        func u32(_ o: Int) -> UInt32 {
            UInt32(bytes[o]) | (UInt32(bytes[o + 1]) << 8) | (UInt32(bytes[o + 2]) << 16) | (UInt32(bytes[o + 3]) << 24)
        }

        var remaining = u16(e + 10)
        var cursor = Int(u32(e + 16))
        if remaining == 0xFFFF || u32(e + 16) == 0xFFFF_FFFF { return nil } // zip64: bail

        var entries: [Entry] = []
        while remaining > 0 {
            guard cursor + 46 <= bytes.count else { return nil }
            guard bytes[cursor] == 0x50, bytes[cursor + 1] == 0x4B,
                  bytes[cursor + 2] == 0x01, bytes[cursor + 3] == 0x02 else { return nil }
            let flags = UInt16(u16(cursor + 8))
            let method = UInt16(u16(cursor + 10))
            let compSize = Int(u32(cursor + 20))
            let uncompSize = Int(u32(cursor + 24))
            let nameLen = u16(cursor + 28)
            let extraLen = u16(cursor + 30)
            let commentLen = u16(cursor + 32)
            let localOffset = Int(u32(cursor + 42))
            guard cursor + 46 + nameLen <= bytes.count else { return nil }
            let nameData = Data(bytes[(cursor + 46)..<(cursor + 46 + nameLen)])
            let name = String(data: nameData, encoding: .utf8)
                ?? String(decoding: nameData, as: UTF8.self)
            entries.append(Entry(name: name, method: method, flags: flags,
                                 compressedSize: compSize, uncompressedSize: uncompSize,
                                 localHeaderOffset: localOffset))
            cursor += 46 + nameLen + extraLen + commentLen
            remaining -= 1
        }
        return entries
    }

    // MARK: - Extraction

    /// Extract all file entries of the zip at `zipURL` into `destDir`.
    /// Skips __MACOSX / AppleDouble / .DS_Store noise (same filter the
    /// CocoWall importer applies). Returns (writtenFiles, per-entry notes).
    static func extract(zipURL: URL, to destDir: URL) throws -> (files: [String], notes: [String]) {
        let data = try Data(contentsOf: zipURL)
        guard let entries = centralDirectory(of: data) else {
            throw ZipError.notAZip("central directory not found or zip64")
        }
        let bytes = [UInt8](data)
        let fm = FileManager.default
        var written: [String] = []
        var notes: [String] = []

        for entry in entries {
            let name = entry.name
            if name.hasSuffix("/") { continue } // directory entry
            if name.contains("__MACOSX/") || name.hasSuffix(".DS_Store") { continue }
            let base = (name as NSString).lastPathComponent
            if base.hasPrefix("._") { continue } // AppleDouble shadow file
            if entry.flags & 0x0001 != 0 {
                notes.append("skip encrypted entry \(name)")
                continue
            }
            // Local header: signature(4) ... nameLen@26, extraLen@28.
            let lo = entry.localHeaderOffset
            guard lo + 30 <= bytes.count,
                  bytes[lo] == 0x50, bytes[lo + 1] == 0x4B,
                  bytes[lo + 2] == 0x03, bytes[lo + 3] == 0x04 else {
                notes.append("skip \(name): bad local header")
                continue
            }
            let lNameLen = Int(bytes[lo + 26]) | (Int(bytes[lo + 27]) << 8)
            let lExtraLen = Int(bytes[lo + 28]) | (Int(bytes[lo + 29]) << 8)
            let dataStart = lo + 30 + lNameLen + lExtraLen
            // NOTE: when flag bit 3 (data descriptor) is set the LOCAL
            // header sizes may be zero — always trust the central sizes.
            guard dataStart + entry.compressedSize <= bytes.count else {
                notes.append("skip \(name): truncated data")
                continue
            }
            let raw = Data(bytes[dataStart..<(dataStart + entry.compressedSize)])
            let content: Data
            switch entry.method {
            case 0:
                content = raw
            case 8:
                guard let inflated = inflate(raw, expectedSize: entry.uncompressedSize) else {
                    throw ZipError.inflateFailed(name)
                }
                content = inflated
            default:
                notes.append("skip \(name): compression method \(entry.method) unsupported")
                continue
            }
            // Path safety: strip any ".." components before writing.
            let safeParts = name.split(separator: "/").filter { $0 != ".." && $0 != "." }
            guard !safeParts.isEmpty else { continue }
            let dest = safeParts.reduce(destDir) { $0.appendingPathComponent(String($1)) }
            try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try content.write(to: dest)
            written.append(name)
        }
        return (written, notes)
    }

    // MARK: - DEFLATE via Compression framework

    /// Inflate a raw DEFLATE stream. First attempt feeds the stream as-is
    /// (zip method 8 is raw deflate). Some encoders wrap the stream in a
    /// zlib header (0x78 ..) + Adler-32 trailer despite the zip spec; if
    /// the raw attempt fails and that signature is present, retry with
    /// the wrapper stripped. Returns nil when both attempts fail.
    static func inflate(_ src: Data, expectedSize: Int) -> Data? {
        if expectedSize == 0 { return Data() }
        if let out = inflateRaw(src, expectedSize: expectedSize) { return out }
        let raw = [UInt8](src)
        if raw.count > 6, raw[0] == 0x78 {
            let stripped = Data(raw[2..<(raw.count - 4)])
            return inflateRaw(stripped, expectedSize: expectedSize)
        }
        return nil
    }

    private static func inflateRaw(_ src: Data, expectedSize: Int) -> Data? {
        var out = Data(count: expectedSize)
        let produced: Int = out.withUnsafeMutableBytes { dst in
            src.withUnsafeBytes { s in
                guard let dstPtr = dst.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let srcPtr = s.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else { return 0 }
                return compression_decode_buffer(dstPtr, expectedSize,
                                                 srcPtr, src.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        return produced == expectedSize ? out : nil
    }
}
