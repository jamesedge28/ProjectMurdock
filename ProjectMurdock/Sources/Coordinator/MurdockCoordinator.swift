import Foundation
import Combine
import CoreVideo
import SwiftUI

public enum TacticalMode: Int, CaseIterable, Identifiable {
    case flamesOfHell = 0        // [MUNDO EN LLAMAS (ECO)]
    case lidarNocturnal = 1      // [LIDAR / IR NOCTURNO 3D]
    case underDoorScanner = 2    // [BAJO PUERTA (40X)]
    case opticalHyperTouch = 3   // [HIPER-TACTO (PAPEL/RELIEVES)]
    case sonarDoppler = 4        // [SONAR DOPPLER 19.5kHz]
    case cocktailAudioZoom = 5   // [AUDIO ZOOM (CÓCTEL + LABIOS)]
    case blindSense3D = 6        // [MODO CIEGO (AUDIO 3D + HÁPTICO)]
    
    public var id: Int { rawValue }
    
    public var title: String {
        switch self {
        case .flamesOfHell: return "MUNDO EN LLAMAS (ECO)"
        case .lidarNocturnal: return "LIDAR / IR NOCTURNO 3D"
        case .underDoorScanner: return "BAJO PUERTA (40X)"
        case .opticalHyperTouch: return "HIPER-TACTO (PAPEL/RELIEVES)"
        case .sonarDoppler: return "SONAR DOPPLER 19.5kHz"
        case .cocktailAudioZoom: return "AUDIO ZOOM (CÓCTEL + LABIOS)"
        case .blindSense3D: return "MODO CIEGO (AUDIO 3D + HÁPTICO)"
        }
    }
}

public final class MurdockCoordinator: ObservableObject {
    
    // MARK: - Subsystem Engines
    public let visionEngine: MetalVisionAndLiDAREngine
    public let biometricEngine: BiometricAndGaitEngine
    public let audioEngine: AudioSonarAndCocktailEngine
    public let lipReadingEngine: OpticalLipReadingEngine
    public let seismicEngine: SeismicBarometerEngine
    public let blindSenseEngine: BlindSense3DEngine
    
    // MARK: - Current Tactical Mode
    @Published public var currentMode: TacticalMode = .flamesOfHell {
        didSet {
            handleModeTransition(oldMode: oldValue, newMode: currentMode)
        }
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    public init() {
        self.visionEngine = MetalVisionAndLiDAREngine()
        self.biometricEngine = BiometricAndGaitEngine()
        self.audioEngine = AudioSonarAndCocktailEngine()
        self.lipReadingEngine = OpticalLipReadingEngine()
        self.seismicEngine = SeismicBarometerEngine()
        self.blindSenseEngine = BlindSense3DEngine()
        
        setupInterEngineWiring()
    }
    
    // MARK: - System Lifecycle
    public func startAllEngines() {
        visionEngine.startEngine()
        audioEngine.start()
        seismicEngine.start()
        
        handleModeTransition(oldMode: .flamesOfHell, newMode: currentMode)
    }
    
    public func stopAllEngines() {
        visionEngine.stopEngine()
        audioEngine.stop()
        seismicEngine.stop()
        blindSenseEngine.stop()
    }
    
    // MARK: - Inter-Engine Wiring
    private func setupInterEngineWiring() {
        // Wire camera & depth frame delivery to Vision, Biometric, Lip Reading, and 3D BlindSense
        visionEngine.onFrameCaptured = { [weak self] colorBuffer, depthBuffer in
            guard let self = self else { return }
            
            // Forward color buffer to Biometrics and Lip Reading
            self.biometricEngine.processFrame(pixelBuffer: colorBuffer)
            self.lipReadingEngine.processFrame(pixelBuffer: colorBuffer)
            
            // If LiDAR depth map is available, sample 5 spatial sectors for BlindSense HRTF
            if let depth = depthBuffer {
                self.sampleDepthGridForBlindSense(depthBuffer: depth)
            }
        }
        
        // Feed real-time Audio Energy to Metal shader for "Mundo en Llamas"
        audioEngine.$normalizedAudioEnergy
            .receive(on: DispatchQueue.main)
            .sink { [weak self] energy in
                self?.visionEngine.uniforms.audioEnergy = energy
            }
            .store(in: &cancellables)
        
        // Feed Facial ROI to Metal shader for 15x Eulerian skin pulse magnification
        biometricEngine.$normalizedFacialROI
            .receive(on: DispatchQueue.main)
            .sink { [weak self] roi in
                guard let self = self else { return }
                if roi != .zero {
                    self.visionEngine.uniforms.eulerianRect = SIMD4<Float>(
                        Float(roi.origin.x),
                        Float(1.0 - (roi.origin.y + roi.size.height)), // Flip Y
                        Float(roi.size.width),
                        Float(roi.size.height)
                    )
                } else {
                    self.visionEngine.uniforms.eulerianRect = .zero
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Mode Transition Controller
    private func handleModeTransition(oldMode: TacticalMode, newMode: TacticalMode) {
        // 1. Torch control for Hiper-Tacto Óptico
        if oldMode == .opticalHyperTouch && newMode != .opticalHyperTouch {
            visionEngine.setTorch(enabled: false)
        } else if newMode == .opticalHyperTouch {
            visionEngine.setTorch(enabled: true, level: 1.0)
        }
        
        // 2. Cocktail Party Zoom EQ
        if newMode == .cocktailAudioZoom {
            audioEngine.setCocktailZoom(enabled: true)
        } else {
            audioEngine.setCocktailZoom(enabled: false)
        }
        
        // 3. Sonar Doppler 19.5 kHz Transmitter
        if newMode == .sonarDoppler {
            audioEngine.setUltrasonicTransmit(enabled: true)
        }
        
        // 4. BlindSense 3D Spatial Audio & Haptics
        if newMode == .blindSense3D {
            blindSenseEngine.start()
        } else if oldMode == .blindSense3D {
            blindSenseEngine.stop()
        }
        
        // 5. Metal Shader Display Mode Assignment
        switch newMode {
        case .flamesOfHell:
            visionEngine.uniforms.displayMode = 0
        case .lidarNocturnal:
            visionEngine.uniforms.displayMode = 1
        case .underDoorScanner:
            visionEngine.uniforms.displayMode = 2
        case .opticalHyperTouch:
            visionEngine.uniforms.displayMode = 3
        case .sonarDoppler, .cocktailAudioZoom, .blindSense3D:
            // Keep reactive flame mode 0 as HUD background for acoustic/tactile modes
            visionEngine.uniforms.displayMode = 0
        }
    }
    
    // MARK: - LiDAR Spatial Sector Sampling (5 Sectors for HRTF Audio)
    private func sampleDepthGridForBlindSense(depthBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly) }
        
        guard let base = CVPixelBufferGetBaseAddress(depthBuffer) else { return }
        let width = CVPixelBufferGetWidth(depthBuffer)
        let height = CVPixelBufferGetHeight(depthBuffer)
        let floatPtr = base.assumingMemoryBound(to: Float32.self)
        
        let midY = height / 2
        let sampleColumns: [Int] = [
            width / 10,       // Far Left (-60 deg)
            (width * 3) / 10, // Center Left (-30 deg)
            width / 2,        // Center (0 deg)
            (width * 7) / 10, // Center Right (+30 deg)
            (width * 9) / 10  // Far Right (+60 deg)
        ]
        
        var sectorDistances: [Float] = []
        for col in sampleColumns {
            let idx = midY * width + col
            let rawDepth = floatPtr[idx]
            let validDepth = (rawDepth > 0.05 && !rawDepth.isNaN && !rawDepth.isInfinite) ? rawDepth : 5.0
            sectorDistances.append(validDepth)
        }
        
        blindSenseEngine.updateDepthMap(distances: sectorDistances)
    }
}
