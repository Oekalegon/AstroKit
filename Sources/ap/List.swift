import ArgumentParser
import AstrophotoKit

extension AP {
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List available pipelines or processors."
        )

        @Flag(name: .long, help: "List processors instead of pipelines.")
        var processors = false

        func run() async throws {
            if processors {
                let ids = await ProcessorRegistry.shared.getAllIDs()
                guard !ids.isEmpty else { print("No processors registered."); return }
                print("Processors (\(ids.count)):")
                ids.forEach { print("  \($0)") }
                return
            }

            let all = PipelineRegistry.shared.getAll()
            guard !all.isEmpty else { print("No pipelines registered."); return }
            print("Pipelines (\(all.count)):")
            for p in all.values.sorted(by: { $0.id < $1.id }) {
                print("  \(p.id)")
                if let desc = p.description {
                    print("    \(desc)")
                }
            }
        }
    }
}
