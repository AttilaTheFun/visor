extension TranscriptEntry {
    /// The row as JSON — what a cache keeps and what goes over the wire.
    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "role": .string(role.rawValue), "text": .string(text),
            "activities": .array(activities.map(JSONValue.string)),
        ]
        if let toolName { o["toolName"] = .string(toolName) }
        if !images.isEmpty { o["images"] = .array(images.map(JSONValue.string)) }
        if !imageSizes.isEmpty {
            o["imageSizes"] = .array(imageSizes.map { .object(["width": .number(Double($0.width)), "height": .number(Double($0.height))]) })
        }
        return .object(o)
    }

    public init?(json: JSONValue) {
        guard let id = json["id"].string, let role = json["role"].string.flatMap(Role.init(rawValue:)),
              let text = json["text"].string else { return nil }
        self.init(id: id, role: role, text: text, activities: json["activities"].array?.compactMap(\.string) ?? [],
                  toolName: json["toolName"].string,
                  images: json["images"].array?.compactMap(\.string) ?? [],
                  imageSizes: json["imageSizes"].array?.compactMap { size -> ImageSize? in
                      guard let w = size["width"].double, let h = size["height"].double, w > 0, h > 0 else { return nil }
                      return ImageSize(width: Int(whole: w), height: Int(whole: h))
                  } ?? [])
    }
}
