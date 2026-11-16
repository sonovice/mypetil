// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "mypetil",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "mypetil", targets: ["mypetil"]),
    ],
    targets: [
        // Pure layout logic: no AppKit, no Accessibility. Fully unit-testable.
        .target(name: "MypetilCore"),
        // The macOS window manager: Accessibility, event tap, overlays, sidebar.
        .executableTarget(name: "mypetil", dependencies: ["MypetilCore"]),
        .testTarget(name: "MypetilCoreTests", dependencies: ["MypetilCore"]),
    ]
)
