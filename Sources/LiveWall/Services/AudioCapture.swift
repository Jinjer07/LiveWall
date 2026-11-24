import Foundation
import ScreenCaptureKit
import CoreMedia
import Accelerate
import CoreAudio
import AudioToolbox

/// Захват системного звука и разложение в спектр:
/// 128 значений 0…1 (64 полосы левого канала + 64 правого) — как в Wallpaper Engine.
/// macOS 14.2+: аудиотап Core Audio (разрешение «Только запись системного звука», не слетает после обновлений).
/// Старее: ScreenCaptureKit (разрешение «Запись экрана и системного звука»).
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "livewall.audio", qos: .userInteractive)
    private var handler: (([Float]) -> Void)?

    private let n = 1024
    private let log2n: vDSP_Length = 10
    private var fft: FFTSetup?
    private var window: [Float]
    private var bufL: [Float] = []
    private var bufR: [Float] = []
    private var smoothed = [Float](repeating: 0, count: 128)
    private var lastEmit: CFAbsoluteTime = 0
    private var sampleRate: Double = 48000

    var isRunning: Bool { stream != nil || aggID != 0 }
    /// Работает ли захват через аудиотап (без «Записи экрана»).
    private(set) var usingTap = false

    // Аудиотап Core Audio
    private var tapID = AudioObjectID(0)
    private var aggID = AudioObjectID(0)
    private var procID: AudioDeviceIOProcID?

    override init() {
        window = [Float](repeating: 0, count: 1024)
        vDSP_hann_window(&window, vDSP_Length(1024), Int32(vDSP_HANN_NORM))
        fft = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))
        super.init()
    }

    deinit { if let fft { vDSP_destroy_fftsetup(fft) } }

    static var tapSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    func start(handler: @escaping ([Float]) -> Void) async throws {
        self.handler = handler
        if isRunning { return }
        if #available(macOS 14.2, *) {
            do { try startTap(); usingTap = true; return } catch {
                stopTap()   // переходим на ScreenCaptureKit
            }
        }
        usingTap = false
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw LWError(tr("Нет дисплея для захвата звука")) }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.showsCursor = false
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() {
        let s = stream
        stream = nil
        handler = nil
        if let s { Task { try? await s.stopCapture() } }
        stopTap()
    }

    // MARK: Аудиотап Core Audio (macOS 14.2+)

    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pidVar = pid
        var obj = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                             UInt32(MemoryLayout<pid_t>.size), &pidVar, &size, &obj)
        return err == noErr && obj != 0 ? obj : nil
    }

    @available(macOS 14.2, *)
    private func startTap() throws {
        // Не слушаем звук самого LiveWall (видео-обои)
        let excluded = Self.processObject(pid: getpid()).map { [$0] } ?? []
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(0)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr, tap != 0 else { throw LWError("tap \(err)") }
        tapID = tap

        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LiveWall Audio Tap",
            kAudioAggregateDeviceUIDKey: "com.local.livewall.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        var device = AudioObjectID(0)
        err = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &device)
        guard err == noErr, device != 0 else { throw LWError("aggregate \(err)") }
        aggID = device

        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &fmt) == noErr, fmt.mSampleRate > 0 {
            sampleRate = fmt.mSampleRate
        }
        let isFloat = fmt.mFormatFlags & kAudioFormatFlagIsFloat != 0 || fmt.mFormatID == 0
        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [weak self] _, inData, _, _, _ in
            guard let self, isFloat else { return }
            self.ingest(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData)))
            self.process()
        }
        guard err == noErr, let proc else { throw LWError("ioproc \(err)") }
        procID = proc
        err = AudioDeviceStart(device, proc)
        guard err == noErr else { throw LWError("start \(err)") }
    }

    private func stopTap() {
        if aggID != 0, let p = procID {
            AudioDeviceStop(aggID, p)
            AudioDeviceDestroyIOProcID(aggID, p)
        }
        procID = nil
        if aggID != 0 { AudioHardwareDestroyAggregateDevice(aggID); aggID = 0 }
        if tapID != 0 {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = 0
        }
        usingTap = false
    }

    /// Раскладывает буферы по каналам (раздельные или чередующиеся).
    private func ingest(_ abl: UnsafeMutableAudioBufferListPointer) {
        if abl.count >= 2 {
            append(abl[0], to: &bufL)
            append(abl[1], to: &bufR)
        } else if abl.count == 1 {
            let b = abl[0]
            guard let data = b.mData else { return }
            let ch = max(1, Int(b.mNumberChannels))
            let total = Int(b.mDataByteSize) / MemoryLayout<Float>.size
            let p = data.assumingMemoryBound(to: Float.self)
            var i = 0
            while i + ch - 1 < total {
                bufL.append(p[i]); bufR.append(ch > 1 ? p[i + 1] : p[i]); i += ch
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid else { return }
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }
        sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000
        try? sb.withAudioBufferList { abl, _ in ingest(abl) }
        process()
    }

    private func append(_ b: AudioBuffer, to arr: inout [Float]) {
        guard let data = b.mData else { return }
        let count = Int(b.mDataByteSize) / MemoryLayout<Float>.size
        arr.append(contentsOf: UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
    }

    private func process() {
        if bufL.count > n * 8 { bufL.removeFirst(bufL.count - n * 2); bufR.removeFirst(max(0, bufR.count - n * 2)) }
        var produced = false
        while bufL.count >= n && bufR.count >= n {
            let l = bands(Array(bufL[0..<n]))
            let r = bands(Array(bufR[0..<n]))
            bufL.removeFirst(n); bufR.removeFirst(n)
            let raw = l + r
            for i in 0..<128 {
                let o = smoothed[i], v = raw[i]
                smoothed[i] = v > o ? o + (v - o) * 0.7 : o * 0.82 + v * 0.18
            }
            produced = true
        }
        let now = CFAbsoluteTimeGetCurrent()
        if produced, now - lastEmit >= 1.0 / 30.0, let h = handler {
            lastEmit = now
            let out = smoothed
            DispatchQueue.main.async { h(out) }
        }
    }

    private func bands(_ samples: [Float]) -> [Float] {
        guard let fft else { return [Float](repeating: 0, count: 64) }
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        let half = n / 2
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                mags.withUnsafeMutableBufferPointer { mp in
                    vDSP_zvabs(&split, 1, mp.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }
        let binHz = sampleRate / Double(n)
        var out = [Float](repeating: 0, count: 64)
        for i in 0..<64 {
            let f0 = 40 * pow(400.0, Double(i) / 64), f1 = 40 * pow(400.0, Double(i + 1) / 64)
            var lo = Int(f0 / binHz), hi = Int(f1 / binHz)
            lo = max(1, min(lo, half - 1)); hi = max(lo + 1, min(hi, half))
            var m: Float = 0
            for b in lo..<hi { m = max(m, mags[b]) }
            let db = 20 * log10(m / Float(n) + 1e-9)
            let v = (db + 72) / 56 + Float(i) / 64 * 0.12
            out[i] = min(1, max(0, v))
        }
        return out
    }
}
