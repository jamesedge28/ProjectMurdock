import SwiftUI
import Vision

public struct TacticalHUDView: View {
    
    @ObservedObject var coordinator: MurdockCoordinator
    @State private var alertBlink: Bool = false
    
    public init(coordinator: MurdockCoordinator) {
        self.coordinator = coordinator
    }
    
    public var body: some View {
        ZStack {
            // 1. Background: Metal 60 FPS View
            MetalViewRepresentable(engine: coordinator.visionEngine)
                .edgesIgnoringSafeArea(.all)
            
            // 2. Scanline & Tactical Vignette Overlay
            TacticalVignetteOverlay()
                .edgesIgnoringSafeArea(.all)
                .allowsHitTesting(false)
            
            // 3. Dynamic Center Reticle & Biomechanical Skeletons
            GeometryReader { geo in
                DynamicReticleView(
                    coordinator: coordinator,
                    screenSize: geo.size
                )
            }
            .allowsHitTesting(false)
            
            // 4. Foreground HUD Controls & Telemetry
            VStack(spacing: 8) {
                // Top Telemetry Header
                TelemetryHeaderView(coordinator: coordinator, alertBlink: alertBlink)
                    .padding(.horizontal, 12)
                    .padding(.top, 44)
                
                Spacer()
                
                // Seismic 100 Hz Oscilloscope
                SeismicOscilloscopeView(seismicEngine: coordinator.seismicEngine)
                    .frame(height: 54)
                    .padding(.horizontal, 16)
                
                // Bottom Tactical Mode Selector
                TacticalModeSelectorView(currentMode: $coordinator.currentMode)
                    .padding(.bottom, 20)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                alertBlink.toggle()
            }
        }
    }
}

// MARK: - Telemetry Header View
struct TelemetryHeaderView: View {
    @ObservedObject var coordinator: MurdockCoordinator
    let alertBlink: Bool
    
    var body: some View {
        VStack(spacing: 4) {
            // Top Bar: System ID, FPS, LiDAR Status
            HStack {
                Text("PROJECT MURDOCK // SUITE TÁCTICA")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundColor(Color(red: 1.0, green: 0.16, blue: 0.0))
                
                Spacer()
                
                HStack(spacing: 12) {
                    Text("FPS: \(Int(coordinator.visionEngine.currentFPS))")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)
                    
                    Text(coordinator.visionEngine.isLiDARAvailable ? "LiDAR: ACTIVO" : "IR: TRUE-DEPTH")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(coordinator.visionEngine.isLiDARAvailable ? .green : .yellow)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.75))
            .border(Color(red: 0.54, green: 0.0, blue: 0.0), width: 1)
            
            // Multi-Sensor Telemetry Grid
            HStack(alignment: .top, spacing: 6) {
                // Telemetry Cell 1: Biometrics rPPG
                VStack(alignment: .leading, spacing: 2) {
                    Text("POLÍGRAFO rPPG")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.red)
                    
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                        Text("\(Int(coordinator.biometricEngine.currentBPM)) BPM")
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    
                    Text("ESTRÉS: \(Int(coordinator.biometricEngine.stressLevelPercent))%")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(coordinator.biometricEngine.stressLevelPercent > 60 ? .red : .orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(Color.black.opacity(0.75))
                .border(Color.red.opacity(0.4), width: 1)
                
                // Telemetry Cell 2: Sonar Doppler 19.5 kHz
                VStack(alignment: .leading, spacing: 2) {
                    Text("SONAR 19.5 kHz")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.red)
                    
                    Text(coordinator.audioEngine.dopplerState.rawValue)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(coordinator.audioEngine.dopplerState == .approaching ? .red : (coordinator.audioEngine.dopplerState == .receding ? .orange : .gray))
                        .lineLimit(1)
                    
                    Text("Δf: \(String(format: "%.1f", coordinator.audioEngine.dopplerShiftHz)) Hz")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.yellow)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(Color.black.opacity(0.75))
                .border(Color.red.opacity(0.4), width: 1)
                
                // Telemetry Cell 3: Infrasound & Footsteps
                VStack(alignment: .leading, spacing: 2) {
                    Text("INFRASONIDO 15-80Hz")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.red)
                    
                    Text(coordinator.audioEngine.footstepClassification.rawValue)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(coordinator.audioEngine.footstepClassification == .silence ? .gray : .orange)
                        .lineLimit(1)
                    
                    Text(coordinator.audioEngine.footstepIntervalMs > 0 ? "CAD: \(Int(coordinator.audioEngine.footstepIntervalMs)) ms" : "SÍSMICO: CALMA")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.yellow)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(Color.black.opacity(0.75))
                .border(Color.red.opacity(0.4), width: 1)
            }
            
            // Telemetry Cell 4: Lip Reading & Visemes
            HStack {
                Text("LABIAL:")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.red)
                
                Text(coordinator.lipReadingEngine.isSpeaking ? "HABLANDO (CAD: \(String(format: "%.1f", coordinator.lipReadingEngine.syllabicCadenceSPS)) syl/s)" : "REPOSO")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(coordinator.lipReadingEngine.isSpeaking ? .orange : .gray)
                
                Spacer()
                
                Text(coordinator.lipReadingEngine.currentVisemeLabel)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.75))
            .border(Color.red.opacity(0.3), width: 1)
            
            // Barometer Intrusion Alert Banner
            if coordinator.seismicEngine.isDoorBreachAlert {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text(coordinator.seismicEngine.breachAlertMessage)
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.leading)
                }
                .padding(6)
                .frame(maxWidth: .infinity)
                .background(Color.red.opacity(alertBlink ? 0.9 : 0.4))
                .border(Color.yellow, width: 1)
            } else {
                HStack {
                    Text("BARÓMETRO: \(String(format: "%.2f", coordinator.seismicEngine.currentPressureHPa)) hPa")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                    Spacer()
                    Text("ESTADO: NORMAL (ΔP: \(String(format: "%+.3f", coordinator.seismicEngine.pressureDelta1_2s)) hPa)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.gray)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.6))
            }
        }
    }
}

// MARK: - Dynamic Reticle & Biomechanical Skeleton
struct DynamicReticleView: View {
    @ObservedObject var coordinator: MurdockCoordinator
    let screenSize: CGSize
    
    var body: some View {
        ZStack {
            // Central Tactical Crosshair
            Path { path in
                let midX = screenSize.width / 2
                let midY = screenSize.height / 2
                
                // Crosshair lines
                path.move(to: CGPoint(x: midX - 30, y: midY))
                path.addLine(to: CGPoint(x: midX - 8, y: midY))
                path.move(to: CGPoint(x: midX + 8, y: midY))
                path.addLine(to: CGPoint(x: midX + 30, y: midY))
                
                path.move(to: CGPoint(x: midX, y: midY - 30))
                path.addLine(to: CGPoint(x: midX, y: midY - 8))
                path.move(to: CGPoint(x: midX, y: midY + 8))
                path.addLine(to: CGPoint(x: midX, y: midY + 30))
                
                // Milliradian ticks
                for offset in [-20, -10, 10, 20] {
                    let off = CGFloat(offset)
                    path.move(to: CGPoint(x: midX + off, y: midY - 3))
                    path.addLine(to: CGPoint(x: midX + off, y: midY + 3))
                    path.move(to: CGPoint(x: midX - 3, y: midY + off))
                    path.addLine(to: CGPoint(x: midX + 3, y: midY + off))
                }
            }
            .stroke(Color.red.opacity(0.6), lineWidth: 1)
            
            // Face Bounding Box & Telemetry
            if coordinator.biometricEngine.normalizedFacialROI != .zero {
                let box = coordinator.biometricEngine.normalizedFacialROI
                let rect = CGRect(
                    x: box.origin.x * screenSize.width,
                    y: (1.0 - (box.origin.y + box.size.height)) * screenSize.height,
                    width: box.size.width * screenSize.width,
                    height: box.size.height * screenSize.height
                )
                
                Path { path in
                    // Corner brackets
                    let c: CGFloat = 12
                    path.move(to: CGPoint(x: rect.minX, y: rect.minY + c))
                    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.minX + c, y: rect.minY))
                    
                    path.move(to: CGPoint(x: rect.maxX - c, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + c))
                    
                    path.move(to: CGPoint(x: rect.minX, y: rect.maxY - c))
                    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                    path.addLine(to: CGPoint(x: rect.minX + c, y: rect.maxY))
                    
                    path.move(to: CGPoint(x: rect.maxX - c, y: rect.maxY))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - c))
                }
                .stroke(Color.red, lineWidth: 1.5)
                
                // Biometric floating badge
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(coordinator.biometricEngine.currentSubjectID)")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.red.opacity(0.85))
                    
                    Text("PULSO: \(Int(coordinator.biometricEngine.currentBPM)) BPM // MAG 15x")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)
                        .background(Color.black.opacity(0.75))
                }
                .position(x: rect.minX + 50, y: max(rect.minY - 14, 20))
            }
            
            // Biomechanical Gait Skeleton Lines
            Path { path in
                let joints = coordinator.biometricEngine.trackedJoints
                
                func pt(_ name: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
                    if let joint = joints[name] {
                        return CGPoint(x: joint.x * screenSize.width, y: joint.y * screenSize.height)
                    }
                    return nil
                }
                
                // Shoulders to Hips
                if let ls = pt(.leftShoulder), let rs = pt(.rightShoulder),
                   let lh = pt(.leftHip), let rh = pt(.rightHip) {
                    path.move(to: ls); path.addLine(to: rs)
                    path.move(to: ls); path.addLine(to: lh)
                    path.move(to: rs); path.addLine(to: rh)
                    path.move(to: lh); path.addLine(to: rh)
                }
                
                // Left Leg
                if let lh = pt(.leftHip), let lk = pt(.leftKnee), let la = pt(.leftAnkle) {
                    path.move(to: lh); path.addLine(to: lk)
                    path.move(to: lk); path.addLine(to: la)
                }
                
                // Right Leg
                if let rh = pt(.rightHip), let rk = pt(.rightKnee), let ra = pt(.rightAnkle) {
                    path.move(to: rh); path.addLine(to: rk)
                    path.move(to: rk); path.addLine(to: ra)
                }
            }
            .stroke(Color(red: 1.0, green: 0.27, blue: 0.0).opacity(0.7), lineWidth: 2)
            
            // Kinetic Anticipation Vector Arrow (0.5s Future Prediction)
            if coordinator.biometricEngine.centerOfMass != .zero && coordinator.biometricEngine.kineticVectorEndpoint != .zero {
                let start = CGPoint(
                    x: coordinator.biometricEngine.centerOfMass.x * screenSize.width,
                    y: coordinator.biometricEngine.centerOfMass.y * screenSize.height
                )
                let end = CGPoint(
                    x: coordinator.biometricEngine.kineticVectorEndpoint.x * screenSize.width,
                    y: coordinator.biometricEngine.kineticVectorEndpoint.y * screenSize.height
                )
                
                Path { path in
                    path.move(to: start)
                    path.addLine(to: end)
                }
                .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [4, 3]))
                
                // Vector head circle
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 6, height: 6)
                    .position(end)
            }
        }
    }
}

// MARK: - Seismic Oscilloscope (100 Hz Real-Time Waveform)
struct SeismicOscilloscopeView: View {
    @ObservedObject var seismicEngine: SeismicBarometerEngine
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("SISMÓGRAFO 100 Hz [MICRO-VIBRACIÓN]")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.red)
                
                Spacer()
                
                Text("PICO: \(Int(seismicEngine.peakVibrationMicroG)) µG")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.orange)
            }
            
            GeometryReader { geo in
                Path { path in
                    let samples = seismicEngine.seismicWaveform
                    guard samples.count > 1 else { return }
                    
                    let stepX = geo.size.width / CGFloat(samples.count - 1)
                    let midY = geo.size.height / 2
                    let scaleY = geo.size.height / 600.0 // +/- 300 uG range
                    
                    path.move(to: CGPoint(x: 0, y: midY - CGFloat(samples[0]) * scaleY))
                    for i in 1..<samples.count {
                        let x = CGFloat(i) * stepX
                        let y = midY - CGFloat(samples[i]) * scaleY
                        path.addLine(to: CGPoint(x: x, y: max(0, min(geo.size.height, y))))
                    }
                }
                .stroke(Color(red: 1.0, green: 0.16, blue: 0.0), lineWidth: 1.5)
            }
            .background(Color.black.opacity(0.85))
            .border(Color.red.opacity(0.4), width: 1)
        }
    }
}

// MARK: - Tactical Mode Selector View
struct TacticalModeSelectorView: View {
    @Binding var currentMode: TacticalMode
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TacticalMode.allCases) { mode in
                    Button(action: {
                        currentMode = mode
                    }) {
                        Text(mode.title)
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .foregroundColor(currentMode == mode ? .black : Color(red: 1.0, green: 0.25, blue: 0.0))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(currentMode == mode ? Color(red: 1.0, green: 0.25, blue: 0.0) : Color.black.opacity(0.8))
                            .border(Color(red: 1.0, green: 0.25, blue: 0.0), width: currentMode == mode ? 2 : 1)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

// MARK: - Tactical CRT / Scanline Vignette
struct TacticalVignetteOverlay: View {
    var body: some View {
        ZStack {
            // Dark edge vignette
            RadialGradient(
                gradient: Gradient(colors: [Color.clear, Color.black.opacity(0.6)]),
                center: .center,
                startRadius: 200,
                endRadius: 500
            )
            
            // Corner Bracket Accents
            GeometryReader { geo in
                Path { path in
                    let m: CGFloat = 16
                    let len: CGFloat = 24
                    
                    // Top-Left
                    path.move(to: CGPoint(x: m, y: m + len))
                    path.addLine(to: CGPoint(x: m, y: m))
                    path.addLine(to: CGPoint(x: m + len, y: m))
                    
                    // Top-Right
                    path.move(to: CGPoint(x: geo.size.width - m - len, y: m))
                    path.addLine(to: CGPoint(x: geo.size.width - m, y: m))
                    path.addLine(to: CGPoint(x: geo.size.width - m, y: m + len))
                    
                    // Bottom-Left
                    path.move(to: CGPoint(x: m, y: geo.size.height - m - len))
                    path.addLine(to: CGPoint(x: m, y: geo.size.height - m))
                    path.addLine(to: CGPoint(x: m + len, y: geo.size.height - m))
                    
                    // Bottom-Right
                    path.move(to: CGPoint(x: geo.size.width - m - len, y: geo.size.height - m))
                    path.addLine(to: CGPoint(x: geo.size.width - m, y: geo.size.height - m))
                    path.addLine(to: CGPoint(x: geo.size.width - m, y: geo.size.height - m - len))
                }
                .stroke(Color.red.opacity(0.5), lineWidth: 1.5)
            }
        }
    }
}
