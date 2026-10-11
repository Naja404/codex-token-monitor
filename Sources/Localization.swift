import Foundation

enum AppLanguage: String, CaseIterable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    var title: String { self == .english ? "English" : "中文–简体" }
    var locale: Locale { Locale(identifier: rawValue) }
}

enum L10n {
    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "monitorLanguage") ?? "") ?? .simplifiedChinese
    }

    static let english: [String: String] = {
        guard let url = ProviderBrand.resourceBundle(in: .main)?.url(forResource: "English", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }()

    static func text(_ source: String, language: AppLanguage = current) -> String {
        language == .english ? english[source] ?? source : source
    }

    static func text(_ source: String, locale: Locale) -> String {
        text(source, language: AppLanguage(rawValue: locale.identifier) ?? current)
    }

    static func format(_ source: String, _ arguments: CVarArg..., language: AppLanguage = current) -> String {
        String(format: text(source, language: language), locale: language.locale, arguments: arguments)
    }

    static func date(_ value: Date, includesTime: Bool = true, language: AppLanguage = current) -> String {
        let format = DateFormatter()
        format.locale = language.locale
        format.setLocalizedDateFormatFromTemplate(includesTime ? "MMMdHHmm" : "MMMd")
        return format.string(from: value)
    }
}
