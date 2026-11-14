import Foundation
import Vision
import CoreVideo
import CoreGraphics
import Accelerate
import Combine

public struct GaitProfile {
    public var subjectID: String
    public var cadenceSPM: Double
    public var strideLengthRelative: Double
    public var shoulderOscillationDeg: Double
}

public final class BiometricAndGaitEngine: ObservableObject {
    
    // MARK: - Published Telemetry
    @Published public var currentBPM: Double = 72.0
    @Published public var stressLevelPercent: Double = 22.0
    @Published public var isPulseLocked: Bool = false
    @Published public var normalizedFacialROI: CGRect = .zero
    
    // Biomechanical Gait Tracking
    @Published public var trackedJoints: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
    @Published public var centerOfMass: CGPoint = .zero
    @Published public var kineticVectorEndpoint: CGPoint = .zero
    @Published public var cadenceSPM: Double = 0.0
    @Published public var strideLengthRelative: Double = 0.0
    @Published public var currentSubjectID: String = "SUJETO NO IDENTIFICADO"
    
    // MARK: - Internal Processing Buffers
    private let visionQueue = DispatchQueue(label: "com.murdock.biometrics", qos: .userInitiated)
    private var isProcessingFrame: Bool = false
    
    // rPPG Sliding Window
    private let windowSize: Int = 150 // ~5 seconds at 30 fps
    private var greenChannelSamples: [Float] = []
    private var sampleTimestamps: [CFAbsoluteTime] = []
    
    // Gait History for 1st & 2nd Derivatives
    private struct CoMRecord {
        let position: CGPoint
        let timestamp: CFAbsoluteTime
    }
    private var comHistory: [CoMRecord] = []
    private var ankleHistory: [(leftY: CGFloat, rightY: CGFloat, timestamp: CFAbsoluteTime)] = []
    
    // Pre-allocated Accelerate DSP buffers
    private let fftSize: Int = 256
    private var fftSetup: FFTSetup?
    
    public init() {
        let log2n = vDSP_Length(log2(Double(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }
    
    deinit {
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }
    
    // MARK: - Frame Processing Entry
    public func processFrame(pixelBuffer: CVPixelBuffer) {
        guard !isProcessingFrame else { return }
        isProcessingFrame = true
        
        visionQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.isProcessingFrame = false }
            
            let orientation: CGImagePropertyOrientation = .up
            let faceHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            let poseHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            
            // 1. Process Face & rPPG
            let faceRequest = VNDetectFaceLandmarksRequest()
            try? faceHandler.perform([faceRequest])
            
            if let faceObservation = faceRequest.results?.first {
                self.processRPPG(face: faceObservation, pixelBuffer: pixelBuffer)
            } else {
                DispatchQueue.main.async {
                    self.normalizedFacialROI = .zero
                    self.isPulseLocked = false
                }
            }
            
            // 2. Process Gait & Kinetic Anticipation
            let poseRequest = VNDetectHumanBodyPoseRequest()
            try? poseHandler.perform([poseRequest])
            
            if let poseObservation = poseRequest.results?.first {
                self.processGaitAndKinematics(pose: poseObservation)
            }
        }
    }
    
    // MARK: - rPPG Processing (vDSP FFT & Detrending)
    private func processRPPG(face: VNFaceObservation, pixelBuffer: CVPixelBuffer) {
        let faceBox = face.boundingBox
        DispatchQueue.main.async {
            self.normalizedFacialROI = faceBox
        }
        
        // Extract spatial mean of Green channel across facial region
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        
        let startX = Int(faceBox.minX * CGFloat(width))
        let endX = Int(faceBox.maxX * CGFloat(width))
        // Note: Vision coordinates have origin at bottom-left
        let startY = Int((1.0 - faceBox.maxY) * CGFloat(height))
        let endY = Int((1.0 - faceBox.minY) * CGFloat(height))
        
        var greenSum: Double = 0.0
        var pixelCount: Double = 0.0
        
        if format == kCVPixelFormatType_32BGRA {
            let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
            for y in max(0, startY)..<min(height, endY) {
                let rowStart = y * bytesPerRow
                for x in max(0, startX)..<min(width, endX) {
                    let pixelOffset = rowStart + (x * 4)
                    let green = buffer[pixelOffset + 1] // BGRA -> G is index 1
                    greenSum += Double(green)
                    pixelCount += 1.0
                }
            }
        } else {
            // Y plane fallback
            let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
            for y in max(0, startY)..<min(height, endY) {
                let rowStart = y * bytesPerRow
                for x in max(0, startX)..<min(width, endX) {
                    greenSum += Double(buffer[rowStart + x])
                    pixelCount += 1.0
                }
            }
        }
        
        guard pixelCount > 0 else { return }
        let meanGreen = Float(greenSum / pixelCount)
        
        // Append to sliding window
        greenChannelSamples.append(meanGreen)
        sampleTimestamps.append(CFAbsoluteTimeGetCurrent())
        
        if greenChannelSamples.count > windowSize {
            greenChannelSamples.removeFirst()
            sampleTimestamps.removeFirst()
        }
        
        guard greenChannelSamples.count >= windowSize else { return }
        
        // Execute Accelerate DSP pipeline
        calculateHeartRateAccelerate()
    }
    
    private func calculateHeartRateAccelerate() {
        let n = greenChannelSamples.count
        guard n >= windowSize, let setup = self.fftSetup else { return }
        
        // 1. Detrending (Mean subtraction)
        var mean: Float = 0.0
        vDSP_meanv(greenChannelSamples, 1, &mean, vDSP_Length(n))
        var negMean = -mean
        var detrended = [Float](repeating: 0.0, count: n)
        vDSP_vsadd(greenChannelSamples, 1, &negMean, &detrended, 1, vDSP_Length(n))
        
        // 2. Hanning Windowing
        var window = [Float](repeating: 0.0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var windowed = [Float](repeating: 0.0, count: n)
        vDSP_vmul(detrended, 1, window, 1, &windowed, 1, vDSP_Length(n))
        
        // 3. Zero-Pad to FFT Size (256)
        var realParts = [Float](repeating: 0.0, count: fftSize / 2)
        var imagParts = [Float](repeating: 0.0, count: fftSize / 2)
        
        for i in 0..<(fftSize / 2) {
            let idx2 = i * 2
            realParts[i] = (idx2 < n) ? windowed[idx2] : 0.0
            imagParts[i] = (idx2 + 1 < n) ? windowed[idx2 + 1] : 0.0
        }
        
        // 4. Real-to-Complex FFT via vDSP_fft_zrip
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
        
        // 5. Compute Magnitudes: sqrt(real^2 + imag^2)
        var magnitudes = [Float](repeating: 0.0, count: fftSize / 2)
        realParts.withUnsafeMutableBufferPointer { realPtr in
            imagParts.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(
                    realp: realPtr.baseAddress!,
                    imagp: imagPtr.baseAddress!
                )
                vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }
        
        // Calculate sampling frequency from timestamps
        let totalDuration = sampleTimestamps.last! - sampleTimestamps.first!
        guard totalDuration > 0.0 else { return }
        let fs = Float(n - 1) / Float(totalDuration)
        let df = fs / Float(fftSize)
        
        // 6. Find dominant peak within 0.8 Hz to 2.5 Hz (48 to 150 BPM)
        let minBin = max(1, Int(0.8 / df))
        let maxBin = min(fftSize / 2 - 2, Int(2.5 / df))
        
        var maxMag: Float = -1.0
        var bestBin: Int = minBin
        
        for k in minBin...maxBin {
            let mag = magnitudes[k]
            if mag > maxMag {
                maxMag = mag
                bestBin = k
            }
        }
        
        // Sub-bin Parabolic Interpolation for accurate frequency
        let y0 = magnitudes[max(0, bestBin - 1)]
        let y1 = magnitudes[bestBin]
        let y2 = magnitudes[min(fftSize / 2 - 1, bestBin + 1)]
        let denom = 2.0 * (2.0 * y1 - y0 - y2)
        let delta = (denom != 0.0) ? (y2 - y0) / denom : 0.0
        
        let refinedFreq = (Float(bestBin) + delta) * df
        let calculatedBPM = Double(refinedFreq * 60.0)
        
        // 7. Calculate Stress Index (spectral prominence & pulse variation)
        var totalBandEnergy: Float = 0.0
        magnitudes.withUnsafeBufferPointer { magPtr in
            if let base = magPtr.baseAddress {
                vDSP_sve(base + minBin, 1, &totalBandEnergy, vDSP_Length(maxBin - minBin + 1))
            }
        }
        let peakPurity = (totalBandEnergy > 0) ? (maxMag / totalBandEnergy) : 0.2
        let stress = min(max((1.0 - Double(peakPurity)) * 80.0 + (calculatedBPM > 85 ? (calculatedBPM - 85.0) * 0.8 : 0.0), 10.0), 98.0)
        
        DispatchQueue.main.async {
            if calculatedBPM >= 45.0 && calculatedBPM <= 165.0 {
                // Smooth BPM update
                self.currentBPM = (self.currentBPM * 0.85) + (calculatedBPM * 0.15)
                self.stressLevelPercent = (self.stressLevelPercent * 0.9) + (stress * 0.1)
                self.isPulseLocked = true
            }
        }
    }
    
    // MARK: - Gait & Kinetic Anticipation
    private func processGaitAndKinematics(pose: VNHumanBodyPoseObservation) {
        guard let recognizedPoints = try? pose.recognizedPoints(.all) else { return }
        
        var jointsDict: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
        var validPoints: [CGPoint] = []
        
        for (jointName, point) in recognizedPoints where point.confidence > 0.3 {
            // Convert to UIKit coordinate space (flip Y)
            let pointUIKit = CGPoint(x: point.location.x, y: 1.0 - point.location.y)
            jointsDict[jointName] = pointUIKit
            validPoints.append(pointUIKit)
        }
        
        guard !validPoints.isEmpty else { return }
        
        // Center of Mass (CoM) calculation: weighted average
        let comX = validPoints.map { $0.x }.reduce(0, +) / CGFloat(validPoints.count)
        let comY = validPoints.map { $0.y }.reduce(0, +) / CGFloat(validPoints.count)
        let comNow = CGPoint(x: comX, y: comY)
        let now = CFAbsoluteTimeGetCurrent()
        
        comHistory.append(CoMRecord(position: comNow, timestamp: now))
        if comHistory.count > 30 { comHistory.removeFirst() }
        
        // First & Second Derivative for 0.5s Kinetic Anticipation
        var predictedPt = comNow
        if comHistory.count >= 3 {
            let r0 = comHistory[comHistory.count - 3]
            let r1 = comHistory[comHistory.count - 2]
            let r2 = comHistory[comHistory.count - 1]
            
            let dt1 = CGFloat(r1.timestamp - r0.timestamp)
            let dt2 = CGFloat(r2.timestamp - r1.timestamp)
            
            if dt1 > 0 && dt2 > 0 {
                let vx1 = (r1.position.x - r0.position.x) / dt1
                let vy1 = (r1.position.y - r0.position.y) / dt1
                
                let vx2 = (r2.position.x - r1.position.x) / dt2
                let vy2 = (r2.position.y - r1.position.y) / dt2
                
                let ax = (vx2 - vx1) / dt2
                let ay = (vy2 - vy1) / dt2
                
                // P_pred = P_now + v*0.5 + 0.5*a*(0.5)^2
                let tPred: CGFloat = 0.5
                predictedPt = CGPoint(
                    x: comNow.x + (vx2 * tPred) + (0.5 * ax * tPred * tPred),
                    y: comNow.y + (vy2 * tPred) + (0.5 * ay * tPred * tPred)
                )
            }
        }
        
        // Biomechanical Signature (Gait cadence, stride, shoulder sway)
        var currentStride: Double = 0.0
        var currentSway: Double = 0.0
        
        if let leftAnkle = jointsDict[.leftAnkle], let rightAnkle = jointsDict[.rightAnkle] {
            let dx = leftAnkle.x - rightAnkle.x
            let dy = leftAnkle.y - rightAnkle.y
            currentStride = Double(sqrt(dx * dx + dy * dy))
            
            ankleHistory.append((leftY: leftAnkle.y, rightY: rightAnkle.y, timestamp: now))
            if ankleHistory.count > 45 { ankleHistory.removeFirst() }
        }
        
        if let leftShoulder = jointsDict[.leftShoulder], let rightShoulder = jointsDict[.rightShoulder] {
            let angleRad = atan2(rightShoulder.y - leftShoulder.y, rightShoulder.x - leftShoulder.x)
            currentSway = abs(Double(angleRad * 180.0 / .pi))
        }
        
        // Calculate Cadence (Steps per Minute) from ankle zero-crossings
        var stepCount = 0
        if ankleHistory.count >= 6 {
            for i in 1..<(ankleHistory.count - 1) {
                let diffPrev = ankleHistory[i].leftY - ankleHistory[i].rightY
                let diffNext = ankleHistory[i + 1].leftY - ankleHistory[i + 1].rightY
                if (diffPrev < 0 && diffNext >= 0) || (diffPrev > 0 && diffNext <= 0) {
                    stepCount += 1
                }
            }
        }
        let historyDuration = (ankleHistory.last?.timestamp ?? now) - (ankleHistory.first?.timestamp ?? now)
        let calcCadence = (historyDuration > 1.0) ? (Double(stepCount) / historyDuration) * 60.0 : 96.0
        
        // Subject Biomechanical Classification
        let subjectID = (calcCadence > 105.0 || currentStride > 0.4) ? "SUJETO ALFA (PESADO/RÁPIDO)" : "SUJETO BETA (LIGERO/CAUTO)"
        
        DispatchQueue.main.async {
            self.trackedJoints = jointsDict
            self.centerOfMass = comNow
            self.kineticVectorEndpoint = predictedPt
            self.cadenceSPM = (self.cadenceSPM * 0.8) + (calcCadence * 0.2)
            self.strideLengthRelative = currentStride
            self.currentSubjectID = subjectID
        }
    }
}
