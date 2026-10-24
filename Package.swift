// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "SwiftCircularBuffer",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .visionOS(.v2),
        .watchOS(.v11),
    ],
    products: [
        .library(
            name: "SwiftCircularBuffer",
            targets: ["SwiftCircularBuffer"]
        )
    ],
    targets: [
        .target(name: "SwiftCircularBuffer"),
        .testTarget(
            name: "SwiftCircularBufferTests",
            dependencies: ["SwiftCircularBuffer"]
        ),
    ]
)

// Hold the package's own code to a clean diagnostic record. Packages that depend
// on this one are unaffected.
for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + [.treatAllWarnings(as: .error)]
}
