// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SecureVault",
    platforms: [.iOS(.v16)],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
    ],
    targets: [
        .target(
            name: "SecureVault",
            dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")],
            path: ".",
            exclude: ["Tests", ".github", "project.yml", "README.md"],
            sources: ["Sources/SecureVault"],
            resources: [.process("Resources/Assets.xcassets")]
        )
    ]
)
