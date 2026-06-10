// swift-tools-version:5.9
import PackageDescription

// Self-contained, optional wake-word module. Wraps livekit/livekit-wakeword's
// Swift detector plus an `AVAudioEngine`-based `WakewordEngine` that the app can
// opt into. Everything ships inside the package: the mel + embedding frontend
// models AND the "hey_livekit" classifier are bundled resources (loaded via
// `Bundle.module`). The app works without this package; link it only to enable
// hands-free activation. See README.md for the ~6-line integration.
let package = Package(
    name: "WakeWord",
    platforms: [
        .iOS(.v16),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "WakeWord",
            targets: ["WakeWord"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
            from: "1.20.0"
        ),
    ],
    targets: [
        .target(
            name: "WakeWord",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Sources/WakeWord",
            resources: [
                .copy("Resources/melspectrogram.onnx"),
                .copy("Resources/embedding_model.onnx"),
                .copy("Resources/hey_livekit.onnx"),
            ]
        ),
    ]
)
