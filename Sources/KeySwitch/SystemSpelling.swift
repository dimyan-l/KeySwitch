import AppKit

/// The macOS spell checker knows inflected and rare forms that the bundled frequency
/// lists miss ("баги", "сверить", "сверю"). KeySwitch uses it only as a veto before an
/// automatic change, never as a source of replacements. A local call takes well under
/// a few milliseconds once the checker is warm, so it is safe on the tap's main thread.
enum SystemSpelling {
    private static var languages: Set<String>?
    private static var cache: [String: Bool] = [:]
    private static let maxCacheEntries = 4_096

    /// Loads the checker and its dictionaries before the first keystroke needs them.
    static func warmUp() {
        for lang in Lang.allCases { _ = accepts(lang == .ru ? "привет" : "hello", lang: lang) }
    }

    /// True when macOS considers `word` correctly spelled in `lang`. False when the
    /// language is not installed: then the bundled dictionaries alone decide.
    static func accepts(_ word: String, lang: Lang) -> Bool {
        guard Thread.isMainThread, !word.isEmpty else { return false }
        let cacheKey = "\(lang.rawValue):\(word)"
        if let cached = cache[cacheKey] { return cached }
        let checker = NSSpellChecker.shared
        if languages == nil { languages = Set(checker.availableLanguages) }
        guard languages?.contains(lang.rawValue) == true else { return false }
        let range = checker.checkSpelling(of: word, startingAt: 0, language: lang.rawValue,
                                          wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        let accepted = range.location == NSNotFound
        if cache.count >= maxCacheEntries { cache.removeAll(keepingCapacity: true) }
        cache[cacheKey] = accepted
        return accepted
    }
}
