// watch: turns any camera or capture device into a latency instrument.
//
// Samples the mean brightness of one or two regions of every frame it receives and writes them
// with the host clock. Paired with flashboard's log, that is the latency of whatever carried
// the picture. Nothing here knows which streaming app is running, which is the point.
//
// Two ways to use it:
//
//   One region, live capture of the phone (iPhone over USB, or a camera pointed at it):
//       watch --device "iiiiiPhone" --roi 0.3,0.3,0.4,0.4 --out phone.csv
//   Two regions, one camera seeing the Mac screen and the phone side by side:
//       watch --device "Logitech" --roi 0.05,0.3,0.3,0.4 --roi2 0.6,0.3,0.3,0.4 --out both.csv
//
// The second needs no clocks at all: the flip appears in region A, then in region B, and the
// difference between them is the latency of the path between the two screens.
//
// Output: L,<mach_ns>,<luma A 0-255>[,<luma B>]

import AVFoundation
import CoreMediaIO
import CoreImage

var deviceQuery = "", outPath = "/Volumes/yuh/business/.scratch/bench/watch.csv"
var roiA = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
var roiB: CGRect? = nil
var listOnly = false, seconds = 600.0
var args = CommandLine.arguments.dropFirst().makeIterator()
func rect(_ s: String) -> CGRect {
    let p = s.split(separator: ",").compactMap { Double($0) }
    guard p.count == 4 else { return CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4) }
    return CGRect(x: p[0], y: p[1], width: p[2], height: p[3])
}
while let a = args.next() {
    switch a {
    case "--device": deviceQuery = args.next() ?? ""
    case "--out": outPath = args.next() ?? outPath
    case "--roi": roiA = rect(args.next() ?? "")
    case "--roi2": roiB = rect(args.next() ?? "")
    case "--seconds": seconds = Double(args.next() ?? "") ?? seconds
    case "--list": listOnly = true
    default: break
    }
}

// iOS devices are hidden from AVFoundation until this is set. Without it an iPhone on USB is
// simply not in the list, which looks like a cable problem and is not one.
var allowProp = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
                                          mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                          mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
var allow: UInt32 = 1
CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &allowProp, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)

let discovery = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.external, .builtInWideAngleCamera, .deskViewCamera, .continuityCamera],
    mediaType: .video, position: .unspecified)

if listOnly || deviceQuery.isEmpty {
    for d in discovery.devices {
        let best = d.formats.map { f -> String in
            let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let fps = f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            return "\(dim.width)x\(dim.height)@\(Int(fps))"
        }
        print("\(d.localizedName)  [\(d.deviceType.rawValue)]")
        print("   \(Set(best).sorted().joined(separator: " "))")
    }
    if discovery.devices.isEmpty { print("no capture devices. An iPhone must be connected by cable, unlocked and trusted.") }
    exit(0)
}

guard let device = discovery.devices.first(where: { $0.localizedName.localizedCaseInsensitiveContains(deviceQuery) }) else {
    FileHandle.standardError.write("no capture device matching '\(deviceQuery)'. --list shows them.\n".data(using: .utf8)!)
    exit(2)
}

// The highest frame rate this device offers, because every millisecond of capture interval is a
// millisecond of uncertainty in a single trial.
var bestFormat: AVCaptureDevice.Format?
var bestRate = 0.0
for f in device.formats {
    let rate = f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
    if rate > bestRate { bestRate = rate; bestFormat = f }
}

let session = AVCaptureSession()
session.beginConfiguration()
guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
    FileHandle.standardError.write("cannot open \(device.localizedName)\n".data(using: .utf8)!); exit(3)
}
session.addInput(input)
let output = AVCaptureVideoDataOutput()
output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
output.alwaysDiscardsLateVideoFrames = false
session.addOutput(output)
if let f = bestFormat, (try? device.lockForConfiguration()) != nil {
    device.activeFormat = f
    if let r = f.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
        device.activeVideoMinFrameDuration = r.minFrameDuration
    }
    device.unlockForConfiguration()
}
session.commitConfiguration()

var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
func nowNanos() -> UInt64 { mach_absolute_time() * UInt64(timebase.numer) / UInt64(timebase.denom) }

try? FileManager.default.createDirectory(atPath: (outPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
FileManager.default.createFile(atPath: outPath, contents: nil)
let handle = try! FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
let logQueue = DispatchQueue(label: "watch.log")

final class Sink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var frames = 0
    func captureOutput(_ o: AVCaptureOutput, didOutput sample: CMSampleBuffer, from c: AVCaptureConnection) {
        // The presentation timestamp is on the host clock, which is the clock flashboard writes,
        // so the two logs need no synchronisation of any kind.
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let stamp = pts.isValid ? UInt64(pts.seconds * 1_000_000_000) : nowNanos()
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        func luma(_ roi: CGRect) -> Int {
            let x0 = max(0, Int(roi.minX * Double(w))), x1 = min(w, Int(roi.maxX * Double(w)))
            let y0 = max(0, Int(roi.minY * Double(h))), y1 = min(h, Int(roi.maxY * Double(h)))
            guard x1 > x0, y1 > y0 else { return 0 }
            var total = 0, count = 0
            let p = base.assumingMemoryBound(to: UInt8.self)
            // Every fourth pixel and every second row: enough for a mean, cheap enough to keep up
            // with 240 fps on one core.
            for y in stride(from: y0, to: y1, by: 2) {
                let row = p + y * rowBytes
                for x in stride(from: x0, to: x1, by: 4) {
                    let px = row + x * 4
                    total += (Int(px[2]) * 299 + Int(px[1]) * 587 + Int(px[0]) * 114) / 1000
                    count += 1
                }
            }
            return count > 0 ? total / count : 0
        }
        let a = luma(roiA)
        let line = roiB.map { "L,\(stamp),\(a),\(luma($0))\n" } ?? "L,\(stamp),\(a)\n"
        frames += 1
        logQueue.async { handle.write(line.data(using: .utf8)!) }
    }
}
let sink = Sink()
output.setSampleBufferDelegate(sink, queue: DispatchQueue(label: "watch.capture", qos: .userInteractive))
session.startRunning()

let dims = bestFormat.map { CMVideoFormatDescriptionGetDimensions($0.formatDescription) }
FileHandle.standardError.write("watching \(device.localizedName) at \(dims?.width ?? 0)x\(dims?.height ?? 0) up to \(Int(bestRate)) fps -> \(outPath)\n".data(using: .utf8)!)
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    session.stopRunning(); logQueue.sync {}
    FileHandle.standardError.write("captured \(sink.frames) frames\n".data(using: .utf8)!)
    exit(0)
}
RunLoop.main.run()
