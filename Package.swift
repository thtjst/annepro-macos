// swift-tools-version: 6.0
import PackageDescription

// Command-line tools that use CoreBluetooth must carry an Info.plist with a
// Bluetooth usage description, otherwise macOS kills them on first use.
let cliInfoPlist = Context.packageDirectory + "/Resources/anne-Info.plist"

let package = Package(
    name: "AnnePro",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AnneProKit", targets: ["AnneProKit"]),
        .library(name: "AnneProBluetooth", targets: ["AnneProBluetooth"]),
        .executable(name: "anne", targets: ["anne"]),
        .executable(name: "AnnePro", targets: ["AnneProApp"]),
    ],
    targets: [
        // Pure protocol: packets, checksums, key map, lighting and layout data. No I/O.
        .target(name: "AnneProKit"),

        // CoreBluetooth connection to the keyboard.
        .target(name: "AnneProBluetooth", dependencies: ["AnneProKit"]),

        // `anne` command-line tool.
        .executableTarget(
            name: "anne",
            dependencies: ["AnneProKit", "AnneProBluetooth"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", cliInfoPlist]),
            ]
        ),

        // Menu bar app. Package it into AnnePro.app with scripts/build-app.sh.
        .executableTarget(name: "AnneProApp", dependencies: ["AnneProKit", "AnneProBluetooth"]),

        .testTarget(name: "AnneProKitTests", dependencies: ["AnneProKit"]),
    ]
)
