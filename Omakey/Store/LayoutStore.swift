import Foundation
import OmakeyCore
import os

/// Built-in layouts (bundled with OmakeyCore) plus imported ones, kept as
/// files in Application Support/layouts.
@MainActor
final class LayoutStore {
    /// The layout a new install starts on, first in the list and recommended there.
    nonisolated static let defaultId = "omakey-pro"
    /// Not a layout: the phone's own keyboard under the touchpad, in portrait.
    static let portraitId = "portrait"
    static let portraitName = "Portrait: your keyboard + touchpad"

    struct Entry {
        let layout: Layout
        let builtIn: Bool
    }

    /// keycodes.json, parsed in the background at start-up (`prewarm`), or
    /// here if something needs it sooner.
    var keycodes: Keycodes {
        if let k = parsedKeycodes { return k }
        let k = try! Keycodes.parse(BundledSpec.keycodesJSON()) // bundled, and tested
        parsedKeycodes = k
        return k
    }

    private var parsedKeycodes: Keycodes?
    /// The built-in layouts' ids, the default first, the rest by file name:
    /// listed in the background at start-up (`prewarm`), finding the bundle
    /// takes a few milliseconds, or here if needed sooner.
    private var builtInIds: [String] {
        if let ids = listedIds { return ids }
        let ids = Self.ordered(BundledSpec.layoutIds())
        listedIds = ids
        return ids
    }

    private var listedIds: [String]?

    private nonisolated static func ordered(_ ids: [String]) -> [String] {
        ids.filter { $0 == defaultId } + ids.filter { $0 != defaultId }
    }
    /// Built-in layouts parsed so far: start-up parses none (the connect
    /// screen shows the chosen one's remembered name); they come in the
    /// background (`prewarm`), or one by one when asked for sooner.
    private var parsed: [String: Layout] = [:]
    private let dir: URL
    private let defaults: UserDefaults
    /// Parsed imports by file name, again only when the file changes.
    private var importedCache: [String: (stamp: Date, layout: Layout?)] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Made with the first import; until then there are none to list.
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("layouts")
    }

    private func builtIn(_ id: String) -> Layout? {
        if let l = parsed[id] { return l }
        guard let json = BundledSpec.layoutJSON(id), let l = try? LayoutParser.parse(json, keycodes: keycodes) else { return nil }
        parsed[id] = l
        rememberName(l)
        return l
    }

    /// Layout names by id, kept so the next start-up can show the chosen one's without parsing.
    private var names: [String: String] {
        get { defaults.dictionary(forKey: "layoutNames") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "layoutNames") }
    }

    private func rememberName(_ l: Layout) {
        if names[l.id] != l.name { names[l.id] = l.name }
    }

    private var builtIn: [Entry] { builtInIds.compactMap { builtIn($0).map { Entry(layout: $0, builtIn: true) } } }

    /// Parse keycodes.json and the built-in layouts not read yet, off the main thread.
    func prewarm() {
        let knownIds = listedIds
        let done = Set(parsed.keys)
        let known = parsedKeycodes
        Task.detached(priority: .userInitiated) {
            let ids = knownIds ?? Self.ordered(BundledSpec.layoutIds())
            guard let codes = known ?? (try? Keycodes.parse(BundledSpec.keycodesJSON())) else { return }
            let layouts = ids.filter { !done.contains($0) }.compactMap { id in
                BundledSpec.layoutJSON(id).flatMap { try? LayoutParser.parse($0, keycodes: codes) }
            }
            await self.keep(ids, codes, layouts)
        }
    }

    private func keep(_ ids: [String], _ codes: Keycodes, _ layouts: [Layout]) {
        if listedIds == nil { listedIds = ids }
        if parsedKeycodes == nil { parsedKeycodes = codes }
        for l in layouts where parsed[l.id] == nil { parsed[l.id] = l }
        var n = names
        for l in layouts { n[l.id] = l.name }
        if n != names { names = n }
    }

    /// The default layout first, the other built-in ones by file name, then imports.
    func all() -> [Entry] {
        let ids = Set(builtInIds)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let imported = files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { f -> Entry? in
            guard let layout = imported(f), !ids.contains(layout.id) else { return nil }
            return Entry(layout: layout, builtIn: false)
        }
        return builtIn + imported
    }

    /// An imported layout's file, parsed again only when it changes.
    private func imported(_ f: URL) -> Layout? {
        let stamp = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let cached = importedCache[f.lastPathComponent], cached.stamp == stamp { return cached.layout }
        let layout = (try? String(contentsOf: f, encoding: .utf8)).flatMap { try? LayoutParser.parse($0, keycodes: keycodes) }
        importedCache[f.lastPathComponent] = (stamp, layout)
        if let layout { rememberName(layout) }
        return layout
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
        // Without reading the rest, as at start-up: a built-in one, or an import by its file.
        if let l = builtIn(selectedId) { return l }
        let file = dir.appendingPathComponent("\(selectedId).json")
        if !portrait, FileManager.default.fileExists(atPath: file.path), let l = imported(file), l.id == selectedId { return l }
        if portrait, let l = builtIn(Self.defaultId) { return l }
        let list = all()
        return (list.first { $0.layout.id == selectedId } ?? list.first { $0.layout.id == Self.defaultId } ?? list[0]).layout
    }

    /// What the keyboard opens with, for the connect screen and Settings:
    /// as remembered, so start-up needn't parse the layout for its name.
    var currentName: String {
        if portrait { return Self.portraitName }
        if let l = parsed[selectedId] { return l.name }
        if let name = names[selectedId] { return name }
        let l = selected()
        rememberName(l)
        return l.name
    }

    /// Validates and saves an imported layout; it becomes the selected one.
    @discardableResult
    func importLayout(_ json: String) throws -> Layout {
        let layout = try LayoutParser.parse(json, keycodes: keycodes)
        if builtInIds.contains(layout.id) {
            throw LayoutError("\"\(layout.id)\" is a built-in layout id; give your layout another id")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent("\(layout.id).json"), options: .atomic)
        selectedId = layout.id
        rememberName(layout)
        return layout
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
        if selectedId == id { selectedId = Self.defaultId }
    }
}
