import ArgumentParser
import Foundation

/// Status Command
/// Shows overall IMQ status
struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show overall IMQ status"
    )

    @Flag(name: .shortAndLong, help: "Show detailed status")
    var verbose: Bool = false

    func run() async throws {
        print("IMQ Status")
        print("==========")
        print()

        // TODO: Implement via API client
        print("Daemon: Not running")
        print("API Server: N/A")
        print("GitHub Connection: N/A")
        print("Database: N/A")
        print()
        print("Queues: 0")
        print("Total PRs in queue: 0")
        print("Processing: 0")
        print()

        if verbose {
            print("Configuration:")
            print("  GitHub Mode: N/A")
            print("  Polling Interval: N/A")
            print("  Database Path: N/A")
            print()
        }

        print("Use 'imq start' to start the daemon")
    }
}
