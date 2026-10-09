import Foundation

/// The layout spec files the app ships with (keycodes.json and the stock
/// layouts), synced from the layout studio by scripts/sync-spec.sh.
public enum BundledSpec {
    private static func url(_ name: String, _ subdirectory: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: subdirectory)
    }

    public static func keycodesJSON() -> String {
        guard let u = url("keycodes", "Spec"), let s = try? String(contentsOf: u, encoding: .utf8) else {
            preconditionFailure("keycodes.json is missing from the bundle")
        }
        return s
    }

    /// The stock layouts' JSON, by file name.
    public static func layoutFiles() -> [(file: String, json: String)] {
        let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Spec/layouts") ?? []
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { u in
            (try? String(contentsOf: u, encoding: .utf8)).map { (u.lastPathComponent, $0) }
        }
    }
}
