import PackagePlugin

@main
struct VersionPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let versionFile = context.package.directory.appending("version.txt")
        let outputFile  = context.pluginWorkDirectory.appending("Version.generated.swift")
        let tool        = try context.tool(named: "version-tool")

        return [
            .buildCommand(
                displayName: "Generating Version.swift (\(target.name))",
                executable: tool.path,
                arguments: [versionFile.string, outputFile.string],
                inputFiles: [versionFile],
                outputFiles: [outputFile]
            )
        ]
    }
}
