// ACP agent powered by Apple Foundation Models.
//
// Communicates over stdio using newline-delimited JSON-RPC (the ACP standard
// transport). Stdout is reserved exclusively for protocol messages: logging
// goes to stderr (and optionally to `--log-file`).

import ACPKit
import ArgumentParser
import Foundation

@main
struct fmagent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fmagent",
        abstract: "ACP agent backed by Apple Foundation Models.")

    @Option(
        name: .long,
        help: "Directory for persisted sessions. Defaults to ~/.local/share/fmagent/sessions.")
    var sessionsDir: String?

    @Flag(name: .long, help: "Enable debug logging (to stderr).")
    var debug = false

    @Option(
        name: .long,
        help: "Append log output to this file as well as stderr.")
    var logFile: String?

    mutating func run() async throws {
        let debug = debug
        let logFileURL = logFile.map { URL(fileURLWithPath: $0) }
        AgentLogging.bootstrap(debug: debug, logFileURL: logFileURL)

        let root: URL
        if let sessionsDir {
            root = URL(fileURLWithPath: sessionsDir, isDirectory: true)
        } else {
            root = SessionStore.defaultRoot()
        }

        let store = SessionStore(root: root)
        let agent = FoundationModelsAgent(store: store, engine: FoundationModelsEngine())
        let transport = StdioTransport()
        let connection = AgentConnection(transport: transport, agent: agent)
        try await connection.start()

        // Serve until the client closes stdin (EOF yields .closed).
        for await state in transport.state {
            if state == .closed {
                break
            }
        }
        await connection.close()
    }
}
