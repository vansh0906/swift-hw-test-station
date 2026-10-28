// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "hwtest",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "hwtest", targets: ["hwtest"]),
        .library(name: "HWTestKit", targets: ["HWTestKit"]),
    ],
    targets: [
        .target(name: "HWTestKit"),
        .executableTarget(name: "hwtest", dependencies: ["HWTestKit"]),
        // Self-tests as a plain program, so they run without Xcode: `swift run selftest`.
        .executableTarget(name: "selftest", dependencies: ["HWTestKit"]),
    ]
)
