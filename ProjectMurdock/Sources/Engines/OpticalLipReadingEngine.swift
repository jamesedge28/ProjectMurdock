import Foundation
import Vision
import CoreGraphics
import CoreVideo
import Combine

public struct VisemeClassification {
    public let label: String
    public let phonemes: String
    public let confidence: Float
}

public final class OpticalLipReadingEngine: ObservableObject {
    
    // MARK: - Published Telemetry
    @Published public var isSpeaking: Bool = false
    @Published public var mouthAspectRatio: Float = 0.0
    @Published public var articulationVelocity: Float = 0.0
    @Published public var syllabicCadenceSPS: Double = 0.0
    @Published public var currentVisemeLabel: String = "[SILENCIO / REPOSO]"
    @Published public var recentVisemes: [String] = []
    
    // Lip Landmark Points (Normalized 0.0 - 1.0)
    @Published public var outerLipPoints: [CGPoint] = []
    @Published public var innerLipPoints: [CGPoint] = []
    
    // MARK: - Internal Processing State
    private let processingQueue = DispatchQueue(label: "com.murdock.lipreading", qos: .userInitiated)
    private var isBusy: Bool = false
    
    private var previousMAR: Float = 0.0
    private var previousTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    
    // Syllable peak tracking over sliding 2.5-second window
    private struct MARPeak {
        let timestamp: CFAbsoluteTime
        let value: Float
    }
    private var marHistory: [MARPeak] = []
    
    public init() {}
    
    // MARK: - Frame Input
    public func processFrame(pixelBuffer: CVPixelBuffer) {
        guard !isBusy else { return }
        isBusy = true
        
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.isBusy = false }
            
            let request = VNDetectFaceLandmarksRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            
            try? handler.perform([request])
            
            if let face = request.results?.first, let landmarks = face.landmarks {
                self.extractAndAnalyzeLips(landmarks: landmarks, faceBox: face.boundingBox)
            } else {
                DispatchQueue.main.async {
                    self.isSpeaking = false
                    self.mouthAspectRatio = 0.0
                    self.outerLipPoints = []
                    self.innerLipPoints = []
                }
            }
        }
    }
    
    // MARK: - MAR & Viseme DSP Analysis
    private func extractAndAnalyzeLips(landmarks: VNFaceLandmarks2D, faceBox: CGRect) {
        guard let outerLips = landmarks.outerLips,
              let innerLips = landmarks.innerLips else {
            return
        }
        
        let outerPts = outerLips.normalizedPoints.map { pt in
            CGPoint(
                x: faceBox.origin.x + pt.x * faceBox.width,
                y: (1.0 - (faceBox.origin.y + pt.y * faceBox.height)) // Flip Y to match UIKit
            )
        }
        
        let innerPts = innerLips.normalizedPoints.map { pt in
            CGPoint(
                x: faceBox.origin.x + pt.x * faceBox.width,
                y: (1.0 - (faceBox.origin.y + pt.y * faceBox.height))
            )
        }
        
        let now = CFAbsoluteTimeGetCurrent()
        let dt = max(Float(now - previousTime), 0.001)
        
        // Compute Mouth Aspect Ratio (MAR) using Inner & Outer landmarks
        // MAR = (||p2 - p8|| + ||p3 - p7|| + ||p4 - p6||) / (3 * ||p1 - p5||)
        let outerCount = outerLips.normalizedPoints.count
        var verticalAperture: Float = 0.0
        var horizontalWidth: Float = 0.05
        
        if outerCount >= 8 {
            let p0 = outerLips.normalizedPoints[0]
            let p4 = outerLips.normalizedPoints[outerCount / 2]
            let dx = Float(p4.x - p0.x) * Float(faceBox.width)
            let dy = Float(p4.y - p0.y) * Float(faceBox.height)
            horizontalWidth = max(sqrt(dx * dx + dy * dy), 0.001)
            
            // Vertical pairs across upper and lower lip
            let idxTopMid = outerCount / 4
            let idxBotMid = (3 * outerCount) / 4
            
            let pTop = outerLips.normalizedPoints[idxTopMid]
            let pBot = outerLips.normalizedPoints[idxBotMid]
            let vdx = Float(pTop.x - pBot.x) * Float(faceBox.width)
            let vdy = Float(pTop.y - pBot.y) * Float(faceBox.height)
            verticalAperture = sqrt(vdx * vdx + vdy * vdy)
        }
        
        let calculatedMAR = verticalAperture / horizontalWidth
        let marVelocity = abs(calculatedMAR - previousMAR) / dt
        
        previousMAR = calculatedMAR
        previousTime = now
        
        // Record MAR peak history for Syllabic Cadence
        marHistory.append(MARPeak(timestamp: now, value: calculatedMAR))
        marHistory.removeAll { (now - $0.timestamp) > 2.5 }
        
        // Detect Syllabic Peaks (inflection points where MAR opens and closes)
        var syllableCycles = 0
        if marHistory.count >= 5 {
            for i in 1..<(marHistory.count - 1) {
                let prev = marHistory[i - 1].value
                let curr = marHistory[i].value
                let next = marHistory[i + 1].value
                if curr > prev && curr > next && curr > 0.22 {
                    syllableCycles += 1
                }
            }
        }
        let historyDuration = (marHistory.last?.timestamp ?? now) - (marHistory.first?.timestamp ?? now)
        let calculatedCadence = (historyDuration > 0.5) ? Double(syllableCycles) / historyDuration : 0.0
        
        let speakingActive = marVelocity > 0.25 || (calculatedMAR > 0.20 && calculatedCadence > 1.0)
        
        // Heuristic Viseme Classifier
        let viseme = classifyViseme(mar: calculatedMAR, velocity: marVelocity, horizontalWidth: horizontalWidth)
        
        DispatchQueue.main.async {
            self.outerLipPoints = outerPts
            self.innerLipPoints = innerPts
            self.mouthAspectRatio = calculatedMAR
            self.articulationVelocity = marVelocity
            self.syllabicCadenceSPS = calculatedCadence
            self.isSpeaking = speakingActive
            self.currentVisemeLabel = viseme.label + " " + viseme.phonemes
            
            if speakingActive && (self.recentVisemes.last != viseme.phonemes) {
                self.recentVisemes.append(viseme.phonemes)
                if self.recentVisemes.count > 6 { self.recentVisemes.removeFirst() }
            }
        }
    }
    
    private func classifyViseme(mar: Float, velocity: Float, horizontalWidth: Float) -> VisemeClassification {
        if mar < 0.08 {
            return VisemeClassification(label: "[BILABIAL]", phonemes: "/m, p, b/", confidence: 0.92)
        } else if mar > 0.40 {
            return VisemeClassification(label: "[ABIERTA]", phonemes: "/a, o, ɑ/", confidence: 0.88)
        } else if mar >= 0.20 && mar <= 0.40 {
            if horizontalWidth < 0.08 {
                return VisemeClassification(label: "[REDONDEADA]", phonemes: "/u, w, oʊ/", confidence: 0.84)
            } else {
                return VisemeClassification(label: "[MEDIA]", phonemes: "/e, ɛ, ʌ/", confidence: 0.80)
            }
        } else if mar >= 0.08 && mar < 0.20 {
            if velocity > 0.3 {
                return VisemeClassification(label: "[DENTAL]", phonemes: "/f, v, θ/", confidence: 0.78)
            } else {
                return VisemeClassification(label: "[ESTIRADA]", phonemes: "/i, ɪ, j/", confidence: 0.82)
            }
        } else {
            return VisemeClassification(label: "[REPOSO]", phonemes: "—", confidence: 0.95)
        }
    }
}
