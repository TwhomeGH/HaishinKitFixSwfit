import PackagePlugin

// Generates `kHaishinKitRevision` from the checkout's git HEAD at build time, so
// runtime logs always report the commit actually compiled. Attached to the
// HaishinKit target in Package.swift.
@main
struct HaishinKitRevisionPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let tool = try context.tool(named: "RevisionTool")
        let outputDirectory = context.pluginWorkDirectoryURL
        let outputFile = outputDirectory.appendingPathComponent("HaishinKitRevision.swift")
        return [
            .prebuildCommand(
                displayName: "Generate kHaishinKitRevision (\(target.name))",
                executable: tool.url,
                arguments: [context.package.directoryURL.path, outputFile.path],
                outputFilesDirectory: outputDirectory
            )
        ]
    }
}
