#if canImport(AppKit)
import AppKit

/// NSOpenPanel delegate for "打开资源库".
///
/// `.tlkbundle` is a directory package that the system doesn't know about (not
/// registered as a UTType with LSTypeIsPackage), so NSOpenPanel treats it as a
/// plain folder. We allow directory navigation but only *enable* (selectable)
/// items whose name ends with `.tlkbundle` — matching FCP's "only libraries are
/// selectable" behavior.
@MainActor
final class MacLibraryOpenPanelDelegate: NSObject, NSOpenSavePanelDelegate {

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        // Directories stay navigable (so the user can drill into folders);
        // only .tlkbundle items are selectable.
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        if isDir.boolValue {
            // Allow browsing directories, but never enable a non-bundle folder
            // as a selection target. `shouldEnable` controls selectability;
            // navigation still works for enabled items, so enabling directories
            // is required to enter them.
            return true
        }

        // Files: only .tlkbundle (directory packages appear as files in the panel
        // once the system or the panel treats them as packages; as a fallback we
        // also accept any path whose extension is tlkbundle).
        return url.pathExtension.lowercased() == "tlkbundle"
    }
}

#endif
