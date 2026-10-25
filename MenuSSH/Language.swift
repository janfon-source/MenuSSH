import Foundation

/// The UI language the user picked from the More menu. Switches live, without relaunching.
enum Language: String, CaseIterable {
    case zh, zhHans = "zh-Hans", en

    /// Each language is listed in its own name, so it's findable whichever one is showing.
    var title: String {
        switch self {
        case .zh: return "繁體中文"
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }

    private static let key = "menussh.language"

    /// Posted after `current` changes, so views built earlier can relabel themselves.
    static let didChange = Notification.Name("menussh.languageDidChange")

    static var current: Language {
        get { Language(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? systemDefault }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Before anything is picked: Simplified Chinese for a Mac set to it, else Traditional.
    private static var systemDefault: Language {
        Locale.preferredLanguages.first?.hasPrefix("zh-Hans") == true ? .zhHans : .zh
    }
}

/// Picks the Chinese or English text for the current language. The Simplified Chinese is made
/// from the Traditional, so each piece of text is written only twice.
func tr(_ zh: String, _ en: String) -> String {
    switch Language.current {
    case .zh: return zh
    case .zhHans: return Simplified.convert(zh)
    case .en: return en
    }
}

/// Traditional Chinese as written in Taiwan, turned into Simplified Chinese as written in mainland
/// China: the words that differ first, then the characters.
enum Simplified {
    /// Taiwan's word, then mainland China's, both in Traditional characters, in order: a longer
    /// word goes before any word inside it; 文件 (a document) becomes 文檔 before 檔案 and 資料夾
    /// bring in the mainland 文件; and 列 means a row in Taiwan but a column in mainland China, so
    /// the words with 列 in them come before the 列 that becomes 行.
    private static let words: [(String, String)] = [
        ("選單列", "菜單欄"), ("工具列", "工具欄"), ("選單", "菜單"), ("列印", "打印"),
        ("文件", "文檔"),
        ("資料庫", "數據庫"), ("資料表", "數據表"), ("資料列", "行"), ("資料夾", "文件夾"), ("資料", "數據"),
        ("欄位", "字段"), ("列", "行"), ("清單", "列表"),
        ("另存新檔", "另存為"), ("存檔", "保存"), ("檔案", "文件"),
        ("視窗", "窗口"), ("預設", "默認"), ("設定", "設置"), ("儲存", "保存"),
        ("拷貝", "複製"), ("剪下", "剪切"), ("貼上", "粘貼"), ("還原", "撤銷"),
        ("伺服器", "服務器"), ("連接埠", "端口"), ("連線", "連接"), ("登入", "登錄"), ("金鑰", "密鑰"), ("帳號", "賬號"),
        ("觸發程序", "觸發器"), ("程式", "程序"), ("軟體", "軟件"), ("指令", "命令"),
        ("位元組", "字節"), ("字元", "字符"), ("物件", "對象"), ("參照", "引用"),
        ("選取", "選中"), ("支援", "支持"), ("拖曳", "拖動"), ("按兩下", "雙擊"), ("游標", "光標"),
        ("分頁", "標籤頁"), ("釘選", "固定"), ("選填", "可選"), ("網路", "網絡"), ("訊息", "信息"),
        ("音訊", "音頻"), ("影片", "視頻"), ("螢幕", "屏幕"), ("建立", "創建"), ("載入", "加載"),
        ("重新整理", "刷新"), ("匯出", "導出"), ("匯入", "導入"), ("寄出", "發送"), ("產生", "生成"),
        ("開啟", "打開"), ("透過", "通過"), ("傳回", "返回"), ("遺失", "丟失"), ("回應", "響應"),
        ("結束隨手", "退出隨手"),
    ]

    private static var cache: [String: String] = [:]

    static func convert(_ text: String) -> String {
        if let done = cache[text] { return done }
        var out = text
        for (taiwan, mainland) in words { out = out.replacingOccurrences(of: taiwan, with: mainland) }
        out = out.applyingTransform(StringTransform(rawValue: "Hant-Hans"), reverse: false) ?? out
        cache[text] = out
        return out
    }
}
