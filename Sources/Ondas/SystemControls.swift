import AppKit
import AudioToolbox
import CoreAudio

/// Brillo de la pantalla y volumen del Mac. Avisa cuando cambian desde fuera (teclas, sensor de luz).
final class SystemControls {
    var onChange: (() -> Void)?

    private(set) var brightness: Float = 0.5
    private(set) var volume: Float = 0.5
    private(set) var isMuted = false
    private(set) var canChangeBrightness = false

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private var getBrightness: GetBrightness?
    private var setBrightnessFn: SetBrightness?
    private let display: CGDirectDisplayID
    private var outputDevice = AudioObjectID(kAudioObjectUnknown)
    private var brightnessTimer: Timer?
    private var volumeAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                           mScope: kAudioDevicePropertyScopeOutput,
                                                           mElement: kAudioObjectPropertyElementMain)
    private var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                         mScope: kAudioDevicePropertyScopeOutput,
                                                         mElement: kAudioObjectPropertyElementMain)
    private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.readVolume()
    }

    init() {
        display = Self.builtInDisplay()
        // El brillo de la pantalla integrada se cambia con DisplayServices (privado, sin permisos).
        if let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) {
            if let symbol = dlsym(handle, "DisplayServicesGetBrightness") {
                getBrightness = unsafeBitCast(symbol, to: GetBrightness.self)
            }
            if let symbol = dlsym(handle, "DisplayServicesSetBrightness") {
                setBrightnessFn = unsafeBitCast(symbol, to: SetBrightness.self)
            }
        }
        canChangeBrightness = getBrightness != nil && setBrightnessFn != nil
        readBrightness()
        attachToDefaultOutput()

        var defaultOutput = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultOutput, DispatchQueue.main) { [weak self] _, _ in
            self?.attachToDefaultOutput()
        }

        // El brillo también cambia con las teclas o el sensor de luz: se relee cada segundo.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.readBrightness() }
        RunLoop.main.add(timer, forMode: .common)
        brightnessTimer = timer
    }

    // MARK: - Cambios

    func setBrightness(_ value: Float) {
        guard canChangeBrightness else { return }
        brightness = max(0, min(1, value))
        _ = setBrightnessFn?(display, brightness)
        onChange?()
    }

    func setVolume(_ value: Float) {
        var level = Float32(max(0, min(1, value)))
        AudioObjectSetPropertyData(outputDevice, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &level)
        volume = level
        if isMuted && level > 0 { setMuted(false) }   // subir el volumen quita el silencio
        onChange?()
    }

    func setMuted(_ muted: Bool) {
        var flag: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(outputDevice, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &flag)
        isMuted = muted
        onChange?()
    }

    // MARK: - Lectura

    private func readBrightness() {
        guard let getBrightness else { return }
        var value: Float = 0
        if getBrightness(display, &value) == 0, abs(value - brightness) > 0.004 {
            brightness = value
            onChange?()
        }
    }

    private func readVolume() {
        var level: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(outputDevice, &volumeAddress, 0, nil, &size, &level) == noErr {
            volume = level
        }
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(outputDevice, &muteAddress, 0, nil, &size, &muted) == noErr {
            isMuted = muted != 0
        }
        onChange?()
    }

    private func attachToDefaultOutput() {
        if outputDevice != AudioObjectID(kAudioObjectUnknown) {
            AudioObjectRemovePropertyListenerBlock(outputDevice, &volumeAddress, DispatchQueue.main, deviceListener)
            AudioObjectRemovePropertyListenerBlock(outputDevice, &muteAddress, DispatchQueue.main, deviceListener)
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        outputDevice = device
        AudioObjectAddPropertyListenerBlock(outputDevice, &volumeAddress, DispatchQueue.main, deviceListener)
        AudioObjectAddPropertyListenerBlock(outputDevice, &muteAddress, DispatchQueue.main, deviceListener)
        readVolume()
    }

    private static func builtInDisplay() -> CGDirectDisplayID {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &displays, &count)
        return displays.first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }
}
