import Foundation
import AstrophotoKit

/// Minimal MCP server implementing JSON-RPC 2.0 over stdio.
/// Handles: initialize, tools/list, tools/call.
struct MCPServer {
    private let tools        = Tools()
    private let archiveTools = ArchiveTools()

    func run() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)

        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) {
                continuation.yield(line)
            }
            continuation.finish()
        }

        for await line in stream {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            await handleMessage(trimmed)
        }
    }

    private func handleMessage(_ json: String) async {
        guard
            let data = json.data(using: .utf8),
            let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            respond(id: nil, error: (-32700, "Parse error"))
            return
        }

        let method = msg["method"] as? String ?? ""
        let id = msg["id"]

        // Notifications have no id and require no response
        if id == nil, method.hasPrefix("notifications/") { return }

        switch method {
        case "initialize":
            respond(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: String]()],
                "serverInfo": ["name": "astrokit-mcp", "version": Version.string],
            ])

        case "tools/list":
            respond(id: id, result: ["tools": Tools.definitions + ArchiveTools.definitions])

        case "tools/call":
            let params = msg["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            await handleToolCall(id: id, name: name, args: args)

        default:
            respond(id: id, error: (-32601, "Method not found: \(method)"))
        }
    }

    private func handleToolCall(id: Any?, name: String, args: [String: Any]) async {
        do {
            let text = name.hasPrefix("archive_")
                ? try await archiveTools.call(name: name, arguments: args)
                : try await tools.call(name: name, arguments: args)
            respond(id: id, result: [
                "content": [["type": "text", "text": text]],
            ])
        } catch {
            respond(id: id, result: [
                "isError": true,
                "content": [["type": "text", "text": error.localizedDescription]],
            ])
        }
    }

    private func respond(id: Any?, result: Any) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "result": result]
        msg["id"] = id ?? NSNull()
        write(msg)
    }

    private func respond(id: Any?, error: (Int, String)) {
        let msg: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": error.0, "message": error.1],
        ]
        write(msg)
    }

    private func write(_ obj: [String: Any]) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: obj),
            let line = String(data: data, encoding: .utf8)
        else { return }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}
