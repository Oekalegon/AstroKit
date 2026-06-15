import ArgumentParser
import AstrophotoKit

@main
struct AP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ap",
        abstract: "Process astrophotos using AstrophotoKit pipelines.",
        version: Version.string,
        subcommands: [List.self, Inspect.self, Run.self, Headers.self]
    )
}
