import AVFoundation
import Foundation
import MediaToolbox
import os

/// 5 段图示均衡器的频点与 Q（峰值滤波）。
struct AudioEQBand {
    let frequency: Double
    let q: Double
}

/// 音乐均衡器 DSP：通过 MTAudioProcessingTap 挂到 AVPlayerItem 的音轨上，对 Float32 PCM 做多段峰值（peaking）双二阶滤波。
/// 仅在用户启用 EQ 且预设非纯平时才创建并挂载——默认不挂，现有播放管线零改动、零开销。
final class AudioEQProcessor {
    static let bands: [AudioEQBand] = [
        AudioEQBand(frequency: 60, q: 0.9),
        AudioEQBand(frequency: 230, q: 0.9),
        AudioEQBand(frequency: 910, q: 0.9),
        AudioEQBand(frequency: 3600, q: 0.9),
        AudioEQBand(frequency: 14000, q: 0.9)
    ]

    /// 归一化（a0=1）后的双二阶系数。
    private struct Biquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    }

    private var lock = os_unfair_lock_s()

    private var gainsDB: [Double]
    private var coeffs: [Biquad]
    private var hasNonZeroGain = false

    private var sampleRate: Double = 44100
    private var channelCount = 0
    private var isInterleaved = false
    private var isFloat32 = false
    private var ready = false

    // 每通道每段的 TDF-II 状态（扁平存储，避免 RT 线程的嵌套数组 CoW）。
    private var z1: [Double] = []
    private var z2: [Double] = []

    init(gainsDB: [Double]) {
        let count = Self.bands.count
        self.gainsDB = Self.normalized(gainsDB, count: count)
        self.coeffs = Array(repeating: Biquad(), count: count)
        self.hasNonZeroGain = self.gainsDB.contains { abs($0) > 0.01 }
    }

    private static func normalized(_ gains: [Double], count: Int) -> [Double] {
        if gains.count == count { return gains }
        var result = gains
        if result.count > count { result = Array(result.prefix(count)) }
        else { result += Array(repeating: 0, count: count - result.count) }
        return result
    }

    /// 主线程：实时更新各段增益（dB），并重算系数。
    func updateGains(_ gains: [Double]) {
        os_unfair_lock_lock(&lock)
        gainsDB = Self.normalized(gains, count: Self.bands.count)
        hasNonZeroGain = gainsDB.contains { abs($0) > 0.01 }
        recomputeCoeffsLocked()
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - tap 生命周期（在 RT/准备线程被 C 回调调用）

    fileprivate func prepare(format: AudioStreamBasicDescription) {
        os_unfair_lock_lock(&lock)
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44100
        channelCount = Int(format.mChannelsPerFrame)
        isInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        isFloat32 = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && format.mBitsPerChannel == 32
        let stateCount = max(channelCount, 0) * Self.bands.count
        z1 = Array(repeating: 0, count: stateCount)
        z2 = Array(repeating: 0, count: stateCount)
        recomputeCoeffsLocked()
        ready = isFloat32 && channelCount > 0
        os_unfair_lock_unlock(&lock)
    }

    fileprivate func unprepare() {
        os_unfair_lock_lock(&lock)
        ready = false
        for i in z1.indices { z1[i] = 0 }
        for i in z2.indices { z2[i] = 0 }
        os_unfair_lock_unlock(&lock)
    }

    private func recomputeCoeffsLocked() {
        for (index, band) in Self.bands.enumerated() {
            coeffs[index] = Self.peakingCoeff(frequency: band.frequency, q: band.q, gainDB: gainsDB[index], sampleRate: sampleRate)
        }
    }

    /// RBJ cookbook 峰值（peaking EQ）双二阶系数。
    private static func peakingCoeff(frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> Biquad {
        let a = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Double.pi * frequency / sampleRate
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2.0 * q)

        let b0 = 1.0 + alpha * a
        let b1 = -2.0 * cosW0
        let b2 = 1.0 - alpha * a
        let a0 = 1.0 + alpha / a
        let a1 = -2.0 * cosW0
        let a2 = 1.0 - alpha / a
        guard a0 != 0 else { return Biquad() }
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    // MARK: - RT 处理

    fileprivate func process(frames: Int, bufferList: UnsafeMutablePointer<AudioBufferList>) {
        // 非阻塞：主线程正在改系数时直接跳过本缓冲（瞬时不可闻），避免读到撕裂系数。
        guard os_unfair_lock_trylock(&lock) else { return }
        defer { os_unfair_lock_unlock(&lock) }
        guard ready, hasNonZeroGain else { return }

        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        let bandCount = Self.bands.count

        if isInterleaved {
            for buffer in abl {
                guard let data = buffer.mData else { continue }
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0 else { continue }
                let pointer = data.assumingMemoryBound(to: Float.self)
                let totalSamples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let frameCount = totalSamples / channels
                for frame in 0..<frameCount {
                    for channel in 0..<channels where channel < channelCount {
                        let index = frame * channels + channel
                        pointer[index] = Float(filter(channel: channel, bandCount: bandCount, sample: Double(pointer[index])))
                    }
                }
            }
        } else {
            for (channel, buffer) in abl.enumerated() where channel < channelCount {
                guard let data = buffer.mData else { continue }
                let pointer = data.assumingMemoryBound(to: Float.self)
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                for i in 0..<count {
                    pointer[i] = Float(filter(channel: channel, bandCount: bandCount, sample: Double(pointer[i])))
                }
            }
        }
    }

    /// 单个采样串联通过该通道的各段双二阶（Transposed Direct Form II）。
    private func filter(channel: Int, bandCount: Int, sample: Double) -> Double {
        var x = sample
        let base = channel * bandCount
        for band in 0..<bandCount {
            let c = coeffs[band]
            let stateIndex = base + band
            let y = c.b0 * x + z1[stateIndex]
            z1[stateIndex] = c.b1 * x - c.a1 * y + z2[stateIndex]
            z2[stateIndex] = c.b2 * x - c.a2 * y
            x = y
        }
        return x
    }

    // MARK: - 挂载

    /// 为某个资源的音轨创建带本 EQ tap 的 AVAudioMix；无音轨或创建失败返回 nil。
    func makeAudioMix(for asset: AVAsset) -> AVAudioMix? {
        guard let track = asset.tracks(withMediaType: .audio).first else { return nil }

        let unmanaged = Unmanaged.passRetained(self)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: unmanaged.toOpaque(),
            init: eqTapInit,
            finalize: eqTapFinalize,
            prepare: eqTapPrepare,
            unprepare: eqTapUnprepare,
            process: eqTapProcess
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let createdTap = tap else {
            unmanaged.release() // tap 未创建，init 不会调用，需手动平衡 +1
            return nil
        }

        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = createdTap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}

// MARK: - MTAudioProcessingTap C 回调（顶层函数，不捕获环境，可作 C 函数指针）

private func eqTapInit(_ tap: MTAudioProcessingTap, _ clientInfo: UnsafeMutableRawPointer?, _ storageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    storageOut.pointee = clientInfo
}

private func eqTapFinalize(_ tap: MTAudioProcessingTap) {
    Unmanaged<AudioEQProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private func eqTapPrepare(_ tap: MTAudioProcessingTap, _ maxFrames: CMItemCount, _ format: UnsafePointer<AudioStreamBasicDescription>) {
    let processor = Unmanaged<AudioEQProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    processor.prepare(format: format.pointee)
}

private func eqTapUnprepare(_ tap: MTAudioProcessingTap) {
    let processor = Unmanaged<AudioEQProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    processor.unprepare()
}

private func eqTapProcess(
    _ tap: MTAudioProcessingTap,
    _ numberFrames: CMItemCount,
    _ flags: MTAudioProcessingTapFlags,
    _ bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    _ numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    var sourceFlags = MTAudioProcessingTapFlags()
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, &sourceFlags, nil, numberFramesOut)
    guard status == noErr else { return }
    let processor = Unmanaged<AudioEQProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    processor.process(frames: numberFramesOut.pointee, bufferList: bufferListInOut)
    flagsOut.pointee = sourceFlags
}
