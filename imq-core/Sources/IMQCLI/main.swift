import ArgumentParser
import Foundation

struct IMQCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "imq",
        abstract: "Immediate Merge Queue - A local GitHub merge queue system",
        version: "1.0.0",
        subcommands: [
            StartCommand.self,
            QueueCommand.self,
            ConfigCommand.self,
            StatusCommand.self,
            VersionCommand.self
        ],
        defaultSubcommand: StatusCommand.self
    )
}

IMQCLI.main()
