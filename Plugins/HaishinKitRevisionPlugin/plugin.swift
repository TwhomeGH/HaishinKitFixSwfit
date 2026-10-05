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
            // 必須用 buildCommand（不能用 prebuildCommand）：SwiftPM 不允許
            // prebuild command 執行「由原始碼建置的可執行檔」（會報
            // "a prebuild command cannot use executables built from source"）。
            // buildCommand 會在 RevisionTool 建置完成後才執行。
            .buildCommand(
                displayName: "Generate kHaishinKitRevision (\(target.name))",
                executable: tool.url,
                arguments: [context.package.directoryURL.path, outputFile.path],
                inputFiles: [],
                outputFiles: [outputFile]
            )
        ]
    }
}
