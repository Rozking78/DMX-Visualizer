// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "dmx-visualizer",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // C++/Objective-C++ output engine from Switcher
        .target(
            name: "OutputEngine",
            path: "OutputEngine",
            sources: [
                "output_display.mm",
                "output_ndi.mm",
                "OutputEngineWrapper.mm"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .define("__APPLE__"),
                .unsafeFlags(["-I/Library/NDI SDK for Apple/include"])
            ],
            cxxSettings: [
                .headerSearchPath("."),
                .define("__APPLE__"),
                .unsafeFlags(["-I/Library/NDI SDK for Apple/include", "-std=c++17"])
            ],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("Cocoa"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore")
            ]
        ),
        // Main Swift executable
        .executableTarget(
            name: "dmx-visualizer",
            dependencies: ["OutputEngine"],
            swiftSettings: [
                .unsafeFlags(["-F", ".", "-parse-as-library"]),
                .interoperabilityMode(.Cxx)
            ],
            linkerSettings: [
                .unsafeFlags(["-F", ".", "-framework", "Syphon"]),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
