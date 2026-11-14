import Foundation
import AVFoundation
import CoreHaptics
import Combine

public struct SpatialSectorReading {
    public var distanceMeters: Float
    public var angleDeg: Float
    public var label: String
}

public final class BlindSense3DEngine: ObservableObject {
    
    // MARK: - Published Telemetry
    @Published public var isActive: Bool = false
    @Published public var closestObstacleDistance: Float = 5.0
    @Published public var hapticIntensityPercent: Double = 0.0
    @Published public var activeSectorLabel: String = "DESPEJADO"
    
    // 5 Spatial Sectors: Left, Center-Left, Center, Center-Right, Right
    public private(set) var sectors: [SpatialSectorReading] = [
        SpatialSectorReading(distanceMeters: 5.0, angleDeg: -60.0, label: "EXTREMO IZQUIERDA"),
        SpatialSectorReading(distanceMeters: 5.0, angleDeg: -30.0, label: "CENTRO-IZQUIERDA"),
        SpatialSectorReading(distanceMeters: 5.0, angleDeg:   0.0, label: "CENTRO"),
        SpatialSectorReading(distanceMeters: 5.0, angleDeg:  30.0, label: "CENTRO-DERECHA"),
        SpatialSectorReading(distanceMeters: 5.0, angleDeg:  60.0, label: "EXTREMO DERECHA")
    ]
    
    // MARK: - Spatial Audio Engine (HRTF .sphericalHead)
    private let spatialEngine = AVAudioEngine()
    private let environmentNode = AVAudioEnvironmentNode()
    private var sectorPlayerNodes: [AVAudioPlayerNode] = []
    private var pingBuffers: [AVAudioPCMBuffer] = []
    
    // Pulse Scheduling Timer
    private var sonificationTimer: Timer?
    private var pulseStep: Int = 0
    
    // MARK: - CoreHaptics Engine
    private var hapticEngine: CHHapticEngine?
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?
    private var isHapticsSupported: Bool = false
    
    private var isSpatialConfigured: Bool = false
    
    public init() {
        setupHaptics()
    }
    
    deinit {
        stop()
    }
    
    // MARK: - Setup Spatial Audio (AVAudioEnvironmentNode)
    private func setupSpatialAudioEnvironment() {
        environmentNode.renderingAlgorithm = .sphericalHead // HRTF Binaural Synthesis
        environmentNode.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environmentNode.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)
        
        spatialEngine.attach(environmentNode)
        spatialEngine.connect(environmentNode, to: spatialEngine.mainMixerNode, format: nil)
        
        // Generate pre-rendered short acoustic click/ping buffers at different harmonic frequencies
        let sampleRate = 44100.0
        let pingDuration = 0.035 // 35ms sharp click
        let frameCount = AVAudioFrameCount(sampleRate * pingDuration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        
        let frequencies: [Float] = [520.0, 780.0, 1040.0, 1320.0, 1760.0]
        for freq in frequencies {
            if let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) {
                pcmBuffer.frameLength = frameCount
                if let channel = pcmBuffer.floatChannelData?[0] {
                    let twoPi = 2.0 * Float.pi
                    let increment = (twoPi * freq) / Float(sampleRate)
                    var phase: Float = 0.0
                    for f in 0..<Int(frameCount) {
                        // Apply triangular envelope to prevent pop
                        let envelope = 1.0 - (Float(f) / Float(frameCount))
                        channel[f] = sin(phase) * envelope * 0.4
                        phase += increment
                    }
                }
                pingBuffers.append(pcmBuffer)
            }
        }
        
        // Setup 5 3D emitter player nodes
        let sectorPositions: [AVAudio3DPoint] = [
            AVAudio3DPoint(x: -2.0, y: 0.0, z: 1.0),
            AVAudio3DPoint(x: -0.8, y: 0.0, z: 1.5),
            AVAudio3DPoint(x:  0.0, y: 0.0, z: 2.0),
            AVAudio3DPoint(x:  0.8, y: 0.0, z: 1.5),
            AVAudio3DPoint(x:  2.0, y: 0.0, z: 1.0)
        ]
        
        for pos in sectorPositions {
            let player = AVAudioPlayerNode()
            player.renderingAlgorithm = .sphericalHead
            player.position = pos
            spatialEngine.attach(player)
            spatialEngine.connect(player, to: environmentNode, format: format)
            sectorPlayerNodes.append(player)
        }
    }
    
    // MARK: - CoreHaptics Setup
    private func setupHaptics() {
        let hapticCapabilities = CHHapticEngine.capabilitiesForHardware()
        self.isHapticsSupported = hapticCapabilities.supportsHaptics
        
        guard isHapticsSupported else { return }
        
        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            
            engine.resetHandler = { [weak self] in
                try? self?.hapticEngine?.start()
            }
            
            try engine.start()
            self.hapticEngine = engine
        } catch {
            print("[BlindSense] CoreHaptics init error: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Lifecycle Controls
    public func start() {
        guard !isActive else { return }
        isActive = true
        
        if !isSpatialConfigured {
            setupSpatialAudioEnvironment()
            isSpatialConfigured = true
        }
        
        do {
            try spatialEngine.start()
            for player in sectorPlayerNodes {
                player.play()
            }
        } catch {
            print("[BlindSense] Spatial engine start error: \(error.localizedDescription)")
        }
        
        try? hapticEngine?.start()
        
        // Sonification scheduler at 15 Hz
        sonificationTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.tickSonification()
        }
    }
    
    public func stop() {
        guard isActive else { return }
        isActive = false
        sonificationTimer?.invalidate()
        sonificationTimer = nil
        
        for player in sectorPlayerNodes {
            player.stop()
        }
        spatialEngine.stop()
        
        try? continuousPlayer?.stop(atTime: 0)
        continuousPlayer = nil
        hapticEngine?.stop()
    }
    
    // MARK: - Depth Grid Ingestion
    /// Updates the 5 spatial sectors using LiDAR or Vision depth measurements
    public func updateDepthMap(distances: [Float]) {
        guard distances.count >= 5 else { return }
        
        var minDistance: Float = 5.0
        var closestIdx: Int = 2
        
        for i in 0..<5 {
            let d = max(min(distances[i], 5.0), 0.1)
            sectors[i].distanceMeters = d
            
            // Adjust 3D emitter position dynamically in virtual room space
            if i < sectorPlayerNodes.count {
                let angleRad = Double(sectors[i].angleDeg) * .pi / 180.0
                let x = Float(sin(angleRad)) * d
                let z = Float(cos(angleRad)) * d
                sectorPlayerNodes[i].position = AVAudio3DPoint(x: x, y: 0.0, z: z)
            }
            
            if d < minDistance {
                minDistance = d
                closestIdx = i
            }
        }
        
        let label = sectors[closestIdx].label
        let hapticVal = minDistance < 1.5 ? Double(1.0 - (minDistance / 1.5)) * 100.0 : 0.0
        
        DispatchQueue.main.async {
            self.closestObstacleDistance = minDistance
            self.activeSectorLabel = "\(label) (\(String(format: "%.2f", minDistance)) m)"
            self.hapticIntensityPercent = hapticVal
        }
        
        // Trigger Proximity Haptic Pulse if obstacle < 1.5 meters
        if minDistance < 1.5 {
            triggerProximityHaptic(distanceMeters: minDistance)
        }
    }
    
    // MARK: - Dynamic Spatial Sonification Loop
    private func tickSonification() {
        pulseStep += 1
        
        for i in 0..<min(sectors.count, sectorPlayerNodes.count) {
            let dist = sectors[i].distanceMeters
            
            // Repetition interval: closer objects ping more frequently
            // d = 0.5m -> ping every 2 steps (~160ms)
            // d = 4.0m -> ping every 10 steps (~800ms)
            let stepInterval = max(2, Int(dist * 2.2))
            
            if pulseStep % stepInterval == 0 {
                let player = sectorPlayerNodes[i]
                
                // Select ping pitch: closer = higher frequency buffer
                let bufferIdx = max(0, min(pingBuffers.count - 1, Int((1.0 - (dist / 5.0)) * Float(pingBuffers.count))))
                if bufferIdx < pingBuffers.count {
                    player.scheduleBuffer(pingBuffers[bufferIdx], at: nil, options: [], completionHandler: nil)
                }
            }
        }
    }
    
    // MARK: - CoreHaptics Proximity Radar
    private func triggerProximityHaptic(distanceMeters: Float) {
        guard isHapticsSupported, let engine = hapticEngine else { return }
        
        let proximityFactor = max(0.0, min(1.0, 1.0 - (distanceMeters / 1.5)))
        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(0.3 + 0.7 * proximityFactor))
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(0.4 + 0.6 * proximityFactor))
        
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [intensity, sharpness],
            relativeTime: 0
        )
        
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            // Engine might be transiently restarting
        }
    }
}
