import AppKit
import AVFoundation
import Darwin
import Foundation
import MediaPlayer
import os.lock
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Constants & Supported Formats

private enum PlayerConstants {
    static let sampleRate: Double = 48_000.0
    static let channels: Int = 2
    /// 20 seconds of 48 kHz stereo Float32 (~7.68 MB max RAM regardless of track length).
    static let ringCapacityFrames: Int = 48_000 * 20
    /// Wait for 100 ms of decoded PCM (or EOF) before starting hardware pull to prevent startup underruns.
    static let prebufferFrames: Int = 4_800
    /// 4 ms linear fade-in on start/seek/unpause to eliminate waveform discontinuity clicks.
    static let microFadeFrames: Int = 192

    static let supportedExtensions: Set<String> = [
        "ac4", "m4a", "mp4", "mka", "mkv", "mov",
        "flac", "wav", "opus", "ogg", "mp3", "aiff", "aif"
    ]

    static let customDecoderDefaultsKey = "AC4Player.customDecoderPath"
    static let savedTrackPathsDefaultsKey = "AC4Player.savedTrackPaths"
    static let volumeDefaultsKey = "AC4Player.volume"
    static let preampDefaultsKey = "AC4Player.preampDB"
}

// MARK: - Models

enum RepeatMode: Int, CaseIterable {
    case off = 0
    case all = 1
    case one = 2

    var systemImage: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var label: String {
        switch self {
        case .off: return "Repeat Off"
        case .all: return "Repeat All"
        case .one: return "Repeat One"
        }
    }
}

enum PipeStreamMode: Equatable, Sendable {
    /// Streams a RIFF/RF64 WAV header + uncompressed PCM over stdout (`-f wav`).
    /// Works across both LibreMPEG (which removed legacy `-f f32le` raw muxers) and mainline FFmpeg.
    case wav(pcmCodec: String?)
    /// Fallback for ultra-minimal builds that only enable the `flac` muxer (`-f flac`).
    case flac
}

struct DecoderCapabilities: Equatable, Sendable {
    var pipeMode: PipeStreamMode = .wav(pcmCodec: "pcm_f32le")
    var hasAresampleFilter: Bool = true
    var hasPipeProtocol: Bool = true
    var isBuiltInNative: Bool = false
}

enum DecoderStatus: Equatable {
    case readyAC4(source: String, path: String, versionLine: String, capabilities: DecoderCapabilities)
    case missingAC4Codec(path: String, versionLine: String, capabilities: DecoderCapabilities)
    case notFound(reason: String)

    var isAC4Capable: Bool {
        if case .readyAC4 = self { return true }
        return false
    }

    var isBuiltInNative: Bool {
        capabilities.isBuiltInNative
    }

    var activeBinaryPath: String? {
        guard !capabilities.isBuiltInNative else { return nil }
        switch self {
        case .readyAC4(_, let path, _, _), .missingAC4Codec(let path, _, _):
            return path
        case .notFound:
            return nil
        }
    }

    var displaySubtitle: String? {
        switch self {
        case .readyAC4(_, let path, let versionLine, let caps):
            return caps.isBuiltInNative ? versionLine : path
        case .missingAC4Codec(let path, _, _):
            return path
        case .notFound:
            return nil
        }
    }

    var capabilities: DecoderCapabilities {
        switch self {
        case .readyAC4(_, _, _, let caps), .missingAC4Codec(_, _, let caps):
            return caps
        case .notFound:
            return DecoderCapabilities()
        }
    }
}

struct TrackMetadata {
    var title: String
    var artist: String
    var albumArtist: String
    var album: String
    var trackNumber: Int?
    var trackTotal: Int?
    var discNumber: Int?
    var discTotal: Int?
    var year: String
    var codecName: String
    var isAC4: Bool
    var audioStreamIndex: Int
    var sampleRateHz: Int?
    var channelCount: Int?
    var bitrateKbps: Int?
    var durationSeconds: Double?
    var artworkData: Data?
    var hasArtwork: Bool = false
}

struct AudioTrack: Identifiable, Hashable {
    let id: UUID
    let url: URL
    var title: String
    var artist: String
    var albumArtist: String
    var album: String
    var trackNumber: Int?
    var trackTotal: Int?
    var discNumber: Int?
    var discTotal: Int?
    var year: String
    var codecName: String
    var isAC4: Bool
    var audioStreamIndex: Int
    var sampleRateHz: Int?
    var channelCount: Int?
    var bitrateKbps: Int?
    var durationSeconds: Double?
    let fileSizeBytes: Int64
    var hasEmbeddedArtwork: Bool

    static func == (lhs: AudioTrack, rhs: AudioTrack) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var formattedDuration: String {
        guard let d = durationSeconds, d.isFinite, d > 0 else { return "--:--" }
        return TimeFormatting.clockString(seconds: d)
    }

    var formattedTrackNumber: String {
        guard let n = trackNumber, n > 0 else { return "" }
        return "\(n)"
    }

    var formattedSpecs: String {
        var parts: [String] = []
        if let sr = sampleRateHz, sr > 0 {
            let khz = Double(sr) / 1000.0
            if abs(khz.rounded() - khz) < 0.01 {
                parts.append("\(Int(khz.rounded())) kHz")
            } else {
                parts.append(String(format: "%.1f kHz", khz))
            }
        }
        if let br = bitrateKbps, br > 0 {
            parts.append("\(br) kbps")
        }
        return parts.joined(separator: " · ")
    }

    var effectiveAlbumTitle: String {
        album.isEmpty ? "Unknown Album" : album
    }

    var effectiveArtist: String {
        if !artist.isEmpty { return artist }
        if !albumArtist.isEmpty { return albumArtist }
        return "Unknown Artist"
    }
}

enum TimeFormatting {
    static func clockString(seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let clamped = max(0, Int(seconds.rounded(.down)))
        let hrs = clamped / 3600
        let mins = (clamped % 3600) / 60
        let secs = clamped % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Safe Seek-Based MP4 / ISOBMFF Metadata & AC-4 Inspector

enum MP4MetadataReader {
    /// Maximum `moov` box size read into memory (32 MB) to prevent crafted files from exhausting RAM.
    private static let maxMoovSize: UInt64 = 32 * 1024 * 1024
    /// Maximum embedded cover art size accepted (16 MB).
    private static let maxArtworkSize: Int = 16 * 1024 * 1024

    static func inspect(url: URL, loadArtwork: Bool) -> TrackMetadata? {
        let ext = url.pathExtension.lowercased()
        guard ["m4a", "mp4", "mov"].contains(ext) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
        } catch {
            return nil
        }
        guard fileSize >= 16 else { return nil }

        var meta = TrackMetadata(
            title: url.deletingPathExtension().lastPathComponent,
            artist: "",
            albumArtist: "",
            album: "",
            trackNumber: nil,
            trackTotal: nil,
            discNumber: nil,
            discTotal: nil,
            year: "",
            codecName: ext.uppercased(),
            isAC4: false,
            audioStreamIndex: 0,
            sampleRateHz: nil,
            channelCount: nil,
            bitrateKbps: nil,
            durationSeconds: nil,
            artworkData: nil
        )

        var offset: UInt64 = 0
        var foundFTYPOrMOOV = false
        var mdatBytes: UInt64 = 0

        while offset + 8 <= fileSize {
            do {
                try handle.seek(toOffset: offset)
                guard let header = try handle.read(upToCount: 16), header.count >= 8 else { break }
                let size32 = readUInt32BE(header, at: 0)
                let fourCC = readFourCC(header, at: 4)

                var boxSize = UInt64(size32)
                var headerLen: UInt64 = 8
                if size32 == 1 {
                    guard header.count >= 16 else { break }
                    boxSize = readUInt64BE(header, at: 8)
                    headerLen = 16
                } else if size32 == 0 {
                    boxSize = fileSize - offset
                }

                guard boxSize >= headerLen, offset <= fileSize - boxSize else { break }

                if fourCC == "ftyp" {
                    foundFTYPOrMOOV = true
                } else if fourCC == "mdat" {
                    mdatBytes &+= (boxSize - headerLen)
                } else if fourCC == "moov" {
                    foundFTYPOrMOOV = true
                    let payloadLen = boxSize - headerLen
                    if payloadLen > 0 && payloadLen <= maxMoovSize {
                        try handle.seek(toOffset: offset + headerLen)
                        if let moovData = try handle.read(upToCount: Int(payloadLen)),
                           moovData.count == Int(payloadLen) {
                            parseMoov(moovData, into: &meta, loadArtwork: loadArtwork)
                        }
                    }
                }
                offset += boxSize
            } catch {
                break
            }
        }

        guard foundFTYPOrMOOV else { return nil }
        if meta.bitrateKbps == nil, let dur = meta.durationSeconds, dur > 0.5, mdatBytes > 0 {
            let kbps = Int(((Double(mdatBytes) * 8.0) / dur / 1000.0).rounded())
            if kbps > 0 && kbps < 20_000 {
                meta.bitrateKbps = kbps
            }
        }
        return meta
    }

    private static func readFourCC(_ data: Data, at offset: Int) -> String {
        String(data: Data(data[offset..<(offset + 4)]), encoding: .isoLatin1) ?? "    "
    }

    private static func parseMoov(_ data: Data, into meta: inout TrackMetadata, loadArtwork: Bool) {
        var audioTrackCounter = 0
        iterateBoxes(in: data, range: 0..<data.count) { fourCC, payloadRange in
            switch fourCC {
            case "mvhd":
                parseMvhd(data, range: payloadRange, into: &meta)
            case "trak":
                parseTrak(data, range: payloadRange, audioTrackCounter: &audioTrackCounter, into: &meta)
            case "udta":
                parseUdta(data, range: payloadRange, into: &meta, loadArtwork: loadArtwork)
            default:
                break
            }
        }
    }

    private static func parseMvhd(_ data: Data, range: Range<Int>, into meta: inout TrackMetadata) {
        guard range.count >= 20 else { return }
        let version = data[range.lowerBound]
        if version == 0 {
            guard range.count >= 20 else { return }
            let timescale = readUInt32BE(data, at: range.lowerBound + 12)
            let duration = readUInt32BE(data, at: range.lowerBound + 16)
            if timescale > 0 && duration > 0 {
                meta.durationSeconds = Double(duration) / Double(timescale)
            }
        } else if version == 1 {
            guard range.count >= 32 else { return }
            let timescale = readUInt32BE(data, at: range.lowerBound + 20)
            let duration = readUInt64BE(data, at: range.lowerBound + 24)
            if timescale > 0 && duration > 0 {
                meta.durationSeconds = Double(duration) / Double(timescale)
            }
        }
    }

    private static func parseTrak(
        _ data: Data,
        range: Range<Int>,
        audioTrackCounter: inout Int,
        into meta: inout TrackMetadata
    ) {
        var isAudioTrack = false
        var stsdRange: Range<Int>?

        iterateBoxes(in: data, range: range) { fourCC, childRange in
            guard fourCC == "mdia" else { return }
            iterateBoxes(in: data, range: childRange) { mdiaFCC, mdiaChild in
                if mdiaFCC == "hdlr", mdiaChild.count >= 12 {
                    let handlerType = readFourCC(data, at: mdiaChild.lowerBound + 8)
                    if handlerType == "soun" {
                        isAudioTrack = true
                    }
                } else if mdiaFCC == "minf" {
                    iterateBoxes(in: data, range: mdiaChild) { minfFCC, minfChild in
                        guard minfFCC == "stbl" else { return }
                        iterateBoxes(in: data, range: minfChild) { stblFCC, stblChild in
                            if stblFCC == "stsd" {
                                stsdRange = stblChild
                            }
                        }
                    }
                }
            }
        }

        guard isAudioTrack, let stsd = stsdRange, stsd.count >= 16 else { return }
        let currentStreamIdx = audioTrackCounter
        audioTrackCounter += 1

        // FullBox (4 bytes version/flags + 4 bytes entry_count) + first SampleEntry
        let entryStart = stsd.lowerBound + 8
        guard entryStart + 8 <= stsd.upperBound else { return }
        let entrySize = Int(readUInt32BE(data, at: entryStart))
        let codecFCC = readFourCC(data, at: entryStart + 4)
        guard entrySize >= 16, entryStart + entrySize <= stsd.upperBound else { return }

        // Prefer AC-4 stream if container has multiple audio tracks
        if meta.isAC4 && codecFCC != "ac-4" { return }

        let (friendlyCodec, ac4Flag) = mapMP4Codec(codecFCC)
        meta.codecName = friendlyCodec
        meta.isAC4 = ac4Flag
        meta.audioStreamIndex = currentStreamIdx

        // AudioSampleEntry v0/v1 layout: 8 header + 6 reserved + 2 data_ref_idx + 8 reserved + 2 channels + 2 sampleSize + 4 reserved + 4 sampleRate(16.16)
        if entryStart + 36 <= stsd.upperBound {
            let ch = Int(readUInt16BE(data, at: entryStart + 24))
            let srFixed = readUInt32BE(data, at: entryStart + 32)
            let sr = Int(srFixed >> 16)
            if ch > 0 && ch <= 32 {
                meta.channelCount = ch
            }
            if sr >= 8_000 && sr <= 384_000 {
                meta.sampleRateHz = sr
            }
            // AC-4 IMS always decodes at 48 kHz binaural stereo (some MP4 muxers store 48000 or 0 in stsd)
            if ac4Flag && (meta.sampleRateHz == nil || meta.sampleRateHz == 0) {
                meta.sampleRateHz = 48_000
            }
        }
    }

    private static func mapMP4Codec(_ fourCC: String) -> (String, Bool) {
        switch fourCC.trimmingCharacters(in: .whitespaces) {
        case "ac-4": return ("AC-4 IMS", true)
        case "ec-3": return ("E-AC-3", false)
        case "ac-3": return ("AC-3", false)
        case "alac": return ("ALAC", false)
        case "fLaC": return ("FLAC", false)
        case "Opus": return ("Opus", false)
        case "mp4a": return ("AAC", false)
        default: return (fourCC.uppercased(), false)
        }
    }

    private static func parseUdta(_ data: Data, range: Range<Int>, into meta: inout TrackMetadata, loadArtwork: Bool) {
        iterateBoxes(in: data, range: range) { fourCC, metaRange in
            guard fourCC == "meta", metaRange.count > 4 else { return }
            // `meta` is normally a FullBox (4-byte version/flags), though some muxers omit the 4-byte flags
            let candidateStart = metaRange.lowerBound + 4
            iterateBoxes(in: data, range: candidateStart..<metaRange.upperBound) { childFCC, ilstRange in
                if childFCC == "ilst" {
                    parseIlst(data, range: ilstRange, into: &meta, loadArtwork: loadArtwork)
                }
            }
        }
    }

    private static func parseIlst(_ data: Data, range: Range<Int>, into meta: inout TrackMetadata, loadArtwork: Bool) {
        iterateBoxes(in: data, range: range) { atomFCC, itemRange in
            if atomFCC == "----" {
                parseFreeformAtom(data, range: itemRange, into: &meta)
                return
            }
            iterateBoxes(in: data, range: itemRange) { subFCC, dataRange in
                guard subFCC == "data", dataRange.count >= 8 else { return }
                let dataType = readUInt32BE(data, at: dataRange.lowerBound)
                let valStart = dataRange.lowerBound + 8
                guard valStart <= dataRange.upperBound else { return }
                let payload = data[valStart..<dataRange.upperBound]

                switch atomFCC {
                case "\u{00A9}nam":
                    if let s = decodeUTF8(payload), !s.isEmpty { meta.title = s }
                case "\u{00A9}ART":
                    if let s = decodeUTF8(payload), !s.isEmpty { meta.artist = s }
                case "aART":
                    if let s = decodeUTF8(payload), !s.isEmpty { meta.albumArtist = s }
                case "\u{00A9}alb":
                    if let s = decodeUTF8(payload), !s.isEmpty { meta.album = s }
                case "\u{00A9}day":
                    if let s = decodeUTF8(payload), !s.isEmpty { meta.year = String(s.prefix(4)) }
                case "trkn":
                    if payload.count >= 4 {
                        let trk = Int(readUInt16BE(data, at: valStart + 2))
                        if trk > 0 { meta.trackNumber = trk }
                        if payload.count >= 6 {
                            let tot = Int(readUInt16BE(data, at: valStart + 4))
                            if tot > 0 { meta.trackTotal = tot }
                        }
                    }
                case "disk":
                    if payload.count >= 4 {
                        let dsc = Int(readUInt16BE(data, at: valStart + 2))
                        if dsc > 0 { meta.discNumber = dsc }
                        if payload.count >= 6 {
                            let dtot = Int(readUInt16BE(data, at: valStart + 4))
                            if dtot > 0 { meta.discTotal = dtot }
                        }
                    }
                case "covr":
                    // Type 13 = JPEG, 14 = PNG, 0 = implicit image bytes
                    if (dataType == 13 || dataType == 14 || dataType == 0),
                       !payload.isEmpty, payload.count <= maxArtworkSize {
                        meta.hasArtwork = true
                        if loadArtwork, meta.artworkData == nil {
                            meta.artworkData = Data(payload)
                        }
                    }
                default:
                    break
                }
            }
        }
    }

    private static func parseFreeformAtom(_ data: Data, range: Range<Int>, into meta: inout TrackMetadata) {
        var nameStr = ""
        var valStr = ""
        iterateBoxes(in: data, range: range) { subFCC, subRange in
            if subFCC == "name", subRange.count > 4 {
                nameStr = decodeUTF8(data[(subRange.lowerBound + 4)..<subRange.upperBound]) ?? ""
            } else if subFCC == "data", subRange.count > 8 {
                valStr = decodeUTF8(data[(subRange.lowerBound + 8)..<subRange.upperBound]) ?? ""
            }
        }
        if nameStr.lowercased() == "albumversion", !valStr.isEmpty, !meta.album.isEmpty,
           !meta.album.localizedCaseInsensitiveContains(valStr) {
            meta.album += " (\(valStr))"
        }
    }

    private static func decodeUTF8(_ slice: Data.SubSequence) -> String? {
        String(data: Data(slice), encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
    }

    private static func iterateBoxes(
        in data: Data,
        range: Range<Int>,
        visitor: (String, Range<Int>) -> Void
    ) {
        var pos = range.lowerBound
        let end = range.upperBound
        while pos >= 0 && pos + 8 <= end {
            let size32 = Int(readUInt32BE(data, at: pos))
            let fourCC = readFourCC(data, at: pos + 4)
            var boxLen = size32
            var hdrLen = 8
            if size32 == 1 {
                guard pos + 16 <= end else { break }
                let size64 = readUInt64BE(data, at: pos + 8)
                guard size64 <= UInt64(Int.max) else { break }
                boxLen = Int(size64)
                hdrLen = 16
            } else if size32 == 0 {
                boxLen = end - pos
            }
            guard boxLen >= hdrLen, pos <= end - boxLen else { break }
            visitor(fourCC, (pos + hdrLen)..<(pos + boxLen))
            pos += boxLen
        }
    }

    private static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func readUInt64BE(_ data: Data, at offset: Int) -> UInt64 {
        let hi = UInt64(readUInt32BE(data, at: offset))
        let lo = UInt64(readUInt32BE(data, at: offset + 4))
        return (hi << 32) | lo
    }
}

// MARK: - In-Process LibreMPEG & Core Audio Metadata Inspectors

enum NativeLibreMPEGReader {
    static func inspect(url: URL) -> TrackMetadata? {
        guard ac4_native_is_available() != 0 else { return nil }
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/") else { return nil }

        var info = AC4ProbeInfo()
        guard ac4_native_probe_file(path, &info) != 0, info.is_valid != 0 else {
            return nil
        }

        func readField<T>(_ tuple: T) -> String {
            withUnsafePointer(to: tuple) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { cPtr in
                    String(cString: cPtr).trimmingCharacters(in: .controlCharacters)
                }
            }
        }

        let parsedTitle = readField(info.title)
        let parsedCodec = readField(info.codec_name)
        let ext = url.pathExtension.lowercased()

        return TrackMetadata(
            title: parsedTitle.isEmpty ? url.deletingPathExtension().lastPathComponent : parsedTitle,
            artist: readField(info.artist),
            albumArtist: readField(info.album_artist),
            album: readField(info.album),
            trackNumber: info.track_number > 0 ? Int(info.track_number) : nil,
            trackTotal: info.track_total > 0 ? Int(info.track_total) : nil,
            discNumber: info.disc_number > 0 ? Int(info.disc_number) : nil,
            discTotal: info.disc_total > 0 ? Int(info.disc_total) : nil,
            year: readField(info.year),
            codecName: parsedCodec.isEmpty ? ext.uppercased() : parsedCodec,
            isAC4: info.is_ac4 != 0,
            audioStreamIndex: max(0, Int(info.audio_stream_index)),
            sampleRateHz: info.sample_rate > 0 ? Int(info.sample_rate) : nil,
            channelCount: info.channels > 0 ? Int(info.channels) : nil,
            bitrateKbps: info.bitrate_kbps > 0 ? Int(info.bitrate_kbps) : nil,
            durationSeconds: info.duration_seconds > 0 ? info.duration_seconds : nil,
            artworkData: nil,
            hasArtwork: false
        )
    }
}

enum CoreAudioMetadataReader {
    static func inspect(url: URL, fileSizeBytes: Int64) -> TrackMetadata? {
        let ext = url.pathExtension.lowercased()
        guard ext != "ac4" else { return nil }
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sr = file.fileFormat.sampleRate
        let ch = Int(file.fileFormat.channelCount)
        guard sr > 0, file.length > 0 else { return nil }
        let dur = Double(file.length) / sr
        let kbps: Int? = (dur > 0.5 && fileSizeBytes > 0)
            ? Int(((Double(fileSizeBytes) * 8.0) / dur / 1000.0).rounded())
            : nil

        return TrackMetadata(
            title: url.deletingPathExtension().lastPathComponent,
            artist: "",
            albumArtist: "",
            album: "",
            trackNumber: nil,
            trackTotal: nil,
            discNumber: nil,
            discTotal: nil,
            year: "",
            codecName: ext.uppercased(),
            isAC4: false,
            audioStreamIndex: 0,
            sampleRateHz: Int(sr.rounded()),
            channelCount: ch > 0 ? ch : nil,
            bitrateKbps: kbps,
            durationSeconds: dur,
            artworkData: nil,
            hasArtwork: false
        )
    }
}

// MARK: - LibreMPEG / FFmpeg Header Inspector (Fallback for .ac4 / .mkv / .flac / .opus)

enum FFmpegProbeReader {
    /// Uses the single `ffmpeg` / `librempeg` binary (`-nostdin -hide_banner -i <file>`) so users do not need a separate `ffprobe` binary.
    static func inspect(url: URL, decoderURL: URL) -> TrackMetadata? {
        let canonicalMedia = url.standardizedFileURL.path
        let canonicalBin = decoderURL.standardizedFileURL.path
        guard canonicalMedia.hasPrefix("/"), canonicalBin.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: canonicalBin) else {
            return nil
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: canonicalBin)
        proc.arguments = [
            "-nostdin",
            "-hide_banner",
            "-i", canonicalMedia
        ]
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return nil
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let output = String(data: errData, encoding: .utf8), !output.isEmpty else {
            return nil
        }

        let ext = url.pathExtension.lowercased()
        var meta = TrackMetadata(
            title: url.deletingPathExtension().lastPathComponent,
            artist: "",
            albumArtist: "",
            album: "",
            trackNumber: nil,
            trackTotal: nil,
            discNumber: nil,
            discTotal: nil,
            year: "",
            codecName: ext == "ac4" ? "AC-4 IMS" : ext.uppercased(),
            isAC4: ext == "ac4",
            audioStreamIndex: 0,
            sampleRateHz: nil,
            channelCount: nil,
            bitrateKbps: nil,
            durationSeconds: nil,
            artworkData: nil
        )

        var audioIdx = 0
        var matchedAudio = false

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Duration:") {
                if let durMatch = line.range(of: #"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)"#, options: .regularExpression) {
                    let sub = String(line[durMatch]).replacingOccurrences(of: "Duration:", with: "").trimmingCharacters(in: .whitespaces)
                    let parts = sub.split(separator: ":")
                    if parts.count == 3,
                       let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) {
                        meta.durationSeconds = h * 3600 + m * 60 + s
                    }
                }
                if let brMatch = line.range(of: #"bitrate:\s*(\d+)\s*kb/s"#, options: .regularExpression) {
                    let digits = line[brMatch].filter(\.isNumber)
                    if let kbps = Int(digits) {
                        meta.bitrateKbps = kbps
                    }
                }
            } else if line.hasPrefix("Stream #0:"), line.contains("Audio:") {
                if !matchedAudio || line.contains("Audio: ac4") {
                    matchedAudio = true
                    meta.audioStreamIndex = audioIdx
                    if let afterAudio = line.components(separatedBy: "Audio:").last {
                        let tokens = afterAudio.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        if let first = tokens.first {
                            let rawCodec = first.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
                            if rawCodec == "ac4" || rawCodec == "ac-4" {
                                meta.codecName = "AC-4 IMS"
                                meta.isAC4 = true
                            } else if !rawCodec.isEmpty {
                                meta.codecName = rawCodec.uppercased()
                            }
                        }
                        for tok in tokens {
                            if tok.hasSuffix("Hz"), let hz = Int(tok.replacingOccurrences(of: "Hz", with: "").trimmingCharacters(in: .whitespaces)) {
                                meta.sampleRateHz = hz
                            } else if tok == "stereo" {
                                meta.channelCount = 2
                            } else if tok == "mono" {
                                meta.channelCount = 1
                            } else if tok.hasSuffix("kb/s") {
                                let digits = tok.filter(\.isNumber)
                                if let kbps = Int(digits) {
                                    meta.bitrateKbps = kbps
                                }
                            }
                        }
                    }
                }
                audioIdx += 1
            } else if let colonIdx = line.firstIndex(of: ":"), !line.hasPrefix("Input #"), !line.hasPrefix("Stream #") {
                let key = line[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
                let val = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
                guard !val.isEmpty else { continue }
                switch key {
                case "title": meta.title = val
                case "artist": meta.artist = val
                case "album_artist", "albumartist": meta.albumArtist = val
                case "album": meta.album = val
                case "date", "year": meta.year = String(val.prefix(4))
                case "track", "tracknumber":
                    let parts = val.split(separator: "/")
                    if let t = parts.first.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                        meta.trackNumber = t
                    }
                    if parts.count > 1, let tot = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                        meta.trackTotal = tot
                    }
                case "disc", "discnumber":
                    let parts = val.split(separator: "/")
                    if let d = parts.first.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                        meta.discNumber = d
                    }
                default:
                    break
                }
            }
        }
        return meta
    }
}

// MARK: - Artwork Loader (Embedded MP4 `covr` + Folder Sidecar `cover.jpg`)

enum ArtworkLoader {
    private static let sidecarNames = [
        "cover.jpg", "cover.jpeg", "cover.png",
        "folder.jpg", "folder.jpeg", "folder.png",
        "front.jpg", "front.png", "album.jpg"
    ]

    static func loadArtwork(for url: URL) -> NSImage? {
        if let meta = MP4MetadataReader.inspect(url: url, loadArtwork: true),
           let data = meta.artworkData,
           let img = NSImage(data: data) {
            return img
        }
        let folder = url.deletingLastPathComponent()
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(atPath: folder.path) {
            let lowerMap = Dictionary(uniqueKeysWithValues: entries.map { ($0.lowercased(), $0) })
            for candidate in sidecarNames {
                if let exactName = lowerMap[candidate] {
                    let imgURL = folder.appendingPathComponent(exactName)
                    if let attrs = try? fm.attributesOfItem(atPath: imgURL.path),
                       let sz = attrs[.size] as? Int, sz > 0, sz <= 16 * 1024 * 1024,
                       let img = NSImage(contentsOf: imgURL) {
                        return img
                    }
                }
            }
        }
        return nil
    }
}

// MARK: - Real-Time Lock-Safe PCM Stream Ring Buffer

/// Thread-safe, zero-ARC-in-render-callback ring buffer bridging LibreMPEG's POSIX stdout pipe to Core Audio.
final class PCMStreamRing: @unchecked Sendable {
    let startTimeSeconds: Double
    private let capacity: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>
    private let cond: UnsafeMutablePointer<pthread_cond_t>

    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private var availableFrames: Int = 0
    private var isPrebuffering: Bool = true
    private var eofReached: Bool = false
    private var cancelled: Bool = false
    private var readerWaiting: Bool = false
    private var framesConsumed: Int64 = 0
    private var decodeErrorText: String?

    init(startTimeSeconds: Double, capacity: Int = PlayerConstants.ringCapacityFrames) {
        self.startTimeSeconds = startTimeSeconds
        self.capacity = capacity
        self.left = .allocate(capacity: capacity)
        self.right = .allocate(capacity: capacity)
        self.left.initialize(repeating: 0, count: capacity)
        self.right.initialize(repeating: 0, count: capacity)

        self.mutex = .allocate(capacity: 1)
        self.cond = .allocate(capacity: 1)
        pthread_mutex_init(mutex, nil)
        pthread_cond_init(cond, nil)
    }

    deinit {
        pthread_cond_destroy(cond)
        pthread_mutex_destroy(mutex)
        cond.deallocate()
        mutex.deallocate()
        left.deallocate()
        right.deallocate()
    }

    /// Writes interleaved Float32 stereo samples `[L0, R0, L1, R1, ...]` from the decoder thread.
    /// Blocks cleanly via `pthread_cond_wait` when full (giving natural POSIX pipe backpressure to LibreMPEG).
    func writeInterleaved(_ interleaved: UnsafeBufferPointer<Float>, frameCount: Int) -> Bool {
        var offsetFrame = 0
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }

        while offsetFrame < frameCount {
            while availableFrames == capacity && !cancelled {
                readerWaiting = true
                pthread_cond_wait(cond, mutex)
                readerWaiting = false
            }
            if cancelled { return false }

            let freeSpace = capacity - availableFrames
            let toWrite = min(frameCount - offsetFrame, freeSpace)
            var idx = writeIndex
            var srcIdx = offsetFrame * 2

            for _ in 0..<toWrite {
                left[idx] = interleaved[srcIdx]
                right[idx] = interleaved[srcIdx + 1]
                srcIdx += 2
                idx += 1
                if idx == capacity { idx = 0 }
            }

            writeIndex = idx
            availableFrames += toWrite
            if isPrebuffering && availableFrames >= PlayerConstants.prebufferFrames {
                isPrebuffering = false
            }
            offsetFrame += toWrite
        }
        return !cancelled
    }

    func markEOF(errorMessage: String? = nil) {
        pthread_mutex_lock(mutex)
        eofReached = true
        isPrebuffering = false
        if let errorMessage, !errorMessage.isEmpty {
            decodeErrorText = errorMessage
        }
        pthread_mutex_unlock(mutex)
    }

    func cancel() {
        pthread_mutex_lock(mutex)
        cancelled = true
        pthread_cond_broadcast(cond)
        pthread_mutex_unlock(mutex)
    }

    /// Real-time Core Audio pull method: zero heap allocations, zero Objective-C messaging.
    @inline(__always)
    private static func softLimitSample(_ x: Float) -> Float {
        let ax = abs(x)
        if ax <= 0.95 { return x }
        let limited = 0.95 + 0.05 * tanhf((ax - 0.95) / 0.05)
        return x >= 0 ? limited : -limited
    }

    func pullInto(
        outLeft: UnsafeMutablePointer<Float>,
        outRight: UnsafeMutablePointer<Float>,
        frameCount: Int,
        fadeGain: inout Float,
        preampCurrentGain: inout Float,
        preampTargetGain: Float,
        peakL: inout Float,
        peakR: inout Float
    ) {
        pthread_mutex_lock(mutex)
        if cancelled || isPrebuffering || availableFrames == 0 {
            pthread_mutex_unlock(mutex)
            memset(outLeft, 0, frameCount * MemoryLayout<Float>.size)
            memset(outRight, 0, frameCount * MemoryLayout<Float>.size)
            return
        }

        let toRead = min(frameCount, availableFrames)
        let firstChunk = min(toRead, capacity - readIndex)
        let secondChunk = toRead - firstChunk

        outLeft.update(from: left.advanced(by: readIndex), count: firstChunk)
        outRight.update(from: right.advanced(by: readIndex), count: firstChunk)

        if secondChunk > 0 {
            outLeft.advanced(by: firstChunk).update(from: left, count: secondChunk)
            outRight.advanced(by: firstChunk).update(from: right, count: secondChunk)
        }

        readIndex = (readIndex + toRead) % capacity
        availableFrames -= toRead
        framesConsumed += Int64(toRead)

        let shouldWakeWriter = readerWaiting && (availableFrames <= (capacity * 3) / 4)
        if shouldWakeWriter {
            pthread_cond_signal(cond)
        }
        pthread_mutex_unlock(mutex)

        if toRead < frameCount {
            let rem = frameCount - toRead
            memset(outLeft.advanced(by: toRead), 0, rem * MemoryLayout<Float>.size)
            memset(outRight.advanced(by: toRead), 0, rem * MemoryLayout<Float>.size)
        }

        let fadeStep: Float = 1.0 / Float(PlayerConstants.microFadeFrames)
        var localMaxL: Float = 0
        var localMaxR: Float = 0
        var curGain = preampCurrentGain
        let needsGainSmoothing = abs(preampTargetGain - curGain) > 0.0001
        let hasPreamp = needsGainSmoothing || abs(curGain - 1.0) > 0.0001

        for i in 0..<toRead {
            if needsGainSmoothing {
                curGain += (preampTargetGain - curGain) * 0.0025
            } else {
                curGain = preampTargetGain
            }

            var sL = outLeft[i]
            var sR = outRight[i]
            if hasPreamp {
                sL *= curGain
                sR *= curGain
            }
            if fadeGain < 1.0 {
                sL *= fadeGain
                sR *= fadeGain
                fadeGain = min(1.0, fadeGain + fadeStep)
            }
            sL = Self.softLimitSample(sL)
            sR = Self.softLimitSample(sR)
            outLeft[i] = sL
            outRight[i] = sR

            let aL = abs(sL)
            let aR = abs(sR)
            if aL > localMaxL { localMaxL = aL }
            if aR > localMaxR { localMaxR = aR }
        }
        preampCurrentGain = curGain
        peakL = localMaxL
        peakR = localMaxR
    }

    func snapshot() -> (consumedFrames: Int64, bufferedSeconds: Double, isFinished: Bool, error: String?) {
        pthread_mutex_lock(mutex)
        let consumed = framesConsumed
        let buffered = Double(availableFrames) / PlayerConstants.sampleRate
        let finished = eofReached && availableFrames == 0 && !cancelled
        let err = decodeErrorText
        pthread_mutex_unlock(mutex)
        return (consumed, buffered, finished, err)
    }
}

// MARK: - Core Audio Render State & Streaming Engine

private final class EngineRenderState: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var activeRing: PCMStreamRing?
    private var paused: Bool = true
    private var fadeGain: Float = 0.0
    private var preampTargetGain: Float = 1.0
    private var preampCurrentGain: Float = 1.0
    private var meterL: Float = 0.0
    private var meterR: Float = 0.0

    init() {
        self.lock = .allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deallocate()
    }

    func setPreampDB(_ db: Float) {
        let clamped = max(0.0, min(6.0, db))
        let linear: Float = abs(clamped) < 0.01 ? 1.0 : powf(10.0, clamped / 20.0)
        os_unfair_lock_lock(lock)
        self.preampTargetGain = linear
        if self.paused || self.activeRing == nil {
            self.preampCurrentGain = linear
        }
        os_unfair_lock_unlock(lock)
    }

    func setRing(_ ring: PCMStreamRing?, paused: Bool) {
        os_unfair_lock_lock(lock)
        self.activeRing = ring
        self.paused = paused
        self.fadeGain = 0.0
        self.preampCurrentGain = self.preampTargetGain
        if ring == nil {
            self.meterL = 0
            self.meterR = 0
        }
        os_unfair_lock_unlock(lock)
    }

    func setPaused(_ paused: Bool) {
        os_unfair_lock_lock(lock)
        self.paused = paused
        if !paused {
            self.fadeGain = 0.0
            self.preampCurrentGain = self.preampTargetGain
        } else {
            self.meterL = 0
            self.meterR = 0
        }
        os_unfair_lock_unlock(lock)
    }

    func render(frameCount: Int, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard abl.count >= 2,
              let outL = abl[0].mData?.assumingMemoryBound(to: Float.self),
              let outR = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
            for buf in abl {
                if let ptr = buf.mData {
                    memset(ptr, 0, Int(buf.mDataByteSize))
                }
            }
            return noErr
        }

        os_unfair_lock_lock(lock)
        let ring = activeRing
        let isPaused = paused
        var localFade = fadeGain
        var localPreampCur = preampCurrentGain
        let localPreampTarget = preampTargetGain
        os_unfair_lock_unlock(lock)

        guard let ring, !isPaused else {
            memset(outL, 0, frameCount * MemoryLayout<Float>.size)
            memset(outR, 0, frameCount * MemoryLayout<Float>.size)
            return noErr
        }

        var pkL: Float = 0
        var pkR: Float = 0
        ring.pullInto(
            outLeft: outL,
            outRight: outR,
            frameCount: frameCount,
            fadeGain: &localFade,
            preampCurrentGain: &localPreampCur,
            preampTargetGain: localPreampTarget,
            peakL: &pkL,
            peakR: &pkR
        )

        os_unfair_lock_lock(lock)
        fadeGain = localFade
        preampCurrentGain = localPreampCur
        meterL = max(pkL, meterL * 0.82)
        meterR = max(pkR, meterR * 0.82)
        os_unfair_lock_unlock(lock)
        return noErr
    }

    func readMeters() -> (Float, Float) {
        os_unfair_lock_lock(lock)
        let l = meterL
        let r = meterR
        meterL *= 0.88
        meterR *= 0.88
        os_unfair_lock_unlock(lock)
        return (l, r)
    }
}

final class AC4AudioEngine {
    private let engine = AVAudioEngine()
    private let renderState = EngineRenderState()
    private var sourceNode: AVAudioSourceNode?
    private var activeProcess: Process?
    private var activeRing: PCMStreamRing?

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = max(0.0, min(1.0, newValue)) }
    }

    var preampDB: Float = 0.0 {
        didSet {
            renderState.setPreampDB(preampDB)
        }
    }

    init() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: PlayerConstants.sampleRate,
            channels: AVAudioChannelCount(PlayerConstants.channels),
            interleaved: false
        ) else {
            return
        }

        let state = renderState
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            state.render(frameCount: Int(frameCount), audioBufferList: audioBufferList)
        }
        self.sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    deinit {
        stop()
        engine.stop()
    }

    func startStream(
        trackURL: URL,
        isAC4Track: Bool,
        decoderStatus: DecoderStatus,
        audioStreamIndex: Int,
        seekSeconds: Double,
        startPaused: Bool = false
    ) throws {
        stopStreamOnly()

        let mediaPath = trackURL.standardizedFileURL.path
        guard mediaPath.hasPrefix("/"), FileManager.default.isReadableFile(atPath: mediaPath) else {
            throw NSError(domain: "AC4Player", code: 1, userInfo: [NSLocalizedDescriptionKey: "Audio file is not readable."])
        }

        if !engine.isRunning {
            try engine.start()
        }

        let clampedSeek = max(0.0, seekSeconds)
        let ring = PCMStreamRing(startTimeSeconds: clampedSeek)
        let caps = decoderStatus.capabilities

        // Tier 1: In-process statically linked LibreMPEG (native 32-bit float AC-4 IMS, zero child process)
        if caps.isBuiltInNative && ac4_native_is_available() != 0 {
            if isAC4Track || ac4_native_can_decode_file(mediaPath, Int32(max(0, audioStreamIndex))) != 0 {
                self.activeRing = ring
                renderState.setRing(ring, paused: startPaused)
                let streamIdx = max(0, audioStreamIndex)
                Thread.detachNewThread {
                    Self.streamNativeLibreMPEG(
                        mediaPath: mediaPath,
                        audioStreamIndex: streamIdx,
                        seekSeconds: clampedSeek,
                        ring: ring
                    )
                }
                return
            }
        }

        // Tier 2: Native macOS Core Audio for standard formats (.flac, .wav, .mp3, .aiff, AAC/ALAC .m4a)
        if !isAC4Track, let testAudioFile = try? AVAudioFile(forReading: trackURL), testAudioFile.length > 0 {
            self.activeRing = ring
            renderState.setRing(ring, paused: startPaused)
            Thread.detachNewThread {
                Self.streamCoreAudioFile(trackURL: trackURL, seekSeconds: clampedSeek, ring: ring)
            }
            return
        }

        // Tier 3: External LibreMPEG / FFmpeg subprocess (stdout pipe or POSIX FIFO when `pipe` protocol is absent)
        guard let binPath = decoderStatus.activeBinaryPath,
              binPath.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: binPath) else {
            throw NSError(
                domain: "AC4Player",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: isAC4Track
                    ? "No AC-4 decoder available. Build with ./librempeg or locate your LibreMPEG binary in the sidebar."
                    : "Audio format is not supported by Core Audio and no external FFmpeg binary is configured."]
            )
        }

        try startExternalProcessStream(
            mediaPath: mediaPath,
            binPath: binPath,
            capabilities: caps,
            audioStreamIndex: audioStreamIndex,
            clampedSeek: clampedSeek,
            startPaused: startPaused,
            ring: ring
        )
    }

    private func startExternalProcessStream(
        mediaPath: String,
        binPath: String,
        capabilities: DecoderCapabilities,
        audioStreamIndex: Int,
        clampedSeek: Double,
        startPaused: Bool,
        ring: PCMStreamRing
    ) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binPath)

        var args: [String] = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "error",
            "-y"
        ]
        if clampedSeek > 0.02 {
            args += ["-ss", String(format: "%.3f", clampedSeek)]
        }
        args += [
            "-i", mediaPath,
            "-map", "0:a:\(max(0, audioStreamIndex))",
            "-vn", "-sn", "-dn"
        ]
        if capabilities.hasAresampleFilter {
            args += [
                "-ar", String(Int(PlayerConstants.sampleRate)),
                "-ac", String(PlayerConstants.channels)
            ]
        }

        let mode = capabilities.pipeMode
        let errPipe = Pipe()
        proc.standardError = errPipe

        if capabilities.hasPipeProtocol {
            switch mode {
            case .wav(let pcmCodec):
                if let pcmCodec { args += ["-c:a", pcmCodec] }
                args += ["-f", "wav", "pipe:1"]
            case .flac:
                args += ["-c:a", "flac", "-compression_level", "0", "-f", "flac", "pipe:1"]
            }
            proc.arguments = args

            let outPipe = Pipe()
            proc.standardOutput = outPipe
            try proc.run()

            self.activeProcess = proc
            self.activeRing = ring
            renderState.setRing(ring, paused: startPaused)

            let outFD = outPipe.fileHandleForReading.fileDescriptor
            let errHandle = errPipe.fileHandleForReading

            Thread.detachNewThread {
                switch mode {
                case .wav:
                    Self.streamWAVPipe(outFD: outFD, errHandle: errHandle, proc: proc, ring: ring)
                case .flac:
                    Self.streamFLACPipeInMemory(outFD: outFD, errHandle: errHandle, proc: proc, ring: ring)
                }
                _ = outPipe
            }
        } else {
            // Minimal LibreMPEG builds with `--enable-protocol=file` only (no `pipe` protocol):
            // stream in RAM through a private 0700-scoped POSIX Named Pipe (FIFO).
            let fifoDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ac4player_fifo_\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: fifoDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let fifoPath = fifoDir.appendingPathComponent("stream.fifo").path
            guard Darwin.mkfifo(fifoPath, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                try? FileManager.default.removeItem(at: fifoDir)
                throw NSError(domain: "AC4Player", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create POSIX audio FIFO."])
            }

            switch mode {
            case .wav(let pcmCodec):
                if let pcmCodec { args += ["-c:a", pcmCodec] }
                args += ["-f", "wav", fifoPath]
            case .flac:
                args += ["-c:a", "flac", "-compression_level", "0", "-f", "flac", fifoPath]
            }
            proc.arguments = args
            proc.standardOutput = FileHandle.nullDevice

            // Ensure reader `open(O_RDONLY)` never blocks if `proc` exits before opening output
            proc.terminationHandler = { _ in
                let wakeFD = Darwin.open(fifoPath, O_WRONLY | O_NONBLOCK)
                if wakeFD >= 0 {
                    Darwin.close(wakeFD)
                }
            }

            do {
                try proc.run()
            } catch {
                try? FileManager.default.removeItem(at: fifoDir)
                throw error
            }

            self.activeProcess = proc
            self.activeRing = ring
            renderState.setRing(ring, paused: startPaused)

            let errHandle = errPipe.fileHandleForReading
            Thread.detachNewThread {
                let outFD = Darwin.open(fifoPath, O_RDONLY)
                defer {
                    if outFD >= 0 {
                        Darwin.close(outFD)
                    }
                    try? FileManager.default.removeItem(at: fifoDir)
                }
                guard outFD >= 0 else {
                    let errMsg = Self.collectProcessError(errHandle: errHandle, proc: proc)
                    ring.markEOF(errorMessage: errMsg)
                    return
                }
                switch mode {
                case .wav:
                    Self.streamWAVPipe(outFD: outFD, errHandle: errHandle, proc: proc, ring: ring)
                case .flac:
                    Self.streamFLACPipeInMemory(outFD: outFD, errHandle: errHandle, proc: proc, ring: ring)
                }
            }
        }
    }

    private static func streamNativeLibreMPEG(
        mediaPath: String,
        audioStreamIndex: Int,
        seekSeconds: Double,
        ring: PCMStreamRing
    ) {
        var errBuf = [CChar](repeating: 0, count: 512)
        let rc: Int32 = withExtendedLifetime(ring) {
            let opaqueRing = Unmanaged.passUnretained(ring).toOpaque()
            return ac4_native_stream_file(
                mediaPath,
                Int32(audioStreamIndex),
                seekSeconds,
                Int32(PlayerConstants.sampleRate),
                { samplesPtr, frameCount, userdata in
                    guard let samplesPtr, let userdata, frameCount > 0 else { return 1 }
                    let ringObj = Unmanaged<PCMStreamRing>.fromOpaque(userdata).takeUnretainedValue()
                    let buf = UnsafeBufferPointer(start: samplesPtr, count: Int(frameCount) * 2)
                    return ringObj.writeInterleaved(buf, frameCount: Int(frameCount)) ? 1 : 0
                },
                opaqueRing,
                &errBuf,
                errBuf.count
            )
        }
        if rc < 0 {
            let msg = String(cString: errBuf).trimmingCharacters(in: .whitespacesAndNewlines)
            ring.markEOF(errorMessage: msg.isEmpty ? "Built-in LibreMPEG decode failed." : msg)
        } else {
            ring.markEOF()
        }
    }

    private static func streamCoreAudioFile(
        trackURL: URL,
        seekSeconds: Double,
        ring: PCMStreamRing
    ) {
        do {
            let audioFile = try AVAudioFile(forReading: trackURL)
            if seekSeconds > 0.01 {
                let targetFrame = AVAudioFramePosition((seekSeconds * audioFile.fileFormat.sampleRate).rounded())
                if targetFrame >= 0 && targetFrame < audioFile.length {
                    audioFile.framePosition = targetFrame
                }
            }

            let srcFmt = audioFile.processingFormat
            let frameCap: AVAudioFrameCount = 4096

            // Direct fast path when Core Audio already delivers 48 kHz Float32 non-interleaved
            if abs(srcFmt.sampleRate - PlayerConstants.sampleRate) < 0.5,
               srcFmt.commonFormat == .pcmFormatFloat32,
               !srcFmt.isInterleaved,
               let inBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: frameCap) {
                let scratch = UnsafeMutablePointer<Float>.allocate(capacity: Int(frameCap) * 2)
                defer { scratch.deallocate() }
                while true {
                    try audioFile.read(into: inBuf, frameCount: frameCap)
                    let count = Int(inBuf.frameLength)
                    if count == 0 { break }
                    guard let chData = inBuf.floatChannelData else { break }
                    let left = chData[0]
                    let right = srcFmt.channelCount >= 2 ? chData[1] : chData[0]
                    for i in 0..<count {
                        scratch[i * 2] = left[i]
                        scratch[i * 2 + 1] = right[i]
                    }
                    let bufPtr = UnsafeBufferPointer(start: scratch, count: count * 2)
                    if !ring.writeInterleaved(bufPtr, frameCount: count) { break }
                }
                ring.markEOF()
                return
            }

            guard let targetFmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: PlayerConstants.sampleRate,
                channels: AVAudioChannelCount(PlayerConstants.channels),
                interleaved: true
            ), let converter = AVAudioConverter(from: srcFmt, to: targetFmt),
               let inBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: frameCap),
               let outBuf = AVAudioPCMBuffer(pcmFormat: targetFmt, frameCapacity: frameCap * 2) else {
                ring.markEOF(errorMessage: "Core Audio could not initialize sample rate converter.")
                return
            }

            var fileEOF = false
            var reachedEOF = false
            while !reachedEOF {
                var convErr: NSError?
                let status = converter.convert(to: outBuf, error: &convErr) { _, outStatus in
                    if fileEOF {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    do {
                        try audioFile.read(into: inBuf, frameCount: frameCap)
                        if inBuf.frameLength == 0 {
                            fileEOF = true
                            outStatus.pointee = .endOfStream
                            return nil
                        }
                        outStatus.pointee = .haveData
                        return inBuf
                    } catch {
                        fileEOF = true
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                }
                if outBuf.frameLength > 0, let mData = outBuf.audioBufferList.pointee.mBuffers.mData {
                    let fPtr = mData.assumingMemoryBound(to: Float.self)
                    let count = Int(outBuf.frameLength)
                    let bufPtr = UnsafeBufferPointer(start: fPtr, count: count * 2)
                    if !ring.writeInterleaved(bufPtr, frameCount: count) { break }
                }
                if status == .endOfStream || status == .error {
                    reachedEOF = true
                }
            }
            ring.markEOF()
        } catch {
            ring.markEOF(errorMessage: error.localizedDescription)
        }
    }

    fileprivate struct WAVStreamFormat {
        var isFloat: Bool
        var channels: Int
        var sampleRate: Int
        var bitsPerSample: Int
    }

    fileprivate static func readExactPipeBytes(fd: Int32, into dst: UnsafeMutableRawPointer, count: Int) -> Int {
        var total = 0
        while total < count {
            let n = Darwin.read(fd, dst.advanced(by: total), count - total)
            if n > 0 {
                total += n
            } else if n == 0 {
                break
            } else {
                if errno == EINTR { continue }
                break
            }
        }
        return total
    }

    private static func discardPipeBytes(fd: Int32, count: Int) -> Bool {
        guard count > 0 else { return true }
        let scratchSize = min(count, 4096)
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: scratchSize, alignment: 1)
        defer { scratch.deallocate() }
        var remaining = count
        while remaining > 0 {
            let step = min(remaining, scratchSize)
            let got = readExactPipeBytes(fd: fd, into: scratch, count: step)
            if got < step { return false }
            remaining -= got
        }
        return true
    }

    fileprivate static func parseWAVHeader(fd: Int32) -> WAVStreamFormat? {
        var riffHdr = [UInt8](repeating: 0, count: 12)
        let gotRiff = riffHdr.withUnsafeMutableBytes { ptr in
            readExactPipeBytes(fd: fd, into: ptr.baseAddress!, count: 12)
        }
        guard gotRiff == 12 else { return nil }
        let magic = String(bytes: riffHdr[0..<4], encoding: .isoLatin1) ?? ""
        let wave = String(bytes: riffHdr[8..<12], encoding: .isoLatin1) ?? ""
        guard (magic == "RIFF" || magic == "RF64"), wave == "WAVE" else { return nil }

        var parsedFmt: WAVStreamFormat?
        var chunkHdr = [UInt8](repeating: 0, count: 8)

        // Walk RIFF chunks until "data" payload begins
        for _ in 0..<32 {
            let gotChunk = chunkHdr.withUnsafeMutableBytes { ptr in
                readExactPipeBytes(fd: fd, into: ptr.baseAddress!, count: 8)
            }
            guard gotChunk == 8 else { return nil }
            let chunkID = String(bytes: chunkHdr[0..<4], encoding: .isoLatin1) ?? ""
            let chunkSize = Int(UInt32(chunkHdr[4])
                | (UInt32(chunkHdr[5]) << 8)
                | (UInt32(chunkHdr[6]) << 16)
                | (UInt32(chunkHdr[7]) << 24))

            if chunkID == "fmt " {
                guard chunkSize >= 16 && chunkSize <= 4096 else { return nil }
                var fmtBytes = [UInt8](repeating: 0, count: chunkSize)
                let gotFmt = fmtBytes.withUnsafeMutableBytes { ptr in
                    readExactPipeBytes(fd: fd, into: ptr.baseAddress!, count: chunkSize)
                }
                guard gotFmt == chunkSize else { return nil }
                if chunkSize % 2 == 1 {
                    _ = discardPipeBytes(fd: fd, count: 1)
                }

                var formatTag = UInt16(fmtBytes[0]) | (UInt16(fmtBytes[1]) << 8)
                let channels = Int(UInt16(fmtBytes[2]) | (UInt16(fmtBytes[3]) << 8))
                let sampleRate = Int(UInt32(fmtBytes[4])
                    | (UInt32(fmtBytes[5]) << 8)
                    | (UInt32(fmtBytes[6]) << 16)
                    | (UInt32(fmtBytes[7]) << 24))
                let bits = Int(UInt16(fmtBytes[14]) | (UInt16(fmtBytes[15]) << 8))

                // WAVE_FORMAT_EXTENSIBLE (0xFFFE) stores actual format tag (1 = PCM, 3 = IEEE float) in SubFormat[0..1]
                if formatTag == 0xFFFE, chunkSize >= 40 {
                    formatTag = UInt16(fmtBytes[24]) | (UInt16(fmtBytes[25]) << 8)
                }

                guard (formatTag == 1 || formatTag == 3),
                      channels >= 1 && channels <= 32,
                      sampleRate >= 2_000 && sampleRate <= 384_000,
                      [16, 24, 32, 64].contains(bits) else {
                    return nil
                }
                parsedFmt = WAVStreamFormat(
                    isFloat: formatTag == 3,
                    channels: channels,
                    sampleRate: sampleRate,
                    bitsPerSample: bits
                )
            } else if chunkID == "data" {
                return parsedFmt
            } else {
                // Skip JUNK, ds64, LIST, fact, etc. (0xFFFFFFFF only appears on "data" or outer RIFF)
                guard chunkSize >= 0 && chunkSize <= 8 * 1024 * 1024 else { return nil }
                let padded = chunkSize + (chunkSize % 2)
                if !discardPipeBytes(fd: fd, count: padded) { return nil }
            }
        }
        return nil
    }

    fileprivate static func decodePCMSample(_ ptr: UnsafeRawPointer, isFloat: Bool, bits: Int) -> Float {
        if isFloat {
            if bits == 32 {
                let bits32 = UInt32(ptr.load(fromByteOffset: 0, as: UInt8.self))
                    | (UInt32(ptr.load(fromByteOffset: 1, as: UInt8.self)) << 8)
                    | (UInt32(ptr.load(fromByteOffset: 2, as: UInt8.self)) << 16)
                    | (UInt32(ptr.load(fromByteOffset: 3, as: UInt8.self)) << 24)
                return Float(bitPattern: bits32)
            } else if bits == 64 {
                var bits64: UInt64 = 0
                for b in 0..<8 {
                    bits64 |= UInt64(ptr.load(fromByteOffset: b, as: UInt8.self)) << (b * 8)
                }
                return Float(Double(bitPattern: bits64))
            }
            return 0
        } else {
            switch bits {
            case 16:
                let u16 = UInt16(ptr.load(fromByteOffset: 0, as: UInt8.self))
                    | (UInt16(ptr.load(fromByteOffset: 1, as: UInt8.self)) << 8)
                return Float(Int16(bitPattern: u16)) * (1.0 / 32_768.0)
            case 24:
                let b0 = Int32(ptr.load(fromByteOffset: 0, as: UInt8.self))
                let b1 = Int32(ptr.load(fromByteOffset: 1, as: UInt8.self))
                let b2 = Int32(ptr.load(fromByteOffset: 2, as: Int8.self))
                let s24 = (b2 << 16) | (b1 << 8) | b0
                return Float(s24) * (1.0 / 8_388_608.0)
            case 32:
                let u32 = UInt32(ptr.load(fromByteOffset: 0, as: UInt8.self))
                    | (UInt32(ptr.load(fromByteOffset: 1, as: UInt8.self)) << 8)
                    | (UInt32(ptr.load(fromByteOffset: 2, as: UInt8.self)) << 16)
                    | (UInt32(ptr.load(fromByteOffset: 3, as: UInt8.self)) << 24)
                return Float(Double(Int32(bitPattern: u32)) * (1.0 / 2_147_483_648.0))
            default:
                return 0
            }
        }
    }

    private static func collectProcessError(errHandle: FileHandle, proc: Process) -> String? {
        let errData = errHandle.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus != 0,
           let text = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text.components(separatedBy: .newlines).first ?? text
        }
        return nil
    }

    private static func streamWAVPipe(
        outFD: Int32,
        errHandle: FileHandle,
        proc: Process,
        ring: PCMStreamRing
    ) {
        guard let wavFmt = parseWAVHeader(fd: outFD) else {
            let errMsg = collectProcessError(errHandle: errHandle, proc: proc)
            ring.markEOF(errorMessage: errMsg)
            return
        }

        let bytesPerSample = wavFmt.bitsPerSample / 8
        let bytesPerFrame = wavFmt.channels * bytesPerSample
        let chunkFrames = 4096
        let maxBytes = chunkFrames * bytesPerFrame
        let rawBuf = UnsafeMutableRawPointer.allocate(byteCount: maxBytes, alignment: 8)
        let stereoOut = UnsafeMutablePointer<Float>.allocate(capacity: chunkFrames * 8)
        defer {
            rawBuf.deallocate()
            stereoOut.deallocate()
        }

        let needsResample = (wavFmt.sampleRate != Int(PlayerConstants.sampleRate))
        let stepRatio = Double(wavFmt.sampleRate) / PlayerConstants.sampleRate
        var resamplePos: Double = 0.0
        var prevL: Float = 0.0
        var prevR: Float = 0.0
        var hasPrev = false

        var carryBytes = 0

        while true {
            let n = Darwin.read(outFD, rawBuf.advanced(by: carryBytes), maxBytes - carryBytes)
            if n > 0 {
                let totalBytes = carryBytes + n
                let wholeFrames = totalBytes / bytesPerFrame
                let leftover = totalBytes % bytesPerFrame

                if wholeFrames > 0 {
                    if wavFmt.isFloat && wavFmt.bitsPerSample == 32 && wavFmt.channels == 2 && !needsResample {
                        let floatPtr = rawBuf.assumingMemoryBound(to: Float.self)
                        let bufPtr = UnsafeBufferPointer(start: floatPtr, count: wholeFrames * 2)
                        if !ring.writeInterleaved(bufPtr, frameCount: wholeFrames) { break }
                    } else if !needsResample {
                        for f in 0..<wholeFrames {
                            let base = rawBuf.advanced(by: f * bytesPerFrame)
                            let sL = decodePCMSample(base, isFloat: wavFmt.isFloat, bits: wavFmt.bitsPerSample)
                            let sR = wavFmt.channels >= 2
                                ? decodePCMSample(base.advanced(by: bytesPerSample), isFloat: wavFmt.isFloat, bits: wavFmt.bitsPerSample)
                                : sL
                            stereoOut[f * 2] = sL
                            stereoOut[f * 2 + 1] = sR
                        }
                        let bufPtr = UnsafeBufferPointer(start: stereoOut, count: wholeFrames * 2)
                        if !ring.writeInterleaved(bufPtr, frameCount: wholeFrames) { break }
                    } else {
                        // Linear resampler fallback when decoder lacks aresample filter on 44.1 kHz tracks
                        var outCount = 0
                        let maxOutFrames = chunkFrames * 4
                        for f in 0..<wholeFrames {
                            let base = rawBuf.advanced(by: f * bytesPerFrame)
                            let curL = decodePCMSample(base, isFloat: wavFmt.isFloat, bits: wavFmt.bitsPerSample)
                            let curR = wavFmt.channels >= 2
                                ? decodePCMSample(base.advanced(by: bytesPerSample), isFloat: wavFmt.isFloat, bits: wavFmt.bitsPerSample)
                                : curL
                            if !hasPrev {
                                prevL = curL
                                prevR = curR
                                hasPrev = true
                            }
                            while resamplePos < 1.0 && outCount < maxOutFrames {
                                let frac = Float(resamplePos)
                                stereoOut[outCount * 2] = prevL + (curL - prevL) * frac
                                stereoOut[outCount * 2 + 1] = prevR + (curR - prevR) * frac
                                outCount += 1
                                resamplePos += stepRatio
                            }
                            resamplePos -= 1.0
                            prevL = curL
                            prevR = curR
                        }
                        if outCount > 0 {
                            let bufPtr = UnsafeBufferPointer(start: stereoOut, count: outCount * 2)
                            if !ring.writeInterleaved(bufPtr, frameCount: outCount) { break }
                        }
                    }
                }

                if leftover > 0 {
                    memmove(rawBuf, rawBuf.advanced(by: wholeFrames * bytesPerFrame), leftover)
                }
                carryBytes = leftover
            } else if n == 0 {
                let errMsg = collectProcessError(errHandle: errHandle, proc: proc)
                ring.markEOF(errorMessage: errMsg)
                break
            } else {
                if errno == EINTR { continue }
                ring.markEOF()
                break
            }
        }
    }

    /// Fallback for minimalist LibreMPEG binaries compiled strictly with `--enable-muxer=flac` and no `wav` muxer.
    private static func streamFLACPipeInMemory(
        outFD: Int32,
        errHandle: FileHandle,
        proc: Process,
        ring: PCMStreamRing
    ) {
        var flacData = Data()
        let chunk = UnsafeMutableRawPointer.allocate(byteCount: 65_536, alignment: 1)
        defer { chunk.deallocate() }
        let maxFLACBytes = 512 * 1024 * 1024

        while flacData.count < maxFLACBytes {
            let n = Darwin.read(outFD, chunk, 65_536)
            if n > 0 {
                flacData.append(chunk.assumingMemoryBound(to: UInt8.self), count: n)
            } else if n == 0 {
                break
            } else {
                if errno == EINTR { continue }
                break
            }
        }

        let errMsg = collectProcessError(errHandle: errHandle, proc: proc)
        guard !flacData.isEmpty else {
            ring.markEOF(errorMessage: errMsg)
            return
        }

        // Decode FLAC via Core Audio temporary unlinked file
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ac4_ram_\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        do {
            try flacData.write(to: tmpURL, options: .atomic)
            flacData.removeAll(keepingCapacity: false)
            let audioFile = try AVAudioFile(forReading: tmpURL)
            guard let targetFmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: PlayerConstants.sampleRate,
                channels: AVAudioChannelCount(PlayerConstants.channels),
                interleaved: true
            ), let converter = AVAudioConverter(from: audioFile.processingFormat, to: targetFmt) else {
                ring.markEOF(errorMessage: "Core Audio could not initialize FLAC converter.")
                return
            }

            let frameCap: AVAudioFrameCount = 4096
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCap),
                  let outBuf = AVAudioPCMBuffer(pcmFormat: targetFmt, frameCapacity: frameCap * 2) else {
                ring.markEOF()
                return
            }

            var reachedEOF = false
            while !reachedEOF {
                var convErr: NSError?
                let status = converter.convert(to: outBuf, error: &convErr) { _, outStatus in
                    do {
                        try audioFile.read(into: inBuf, frameCount: frameCap)
                        if inBuf.frameLength == 0 {
                            outStatus.pointee = .endOfStream
                            return nil
                        }
                        outStatus.pointee = .haveData
                        return inBuf
                    } catch {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                }
                if outBuf.frameLength > 0, let mData = outBuf.audioBufferList.pointee.mBuffers.mData {
                    let fPtr = mData.assumingMemoryBound(to: Float.self)
                    let count = Int(outBuf.frameLength)
                    let bufPtr = UnsafeBufferPointer(start: fPtr, count: count * 2)
                    if !ring.writeInterleaved(bufPtr, frameCount: count) { break }
                }
                if status == .endOfStream || status == .error {
                    reachedEOF = true
                }
            }
            ring.markEOF()
        } catch {
            ring.markEOF(errorMessage: error.localizedDescription)
        }
    }

    func setPaused(_ paused: Bool) {
        if !paused && !engine.isRunning {
            try? engine.start()
        }
        renderState.setPaused(paused)
    }

    func stop() {
        stopStreamOnly()
    }

    private func stopStreamOnly() {
        renderState.setRing(nil, paused: true)
        if let ring = activeRing {
            ring.cancel()
            activeRing = nil
        }
        if let proc = activeProcess {
            if proc.isRunning {
                proc.terminate()
            }
            activeProcess = nil
        }
    }

    func pollProgress() -> (positionSeconds: Double, bufferedSeconds: Double, isFinished: Bool, error: String?, meterL: Float, meterR: Float) {
        let (mL, mR) = renderState.readMeters()
        guard let ring = activeRing else {
            return (0, 0, false, nil, 0, 0)
        }
        let snap = ring.snapshot()
        let pos = ring.startTimeSeconds + (Double(snap.consumedFrames) / PlayerConstants.sampleRate)
        return (pos, snap.bufferedSeconds, snap.isFinished, snap.error, mL, mR)
    }
}

// MARK: - Decoder Discovery & Verification Manager

enum DecoderResolver {
    private static func builtInStatus() -> DecoderStatus? {
        guard ac4_native_is_available() != 0 else { return nil }
        let ver = String(cString: ac4_native_version_string())
        let caps = DecoderCapabilities(
            pipeMode: .wav(pcmCodec: "pcm_f32le"),
            hasAresampleFilter: true,
            hasPipeProtocol: true,
            isBuiltInNative: true
        )
        return .readyAC4(
            source: "Built-in",
            path: "In-Process LibreMPEG",
            versionLine: ver.isEmpty ? "LibreMPEG in-process (32-bit Float)" : ver,
            capabilities: caps
        )
    }

    static func resolveStatus(customPath: String?) -> DecoderStatus {
        // 1. User-selected custom binary path (falls back to Built-in if stale/blocked)
        if let custom = customPath?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            let url = URL(fileURLWithPath: custom).standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: url.path) {
                let verified = verifyBinary(url: url, sourceLabel: "Custom")
                if verified.isAC4Capable || builtInStatus() == nil {
                    return verified
                }
            } else if builtInStatus() == nil {
                return .notFound(reason: "Configured binary not found at \(custom)")
            }
        }

        // 2. Built-in statically linked LibreMPEG (`libavcodec` + `libavformat` in-process)
        if let native = builtInStatus() {
            return native
        }

        // 3. Personal Bundled binary inside AC4 Player.app/Contents/Resources/bin/
        if let resURL = Bundle.main.resourceURL {
            for name in ["librempeg", "ffmpeg"] {
                let bundled = resURL.appendingPathComponent("bin/\(name)").standardizedFileURL
                if FileManager.default.isExecutableFile(atPath: bundled.path) {
                    return verifyBinary(url: bundled, sourceLabel: "Bundled")
                }
            }
        }

        // 4. Adjacent ./librempeg/ffmpeg directory next to AC4 Player.app, then system/local paths
        let appDir = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path
        let cwd = FileManager.default.currentDirectoryPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates: [(String, String)] = [
            ("\(appDir)/librempeg/ffmpeg", "Local Dir"),
            ("\(appDir)/librempeg/librempeg", "Local Dir"),
            ("\(appDir)/ffmpeg", "Local Dir"),
            ("\(cwd)/librempeg/ffmpeg", "Workspace"),
            ("\(cwd)/ffmpeg", "Workspace"),
            ("\(home)/Library/Application Support/AC4Player/bin/librempeg", "App Support"),
            ("\(home)/Library/Application Support/AC4Player/bin/ffmpeg", "App Support"),
            ("/opt/librempeg/bin/ffmpeg", "System"),
            ("/usr/local/bin/librempeg", "System"),
            ("/opt/homebrew/bin/librempeg", "Homebrew"),
            ("\(home)/.local/bin/librempeg", "Local"),
            ("\(home)/.local/bin/ffmpeg", "Local"),
            ("/opt/homebrew/bin/ffmpeg", "Homebrew"),
            ("/usr/local/bin/ffmpeg", "System")
        ]

        var fallbackStandardFFmpeg: DecoderStatus?
        var lastBlockedFailure: DecoderStatus?
        for (path, label) in candidates {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }
            let status = verifyBinary(url: url, sourceLabel: label)
            if status.isAC4Capable {
                return status
            }
            if fallbackStandardFFmpeg == nil, case .missingAC4Codec = status {
                fallbackStandardFFmpeg = status
            } else if lastBlockedFailure == nil, case .notFound = status {
                lastBlockedFailure = status
            }
        }

        if let fallbackStandardFFmpeg {
            return fallbackStandardFFmpeg
        }
        if let lastBlockedFailure {
            return lastBlockedFailure
        }

        return .notFound(reason: "Select your LibreMPEG 'ffmpeg' binary in the sidebar to decode AC-4 IMS.")
    }

    private struct CaptureResult {
        var stdout: String?
        var status: Int32
        var killedBySignal: Bool
    }

    private static func verifyBinary(url: URL, sourceLabel: String) -> DecoderStatus {
        let binPath = url.standardizedFileURL.path
        guard binPath.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: binPath) else {
            return .notFound(reason: "Invalid binary path")
        }

        let verCapture = runQuickCapture(binPath: binPath, args: ["-hide_banner", "-version"])
        if verCapture.killedBySignal {
            return .notFound(
                reason: "macOS / Santa blocked executing \(url.lastPathComponent) (signal \(verCapture.status)). Rebuild with ./build_app.sh to use in-process LibreMPEG."
            )
        }
        let versionLine = verCapture.stdout?
            .components(separatedBy: .newlines).first ?? url.lastPathComponent

        let decCapture = runQuickCapture(binPath: binPath, args: ["-hide_banner", "-decoders"])
        if let decodersOut = decCapture.stdout {
            // Match `A....D ac4` or ` ac4 ` in audio decoder listing
            let hasAC4 = decodersOut.components(separatedBy: .newlines).contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("A") else { return false }
                let parts = trimmed.split(whereSeparator: \.isWhitespace)
                return parts.count >= 2 && (parts[1] == "ac4" || parts[1] == "ac4_ims")
            }
            let caps = probeCapabilities(binPath: binPath)
            if hasAC4 {
                return .readyAC4(source: sourceLabel, path: binPath, versionLine: versionLine, capabilities: caps)
            }
            return .missingAC4Codec(path: binPath, versionLine: versionLine, capabilities: caps)
        }

        return .notFound(reason: "Could not execute \(url.lastPathComponent) (check macOS quarantine or security permissions).")
    }

    private static func probeCapabilities(binPath: String) -> DecoderCapabilities {
        var caps = DecoderCapabilities()

        let muxersOut = runQuickCapture(binPath: binPath, args: ["-hide_banner", "-muxers"]).stdout
            ?? runQuickCapture(binPath: binPath, args: ["-hide_banner", "-formats"]).stdout
            ?? ""
        let muxerNames = Set(muxersOut.components(separatedBy: .newlines).compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            let parts = t.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, parts[1] != "=", parts[0].contains("E"), parts[0].count <= 4 else { return nil }
            return String(parts[1]).components(separatedBy: ",").first
        })

        let encodersOut = runQuickCapture(binPath: binPath, args: ["-hide_banner", "-encoders"]).stdout ?? ""
        let audioEncoders = Set(encodersOut.components(separatedBy: .newlines).compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            let parts = t.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, parts[1] != "=", parts[0].first == "A", parts[0].count <= 8 else { return nil }
            return String(parts[1])
        })

        if muxerNames.isEmpty || muxerNames.contains("wav") {
            let preferredPCM = ["pcm_f32le", "pcm_s32le", "pcm_s24le", "pcm_s16le"].first {
                audioEncoders.contains($0)
            }
            caps.pipeMode = .wav(pcmCodec: audioEncoders.isEmpty ? "pcm_f32le" : preferredPCM)
        } else if muxerNames.contains("flac") {
            caps.pipeMode = .flac
        } else {
            caps.pipeMode = .wav(pcmCodec: nil)
        }

        if let filtersOut = runQuickCapture(binPath: binPath, args: ["-hide_banner", "-filters"]).stdout {
            caps.hasAresampleFilter = filtersOut.contains("aresample")
        }

        if let protocolsOut = runQuickCapture(binPath: binPath, args: ["-hide_banner", "-protocols"]).stdout,
           !protocolsOut.isEmpty {
            var inOutputSection = false
            var outputProtocols = Set<String>()
            for rawLine in protocolsOut.components(separatedBy: .newlines) {
                let t = rawLine.trimmingCharacters(in: .whitespaces)
                if t == "Output:" {
                    inOutputSection = true
                } else if t.hasSuffix(":") {
                    inOutputSection = false
                } else if inOutputSection && !t.isEmpty {
                    outputProtocols.insert(t)
                }
            }
            if !outputProtocols.isEmpty {
                caps.hasPipeProtocol = outputProtocols.contains("pipe")
            }
        }
        return caps
    }

    private static func runQuickCapture(binPath: String, args: [String]) -> CaptureResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return CaptureResult(stdout: nil, status: -1, killedBySignal: false)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let killed = (proc.terminationReason == .uncaughtSignal)
        guard !killed && proc.terminationStatus == 0 else {
            return CaptureResult(stdout: nil, status: proc.terminationStatus, killedBySignal: killed)
        }
        return CaptureResult(stdout: String(data: data, encoding: .utf8), status: 0, killedBySignal: false)
    }
}

// MARK: - Main ViewModel

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var tracks: [AudioTrack] = []
    @Published var selectedTrackID: AudioTrack.ID?

    @Published private(set) var currentTrack: AudioTrack?
    @Published private(set) var currentArtwork: NSImage?
    @Published private(set) var isPlaying: Bool = false
    @Published var playbackPosition: Double = 0.0
    @Published private(set) var bufferedAheadSeconds: Double = 0.0
    @Published var isScrubbing: Bool = false
    @Published var scrubPosition: Double = 0.0

    @Published var shuffleEnabled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var volume: Double = 0.85 {
        didSet {
            audioEngine.volume = Float(volume)
            UserDefaults.standard.set(volume, forKey: PlayerConstants.volumeDefaultsKey)
        }
    }
    @Published var preampDB: Double = 0.0 {
        didSet {
            let clamped = max(0.0, min(6.0, preampDB))
            if abs(clamped - preampDB) > 0.001 {
                preampDB = clamped
                return
            }
            audioEngine.preampDB = Float(clamped)
            UserDefaults.standard.set(clamped, forKey: PlayerConstants.preampDefaultsKey)
        }
    }

    @Published private(set) var meterLeft: Float = 0.0
    @Published private(set) var meterRight: Float = 0.0
    @Published private(set) var decoderStatus: DecoderStatus = .notFound(reason: "Checking decoder…")
    @Published var customDecoderPath: String?
    @Published var errorBanner: String?
    @Published var isDropTargeted: Bool = false

    private let audioEngine = AC4AudioEngine()
    private var progressTimer: Timer?
    private var remoteCommandsConfigured = false

    init() {
        let savedVol = UserDefaults.standard.object(forKey: PlayerConstants.volumeDefaultsKey) as? Double
        let initialVol = savedVol ?? 0.85
        self.volume = initialVol
        audioEngine.volume = Float(initialVol)

        let savedPreamp = UserDefaults.standard.object(forKey: PlayerConstants.preampDefaultsKey) as? Double
        let initialPreamp = max(0.0, min(6.0, savedPreamp ?? 0.0))
        self.preampDB = initialPreamp
        audioEngine.preampDB = Float(initialPreamp)

        let savedCustom = UserDefaults.standard.string(forKey: PlayerConstants.customDecoderDefaultsKey)
        self.customDecoderPath = savedCustom

        if savedCustom == nil && ac4_native_is_available() != 0 {
            let ver = String(cString: ac4_native_version_string())
            var caps = DecoderCapabilities()
            caps.isBuiltInNative = true
            self.decoderStatus = .readyAC4(
                source: "Built-in LibreMPEG",
                path: Bundle.main.executablePath ?? "built-in",
                versionLine: ver,
                capabilities: caps
            )
        }

        setupRemoteCommands()
        startProgressTimer()

        Task {
            await refreshDecoderStatus()
            restoreSavedLibrary()
        }
    }

    func togglePreampBoost() {
        if preampDB > 0.05 {
            preampDB = 0.0
        } else {
            preampDB = 6.0
        }
    }

    func refreshDecoderStatus() async {
        let custom = customDecoderPath
        let resolved = await Task.detached(priority: .userInitiated) {
            DecoderResolver.resolveStatus(customPath: custom)
        }.value
        if custom != nil && resolved.isBuiltInNative {
            customDecoderPath = nil
            UserDefaults.standard.removeObject(forKey: PlayerConstants.customDecoderDefaultsKey)
        }
        self.decoderStatus = resolved
        // Enrich any non-MP4 tracks lacking duration
        let decURL = resolved.activeBinaryPath.map { URL(fileURLWithPath: $0) }
        await enrichMissingMetadata(decoderURL: decURL)
    }

    func pickDecoderBinary() {
        let panel = NSOpenPanel()
        panel.title = "Select LibreMPEG 'ffmpeg' Executable"
        panel.message = "Choose your local LibreMPEG 'ffmpeg' (or 'librempeg') binary with AC-4 decoding support."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            let path = url.standardizedFileURL.path
            customDecoderPath = path
            UserDefaults.standard.set(path, forKey: PlayerConstants.customDecoderDefaultsKey)
            errorBanner = nil
            Task { await refreshDecoderStatus() }
        }
    }

    func clearCustomDecoder() {
        customDecoderPath = nil
        UserDefaults.standard.removeObject(forKey: PlayerConstants.customDecoderDefaultsKey)
        Task { await refreshDecoderStatus() }
    }

    func pickAudioFilesOrFolders() {
        let panel = NSOpenPanel()
        panel.title = "Add AC-4 IMS or Audio Files / Folders"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            addURLs(panel.urls)
        }
    }

    func addURLs(_ urls: [URL]) {
        let decoderPath = decoderStatus.activeBinaryPath
        let existingPaths = Set(tracks.map { $0.url.standardizedFileURL.path.lowercased() })

        Task {
            let added = await Task.detached(priority: .userInitiated) { () -> [AudioTrack] in
                var fileURLs: [URL] = []
                let fm = FileManager.default

                for raw in urls {
                    let std = raw.standardizedFileURL
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: std.path, isDirectory: &isDir) else { continue }
                    if isDir.boolValue {
                        if let enumerator = fm.enumerator(
                            at: std,
                            includingPropertiesForKeys: [.isRegularFileKey],
                            options: [.skipsHiddenFiles, .skipsPackageDescendants]
                        ) {
                            while let item = enumerator.nextObject() as? URL {
                                let ext = item.pathExtension.lowercased()
                                if PlayerConstants.supportedExtensions.contains(ext) {
                                    fileURLs.append(item.standardizedFileURL)
                                }
                            }
                        }
                    } else {
                        let ext = std.pathExtension.lowercased()
                        if PlayerConstants.supportedExtensions.contains(ext) {
                            fileURLs.append(std)
                        }
                    }
                }

                fileURLs.sort {
                    $0.path.localizedStandardCompare($1.path) == .orderedAscending
                }

                var result: [AudioTrack] = []
                var seen = existingPaths
                let decURL = decoderPath.map { URL(fileURLWithPath: $0) }

                for fURL in fileURLs {
                    let key = fURL.path.lowercased()
                    guard !seen.contains(key) else { continue }
                    seen.insert(key)

                    let size = (try? fm.attributesOfItem(atPath: fURL.path)[.size] as? Int64) ?? 0
                    var meta = MP4MetadataReader.inspect(url: fURL, loadArtwork: false)
                    if meta == nil {
                        meta = NativeLibreMPEGReader.inspect(url: fURL)
                            ?? CoreAudioMetadataReader.inspect(url: fURL, fileSizeBytes: size)
                            ?? decURL.flatMap { FFmpegProbeReader.inspect(url: fURL, decoderURL: $0) }
                    } else if let m = meta, m.durationSeconds == nil {
                        let probed = NativeLibreMPEGReader.inspect(url: fURL)
                            ?? CoreAudioMetadataReader.inspect(url: fURL, fileSizeBytes: size)
                            ?? decURL.flatMap { FFmpegProbeReader.inspect(url: fURL, decoderURL: $0) }
                        if let probed {
                            let existingBitrate = meta?.bitrateKbps
                            meta?.durationSeconds = probed.durationSeconds
                            meta?.bitrateKbps = existingBitrate ?? probed.bitrateKbps
                        }
                    }

                    let ext = fURL.pathExtension.lowercased()
                    let fallbackAC4 = (ext == "ac4")
                    let item = AudioTrack(
                        id: UUID(),
                        url: fURL,
                        title: meta?.title ?? fURL.deletingPathExtension().lastPathComponent,
                        artist: meta?.artist ?? "",
                        albumArtist: meta?.albumArtist ?? "",
                        album: meta?.album ?? fURL.deletingLastPathComponent().lastPathComponent,
                        trackNumber: meta?.trackNumber,
                        trackTotal: meta?.trackTotal,
                        discNumber: meta?.discNumber,
                        discTotal: meta?.discTotal,
                        year: meta?.year ?? "",
                        codecName: meta?.codecName ?? (fallbackAC4 ? "AC-4 IMS" : ext.uppercased()),
                        isAC4: meta?.isAC4 ?? fallbackAC4,
                        audioStreamIndex: meta?.audioStreamIndex ?? 0,
                        sampleRateHz: meta?.sampleRateHz ?? (fallbackAC4 ? 48_000 : nil),
                        channelCount: meta?.channelCount,
                        bitrateKbps: meta?.bitrateKbps,
                        durationSeconds: meta?.durationSeconds,
                        fileSizeBytes: size,
                        hasEmbeddedArtwork: (meta?.hasArtwork == true) || (meta?.artworkData != nil)
                    )
                    result.append(item)
                }
                return result
            }.value

            guard !added.isEmpty else { return }
            let wasEmpty = self.tracks.isEmpty
            self.tracks.append(contentsOf: added)
            self.persistLibrary()
            if wasEmpty, let first = self.tracks.first {
                self.selectedTrackID = first.id
            }
        }
    }

    private func enrichMissingMetadata(decoderURL: URL?) async {
        let targets = tracks.filter { $0.durationSeconds == nil }
        guard !targets.isEmpty else { return }
        let updates = await Task.detached(priority: .utility) { () -> [(UUID, TrackMetadata)] in
            var out: [(UUID, TrackMetadata)] = []
            for t in targets {
                let m = NativeLibreMPEGReader.inspect(url: t.url)
                    ?? CoreAudioMetadataReader.inspect(url: t.url, fileSizeBytes: t.fileSizeBytes)
                    ?? decoderURL.flatMap { FFmpegProbeReader.inspect(url: t.url, decoderURL: $0) }
                if let m {
                    out.append((t.id, m))
                }
            }
            return out
        }.value

        let map = Dictionary(uniqueKeysWithValues: updates)
        for i in tracks.indices {
            if let m = map[tracks[i].id] {
                tracks[i].durationSeconds = m.durationSeconds ?? tracks[i].durationSeconds
                tracks[i].bitrateKbps = m.bitrateKbps ?? tracks[i].bitrateKbps
                tracks[i].sampleRateHz = m.sampleRateHz ?? tracks[i].sampleRateHz
                if m.isAC4 {
                    tracks[i].isAC4 = true
                    tracks[i].codecName = "AC-4 IMS"
                }
                if !m.artist.isEmpty && tracks[i].artist.isEmpty { tracks[i].artist = m.artist }
                if !m.album.isEmpty { tracks[i].album = m.album }
                if currentTrack?.id == tracks[i].id {
                    currentTrack = tracks[i]
                    updateNowPlayingCenter()
                }
            }
        }
    }

    func removeTrack(_ track: AudioTrack) {
        let wasSelected = (selectedTrackID == track.id)
        if currentTrack?.id == track.id {
            stopPlayback()
        }
        tracks.removeAll { $0.id == track.id }
        if wasSelected {
            selectedTrackID = tracks.first?.id
        }
        persistLibrary()
    }

    func clearLibrary() {
        stopPlayback()
        tracks.removeAll()
        selectedTrackID = nil
        persistLibrary()
    }

    // MARK: - Transport Controls

    func playTrack(_ track: AudioTrack, startAt seekSeconds: Double = 0.0) {
        errorBanner = nil

        if track.isAC4 && !decoderStatus.isAC4Capable {
            if let binPath = decoderStatus.activeBinaryPath {
                errorBanner = "Selected FFmpeg (\(URL(fileURLWithPath: binPath).lastPathComponent)) lacks the 'ac4' decoder. Point AC-4 Player to your LibreMPEG binary or rebuild with ./librempeg."
            } else if case .notFound(let reason) = decoderStatus {
                errorBanner = reason
            } else {
                errorBanner = "AC-4 decoder not configured. Rebuild with ./librempeg or choose 'Locate LibreMPEG Binary…' from the File menu."
            }
            return
        }

        let isNewTrack = (currentTrack?.id != track.id)
        currentTrack = track
        selectedTrackID = track.id
        playbackPosition = seekSeconds
        scrubPosition = seekSeconds
        bufferedAheadSeconds = 0

        if isNewTrack {
            let url = track.url
            Task {
                let img = await Task.detached(priority: .userInitiated) {
                    ArtworkLoader.loadArtwork(for: url)
                }.value
                if self.currentTrack?.id == track.id {
                    self.currentArtwork = img
                    self.updateNowPlayingCenter()
                }
            }
        }

        do {
            try audioEngine.startStream(
                trackURL: track.url,
                isAC4Track: track.isAC4,
                decoderStatus: decoderStatus,
                audioStreamIndex: track.audioStreamIndex,
                seekSeconds: seekSeconds,
                startPaused: false
            )
            isPlaying = true
            updateNowPlayingCenter()
        } catch {
            isPlaying = false
            errorBanner = "Playback failed: \(error.localizedDescription)"
        }
    }

    func togglePlayPause() {
        if let current = currentTrack {
            if isPlaying {
                audioEngine.setPaused(true)
                isPlaying = false
                updateNowPlayingCenter()
            } else {
                // If stream already ended or hasn't started, restart cleanly from current position
                let snap = audioEngine.pollProgress()
                if snap.isFinished {
                    playTrack(current, startAt: 0)
                } else {
                    audioEngine.setPaused(false)
                    isPlaying = true
                    updateNowPlayingCenter()
                }
            }
        } else if let selID = selectedTrackID, let sel = tracks.first(where: { $0.id == selID }) {
            playTrack(sel)
        } else if let first = tracks.first {
            playTrack(first)
        }
    }

    func stopPlayback() {
        audioEngine.stop()
        isPlaying = false
        playbackPosition = 0
        scrubPosition = 0
        bufferedAheadSeconds = 0
        meterLeft = 0
        meterRight = 0
        currentTrack = nil
        currentArtwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func commitSeek(to targetSeconds: Double) {
        guard let current = currentTrack else { return }
        let maxDur = current.durationSeconds ?? max(targetSeconds, 0)
        let clamped = max(0, min(targetSeconds, max(0, maxDur - 0.1)))
        playbackPosition = clamped
        scrubPosition = clamped
        do {
            try audioEngine.startStream(
                trackURL: current.url,
                isAC4Track: current.isAC4,
                decoderStatus: decoderStatus,
                audioStreamIndex: current.audioStreamIndex,
                seekSeconds: clamped,
                startPaused: !isPlaying
            )
            updateNowPlayingCenter()
        } catch {
            errorBanner = "Seek failed: \(error.localizedDescription)"
        }
    }

    func playNext(automatic: Bool = false) {
        let queue = tracks
        guard !queue.isEmpty else { return }

        if automatic && repeatMode == .one, let current = currentTrack {
            playTrack(current, startAt: 0)
            return
        }

        if shuffleEnabled && queue.count > 1 {
            let candidates = queue.filter { $0.id != currentTrack?.id }
            if let randomTrack = candidates.randomElement() {
                playTrack(randomTrack)
                return
            }
        }

        guard let current = currentTrack,
              let idx = queue.firstIndex(where: { $0.id == current.id }) else {
            if let first = queue.first { playTrack(first) }
            return
        }

        let nextIdx = idx + 1
        if nextIdx < queue.count {
            playTrack(queue[nextIdx])
        } else if repeatMode == .all || !automatic {
            playTrack(queue[0])
        } else {
            isPlaying = false
            audioEngine.setPaused(true)
            playbackPosition = 0
            updateNowPlayingCenter()
        }
    }

    func playPrevious() {
        if playbackPosition > 3.0, let current = currentTrack {
            commitSeek(to: 0)
            if !isPlaying {
                playTrack(current, startAt: 0)
            }
            return
        }
        let queue = tracks
        guard !queue.isEmpty else { return }
        guard let current = currentTrack,
              let idx = queue.firstIndex(where: { $0.id == current.id }) else {
            if let first = queue.first { playTrack(first) }
            return
        }
        let prevIdx = idx > 0 ? (idx - 1) : (queue.count - 1)
        playTrack(queue[prevIdx])
    }

    // MARK: - Progress Timer & macOS Media Keys

    private func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickProgress()
            }
        }
    }

    private func tickProgress() {
        guard currentTrack != nil else { return }
        let snap = audioEngine.pollProgress()
        meterLeft = snap.meterL
        meterRight = snap.meterR
        bufferedAheadSeconds = snap.bufferedSeconds

        if let err = snap.error {
            isPlaying = false
            audioEngine.stop()
            errorBanner = "LibreMPEG decode error: \(err)"
            return
        }

        if isPlaying {
            if !isScrubbing {
                playbackPosition = snap.positionSeconds
                scrubPosition = snap.positionSeconds
            }
            if snap.isFinished {
                playNext(automatic: true)
            }
        }
    }

    private func setupRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.isEnabled = true
        cc.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }

        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }

        cc.togglePlayPauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }

        cc.nextTrackCommand.isEnabled = true
        cc.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playNext(automatic: false) }
            return .success
        }

        cc.previousTrackCommand.isEnabled = true
        cc.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playPrevious() }
            return .success
        }

        cc.changePlaybackPositionCommand.isEnabled = true
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self?.commitSeek(to: posEvent.positionTime) }
            return .success
        }
    }

    private func updateNowPlayingCenter() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.effectiveArtist,
            MPMediaItemPropertyAlbumTitle: track.effectiveAlbumTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: playbackPosition,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let dur = track.durationSeconds, dur > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = dur
        }
        if let img = currentArtwork {
            let artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    // MARK: - Library Persistence

    private func persistLibrary() {
        let paths = tracks.map { $0.url.standardizedFileURL.path }
        UserDefaults.standard.set(paths, forKey: PlayerConstants.savedTrackPathsDefaultsKey)
    }

    private func restoreSavedLibrary() {
        let fm = FileManager.default
        if let saved = UserDefaults.standard.stringArray(forKey: PlayerConstants.savedTrackPathsDefaultsKey) {
            let validURLs = saved
                .filter { fm.isReadableFile(atPath: $0) }
                .map { URL(fileURLWithPath: $0) }
            if !validURLs.isEmpty {
                addURLs(validURLs)
                return
            }
        }

        // Auto-discover top-level audio files situated right next to AC4 Player.app (e.g. workspace AC-4 tracks)
        let appParent = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL
        let homeApps = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").standardizedFileURL.path
        var searchDirs: [URL] = []
        if appParent.path != "/Applications" && appParent.path != homeApps && appParent.path != "/" {
            searchDirs.append(appParent)
        }
        let cwdURL = URL(fileURLWithPath: fm.currentDirectoryPath).standardizedFileURL
        if cwdURL.path != "/" && cwdURL.path != "/Applications" && !searchDirs.contains(cwdURL) {
            searchDirs.append(cwdURL)
        }

        var discovered: [URL] = []
        for dir in searchDirs {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for item in items {
                let isRegular = (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                guard isRegular else { continue }
                let ext = item.pathExtension.lowercased()
                if PlayerConstants.supportedExtensions.contains(ext) {
                    discovered.append(item.standardizedFileURL)
                }
            }
        }
        if !discovered.isEmpty {
            addURLs(discovered)
        }
    }
}

// MARK: - SwiftUI Views

struct ContentView: View {
    @ObservedObject var vm: PlayerViewModel

    var body: some View {
        VStack(spacing: 0) {
            MainLibraryView(vm: vm)

            Divider()

            TransportBarView(vm: vm)
        }
        .frame(minWidth: 840, minHeight: 520)
        .onDrop(of: [.fileURL], isTargeted: $vm.isDropTargeted) { providers in
            handleFileDrop(providers)
        }
        .overlay {
            if vm.isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.08))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let resolvedURL: URL?
                if let data = item as? Data {
                    resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
                } else if let url = item as? URL {
                    resolvedURL = url
                } else {
                    resolvedURL = nil
                }
                if let url = resolvedURL {
                    Task { @MainActor in
                        vm.addURLs([url])
                    }
                }
            }
        }
        return true
    }
}

struct MainLibraryView: View {
    @ObservedObject var vm: PlayerViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let banner = vm.errorBanner {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(banner)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Button("Dismiss") {
                        vm.errorBanner = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.15))
            }

            if vm.tracks.isEmpty {
                EmptyLibraryDropView(vm: vm)
            } else {
                TrackListHeaderBar(vm: vm)
                Divider()
                TrackTableView(vm: vm)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !vm.decoderStatus.isAC4Capable {
                    Button {
                        vm.pickDecoderBinary()
                    } label: {
                        Label("Locate LibreMPEG…", systemImage: "cpu")
                    }
                    .help("Select your LibreMPEG binary for AC-4 IMS decoding")
                }

                Button {
                    vm.pickAudioFilesOrFolders()
                } label: {
                    Label("Add Files / Folders", systemImage: "plus")
                }
                .help("Add AC-4 IMS (.m4a, .mp4, .ac4) or lossless audio files/folders")

                if !vm.tracks.isEmpty {
                    Button {
                        vm.clearLibrary()
                    } label: {
                        Label("Clear Library", systemImage: "trash")
                    }
                    .help("Clear track list (files on disk are never touched)")
                }
            }
        }
    }
}

struct EmptyLibraryDropView: View {
    @ObservedObject var vm: PlayerViewModel

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)

            Text("Drop AC-4 IMS Files or Music Folders Here")
                .font(.title3.weight(.semibold))

            Text("Plays .m4a, .mp4, and .ac4 audio in 48 kHz 32-bit float via LibreMPEG.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            HStack(spacing: 10) {
                Button("Add Files or Folders…") {
                    vm.pickAudioFilesOrFolders()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if !vm.decoderStatus.isAC4Capable {
                    Button("Locate LibreMPEG…") {
                        vm.pickDecoderBinary()
                    }
                    .controlSize(.large)
                }
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TrackListHeaderBar: View {
    @ObservedObject var vm: PlayerViewModel

    var body: some View {
        HStack(spacing: 12) {
            Text("Tracks")
                .font(.headline)
            Text("\(vm.tracks.count) \(vm.tracks.count == 1 ? "track" : "tracks")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !vm.tracks.isEmpty {
                Button {
                    if let first = vm.tracks.first {
                        vm.playTrack(first)
                    }
                } label: {
                    Label("Play All", systemImage: "play.fill")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct TrackTableView: View {
    @ObservedObject var vm: PlayerViewModel

    var body: some View {
        List(selection: $vm.selectedTrackID) {
            ForEach(vm.tracks) { track in
                TrackRowView(
                    track: track,
                    isCurrent: vm.currentTrack?.id == track.id,
                    isPlaying: vm.currentTrack?.id == track.id && vm.isPlaying
                )
                .tag(track.id)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    vm.playTrack(track)
                }
                .onTapGesture(count: 1) {
                    vm.selectedTrackID = track.id
                }
                .contextMenu {
                    Button("Play") {
                        vm.playTrack(track)
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([track.url])
                    }
                    Divider()
                    Button("Remove", role: .destructive) {
                        vm.removeTrack(track)
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
}

struct TrackRowView: View {
    let track: AudioTrack
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if isCurrent {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.caption.weight(.bold))
                } else {
                    Text(track.formattedTrackNumber)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                Text("\(track.effectiveArtist) — \(track.effectiveAlbumTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if !track.formattedSpecs.isEmpty {
                Text(track.formattedSpecs)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            CodecBadgeView(codec: track.codecName, isAC4: track.isAC4)

            Text(track.formattedDuration)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
}

struct CodecBadgeView: View {
    let codec: String
    let isAC4: Bool

    var body: some View {
        Text(codec)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(isAC4 ? Color.purple.opacity(0.20) : Color.secondary.opacity(0.14))
            )
            .foregroundStyle(isAC4 ? Color.purple : Color.secondary)
    }
}

struct TransportBarView: View {
    @ObservedObject var vm: PlayerViewModel

    var body: some View {
        HStack(spacing: 16) {
            // Left: Artwork + Track Metadata
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.15))
                    if let img = vm.currentArtwork {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: vm.currentTrack?.isAC4 == true ? "headphones" : "music.note")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 52, height: 52)

                if let track = vm.currentTrack {
                    let streamModeLabel = track.isAC4
                        ? (vm.decoderStatus.isBuiltInNative ? "In-Process RAM" : "RAM Pipe")
                        : "Core Audio RAM"
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(track.title)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            CodecBadgeView(codec: track.codecName, isAC4: track.isAC4)
                        }
                        Text("\(track.effectiveArtist) · \(track.effectiveAlbumTitle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("\(streamModeLabel) · 48 kHz 32-bit Float (+\(Int(vm.bufferedAheadSeconds.rounded()))s buf)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("Not Playing")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 265, alignment: .leading)

            // Center: Transport Buttons + Seek Bar
            VStack(spacing: 8) {
                HStack(spacing: 18) {
                    Button {
                        vm.shuffleEnabled.toggle()
                    } label: {
                        Image(systemName: "shuffle")
                            .foregroundStyle(vm.shuffleEnabled ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Shuffle")

                    Button {
                        vm.playPrevious()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.tracks.isEmpty)

                    Button {
                        vm.togglePlayPause()
                    } label: {
                        Image(systemName: vm.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 28))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(vm.tracks.isEmpty)

                    Button {
                        vm.playNext(automatic: false)
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.tracks.isEmpty)

                    Button {
                        let nextRaw = (vm.repeatMode.rawValue + 1) % RepeatMode.allCases.count
                        vm.repeatMode = RepeatMode(rawValue: nextRaw) ?? .off
                    } label: {
                        Image(systemName: vm.repeatMode.systemImage)
                            .foregroundStyle(vm.repeatMode != .off ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(vm.repeatMode.label)
                }

                HStack(spacing: 8) {
                    let displayedPos = vm.isScrubbing ? vm.scrubPosition : vm.playbackPosition
                    let totalDur = max(vm.currentTrack?.durationSeconds ?? 0, displayedPos, 1.0)
                    let seekEnabled = vm.currentTrack != nil && (vm.currentTrack?.durationSeconds ?? 0) > 0

                    Text(TimeFormatting.clockString(seconds: displayedPos))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)

                    Slider(
                        value: Binding(
                            get: { vm.isScrubbing ? vm.scrubPosition : vm.playbackPosition },
                            set: { newValue in
                                vm.scrubPosition = newValue
                            }
                        ),
                        in: 0...totalDur,
                        onEditingChanged: { editing in
                            if editing {
                                vm.isScrubbing = true
                            } else {
                                let target = vm.scrubPosition
                                vm.isScrubbing = false
                                vm.commitSeek(to: target)
                            }
                        }
                    )
                    .controlSize(.small)
                    .disabled(!seekEnabled)

                    Text(vm.currentTrack?.durationSeconds != nil ? TimeFormatting.clockString(seconds: totalDur) : "--:--")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity)

            // Right: Live Post-Preamp Stereo Meter + Pre-Amp (+dB) + Output Volume
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    StereoMeterView(left: vm.meterLeft, right: vm.meterRight)
                        .frame(width: 42, height: 14)
                        .help("Real-time post-preamp stereo headroom meter")

                    Text("Pre")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)

                    Slider(value: $vm.preampDB, in: 0.0...6.0, step: 0.5)
                        .controlSize(.small)
                        .frame(width: 86)
                        .help("Pre-amp boost (0 dB to +6 dB) with soft-clip protection")

                    let isBoosted = vm.preampDB > 0.05
                    Button {
                        vm.togglePreampBoost()
                    } label: {
                        Text(isBoosted ? String(format: "+%.1f dB", vm.preampDB) : "0.0 dB")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .frame(width: 54)
                            .background(
                                Capsule()
                                    .fill(isBoosted ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                            )
                            .foregroundStyle(isBoosted ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isBoosted ? "Click to reset pre-amp to 0.0 dB" : "Click for +6.0 dB AC-4 pre-amp boost")
                }

                HStack(spacing: 6) {
                    Image(systemName: vm.volume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                        .onTapGesture {
                            vm.volume = vm.volume < 0.01 ? 0.85 : 0.0
                        }

                    Slider(value: $vm.volume, in: 0...1)
                        .controlSize(.small)
                        .frame(width: 132)

                    Text("\(Int((vm.volume * 100).rounded()))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            .frame(width: 242, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct StereoMeterView: View {
    let left: Float
    let right: Float

    var body: some View {
        VStack(spacing: 3) {
            meterBar(level: left)
            meterBar(level: right)
        }
    }

    private func meterBar(level: Float) -> some View {
        GeometryReader { geo in
            let norm = normalizedDB(level)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.green, .yellow, .orange, .red],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, geo.size.width * CGFloat(norm)))
            }
        }
    }

    private func normalizedDB(_ linear: Float) -> Float {
        guard linear > 0.0001 else { return 0 }
        let db = 20.0 * log10(linear) // [-80, 0]
        return max(0, min(1, (db + 54.0) / 54.0))
    }
}

// MARK: - App Entry Point

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct AC4PlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = PlayerViewModel()

    var body: some Scene {
        WindowGroup("AC-4 Player") {
            ContentView(vm: viewModel)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files or Folders…") {
                    viewModel.pickAudioFilesOrFolders()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Toggle +6 dB Pre-Amp Boost") {
                    viewModel.togglePreampBoost()
                }
                .keyboardShortcut("b", modifiers: [.command])

                Divider()

                Button("Locate LibreMPEG Binary…") {
                    viewModel.pickDecoderBinary()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}
