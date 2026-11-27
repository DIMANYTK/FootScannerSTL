# FootScannerSTL

An experimental iOS foot scanner built around the TrueDepth camera (`AVCaptureDepthDataOutput`) to capture depth data and export a binary `.stl` mesh (`foot_scan_YYYY-MM-DD_HH-mm.stl`) with a depth range filter (5–50 cm) and a 5-second countdown timer.

## How It Was Built & Installed

- **Vibe-coded with:** Gemini (Hydrogen 4)
- **Cloud build:** Compiled as an unsigned `.ipa` via GitHub Actions on a cloud macOS runner (`macos-latest`) using `xcodebuild` / XcodeGen
- **Sideloaded via:** Sideloadly from a Windows PC (`Boris` test iPhone connected over USB)
- **Tested on:** iPhone 13 running iOS 26.5

## Current Results & Known Issues

The output is rough and needs further work in upcoming versions:

- **Extra bumps and ripples ("hills"):** Raw single-frame depth maps from TrueDepth carry sensor noise and quantization ripples, resulting in bumpy hills and uneven micro-relief across the surface.
- **Jagged edges and spikes:** Object boundaries and steep depth transitions still produce spiky fringes and stretched triangles along the edges.
- **Single-pass limitation:** Capturing a single depth frame from one angle misses side geometry and leaves noisy borders.

Smoothing, outlier/spike removal, and cleaner mesh filtering are planned for the next versions.
