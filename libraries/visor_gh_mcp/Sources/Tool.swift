import Foundation

public struct Tool: Sendable {
    public let name: String
    public let description: String
    public let params: [Param]
    public let readOnly: Bool
    let run: @Sendable (Arguments, ToolContext) async throws -> String

    init(_ name: String, _ description: String, _ params: [Param], readOnly: Bool,
         run: @escaping @Sendable (Arguments, ToolContext) async throws -> String) {
        self.name = name
        self.description = description
        self.params = params
        self.readOnly = readOnly
        self.run = run
    }

    public var inputSchema: JSON {
        [
            "type": "object",
            "properties": .object(Dictionary(uniqueKeysWithValues: params.map { ($0.name, $0.schema) })),
            "required": .array(params.filter(\.required).map { .string($0.name) }),
            "additionalProperties": false,
        ]
    }

    public var listing: JSON {
        [
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "readOnlyHint": .bool(readOnly),
                // Only a forced push can lose anything, and only with a lease.
                "destructiveHint": .bool(name == "git_push"),
                "openWorldHint": true,
            ],
        ]
    }
}
