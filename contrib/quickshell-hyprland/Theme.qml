pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Colors come from ~/.cache/qs-theme/theme.json, written by `qs-theme`.
// Change the wallpaper with `qs-theme set <image>` and the whole shell re-colors live.
Singleton {
    id: root

    readonly property string dir: Quickshell.env("HOME") + "/.cache/qs-theme"

    property color bg: "#0b0b10"
    property color surface: "#16161f"
    property color accent: "#c4bee6"
    property color accent2: "#8f88c9"
    property color fg: "#e6e3f5"
    property color dim: "#6d6a8a"
    property real glass: 0.72
    property string wallpaper: ""

    readonly property color urgent: "#f08aa9"
    readonly property string font: "monospace"
    readonly property color glassBg: Qt.rgba(bg.r, bg.g, bg.b, glass)
    readonly property color glassSurface: Qt.rgba(surface.r, surface.g, surface.b, Math.min(1, glass + 0.12))
    readonly property color edge: Qt.rgba(accent.r, accent.g, accent.b, 0.22)

    function apply(raw) {
        try {
            const t = JSON.parse(raw);
            if (t.bg) bg = t.bg;
            if (t.surface) surface = t.surface;
            if (t.accent) accent = t.accent;
            if (t.accent2) accent2 = t.accent2;
            if (t.fg) fg = t.fg;
            if (t.dim) dim = t.dim;
            if (typeof t.glass === "number") glass = Math.max(0.2, Math.min(1, t.glass));
            wallpaper = t.wallpaper ? t.wallpaper : "";
        } catch (e) {
            console.warn("qs-theme: theme.json is invalid: " + e);
        }
    }

    FileView {
        path: root.dir + "/theme.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.apply(text())
    }
}
