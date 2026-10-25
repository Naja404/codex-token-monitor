import AppKit

/// Accessory apps still need a main menu to dispatch standard Command shortcuts.
/// Nil targets let AppKit route editing to the focused field and closing to the key window.
@MainActor
enum ApplicationMenu {
    static func install(language: AppLanguage) {
        let menu = make(language: language)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = menu.items.last?.submenu
    }

    static func make(language: AppLanguage) -> NSMenu {
        let menu = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let contents = NSMenu(title: title)
            item.submenu = contents
            menu.addItem(item)
            return contents
        }
        func item(_ title: String, action: Selector, key: String,
                  modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let value = NSMenuItem(title: L10n.text(title, language: language), action: action, keyEquivalent: key)
            value.keyEquivalentModifierMask = modifiers
            return value
        }
        let app = submenu("Codex Token Monitor")
        app.addItem(item("退出", action: #selector(NSApplication.terminate(_:)), key: "q"))

        let file = submenu(L10n.text("文件", language: language))
        file.addItem(item("关闭窗口", action: #selector(NSWindow.performClose(_:)), key: "w"))

        let edit = submenu(L10n.text("编辑", language: language))
        edit.addItem(item("撤销", action: Selector(("undo:")), key: "z"))
        edit.addItem(item("重做", action: Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("剪切", action: #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(item("拷贝", action: #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(item("粘贴", action: #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(item("全选", action: #selector(NSText.selectAll(_:)), key: "a"))

        let window = submenu(L10n.text("窗口", language: language))
        window.addItem(item("最小化", action: #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        return menu
    }
}
