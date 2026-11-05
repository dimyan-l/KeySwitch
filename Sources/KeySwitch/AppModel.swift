import AppKit
import Observation
import SwiftUI

/// What the SwiftUI views may ask the app to do. Implemented by AppDelegate.
protocol AppActions: AnyObject {
    /// Paste one of the recently copied texts into the app you were typing in.
    func pasteRecent(_ text: String)
    /// "Это ошибка → Не исправлять «…»": a rule for the word you had typed. Protects future typing only.
    func protect(_ id: UUID)
    /// "Это ошибка → Отключить исправление опечаток".
    func disableSpelling()
    /// "Это ошибка → Не исправлять в <app>".
    func excludeApp(_ bundleID: String)
    /// Dictionaries → Не исправлять.
    func addRule(_ word: String, lang: Lang?)
    func removeRule(_ id: String)
    /// Writes the rules again after a failed save.
    func retrySave()
    func clearClipboard()
    func openSettings(_ pane: SettingsPane)
    func showOnboarding()
    func closePanel()
    func setLayout(_ lang: Lang)
    func setLogin(_ on: Bool)
    func openAccessibility()
    func openInputMonitoring()
    func finishOnboarding()
    func addWord(_ word: String, lang: Lang?)
    func removeWord(_ word: String, lang: Lang)
    /// Forget one learned word (taught by mistake with right ⌥, Backspace or the bookmark).
    func forgetWord(_ word: String, lang: Lang)
    func setICloudSync(_ on: Bool)
    func forgetLearned()
    func reloadDictionaries()
    func openUserFolder()
    func quit()
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, apps, words, privacy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "Основное"
        case .apps: "Приложения"
        case .words: "Словари"
        case .privacy: "Конфиденциальность"
        }
    }
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .apps: "square.grid.2x2"
        case .words: "text.book.closed"
        case .privacy: "hand.raised"
        }
    }
}

struct CorrectionRecord: Identifiable {
    let id = UUID()
    let typed: String
    let result: String
    let kind: FixKind
    let to: Lang
    /// The layout you typed `typed` in: the other one for a layout fix, the same one for a typo fix.
    let from: Lang
    let app: String
    var bundleID: String?
    let date: Date
    /// A "Не исправлять" rule exists for this word (made here, by undo or by your own restore).
    var protected = false
}

/// What the panel says after a rule was made: saved for good, or only until you quit.
struct RuleNotice: Equatable {
    let word: String
    let saved: Bool
    let at = Date()
}

/// View state. Settings, the store and the clipboard are plain classes, so views re-read them
/// whenever `revision` changes.
@Observable
final class AppModel {
    var revision = 0

    var lang: Lang?
    var engineRunning = false
    var accessibilityGranted = false
    var inputMonitoringGranted = false
    var dictionariesReady = false
    var loadError: String?
    var hasBothLayouts = true
    /// Another app holds secure keyboard entry: no keys reach KeySwitch. Empty name: the holder is unknown.
    var secureInputHolder: String?
    var lastError: String?
    var correctionsToday = 0
    var learnedCount = 0
    var recent: [CorrectionRecord] = []
    var ruleNotice: RuleNotice?
    var saveError: String?
    var rulesCount = 0
    var frontAppName: String?
    var frontBundleID: String?
    var conflictingApps: [String] = []
    var loginEnabled = false
    var pane: SettingsPane = .general

    @ObservationIgnored weak var actions: AppActions?
    @ObservationIgnored var onSettingsChanged: (() -> Void)?
    @ObservationIgnored let settings = Settings.shared
    @ObservationIgnored let store: UserStore
    @ObservationIgnored let clipboard: ClipboardHistory
    init(store: UserStore, clipboard: ClipboardHistory) {
        self.store = store
        self.clipboard = clipboard
    }

    func touch() { revision += 1 }

    func binding<T>(_ keyPath: ReferenceWritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(
            get: { _ = self.revision; return self.settings[keyPath: keyPath] },
            set: { self.settings[keyPath: keyPath] = $0; self.revision += 1; self.onSettingsChanged?() }
        )
    }

    func excludedBinding(_ bundleID: String) -> Binding<Bool> {
        Binding(
            get: { _ = self.revision; return self.settings.excluded.contains(bundleID) },
            set: { on in
                if on != self.settings.excluded.contains(bundleID) { self.settings.toggleExcluded(bundleID) }
                self.revision += 1
                self.onSettingsChanged?()
            }
        )
    }
}
