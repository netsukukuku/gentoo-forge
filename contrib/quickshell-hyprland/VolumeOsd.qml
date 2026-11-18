import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pipewire

// Small pill at the bottom that appears when the volume or mute state changes.
Scope {
    id: root

    readonly property var sink: Pipewire.defaultAudioSink
    PwObjectTracker { objects: [root.sink] }

    property bool shown: false
    property bool ready: false

    // Ignore the changes PipeWire reports while the shell is starting.
    Timer { interval: 1500; running: true; onTriggered: root.ready = true }
    Timer { id: hide; interval: 1400; onTriggered: root.shown = false }

    function show() {
        if (!root.ready) return;
        root.shown = true;
        hide.restart();
    }

    Connections {
        target: root.sink ? root.sink.audio : null
        ignoreUnknownSignals: true
        function onVolumeChanged() { root.show(); }
        function onMutedChanged() { root.show(); }
    }

    PanelWindow {
        visible: root.shown

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "qs-osd"
        exclusionMode: ExclusionMode.Ignore
        anchors { bottom: true }
        margins { bottom: 80 }
        implicitWidth: 280
        implicitHeight: 52
        color: "transparent"
        mask: Region {}   // never steals clicks

        Rectangle {
            anchors.fill: parent
            radius: 26
            color: Theme.glassBg
            border.width: 1
            border.color: Theme.edge

            Text {
                id: label
                anchors.left: parent.left
                anchors.leftMargin: 20
                anchors.verticalCenter: parent.verticalCenter
                readonly property bool muted: root.sink && root.sink.audio && root.sink.audio.muted
                text: muted ? "MUTE" : "VOL"
                color: muted ? Theme.dim : Theme.accent
                font.family: Theme.font
                font.pixelSize: 13
                font.bold: true
            }

            Rectangle {
                id: track
                anchors.left: label.right
                anchors.leftMargin: 14
                anchors.right: pct.left
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                height: 6
                radius: 3
                color: Theme.glassSurface

                Rectangle {
                    height: parent.height
                    radius: 3
                    color: label.muted ? Theme.dim : Theme.accent
                    width: parent.width * Math.max(0, Math.min(1, root.sink && root.sink.audio ? root.sink.audio.volume : 0))
                }
            }

            Text {
                id: pct
                anchors.right: parent.right
                anchors.rightMargin: 20
                anchors.verticalCenter: parent.verticalCenter
                text: root.sink && root.sink.audio ? Math.round(root.sink.audio.volume * 100) + "%" : ""
                color: Theme.fg
                font.family: Theme.font
                font.pixelSize: 13
            }
        }
    }
}
