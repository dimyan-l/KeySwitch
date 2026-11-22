import Foundation

/// Conservative guards before a keyboard event may change text.
enum InputPolicy {
    static let maxAutomaticWordLength = 24

    static func allowsAutomaticSpelling(terminator: UInt16) -> Bool {
        ![36, 76, 48].contains(terminator)
    }

    static func beginsStructuredToken(_ character: String) -> Bool {
        if character.first?.isNumber == true { return true }
        return ["@", ":", "/", "\\", "_", "#", "=", "+", "&", "%", "$", "~", "|", "*"].contains(character)
    }

    static func structuredEvenIfAlternativeIsLetter(_ character: String) -> Bool {
        // '@' and '/' remain structural even on layout pairs where they map to a letter.
        ["@", "/", "\\", "_", "#", "=", "+", "&", "%", "$", "~", "|", "*"].contains(character)
    }

    private static let englishVowels = Set<Character>("aeiouy")
    private static let domainOrCodeExtensions: Set<String> = [
        "com", "ru", "org", "net", "io", "ai", "dev", "app", "me", "co", "uk", "de", "fr", "es",
        "by", "kz", "ua", "info", "biz", "edu", "gov", "tv", "cc", "gg", "ly", "to", "sh",
        "js", "ts", "jsx", "tsx", "py", "rb", "go", "rs", "md", "txt", "json", "yaml", "yml",
        "xml", "csv", "tsv", "html", "css", "scss", "sql", "pdf", "png", "jpg", "jpeg", "gif",
        "svg", "zip", "tar", "gz", "dmg", "pkg", "exe", "dll", "so", "dylib", "swift", "kt",
        "java", "cpp", "hpp", "php", "env", "log", "lock", "toml", "ini", "cfg", "conf", "bak", "tmp",
    ]

    static func blocksAutomaticCorrection(_ text: String, plan: CorrectionPlan) -> Bool {
        guard containsEmbeddedDot(text) else { return false }
        if looksLikeDomainOrIdentifier(text) { return true }
        // On QWERTY, '.' is the physical key for Russian 'ю'. Allow a known Cyrillic
        // reading (even followed by sentence punctuation like '.' or ',') or a confident
        // Cyrillic n-gram reading when the typed token clearly isn't a domain or code identifier.
        let isPurePunctuationSuffix = plan.suffix.allSatisfy { !$0.isLetter && !$0.isNumber }
        let isCyrillicTarget = plan.decision.convert && isPurePunctuationSuffix && !plan.alternativeWord.isEmpty
            && plan.alternativeWord.unicodeScalars.allSatisfy {
                (0x0400...0x04FF).contains($0.value) || $0 == "-"
            }
        guard isCyrillicTarget else { return true }
        switch plan.decision.reason {
        case "other-dict", "freq", "other-typo":
            return false
        case "ngram":
            return !plan.decision.confident
        default:
            return true
        }
    }

    private static func looksLikeDomainOrIdentifier(_ token: String) -> Bool {
        let lower = token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?()[]{}«»\"'"))
        let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        // Extra Russian-layout punctuation inside the token (like ',' or ';') rules out domains/code.
        if lower.contains(where: { !$0.isASCII || (!$0.isLetter && $0 != "." && $0 != "-") }) {
            return false
        }
        if let last = parts.last, domainOrCodeExtensions.contains(String(last)) {
            return true
        }
        // Identifiers like "object.method" have English vowels in every segment.
        return parts.allSatisfy { part in
            !part.isEmpty && part.contains { englishVowels.contains($0) }
        }
    }

    static func containsEmbeddedDot(_ text: String) -> Bool {
        let chars = Array(text)
        return chars.indices.contains { i in
            i > 0 && i + 1 < chars.count && chars[i] == "." &&
            chars[i - 1].isLetter && chars[i + 1].isLetter
        }
    }
}
