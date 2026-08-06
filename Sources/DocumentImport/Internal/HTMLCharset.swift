import CoreFoundation
import Foundation

func htmlStringEncoding(for label: String?) -> String.Encoding? {
    guard let label else { return nil }
    let normalized = label
        .trimmingCharacters(
            in: CharacterSet(charactersIn: "\u{0009}\u{000A}\u{000C}\u{000D} ")
        )
        .lowercased()
        .replacingOccurrences(of: "_", with: "-")
    guard !normalized.isEmpty,
          normalized.utf8.allSatisfy({ $0 < 0x80 })
    else {
        return nil
    }

    switch normalized {
    case "unicode-1-1-utf-8", "unicode11utf8", "unicode20utf8",
         "utf-8", "utf8", "x-unicode20utf8":
        return .utf8
    case "utf-16", "utf16":
        return .utf16
    case "utf-16le", "utf16le":
        return .utf16LittleEndian
    case "utf-16be", "utf16be":
        return .utf16BigEndian
    case "ansi-x3.4-1968", "ascii", "cp1252", "cp819",
         "csisolatin1", "ibm819", "iso-8859-1", "iso-ir-100",
         "iso8859-1", "iso88591", "iso-8859-1:1987", "l1",
         "latin1", "latin-1", "us-ascii", "windows-1252",
         "x-cp1252":
        return .windowsCP1252
    case "csshiftjis", "ms-kanji", "shift-jis", "shiftjis", "sjis",
         "windows-31j", "x-sjis":
        return .shiftJIS
    case "cseucpkdfmtjapanese", "euc-jp", "eucjp", "x-euc-jp":
        return .japaneseEUC
    case "gb18030":
        return coreFoundationEncoding(named: "gb18030")
    case "chinese", "cp936", "csgb2312", "csiso58gb231280", "gb2312",
         "gb-2312", "gb-2312-80", "gbk", "iso-ir-58", "ms936",
         "windows-936", "x-gbk":
        return coreFoundationEncoding(named: "gbk")
    case "hz-gb-2312", "iso-2022-cn", "iso-2022-cn-ext", "replacement",
         "utf-7", "x-user-defined":
        return nil
    default:
        return nil
    }
}

private func coreFoundationEncoding(named label: String) -> String.Encoding? {
    let cfEncoding = CFStringConvertIANACharSetNameToEncoding(label as CFString)
    guard cfEncoding != kCFStringEncodingInvalidId else {
        return nil
    }
    return String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding)
    )
}
