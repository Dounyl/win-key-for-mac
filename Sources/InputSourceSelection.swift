import Foundation

struct InputSourceDescriptor {
    let id: String
    let languages: [String]
    var isKeyboardLayout = false
    var isASCIICapable = false

    private var primaryLanguage: String {
        (languages.first ?? "").lowercased().replacingOccurrences(of: "_", with: "-")
    }

    var isChinese: Bool {
        primaryLanguage == "zh" || primaryLanguage.hasPrefix("zh-")
    }

    var isEnglish: Bool {
        !isChinese && (primaryLanguage == "en" || primaryLanguage.hasPrefix("en-") ||
            (isKeyboardLayout && isASCIICapable))
    }
}

enum InputSourceSelection {
    static func targetID(currentID: String, available: [InputSourceDescriptor],
                         lastChineseID: String?, lastEnglishID: String?) -> String? {
        let chinese = available.filter { $0.isChinese }
        let english = available.filter { $0.isEnglish }
        guard !chinese.isEmpty, !english.isEmpty else { return nil }
        let currentIsChinese = chinese.contains { $0.id == currentID }
        let choices = currentIsChinese ? english : chinese
        let remembered = currentIsChinese ? lastEnglishID : lastChineseID
        return choices.first { $0.id == remembered }?.id ?? choices.first?.id
    }
}
