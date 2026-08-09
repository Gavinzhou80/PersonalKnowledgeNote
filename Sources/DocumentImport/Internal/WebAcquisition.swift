import Foundation

enum WebAcquisitionError: Error, Equatable, Sendable {
    case networkUnavailable
    case requestTimedOut
    case accessDenied
    case invalidHTTPResponse
    case unsupportedContentType
    case responseTooLarge
}

protocol WebAcquiring: Sendable {
    func acquire(_ url: URL) async throws -> AcquiredWebPage
}

struct AcquiredWebPage: Hashable, Sendable {
    let sourceURL: URL
    let finalURL: URL
    let mimeType: String
    let textEncodingName: String?
    let bytes: Data

    var responseBytes: Data { bytes }
    var html: Data { bytes }

    init(
        sourceURL: URL,
        finalURL: URL,
        mimeType: String,
        textEncodingName: String?,
        bytes: Data
    ) {
        self.sourceURL = sourceURL
        self.finalURL = finalURL
        self.mimeType = mimeType
        self.textEncodingName = normalizedWebCharsetName(textEncodingName)
        self.bytes = bytes
    }

    init(finalURL: URL, mimeType: String, responseBytes: Data) {
        self.init(
            sourceURL: finalURL,
            finalURL: finalURL,
            mimeType: mimeType,
            textEncodingName: nil,
            bytes: responseBytes
        )
    }

    init(sourceURL: URL, html: Data) {
        self.init(
            finalURL: sourceURL,
            mimeType: "text/html",
            responseBytes: html
        )
    }
}

func normalizedWebCharsetName(_ value: String?) -> String? {
    guard let value else { return nil }
    guard !value.isEmpty,
          value.utf8.allSatisfy(isWebCharsetTokenByte)
    else {
        return nil
    }
    return value.lowercased()
}

private func isWebCharsetTokenByte(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"),
         UInt8(ascii: "A")...UInt8(ascii: "Z"),
         UInt8(ascii: "a")...UInt8(ascii: "z"),
         UInt8(ascii: "!"), UInt8(ascii: "#"), UInt8(ascii: "$"),
         UInt8(ascii: "%"), UInt8(ascii: "&"), UInt8(ascii: "'"),
         UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "-"),
         UInt8(ascii: "."), UInt8(ascii: "^"), UInt8(ascii: "_"),
         UInt8(ascii: "`"), UInt8(ascii: "|"), UInt8(ascii: "~"):
        return true
    default:
        return false
    }
}
