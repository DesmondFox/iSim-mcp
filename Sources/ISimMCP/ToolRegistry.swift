import DeviceCore
import Foundation
import MCP
import ProcessKit

public struct ToolDefinition: Sendable {
    public typealias Handler = @Sendable (ToolArguments, ToolContext) async throws -> CallTool.Result

    public var tool: Tool
    public var toolset: Toolset
    public var handler: Handler

    public init(
        name: String,
        toolset: Toolset,
        description: String,
        inputSchema: Value,
        annotations: Tool.Annotations,
        handler: @escaping Handler
    ) {
        self.tool = Tool(name: name, description: description, inputSchema: inputSchema, annotations: annotations)
        self.toolset = toolset
        self.handler = handler
    }

    public var name: String { tool.name }
}

/// All tools of the server; serves `tools/list` and `tools/call` for the enabled toolsets.
public struct ToolRegistry: Sendable {
    public let enabledToolsets: Set<Toolset>
    private let definitions: [String: ToolDefinition]
    private let order: [String]

    public init(definitions: [ToolDefinition], enabledToolsets: Set<Toolset>) {
        self.enabledToolsets = enabledToolsets.union([.core])
        self.definitions = Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) })
        self.order = definitions.map(\.name)
    }

    public var tools: [Tool] {
        order.compactMap { definitions[$0] }.filter { enabledToolsets.contains($0.toolset) }.map(\.tool)
    }

    /// Never throws for tool failures: they become `isError` results the model can read.
    /// Only cancellation propagates, so the server drops the response as the MCP spec requires.
    public func call(_ name: String, arguments: [String: Value]?, context: ToolContext) async throws -> CallTool.Result {
        guard let definition = definitions[name] else {
            return .error("Unknown tool \"\(name)\".")
        }
        guard enabledToolsets.contains(definition.toolset) else {
            let toolsets = (enabledToolsets.union([definition.toolset])).sorted().map(\.rawValue).joined(separator: ",")
            return .error("\(name) belongs to the \"\(definition.toolset.rawValue)\" toolset, which is disabled. Restart the server with --toolsets \(toolsets).")
        }
        do {
            return try await definition.handler(ToolArguments(arguments ?? [:]), context)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .error("\(error)")
        }
    }
}

extension CallTool.Result {
    static func text(_ text: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
    }

    static func error(_ text: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: true)
    }
}

extension Tool.Annotations {
    static let readOnly = Tool.Annotations(readOnlyHint: true, openWorldHint: false)
    static let mutating = Tool.Annotations(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
    static let idempotent = Tool.Annotations(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    static let destructive = Tool.Annotations(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
}
