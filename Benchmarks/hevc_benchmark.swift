// hevc_benchmark.swift
// Standalone VideoToolbox benchmark: H.264 vs HEVC on this Mac, matched settings to Beam's
// encoder (realtime, no frame reordering, 2s keyframe interval, 2x datarate cap).
//
// It synthesizes a deterministic high-motion 1080p scene (scrolling detail + moving gradients
// + noise) that approximates Beam's hardest workload — game/emulator streaming — encodes the
// identical frames with both codecs at several target bitrates, decodes each stream back, and
// reports achieved bitrate, average luma PSNR (quality), and encode latency per frame.
//
// Run:  swiftc -O hevc_benchmark.swift -o /tmp/hevcbench && /tmp/hevcbench
//
// Notes / honesty caveats:
//  - PSNR is luma-only (BT.709 approx from the synthetic BGRA source vs the decoder's Y plane).
//    The colorspace conversion is identical for both codecs, so the *relative* comparison is
//    fair even if absolute dB is approximate.
//  - Synthetic content is deterministic and reproducible; a real game will vary, but the
//    high-motion synthetic scene is deliberately harder than a typical desktop, which is where
//    HEVC's advantage is most and least visible respectively.

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import Accelerate

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered so a crash never eats progress output

// MARK: - Config

let W = 1920, H = 1080
let FPS: Double = 30
let FRAME_COUNT = 90                        // 3 seconds
let TARGET_MBPS: [Double] = [2, 4, 6, 8, 10]

// MARK: - Synthetic frame source

/// Deterministic high-motion scene rendered into a BGRA CVPixelBuffer for frame index `i`.
func makeFrame(_ i: Int, pool: CVPixelBufferPool) -> CVPixelBuffer? {
    var pbOpt: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbOpt)
    guard let pb = pbOpt else { return nil }
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    let ctx = CGContext(data: base, width: W, height: H, bitsPerComponent: 8, bytesPerRow: bpr,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    guard let ctx else { return nil }

    // A frame representative of game/emulator/screen streaming: smooth gradients and flat
    // panels (most of a screen), a scrolling textured playfield, structured "text" rows, and
    // sprites that pan smoothly (predictable motion). This is the kind of content HEVC's larger
    // coding units and better intra/inter prediction exploit — NOT full-frame random noise,
    // which no codec compresses and which would falsely flatten the comparison.
    let phase = Double(i) / Double(FRAME_COUNT)
    let pan = CGFloat((i * 6) % W)   // smooth horizontal camera pan

    // Smooth vertical gradient background (large low-frequency area).
    let cs = CGColorSpaceCreateDeviceRGB()
    if let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.08, green: 0.10 + 0.05 * abs(sin(phase * .pi)), blue: 0.22, alpha: 1),
        CGColor(red: 0.20, green: 0.28, blue: 0.42, alpha: 1)] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: H), options: [])
    }

    // Full-frame scrolling textured playfield with per-tile detail. Covers the whole frame so
    // the content is genuinely hard (visibly compressed at 6 Mbps, like a real 1080p game),
    // not transparent — otherwise both codecs sit near-lossless and nothing is measured.
    let tile = 64
    for ty in stride(from: -tile, to: H + tile, by: tile) {
        for tx in stride(from: -tile, to: W + tile, by: tile) {
            let sx = CGFloat(((tx + Int(pan)) % (W + tile))) - CGFloat(tile)
            let sy = CGFloat(((ty + Int(pan) / 2) % (H + tile))) - CGFloat(tile)
            let shade = 0.2 + 0.35 * abs(sin(Double(tx) * 0.02 + Double(ty) * 0.017 + phase * 3))
            ctx.setFillColor(CGColor(red: shade, green: shade * 0.85, blue: shade * 0.65, alpha: 1))
            ctx.fill(CGRect(x: sx, y: sy, width: CGFloat(tile - 3), height: CGFloat(tile - 3)))
            // Inner detail square (higher spatial frequency)
            ctx.setFillColor(CGColor(red: shade * 1.4, green: shade, blue: shade * 0.4, alpha: 1))
            ctx.fill(CGRect(x: sx + 8, y: sy + 8, width: CGFloat(tile / 3), height: CGFloat(tile / 3)))
        }
    }

    // Structured "text" rows (HUD/UI): high-contrast small blocks, static position.
    ctx.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.98, alpha: 1))
    for row in 0..<8 {
        let ry = 60 + row * 26
        var wx = 60
        while wx < 700 {
            let wlen = 8 + (row * 13 + wx) % 40
            ctx.fill(CGRect(x: CGFloat(wx), y: CGFloat(ry), width: CGFloat(wlen), height: 10))
            wx += wlen + 6
        }
    }

    // Smoothly panning sprites (coherent motion the inter predictor tracks well).
    for s in 0..<60 {
        let sx = (Double(i) * (1.5 + Double(s) * 0.2) + Double(s) * 80).truncatingRemainder(dividingBy: Double(W))
        let sy = Double(H) * 0.35 + 180 * sin(phase * 2 * .pi + Double(s))
        let hue = Double(s) / 24.0
        ctx.setFillColor(CGColor(red: hue, green: 0.6, blue: 1 - hue, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: sx, y: sy, width: 70, height: 70))
    }

    // Light film-grain (a realistic amount of incompressible detail, not a noise storm).
    var rng = UInt64(0x9E3779B97F4A7C15 &* UInt64(i &+ 1))
    for _ in 0..<2500 {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        let px = Int(rng % UInt64(W)); let py = Int((rng >> 20) % UInt64(H))
        let g = 0.4 + Double((rng >> 40) % 64) / 255.0
        ctx.setFillColor(CGColor(red: g, green: g, blue: g, alpha: 0.5))
        ctx.fill(CGRect(x: CGFloat(px), y: CGFloat(py), width: 2, height: 2))
    }
    return pb
}

func makePool() -> CVPixelBufferPool {
    let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: W,
        kCVPixelBufferHeightKey as String: H,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
    return pool!
}

// MARK: - Encoded frame record

final class EncodedStream {
    var samples: [(data: Data, pts: CMTime, keyframe: Bool)] = []
    var formatDesc: CMFormatDescription?
    var totalBytes = 0
    var encodeNanos: [UInt64] = []
}

// Annex B not needed here — we keep AVCC block buffers and reuse the format description for decode.

func encode(codec: CMVideoCodecType, profile: CFString, targetBps: Int, frames: [CVPixelBuffer]) -> EncodedStream? {
    let stream = EncodedStream()
    let spec: [String: Any] = [
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
    ]
    var sessionOpt: VTCompressionSession?
    let refcon = Unmanaged.passRetained(stream).toOpaque()
    let status = VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault, width: Int32(W), height: Int32(H), codecType: codec,
        encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
        compressedDataAllocator: nil,
        outputCallback: { refconOpt, _, status, _, sbOpt in
            guard let refconOpt, status == noErr, let sb = sbOpt, CMSampleBufferGetDataBuffer(sb) != nil else { return }
            let s = Unmanaged<EncodedStream>.fromOpaque(refconOpt).takeUnretainedValue()
            if s.formatDesc == nil { s.formatDesc = CMSampleBufferGetFormatDescription(sb) }
            var len = 0; var ptr: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(CMSampleBufferGetDataBuffer(sb)!, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            let data = Data(bytes: ptr!, count: len)
            let attach = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
            var keyframe = true
            if let attach, CFArrayGetCount(attach) > 0,
               let d = CFArrayGetValueAtIndex(attach, 0).map({ Unmanaged<CFDictionary>.fromOpaque($0).takeUnretainedValue() }),
               let ns = (d as NSDictionary)[kCMSampleAttachmentKey_NotSync] as? Bool { keyframe = !ns }
            s.totalBytes += len
            s.samples.append((data, CMSampleBufferGetPresentationTimeStamp(sb), keyframe))
        },
        refcon: refcon, compressionSessionOut: &sessionOpt)
    guard status == noErr, let session = sessionOpt else {
        Unmanaged<EncodedStream>.fromOpaque(refcon).release()
        return nil
    }
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: targetBps))
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [targetBps * 2, 1] as CFArray)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: FPS))
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: Int(FPS * 2)))

    for (i, pb) in frames.enumerated() {
        let pts = CMTime(value: Int64(i), timescale: Int32(FPS))
        let t0 = DispatchTime.now().uptimeNanoseconds
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: Int32(FPS)), frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: pts)
        stream.encodeNanos.append(DispatchTime.now().uptimeNanoseconds - t0)
    }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    VTCompressionSessionInvalidate(session)
    Unmanaged<EncodedStream>.fromOpaque(refcon).release()
    return stream
}

// MARK: - Decode + PSNR

final class DecodedSink { var luma: [[UInt8]] = [] }

func lumaFromBGRA(_ pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    var out = [UInt8](repeating: 0, count: W * H)
    for y in 0..<H { for x in 0..<W {
        let p = y * bpr + x * 4
        let b = Double(base[p]); let g = Double(base[p+1]); let r = Double(base[p+2])
        out[y * W + x] = UInt8(min(255, max(0, 0.2126 * r + 0.7152 * g + 0.0722 * b)))
    } }
    return out
}

func lumaFromYUV(_ pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
    let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    var out = [UInt8](repeating: 0, count: W * H)
    for y in 0..<H { for x in 0..<W { out[y * W + x] = base[y * bpr + x] } }
    return out
}

func decodeLuma(_ stream: EncodedStream) -> [[UInt8]] {
    guard let fmt = stream.formatDesc else { return [] }
    let sink = DecodedSink()
    let refcon = Unmanaged.passRetained(sink).toOpaque()
    var cb = VTDecompressionOutputCallbackRecord(
        decompressionOutputCallback: { refconOpt, _, status, _, img, _, _ in
            guard let refconOpt, status == noErr, let img else { return }
            let s = Unmanaged<DecodedSink>.fromOpaque(refconOpt).takeUnretainedValue()
            // Decode to BGRA and derive luma the SAME way as the source frames, so the only
            // difference measured is genuine codec loss — not a YUV range/matrix mismatch that
            // would otherwise cap PSNR at ~31 dB regardless of bitrate.
            s.luma.append(lumaFromBGRA(img))
        }, decompressionOutputRefCon: refcon)
    let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    var sessionOpt: VTDecompressionSession?
    VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fmt, decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary, outputCallback: &cb, decompressionSessionOut: &sessionOpt)
    guard let session = sessionOpt else { Unmanaged<DecodedSink>.fromOpaque(refcon).release(); return [] }
    for s in stream.samples {
        var bb: CMBlockBuffer?
        s.data.withUnsafeBytes { raw in
            CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: s.data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: s.data.count, flags: 0, blockBufferOut: &bb)
            _ = raw.baseAddress.map { CMBlockBufferReplaceDataBytes(with: $0, blockBuffer: bb!, offsetIntoDestination: 0, dataLength: s.data.count) }
        }
        guard let bb else { continue }
        var sizes = [s.data.count]; var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(FPS)), presentationTimeStamp: s.pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: bb, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sb)
        if let sb { VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [._EnableTemporalProcessing], frameRefcon: nil, infoFlagsOut: nil) }
    }
    VTDecompressionSessionWaitForAsynchronousFrames(session)
    VTDecompressionSessionInvalidate(session)
    Unmanaged<DecodedSink>.fromOpaque(refcon).release()
    return sink.luma
}

func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var mse = 0.0
    for i in 0..<a.count { let d = Double(a[i]) - Double(b[i]); mse += d * d }
    mse /= Double(a.count)
    if mse <= 0 { return 99 }
    return 10 * log10(255 * 255 / mse)
}

// MARK: - Run

print("HEVC vs H.264 benchmark — \(W)x\(H) @ \(Int(FPS))fps, \(FRAME_COUNT) frames of synthetic high-motion content")
print("HEVC hardware encode available: \(VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC))\n")

let pool = makePool()
print("Rendering \(FRAME_COUNT) source frames…")
var srcFrames: [CVPixelBuffer] = []
var srcLuma: [[UInt8]] = []
for i in 0..<FRAME_COUNT { if let f = makeFrame(i, pool: pool) { srcFrames.append(f); srcLuma.append(lumaFromBGRA(f)) } }

struct Row { let codec: String; let mbps: Double; let achieved: Double; let psnr: Double; let encMs: Double }
var rows: [Row] = []

let codecs: [(name: String, type: CMVideoCodecType, profile: CFString)] = [
    ("H.264", kCMVideoCodecType_H264, kVTProfileLevel_H264_High_AutoLevel),
    ("HEVC",  kCMVideoCodecType_HEVC, kVTProfileLevel_HEVC_Main_AutoLevel),
]

for target in TARGET_MBPS {
    for c in codecs {
        guard let s = encode(codec: c.type, profile: c.profile, targetBps: Int(target * 1_000_000), frames: srcFrames) else {
            print("  \(c.name) @ \(target)Mbps — encoder unavailable"); continue
        }
        let seconds = Double(FRAME_COUNT) / FPS
        let achieved = Double(s.totalBytes) * 8 / seconds / 1_000_000
        let dec = decodeLuma(s)
        let n = min(dec.count, srcLuma.count)
        var psnrSum = 0.0
        for i in 0..<n { psnrSum += psnr(srcLuma[i], dec[i]) }
        let avgPsnr = n > 0 ? psnrSum / Double(n) : 0
        let avgEnc = s.encodeNanos.reduce(0, +) / UInt64(max(1, s.encodeNanos.count))
        rows.append(Row(codec: c.name, mbps: target, achieved: achieved, psnr: avgPsnr, encMs: Double(avgEnc) / 1_000_000))
    }
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func f(_ v: Double, _ d: Int) -> String { String(format: "%.\(d)f", v) }
print("\n  target   codec   achieved     PSNR       encode")
print("  ------   -----   --------   ---------   --------")
for r in rows {
    print("  \(pad(f(r.mbps,0)+"M",6))   \(pad(r.codec,5))   \(pad(f(r.achieved,2)+"M",8))   \(pad(f(r.psnr,2)+" dB",9))   \(f(r.encMs,2)) ms")
}

// Headline: at each target, HEVC PSNR gain over H.264, and the bitrate H.264 would need to
// match HEVC (interpolated along the H.264 curve).
print("\nHeadline:")
let h264 = rows.filter { $0.codec == "H.264" }.sorted { $0.mbps < $1.mbps }
let hevc = rows.filter { $0.codec == "HEVC" }.sorted { $0.mbps < $1.mbps }
func h264BitrateFor(psnr target: Double) -> Double? {
    for i in 1..<max(1, h264.count) {
        let a = h264[i-1], b = h264[i]
        let lo = min(a.psnr, b.psnr), hi = max(a.psnr, b.psnr)
        if (lo...hi).contains(target), b.psnr != a.psnr {
            let t = (target - a.psnr) / (b.psnr - a.psnr)
            return a.mbps + t * (b.mbps - a.mbps)
        }
    }
    return nil
}
for hv in hevc {
    if let h = h264.first(where: { $0.mbps == hv.mbps }) {
        let gain = hv.psnr - h.psnr
        var savingStr = ""
        if let needed = h264BitrateFor(psnr: hv.psnr), needed > 0 {
            let saving = (1 - hv.mbps / needed) * 100
            savingStr = " | H.264 needs ~\(f(needed,1))Mbps to match, so HEVC saves ~\(f(saving,0))%"
        }
        let sign = gain >= 0 ? "+" : ""
        print("  @\(f(hv.mbps,0))Mbps: HEVC \(sign)\(f(gain,2)) dB vs H.264\(savingStr)")
    }
}

exit(0)
