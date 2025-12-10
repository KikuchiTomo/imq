import ArgumentParser
import Foundation

/// Version Command
/// Shows version information
struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Show version information"
    )

    func run() throws {
        print("IMQ (Immediate Merge Queue)")
        print("Version: 1.0.0")
        print("Build: \(buildInfo)")
        print()
        print("Swift Version: \(swiftVersion)")
        print("Platform: \(platform)")
    }

    private var buildInfo: String {
        // TODO: Get from build system
        return "dev"
    }

    private var swiftVersion: String {
        #if swift(>=5.9)
        return "5.9+"
        #else
        return "Unknown"
        #endif
    }

    private var platform: String {
        #if os(macOS)
        return "macOS"
        #elseif os(Linux)
        return "Linux"
        #else
        return "Unknown"
        #endif
    }
}
