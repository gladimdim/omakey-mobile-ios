import Foundation
import OmakeyCore
import os

/// Built-in layouts (bundled with OmakeyCore) plus imported ones, kept as
/// files in Application Support/layouts.
@MainActor
final class LayoutStore {
    /// The layout a new install starts on, first in the list and recommended there.
    static let defaultId = "omakey-pro"
    /// Not a layout: the phone's own keyboard under the touchpad, in portrait.
    static let portraitId = "portrait"
    static let portraitName = "Portrait: your keyboard + touchpad"

    struct Entry {
        let layout: Layout
        let builtIn: Bool
    }

    let keycodes: Keycodes
    private let builtIn: [Entry]
    private let dir: URL
    private let defaults: UserDefaults
    /// Parsed imports by file name, again only when the file changes.
    private var importedCache: [String: (stamp: Date, layout: Layout?)] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keycodes = try! Keycodes.parse(BundledSpec.keycodesJSON()) // bundled, and tested
        let codes = keycodes
        let parsed = BundledSpec.layoutFiles() // by file name
            .compactMap { f in (try? LayoutParser.parse(f.json, keycodes: codes)).map { Entry(layout: $0, builtIn: true) } }
        builtIn = parsed.filter { $0.layout.id == Self.defaultId } + parsed.filter { $0.layout.id != Self.defaultId }
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("layouts")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// The default layout first, the other built-in ones by file name, then imports.
    func all() -> [Entry] {
        let ids = Set(builtIn.map(\.layout.id))
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let imported = files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { f -> Entry? in
            let stamp = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let layout: Layout?
            if let cached = importedCache[f.lastPathComponent], cached.stamp == stamp {
                layout = cached.layout
            } else {
                layout = (try? String(contentsOf: f, encoding: .utf8)).flatMap { try? LayoutParser.parse($0, keycodes: keycodes) }
                importedCache[f.lastPathComponent] = (stamp, layout)
            }
            guard let layout, !ids.contains(layout.id) else { return nil }
            return Entry(layout: layout, builtIn: false)
        }
        return builtIn + imported
    }

    /// Parse and validate without saving, to preview an import.
    func preview(_ json: String) throws -> Layout { try LayoutParser.parse(json, keycodes: keycodes) }

    /// The imported layout an import of [id] would replace, if any.
    func importedWithId(_ id: String) -> Layout? { all().first { !$0.builtIn && $0.layout.id == id }?.layout }

    var selectedId: String {
        get { defaults.string(forKey: "selectedLayout") ?? Self.defaultId }
        set { defaults.set(newValue, forKey: "selectedLayout") }
    }

    /// The portrait mode is chosen instead of a layout.
    var portrait: Bool { selectedId == Self.portraitId }

    /// The chosen layout; in portrait mode the default one.
    func selected() -> Layout {
        let list = all()
        return (list.first { $0.layout.id == selectedId } ?? list.first { $0.layout.id == Self.defaultId } ?? list[0]).layout
    }

    /// What the keyboard opens with, for the connect screen and Settings.
    var currentName: String { portrait ? Self.portraitName : selected().name }

    /// Validates and saves an imported layout; it becomes the selected one.
    @discardableResult
    func importLayout(_ json: String) throws -> Layout {
        let layout = try LayoutParser.parse(json, keycodes: keycodes)
        if builtIn.contains(where: { $0.layout.id == layout.id }) {
            throw LayoutError("\"\(layout.id)\" is a built-in layout id; give your layout another id")
        }
        try Data(json.utf8).write(to: dir.appendingPathComponent("\(layout.id).json"), options: .atomic)
        selectedId = layout.id
        return layout
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
        if selectedId == id { selectedId = Self.defaultId }
    }
}
