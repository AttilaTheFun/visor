extension ConnectionCodes {
    public var json: JSONValue {
        var o: [String: JSONValue] = ["qr": .string(qr)]
        if let http { o["http"] = .string(http) }
        if let https { o["https"] = .string(https) }
        if let ssh { o["ssh"] = .string(ssh) }
        return .object(o)
    }

    public init?(json: JSONValue) {
        guard let qr = json["qr"].string, !qr.isEmpty else { return nil }
        self.init(qr: qr, http: json["http"].string, https: json["https"].string, ssh: json["ssh"].string)
    }
}
