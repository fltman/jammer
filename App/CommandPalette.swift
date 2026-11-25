import AppKit
import JammerAgent
import SwiftUI

/// Every command by name, for the omnibar (⌘K): the command registry (`Commands`), the same one the menu bar and
/// the context menus come from, so a command, its shortcut and the reason it is off are the same everywhere.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let detail: String
    let shortcut: String
    /// Why it can't run now (shown in place of the detail); nil when it can.
    var unavailable: String? = nil
    let run: @MainActor () -> Void
}

@MainActor
enum CommandPalette {
    static func commands(controller: EditorWindowController) -> [PaletteCommand] {
        Commands.all.filter(\.inPalette).compactMap { c -> PaletteCommand? in
            let item = CommandCenter.item(c)
            guard !item.isHidden else { return nil }
            // The menu path, as the menu bar shows it ("Audio › Loudness Preset").
            let path = [CommandCenter.menuTitle(c.menu)] + (c.submenu.map { [L10n.text($0)] } ?? [])
            let (enabled, why) = controller.availability(c.id, item: item)
            return PaletteCommand(id: c.id, title: item.title, detail: path.joined(separator: " › "), shortcut: c.shortcut,
                                  unavailable: enabled ? nil : (why ?? L10n.text("command.unavailable"))) { [weak controller] in
                guard let controller else { return }
                // Asked again at the moment it runs: the document may have changed since the list was made.
                let (ok, reason) = controller.availability(c.id, item: item)
                guard ok else { controller.session.say(reason ?? L10n.text("command.unavailable"), .info); NSSound.beep(); return }
                NSApp.sendAction(item.action!, to: item.target, from: item)
            }
        }
    }
}
