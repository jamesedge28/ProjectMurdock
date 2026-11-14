import Foundation
import AVFoundation
import Accelerate
import Combine

public enum DopplerMotionState: String {
    case staticTarget = "ESTÁTICO / SIN DETECCIÓN"
    case approaching = "ACERCÁNDOSE (+v)"
    case receding = "ALEJÁNDOSE (-v)"
}

public enum AcousticSeismicFootstep: String {
    case silence = "SILENCIO SÍSMICO"
    case walking = "PASOS (CAMINANDO)"
    case running = "PASOS (CORRIENDO)"
    case dragging = "ARRASTRE DE OBJETOS"
}

public final class AudioSonarAndCocktailEngine: ObservableObject {
    
    // MARK: - Published Telemetry
    @Published public var normalizedAudioEnergy: Float = 0.0
    @Published public var dopplerState: DopplerMotionState = .staticTarget
    @Published public var dopplerShiftHz: Float = 0.0
    @Published public var infrasoundEnergy: Float = 0.0
    @Published public var footstepClassification: AcousticSeismicFootstep = .silence
    @Published public var footstepIntervalMs: Double = 0.0
    @Published public var isSonarTransmitting: Bool = false
    @Published public var isCocktailZoomActive: Bool = false
    
    // MARK: - Core Audio Components
    private let audioEngine = AVAudioEngine()
    private var sourceNode19k: AVAudioSourceNode?
    private var cocktailEQ: AVAudioUnitEQ?
    
    // FFT Constants
    private let fftSize: Int = 4096
    private let sampleRate: Double = 48000.0
    private var binWidthHz: Double { sampleRate / Double(fftSize) } // ~11.71875 Hz
    
    // Accelerate FFT Setup
    private var fftSetup: FFTSetup?
    private var window: [Float]
    private var realParts: [Float]
    private var imagParts: [Float]
    private var magnitudes: [Float]
    
    // Ultrasonic Tone State (19.5 kHz)
    private var tonePhase: Float = 0.0
    private let targetUltrasonicFreq: Float = 19500.0
    
    // Infrasound Impact History
    private var lastImpactTime: CFAbsoluteTime = 0.0
    private var recentFootstepIntervals: [Double] = []
    
    public init() {
        self.window = [Float](repeating: 0.0, count: fftSize)
        self.realParts = [Float](repeating: 0.0, count: fftSize / 2)
        self.imagParts = [Float](repeating: 0.0, count: fftSize / 2)
        self.magnitudes = [Float](repeating: 0.0, count: fftSize / 2)
        
        let log2n = vDSP_Length(log2(Double(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }
    
    deinit {
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
        stop()
    }
    
    // MARK: - Lifecycle & Audio Session Setup
    public func start() {
        configureAudioSession()
        setupAudioGraph()
        
        do {
            try audioEngine.start()
            isSonarTransmitting = true
        } catch {
            print("[AudioSonar] Failed to start AVAudioEngine: \(error.localizedDescription)")
        }
    }
    
    public func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isSonarTransmitting = false
    }
    
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
            try session.setPreferredSampleRate(sampleRate)
            try session.setPreferredIOBufferDuration(Double(fftSize) / sampleRate)
            
            // Beamforming / Audio Zoom: Preferred Cardioid Polar Pattern
            if let inputs = session.availableInputs,
               let builtInMic = inputs.first(where: { $0.portType == .builtInMic }) {
                try session.setPreferredInput(builtInMic)
                if let dataSources = builtInMic.dataSources {
                    // Choose back or front microphone aligned with camera
                    if let cameraMic = dataSources.first(where: { $0.orientation == .back }) ?? dataSources.first {
                        try builtInMic.setPreferredDataSource(cameraMic)
                        if let patterns = cameraMic.supportedPolarPatterns, patterns.contains(.cardioid) {
                            try cameraMic.setPreferredPolarPattern(.cardioid)
                        }
                    }
                }
            }
            try session.setActive(true)
        } catch {
            print("[AudioSonar] AVAudioSession configuration error: \(error.localizedDescription)")
        }
    }
    
    private func setupAudioGraph() {
        let mainMixer = audioEngine.mainMixerNode
        let inputNode = audioEngine.inputNode
        let outputNode = audioEngine.outputNode
        
        // 1. Ultrasonic Tone Generator Node (19.5 kHz Sine)
        let twoPi = 2.0 * Float.pi
        let phaseIncrement = (twoPi * targetUltrasonicFreq) / Float(sampleRate)
        
        self.sourceNode19k = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self, self.isSonarTransmitting else {
                return noErr
            }
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                let sampleVal = sin(self.tonePhase) * 0.35 // Controlled amplitude for Doppler probe
                self.tonePhase += phaseIncrement
                if self.tonePhase >= twoPi { self.tonePhase -= twoPi }
                
                for buffer in ablPointer {
                    let ptr: UnsafeMutableBufferPointer<Float> = UnsafeMutableBufferPointer(buffer)
                    ptr[frame] = sampleVal
                }
            }
            return noErr
        }
        
        if let source = sourceNode19k {
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
            audioEngine.attach(source)
            audioEngine.connect(source, to: mainMixer, format: format)
        }
        
        // 2. Cocktail Party Voice Bandpass EQ (300 Hz - 3200 Hz)
        let eq = AVAudioUnitEQ(numberOfBands: 3)
        // High-pass at 300 Hz
        eq.bands[0].filterType = .highPass
        eq.bands[0].frequency = 300.0
        eq.bands[0].bypass = false
        // Low-pass at 3200 Hz
        eq.bands[1].filterType = .lowPass
        eq.bands[1].frequency = 3200.0
        eq.bands[1].bypass = false
        // Speech Presence Boost at 2000 Hz (+6 dB)
        eq.bands[2].filterType = .parametric
        eq.bands[2].frequency = 2000.0
        eq.bands[2].bandwidth = 1.0
        eq.bands[2].gain = 6.0
        eq.bands[2].bypass = false
        
        self.cocktailEQ = eq
        audioEngine.attach(eq)
        
        let inputFormat = inputNode.outputFormat(forBus: 0)
        audioEngine.connect(inputNode, to: eq, format: inputFormat)
        audioEngine.connect(eq, to: outputNode, format: inputFormat)
        
        // Set initial cocktail pass bypass based on mode
        eq.bypass = !isCocktailZoomActive
        
        // 3. Audio Tap on Input Node for 4096-sample vDSP FFT
        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize), format: inputFormat) { [weak self] buffer, _ in
            self?.processInputAudioBuffer(buffer: buffer)
        }
    }
    
    // MARK: - Cocktail Zoom Toggle
    public func setCocktailZoom(enabled: Bool) {
        self.isCocktailZoomActive = enabled
        self.cocktailEQ?.bypass = !enabled
    }
    
    public func setUltrasonicTransmit(enabled: Bool) {
        self.isSonarTransmitting = enabled
    }
    
    // MARK: - DSP Analysis (4096-point FFT at 48 kHz)
    private func processInputAudioBuffer(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0],
              let setup = self.fftSetup else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount >= fftSize else { return }
        
        // Overall RMS calculation for "Mundo en Llamas" shader
        var rms: Float = 0.0
        vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(fftSize))
        let normalizedRMS = min(max((rms - 0.005) * 12.0, 0.0), 1.0)
        
        // Apply Hanning Window
        var windowedInput = [Float](repeating: 0.0, count: fftSize)
        vDSP_vmul(channelData, 1, window, 1, &windowedInput, 1, vDSP_Length(fftSize))
        
        // Prepare Split Complex (even/odd)
        for i in 0..<(fftSize / 2) {
            realParts[i] = windowedInput[i * 2]
            imagParts[i] = windowedInput[i * 2 + 1]
        }
        
        let log2n = vDSP_Length(log2(Double(fftSize)))
        realParts.withUnsafeMutableBufferPointer { realPtr in
            imagParts.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(
                    realp: realPtr.baseAddress!,
                    imagp: imagPtr.baseAddress!
                )
                vDSP_fft_zrip(setup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
        
        // Compute Magnitudes
        realParts.withUnsafeMutableBufferPointer { realPtr in
            imagParts.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(
                    realp: realPtr.baseAddress!,
                    imagp: imagPtr.baseAddress!
                )
                vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }
        
        // A. Ultrasonic Doppler Analysis (19.5 kHz carrier)
        // Center carrier bin = round(19500 / 11.71875) = 1664
        let carrierBin = Int(round(targetUltrasonicFreq / Float(binWidthHz)))
        
        // Lower sideband: 19,350 Hz to 19,480 Hz (bins 1651 to 1662)
        let lowerStart = max(0, Int(19350.0 / binWidthHz))
        let lowerEnd = max(0, carrierBin - 2)
        
        // Upper sideband: 19,520 Hz to 19,650 Hz (bins 1666 to 1677)
        let upperStart = min(fftSize / 2 - 1, carrierBin + 2)
        let upperEnd = min(fftSize / 2 - 1, Int(19650.0 / binWidthHz))
        
        var lowerEnergy: Float = 0.0
        var upperEnergy: Float = 0.0
        var infraSum: Float = 0.0
        
        let infraStart = max(1, Int(15.0 / binWidthHz))
        let infraEnd = min(fftSize / 2 - 1, Int(80.0 / binWidthHz))
        
        magnitudes.withUnsafeBufferPointer { magPtr in
            guard let base = magPtr.baseAddress else { return }
            if lowerEnd > lowerStart {
                vDSP_sve(base + lowerStart, 1, &lowerEnergy, vDSP_Length(lowerEnd - lowerStart + 1))
            }
            if upperEnd > upperStart {
                vDSP_sve(base + upperStart, 1, &upperEnergy, vDSP_Length(upperEnd - upperStart + 1))
            }
            if infraEnd > infraStart {
                vDSP_sve(base + infraStart, 1, &infraSum, vDSP_Length(infraEnd - infraStart + 1))
            }
        }
        
        let dopplerDelta = upperEnergy - lowerEnergy
        let energyThreshold: Float = 0.08
        
        var motionState: DopplerMotionState = .staticTarget
        var shiftHz: Float = 0.0
        
        if dopplerDelta > energyThreshold {
            motionState = .approaching
            shiftHz = Float(upperEnd - carrierBin) * Float(binWidthHz) * 0.5
        } else if dopplerDelta < -energyThreshold {
            motionState = .receding
            shiftHz = -Float(carrierBin - lowerStart) * Float(binWidthHz) * 0.5
        }
        
        // B. Infrasound Acoustic Seismograph (15 Hz to 80 Hz)
        
        // Impact Impulse Detection
        let now = CFAbsoluteTimeGetCurrent()
        var currentClassification: AcousticSeismicFootstep = .silence
        var stepInterval: Double = 0.0
        
        if infraSum > 0.45 {
            let dt = (now - lastImpactTime) * 1000.0 // ms
            if dt > 200.0 && dt < 1600.0 {
                lastImpactTime = now
                recentFootstepIntervals.append(dt)
                if recentFootstepIntervals.count > 6 { recentFootstepIntervals.removeFirst() }
                
                let avgInterval = recentFootstepIntervals.reduce(0, +) / Double(recentFootstepIntervals.count)
                stepInterval = avgInterval
                
                if avgInterval >= 250.0 && avgInterval <= 420.0 {
                    currentClassification = .running
                } else if avgInterval > 420.0 && avgInterval <= 950.0 {
                    currentClassification = .walking
                } else {
                    currentClassification = .dragging
                }
            } else if dt >= 1600.0 {
                lastImpactTime = now
                currentClassification = .walking
            } else if dt <= 200.0 {
                currentClassification = .dragging
            }
        }
        
        DispatchQueue.main.async {
            self.normalizedAudioEnergy = normalizedRMS
            self.dopplerState = motionState
            self.dopplerShiftHz = shiftHz
            self.infrasoundEnergy = infraSum
            if currentClassification != .silence {
                self.footstepClassification = currentClassification
                self.footstepIntervalMs = stepInterval
            } else if (now - self.lastImpactTime) > 2.5 {
                self.footstepClassification = .silence
            }
        }
    }
}
