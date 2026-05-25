import Foundation
import PackagePlugin

@main
struct VersionPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let versionFile  = context.package.directory.appending("version.txt")
        let outputFile   = context.pluginWorkDirectory.appending("Version.generated.swift")
        let tool         = try context.tool(named: "version-tool")

        // Track COMMIT_EDITMSG so the plugin re-runs on every new commit.
        // The file only exists after at least one local commit (not on a fresh CI clone),
        // so we add it conditionally to avoid a missing-input build error on CI.
        var inputFiles = [versionFile]
        let commitMsg = context.package.directory.appending(".git/COMMIT_EDITMSG")
        if FileManager.default.fileExists(atPath: commitMsg.string) {
            inputFiles.append(commitMsg)
        }

        return [
            .buildCommand(
                displayName: "Generating Version.swift (\(target.name))",
                executable: tool.path,
                arguments: [versionFile.string, outputFile.string],
                inputFiles: inputFiles,
                outputFiles: [outputFile]
            )
        ]
    }
}
