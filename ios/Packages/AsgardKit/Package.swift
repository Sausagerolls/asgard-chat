// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AsgardKit",
    platforms: [.iOS(.v26), .macOS(.v26), .macCatalyst(.v26), .watchOS(.v26)],
    products: [
        .library(name: "AsgardKit", targets: ["AsgardKit"]),
    ],
    targets: [
        .target(name: "AsgardKit"),
        .testTarget(name: "AsgardKitTests", dependencies: ["AsgardKit"], resources: [.copy("Fixtures")]),
    ]
)
