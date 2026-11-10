import Foundation

/// Conservative guards before a keyboard event may change text.
enum InputPolicy {
    static let maxAutomaticWordLength = 24

    static func allowsAutomaticSpelling(terminator: UInt16) -> Bool {
        ![36, 76, 48].contains(terminator)
    }

    static func beginsStructuredToken(_ character: String) -> Bool {
        if character.first?.isNumber == true { return true }
        return ["@", ":", "/", "\\", "_", "#", "="].contains(character)
    }

    static func blocksAutomaticCorrection(_ text: String, plan: CorrectionPlan) -> Bool {
        guard containsEmbeddedDot(text) else { return false }
        // On QWERTY, '.' is the physical key for Russian 'ю'. Allow only
        // a known, whole Cyrillic reading, never a stripped domain fragment
        // or a statistical guess. EN/ES keeps the structured-token guard.
        let knownRussianReading = plan.decision.convert && plan.decision.reason == "other-dict"
            && plan.suffix.isEmpty && !plan.alternativeWord.isEmpty
            && plan.alternativeWord.unicodeScalars.allSatisfy {
                (0x0400...0x04FF).contains($0.value) || $0 == "-"
            }
        return !knownRussianReading
    }

    static func containsEmbeddedDot(_ text: String) -> Bool {
        let chars = Array(text)
        return chars.indices.contains { i in
            i > 0 && i + 1 < chars.count && chars[i] == "." &&
            chars[i - 1].isLetter && chars[i + 1].isLetter
        }
    }
}
