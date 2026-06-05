import Foundation

@main
struct AstrokitMCP {
    static func main() async throws {
        let server = MCPServer()
        try await server.run()
    }
}
