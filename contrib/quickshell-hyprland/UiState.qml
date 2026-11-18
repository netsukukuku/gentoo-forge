pragma Singleton
import QtQuick
import Quickshell

// Which overlays are open. Toggled over IPC (see hyprland.conf) or by clicking the bar.
Singleton {
    property bool launcherOpen: false
    property bool clipboardOpen: false
    property bool mediaOpen: false

    function closeAll() {
        launcherOpen = false;
        clipboardOpen = false;
        mediaOpen = false;
    }
}
