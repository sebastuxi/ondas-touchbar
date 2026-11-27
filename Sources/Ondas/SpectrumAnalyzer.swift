import Foundation
import CoreAudio
import Accelerate

/// Lo que se oye en este instante.
struct AudioSnapshot {
    /// 20 bandas de graves a agudos (0…1).
    let bands: [Float]
    /// Lo fuerte que suena respecto a lo que lleva la canción (0…1).
    let loudness: Float
    /// Golpe (subida brusca del sonido) en este instante (0…1).
    let onset: Float
    /// Golpe de bombo (solo graves) en este instante (0…1): separa la batería del piano o la guitarra.
    let kick: Float
    /// Cuánto suena cada una de las 12 notas (do, do#, re…) en los últimos segundos; suman 1.
    /// Sirve para saber si la canción está en mayor (alegre) o en menor (triste).
    let chroma: [Float]
    let hasSound: Bool
}

/// Escucha el audio de Spotify con un "process tap" de Core Audio (macOS 14.2+)
/// y lo convierte en bandas de frecuencia, volumen y golpes. No graba ni guarda nada.
final class SpectrumAnalyzer {
    static let bandCount = 20

    private(set) var isRunning = false
    private(set) var lastError: String?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.ondas.touchbar.audio", qos: .userInteractive)
    private let lock = NSLock()

    // Compartido con la interfaz (protegido por `lock`).
    private var sharedBands = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var sharedLoudness: Float = 0
    private var sharedOnset: Float = 0
    private var sharedKick: Float = 0
    private var sharedChroma = [Float](repeating: 1.0 / 12, count: 12)
    private var lastSoundTime: TimeInterval = 0

    // Solo se usa dentro de `queue`.
    private let fftSize = 2048
    private let log2n = vDSP_Length(11)
    private var fftSetup: FFTSetup?
    private var window: [Float]
    private var ring: [Float]
    private var ringIndex = 0
    private var pendingSamples = 0
    private var sampleRate: Float = 48_000
    private var smoothed = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var previousTargets = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var peakDB: Float = -20
    private var fluxMean: Float = 0
    private var fluxDeviation: Float = 0.05
    /// Graves (40–120 Hz) en dB: el de ahora, el anterior y su media de ~0.5 s, para reconocer el bombo.
    private var previousLowDB: Float = -120
    private var lowAverageDB: Float = -120
    private var chroma = [Float](repeating: 1.0 / 12, count: 12)
    /// Qué nota le toca a cada trozo del espectro (220–4200 Hz, solo los que caen cerca de una nota).
    private var chromaBins: [(index: Int, pitchClass: Int)] = []
    private var chromaRate: Float = 0
    private var loudPeakDB: Float = -30
    private var loudness: Float = 0

    init() {
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        ring = [Float](repeating: 0, count: fftSize)
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    deinit {
        stop()
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    /// Lo que se oye ahora y si de verdad está llegando sonido.
    func snapshot() -> AudioSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return AudioSnapshot(bands: sharedBands, loudness: sharedLoudness, onset: sharedOnset,
                             kick: sharedKick, chroma: sharedChroma,
                             hasSound: ProcessInfo.processInfo.systemUptime - lastSoundTime < 1.2)
    }

    @discardableResult
    func start() -> Bool {
        stop()
        let processes = spotifyAudioProcesses()
        guard !processes.isEmpty else {
            lastError = "Spotify todavía no ha sonado"
            return false
        }

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "Ondas"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else {
            lastError = "No se pudo escuchar a Spotify (\(status))"
            return false
        }
        tapID = tap

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr, format.mSampleRate > 0 {
            sampleRate = Float(format.mSampleRate)
        }

        guard let outputUID = Self.defaultOutputDeviceUID() else {
            lastError = "No hay salida de audio"
            stop()
            return false
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Ondas",
            kAudioAggregateDeviceUIDKey: "com.ondas.touchbar.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]]
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else {
            lastError = "No se pudo preparar el audio (\(status))"
            stop()
            return false
        }
        aggregateID = device

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, inputData, _, _, _ in
            self?.consume(inputData)
        }
        guard status == noErr else {
            lastError = "No se pudo leer el audio (\(status))"
            stop()
            return false
        }
        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            lastError = "No se pudo arrancar el audio (\(status))"
            stop()
            return false
        }
        isRunning = true
        lastError = nil
        return true
    }

    func stop() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        isRunning = false
    }

    // MARK: - Audio → espectro

    private func consume(_ inputData: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let first = buffers.first, let raw0 = first.mData, first.mDataByteSize > 0 else { return }
        let channels = max(1, Int(first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        guard frames > 0 else { return }
        let left = raw0.assumingMemoryBound(to: Float.self)
        var right: UnsafeMutablePointer<Float>?
        if channels == 1, buffers.count > 1, let raw1 = buffers[1].mData {
            right = raw1.assumingMemoryBound(to: Float.self)
        }
        let mask = fftSize - 1
        for f in 0..<frames {
            let sample: Float
            if channels >= 2 {
                sample = 0.5 * (left[f * channels] + left[f * channels + 1])
            } else if let right {
                sample = 0.5 * (left[f] + right[f])
            } else {
                sample = left[f]
            }
            ring[ringIndex] = sample
            ringIndex = (ringIndex + 1) & mask
        }
        pendingSamples += frames
        if pendingSamples >= fftSize / 2 {   // ~47 análisis por segundo a 48 kHz
            pendingSamples = 0
            analyze()
        }
    }

    private func analyze() {
        guard let fftSetup else { return }
        let n = fftSize, half = n / 2, mask = n - 1
        var frame = [Float](repeating: 0, count: n)
        for i in 0..<n { frame[i] = ring[(ringIndex + i) & mask] }

        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(n))
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(n))

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                windowed.withUnsafeBytes { bytes in
                    let complex = bytes.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(complex.baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }

        let binHz = sampleRate / Float(n)
        var levels = [Float](repeating: -160, count: Self.bandCount)
        var loudest: Float = -160
        for band in 0..<Self.bandCount {
            let low = Self.edge(band), high = Self.edge(band + 1)
            let i0 = max(1, min(half - 1, Int(low / binHz)))
            let i1 = max(i0 + 1, min(half, Int(high / binHz)))
            var sum: Float = 0
            for i in i0..<i1 { sum += power[i] }
            var db = 10 * log10f(sum / Float(i1 - i0) + 1e-12)
            let center = sqrtf(low * high)
            if center > 200 { db += 3 * log2f(center / 200) }   // los agudos traen menos energía
            levels[band] = db
            loudest = max(loudest, db)
        }

        // Ganancia automática: la banda más fuerte reciente marca el techo, 45 dB debajo el suelo.
        peakDB = max(loudest, peakDB - 0.3)
        let range: Float = 45
        var flux: Float = 0
        for band in 0..<Self.bandCount {
            let value = max(0, min(1, (levels[band] - (peakDB - range)) / range))
            let target = powf(value, 1.5)
            // Golpes: cuánto sube cada banda de repente (los graves pesan más).
            let rise = target - previousTargets[band]
            if rise > 0 { flux += rise * (band < 6 ? 1.6 : 1) }
            previousTargets[band] = target
            let k: Float = target > smoothed[band] ? 0.55 : 0.16
            smoothed[band] += (target - smoothed[band]) * k
        }
        // Un golpe es una subida claramente mayor que lo normal en este tramo de la canción.
        fluxMean += (flux - fluxMean) * 0.04
        fluxDeviation += (abs(flux - fluxMean) - fluxDeviation) * 0.04
        let onset = max(0, min(1, (flux - fluxMean) / (fluxDeviation * 2.5 + 0.02)))
        // Bombo, en valores absolutos: los graves (40–120 Hz) suben de golpe (en ~20 ms) muy por encima de lo
        // normal. Una nota de bajo sube suave y poco; un bombo, de golpe y mucho. Y no cuenta si casi no hay graves.
        let lowFrom = max(1, Int(40 / binHz)), lowTo = max(lowFrom + 1, min(half, Int(120 / binHz) + 1))
        var lowPower: Float = 0
        for i in lowFrom..<lowTo { lowPower += power[i] }
        let lowDB = 10 * log10f(lowPower / Float(lowTo - lowFrom) + 1e-12)
        let lowRise = lowDB - previousLowDB
        let lowSpike = lowDB - lowAverageDB
        previousLowDB = lowDB
        lowAverageDB += (lowDB - lowAverageDB) * 0.05
        let audibleLow = lowDB > peakDB - 40
        let kick: Float = audibleLow && lowRise > 4 && lowSpike > 7 ? min(1, 0.55 + (lowSpike - 7) / 10) : 0

        // Notas: cuánta energía cae en cada una de las 12 (para saber si suena en mayor o en menor).
        if chromaRate != sampleRate { buildChromaBins() }
        if rms > 0.0005 {
            var pitch = [Float](repeating: 0, count: 12)
            for bin in chromaBins { pitch[bin.pitchClass] += sqrtf(power[bin.index]) }
            let total = pitch.reduce(0, +)
            if total > 0 {
                for note in 0..<12 { chroma[note] += (pitch[note] / total - chroma[note]) * 0.05 }
            }
        }

        // Volumen: sube en lo fuerte (estribillos), baja en lo suave, respecto a lo que lleva la canción.
        let rmsDB = 20 * log10f(rms + 1e-9)
        loudPeakDB = max(rmsDB, loudPeakDB - 0.04)
        let loud = max(0, min(1, (rmsDB - (loudPeakDB - 24)) / 24))
        loudness += (loud - loudness) * (loud > loudness ? 0.4 : 0.06)

        let hasSound = rms > 0.0005
        lock.lock()
        sharedBands = smoothed
        sharedLoudness = hasSound ? loudness : 0
        sharedOnset = hasSound ? onset : 0
        sharedKick = hasSound ? kick : 0
        sharedChroma = chroma
        if hasSound { lastSoundTime = ProcessInfo.processInfo.systemUptime }
        lock.unlock()
    }

    /// A cada trozo del espectro entre 220 y 4200 Hz le toca una nota; los que caen entre dos notas no cuentan.
    private func buildChromaBins() {
        chromaRate = sampleRate
        let binHz = sampleRate / Float(fftSize)
        chromaBins = (1..<fftSize / 2).compactMap { index -> (index: Int, pitchClass: Int)? in
            let frequency = Float(index) * binHz
            guard frequency >= 220, frequency <= 4200 else { return nil }
            let midi = 69 + 12 * log2f(frequency / 440)
            let nearest = midi.rounded()
            guard abs(midi - nearest) < 0.35 else { return nil }
            return (index, (Int(nearest) % 12 + 12) % 12)
        }
    }

    private static func edge(_ index: Int) -> Float {
        45 * powf(16_000 / 45, Float(index) / Float(bandCount))
    }

    // MARK: - Dispositivos

    private func spotifyAudioProcesses() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { (Self.string(of: $0, kAudioProcessPropertyBundleID) ?? "").hasPrefix(SpotifyClient.bundleID) }
    }

    private static func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return string(of: device, kAudioDevicePropertyDeviceUID)
    }

    private static func string(of object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
