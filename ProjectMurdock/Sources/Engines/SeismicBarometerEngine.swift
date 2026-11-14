import Foundation
import CoreMotion
import Combine

public final class SeismicBarometerEngine: ObservableObject {
    
    // MARK: - Published Telemetry
    @Published public var currentPressureHPa: Double = 1013.25
    @Published public var pressureDelta1_2s: Double = 0.0
    @Published public var isDoorBreachAlert: Bool = false
    @Published public var breachAlertMessage: String = ""
    
    // Seismic 100 Hz Waveform (200 samples = 2 seconds of micro-vibrations)
    @Published public var seismicWaveform: [Float] = [Float](repeating: 0.0, count: 200)
    @Published public var peakVibrationMicroG: Float = 0.0
    @Published public var seismicEnergy: Float = 0.0
    
    // MARK: - CoreMotion Managers
    private let motionManager = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let motionQueue = OperationQueue()
    private let altimeterQueue = OperationQueue()
    
    // High-pass filter state (removes constant 1.0G gravity)
    private var lastAccX: Double = 0.0
    private var lastAccY: Double = 0.0
    private var lastAccZ: Double = 0.0
    private var hpAccX: Double = 0.0
    private var hpAccY: Double = 0.0
    private var hpAccZ: Double = 0.0
    private let alphaHP: Double = 0.95 // Cutoff ~0.8 Hz at 100 Hz sample rate
    
    // Barometer sliding window for derivative calculation
    private struct PressureRecord {
        let timestamp: CFAbsoluteTime
        let pressureHPa: Double
    }
    private var pressureHistory: [PressureRecord] = []
    private var alertResetWorkItem: DispatchWorkItem?
    
    public init() {
        motionQueue.name = "com.murdock.seismic.motion"
        motionQueue.maxConcurrentOperationCount = 1
        altimeterQueue.name = "com.murdock.seismic.altimeter"
        altimeterQueue.maxConcurrentOperationCount = 1
    }
    
    deinit {
        stop()
    }
    
    // MARK: - Lifecycle
    public func start() {
        start100HzSeismograph()
        startIntrusionBarometer()
    }
    
    public func stop() {
        if motionManager.isAccelerometerActive {
            motionManager.stopAccelerometerUpdates()
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.stopRelativeAltitudeUpdates()
        }
        alertResetWorkItem?.cancel()
    }
    
    // MARK: - 100 Hz Structural Seismograph
    private func start100HzSeismograph() {
        guard motionManager.isAccelerometerAvailable else {
            print("[Seismic] Accelerometer hardware unavailable.")
            return
        }
        
        motionManager.accelerometerUpdateInterval = 1.0 / 100.0 // 100 Hz
        motionManager.startAccelerometerUpdates(to: motionQueue) { [weak self] data, error in
            guard let self = self, let acc = data?.acceleration else { return }
            
            // IIR High-pass filter: y[n] = alpha * (y[n-1] + x[n] - x[n-1])
            self.hpAccX = self.alphaHP * (self.hpAccX + acc.x - self.lastAccX)
            self.hpAccY = self.alphaHP * (self.hpAccY + acc.y - self.lastAccY)
            self.hpAccZ = self.alphaHP * (self.hpAccZ + acc.z - self.lastAccZ)
            
            self.lastAccX = acc.x
            self.lastAccY = acc.y
            self.lastAccZ = acc.z
            
            // Calculate total seismic micro-vibration magnitude (in Gs)
            let magG = sqrt(self.hpAccX * self.hpAccX + self.hpAccY * self.hpAccY + self.hpAccZ * self.hpAccZ)
            let microG = Float(magG * 1_000_000.0) // Convert to micro-G
            
            DispatchQueue.main.async {
                // Update 200-sample circular oscilloscope buffer
                if self.seismicWaveform.count >= 200 {
                    self.seismicWaveform.removeFirst()
                }
                self.seismicWaveform.append(Float(self.hpAccZ * 1_000_000.0)) // Z-axis represents floor/table surface
                
                self.peakVibrationMicroG = max(self.peakVibrationMicroG * 0.95, microG)
                self.seismicEnergy = (self.seismicEnergy * 0.9) + (microG * 0.1)
            }
        }
    }
    
    // MARK: - Intrusion Barometer (Door/Window Draft Detector)
    private func startIntrusionBarometer() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            print("[Barometer] Relative altitude/barometer unavailable on this device.")
            return
        }
        
        altimeter.startRelativeAltitudeUpdates(to: altimeterQueue) { [weak self] data, error in
            guard let self = self, let altitudeData = data else { return }
            
            // Pressure is reported in kilopascals (kPa). Convert to hectopascals (hPa).
            // 1 kPa = 10 hPa.
            let pressureHPa = altitudeData.pressure.doubleValue * 10.0
            let now = CFAbsoluteTimeGetCurrent()
            
            self.pressureHistory.append(PressureRecord(timestamp: now, pressureHPa: pressureHPa))
            
            // Keep records within 1.5 seconds window
            self.pressureHistory.removeAll { (now - $0.timestamp) > 1.5 }
            
            // Calculate 1.2-second derivative
            guard let oldest = self.pressureHistory.first(where: { (now - $0.timestamp) >= 1.0 }) ?? self.pressureHistory.first else {
                return
            }
            
            let deltaP = pressureHPa - oldest.pressureHPa
            let ratePerSec = deltaP / max(now - oldest.timestamp, 0.1)
            
            // Intrusion Threshold: > 0.03 hPa variation within 1.2s indicates room volume pressure shock
            let isBreach = abs(deltaP) >= 0.03
            
            DispatchQueue.main.async {
                self.currentPressureHPa = pressureHPa
                self.pressureDelta1_2s = deltaP
                
                if isBreach {
                    self.isDoorBreachAlert = true
                    let sign = deltaP > 0 ? "+" : "-"
                    self.breachAlertMessage = "¡VARIACIÓN BAROMÉTRICA (\(sign)\(String(format: "%.3f", abs(deltaP))) hPa): PUERTA O VENTANA ABIERTA EN EL EDIFICIO!"
                    
                    // Keep alert on HUD for 4.0 seconds
                    self.alertResetWorkItem?.cancel()
                    let resetItem = DispatchWorkItem { [weak self] in
                        self?.isDoorBreachAlert = false
                        self?.breachAlertMessage = ""
                    }
                    self.alertResetWorkItem = resetItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: resetItem)
                }
            }
        }
    }
}
