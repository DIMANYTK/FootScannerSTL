import SwiftUI
import AVFoundation
import simd

@main
struct FootScannerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var scanner = DepthScanner()
    @State private var countdown = 0
    @State private var minDistanceMm: Float = 50   // не ближе 5 см
    @State private var maxDistanceMm: Float = 500  // не дальше 50 см
    @State private var shareURL: URL?
    @State private var statusMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let img = scanner.previewImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .rotationEffect(.degrees(90))
            } else {
                Text("Ожидание TrueDepth камеры...")
                    .foregroundColor(.white)
            }

            VStack {
                VStack(spacing: 6) {
                    HStack {
                        Text("Диапазон: \(Int(minDistanceMm / 10))–\(Int(maxDistanceMm / 10)) см")
                            .foregroundColor(.white)
                            .font(.caption.bold())
                        Spacer()
                        Text("Макс: \(Int(maxDistanceMm)) мм")
                            .foregroundColor(.white.opacity(0.85))
                            .font(.caption)
                    }
                    Slider(value: $maxDistanceMm, in: 100...500, step: 10)
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(12)
                .padding()

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption.bold())
                        .foregroundColor(.yellow)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.75))
                        .cornerRadius(8)
                }

                Spacer()

                if countdown > 0 {
                    Text("\(countdown)")
                        .font(.system(size: 80, weight: .bold))
                        .foregroundColor(.yellow)
                }

                Spacer()

                HStack(spacing: 20) {
                    Button(action: startTimer) {
                        Label("Таймер 5с", systemImage: "timer")
                            .padding()
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    Button(action: captureNow) {
                        Label("Снять STL", systemImage: "camera.metering.center.weighted")
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                }
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            scanner.minDistanceMm = minDistanceMm
            scanner.maxDistanceMm = maxDistanceMm
            scanner.start()
        }
        .onChange(of: maxDistanceMm) { newValue in
            scanner.maxDistanceMm = newValue
        }
        .sheet(item: $shareURL) { url in
            ShareSheet(items: [url])
        }
    }

    func startTimer() {
        statusMessage = nil
        countdown = 5
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if countdown > 1 {
                countdown -= 1
            } else {
                timer.invalidate()
                countdown = 0
                captureNow()
            }
        }
    }

    func captureNow() {
        scanner.minDistanceMm = minDistanceMm
        scanner.maxDistanceMm = maxDistanceMm
        if let url = scanner.exportBinarySTL(minZMm: minDistanceMm, maxZMm: maxDistanceMm) {
            statusMessage = "Сохранён: \(url.lastPathComponent)"
            shareURL = url
        } else {
            statusMessage = "Нет точек в диапазоне 5–50 см"
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

class DepthScanner: NSObject, ObservableObject, AVCaptureDepthDataOutputDelegate {
    @Published var previewImage: UIImage?
    var minDistanceMm: Float = 50
    var maxDistanceMm: Float = 500

    private let session = AVCaptureSession()
    private let output = AVCaptureDepthDataOutput()
    private let queue = DispatchQueue(label: "depth.queue")
    private var latestDepthData: AVDepthData?

    func start() {
        guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.isFilteringEnabled = true
            output.setDelegate(self, callbackQueue: queue)
        }
        session.commitConfiguration()
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection) {
        let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        self.latestDepthData = converted

        let map = converted.depthDataMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }

        let w = CVPixelBufferGetWidth(map)
        let h = CVPixelBufferGetHeight(map)
        guard let base = CVPixelBufferGetBaseAddress(map) else { return }
        let ptr = base.assumingMemoryBound(to: Float32.self)

        let minZ = max(0.05, minDistanceMm / 1000.0)
        let maxZ = max(minZ + 0.05, min(0.50, maxDistanceMm / 1000.0))
        let span = max(0.01, maxZ - minZ)

        var pixels = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let z = ptr[i]
            if z.isFinite && z >= minZ && z <= maxZ {
                let norm = UInt8(max(30, min(255, (1.0 - (z - minZ) / span) * 225.0 + 30.0)))
                pixels[i] = norm
            }
        }

        let cfData = Data(pixels) as CFData
        if let provider = CGDataProvider(data: cfData),
           let cgImg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            DispatchQueue.main.async {
                self.previewImage = UIImage(cgImage: cgImg)
            }
        }
    }

    private func smoothedDepth(ptr: UnsafePointer<Float32>, x: Int, y: Int, w: Int, h: Int, minZ: Float, maxZ: Float) -> Float? {
        var sum: Float = 0
        var count: Float = 0
        for dy in -1...1 {
            let ny = y + dy
            if ny < 0 || ny >= h { continue }
            for dx in -1...1 {
                let nx = x + dx
                if nx < 0 || nx >= w { continue }
                let z = ptr[ny * w + nx]
                if z.isFinite && z >= minZ && z <= maxZ {
                    let weight: Float = (dx == 0 && dy == 0) ? 4.0 : ((dx == 0 || dy == 0) ? 2.0 : 1.0)
                    sum += z * weight
                    count += weight
                }
            }
        }
        // Требуем минимум 5 валидных соседей из 9 — отсекает тонкие края и «волосы»
        guard count >= 7.0 else { return nil }
        return sum / count
    }

    func exportBinarySTL(minZMm: Float, maxZMm: Float) -> URL? {
        guard let depth = latestDepthData else { return nil }
        let map = depth.depthDataMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }

        let w = CVPixelBufferGetWidth(map)
        let h = CVPixelBufferGetHeight(map)
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let ptr = base.assumingMemoryBound(to: Float32.self)

        var fx: Float = 500, fy: Float = 500, cx = Float(w) / 2, cy = Float(h) / 2
        if let cal = depth.cameraCalibrationData {
            let intrinsics = cal.intrinsicMatrix
            let refSize = cal.intrinsicMatrixReferenceDimensions
            let scaleX = Float(w) / Float(refSize.width)
            let scaleY = Float(h) / Float(refSize.height)
            fx = intrinsics.columns.0.x * scaleX
            fy = intrinsics.columns.1.y * scaleY
            cx = intrinsics.columns.2.x * scaleX
            cy = intrinsics.columns.2.y * scaleY
        }

        let minZ = max(0.05, minZMm / 1000.0)
        let maxZ = max(minZ + 0.05, min(0.50, maxZMm / 1000.0))

        let step = 2
        let gw = w / step
        let gh = h / step
        var pts = [SIMD3<Float>?](repeating: nil, count: gw * gh)

        for gy in 0..<gh {
            let y = gy * step
            for gx in 0..<gw {
                let x = gx * step
                guard let z = smoothedDepth(ptr: ptr, x: x, y: y, w: w, h: h, minZ: minZ, maxZ: maxZ) else { continue }
                let X = (Float(x) - cx) * z / fx * 1000.0
                let Y = (Float(y) - cy) * z / fy * 1000.0
                let Z = z * 1000.0
                pts[gy * gw + gx] = SIMD3<Float>(X, -Y, -Z)
            }
        }

        var tris: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        let maxJumpMm: Float = 6.0   // жёсткий порог разрыва поверхности
        let maxEdgeMm: Float = 18.0  // отсекаем длинные «шлейфы» и «иголки»

        func isValidTri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Bool {
            if simd_distance(a, b) > maxEdgeMm || simd_distance(b, c) > maxEdgeMm || simd_distance(c, a) > maxEdgeMm {
                return false
            }
            if abs(a.z - b.z) > maxJumpMm || abs(b.z - c.z) > maxJumpMm || abs(c.z - a.z) > maxJumpMm {
                return false
            }
            let crossLen = simd_length(simd_cross(b - a, c - a))
            return crossLen > 0.05
        }

        for gy in 0..<(gh - 1) {
            for gx in 0..<(gw - 1) {
                guard let p00 = pts[gy * gw + gx],
                      let p10 = pts[gy * gw + gx + 1],
                      let p01 = pts[(gy + 1) * gw + gx],
                      let p11 = pts[(gy + 1) * gw + gx + 1] else { continue }

                if isValidTri(p00, p01, p10) {
                    tris.append((p00, p01, p10))
                }
                if isValidTri(p10, p01, p11) {
                    tris.append((p10, p01, p11))
                }
            }
        }

        guard !tris.isEmpty else { return nil }

        var data = Data(count: 84 + tris.count * 50)
        data.withUnsafeMutableBytes { raw in
            var count = UInt32(tris.count).littleEndian
            memcpy(raw.baseAddress! + 80, &count, 4)
            var offset = 84
            for (v1, v2, v3) in tris {
                let n = simd_normalize(simd_cross(v2 - v1, v3 - v1))
                let vals: [Float] = [n.x, n.y, n.z, v1.x, v1.y, v1.z, v2.x, v2.y, v2.z, v3.x, v3.y, v3.z]
                for val in vals {
                    var bits = val.bitPattern.littleEndian
                    memcpy(raw.baseAddress! + offset, &bits, 4)
                    offset += 4
                }
                offset += 2
            }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let stamp = formatter.string(from: Date())
        let filename = "foot_scan_\(stamp).stl"

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? data.write(to: url)
        return url
    }
}
