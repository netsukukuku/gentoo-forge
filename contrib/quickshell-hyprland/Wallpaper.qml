import QtQuick
import Quickshell
import Quickshell.Wayland

// Draws the wallpaper itself, so no hyprpaper/swww is needed.
// (If you run one of those too, remove it from hyprland.conf.)
Variants {
    model: Quickshell.screens

    PanelWindow {
        required property var modelData
        screen: modelData

        WlrLayershell.layer: WlrLayer.Background
        WlrLayershell.namespace: "qs-wallpaper"
        exclusionMode: ExclusionMode.Ignore
        anchors { top: true; bottom: true; left: true; right: true }
        color: Theme.bg

        Image {
            anchors.fill: parent
            source: Theme.wallpaper !== "" ? "file://" + Theme.wallpaper : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: false
            sourceSize.width: parent.width
            sourceSize.height: parent.height
            opacity: status === Image.Ready ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 400 } }
        }
    }
}
