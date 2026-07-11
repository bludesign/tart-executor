import Foundation

public extension JSONEncoder {
    /// Encoder used for management API responses. Encodes dates as ISO-8601 strings.
    static var api: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public extension JSONDecoder {
    /// Decoder used for management API request bodies. Decodes ISO-8601 date strings.
    static var api: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
