import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import Quickshell.Services.SystemTray

// Floating glass bar, one per monitor.
Scope {
    id: root

    property int memPercent: 0

    readonly property var sink: Pipewire.defaultAudioSink
    PwObjectTracker { objects: [root.sink] }

    function volumeText() {
        if (!root.sink || !root.sink.audio) return "--";
        return root.sink.audio.muted ? "muted" : Math.round(root.sink.audio.volume * 100) + "%";
    }

    // First playing player, else the first one.
    readonly property var player: {
        const list = Mpris.players.values;
        for (const p of list) if (p.isPlaying) return p;
        return list.length > 0 ? list[0] : null;
    }

    Process {
        id: memProc
        command: ["sh", "-c", "awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{print int((t-a)*100/t)}' /proc/meminfo"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: root.memPercent = parseInt(this.text) || 0
        }
    }

    Timer {
        interval: 3000
        running: true
        repeat: true
        onTriggered: memProc.running = true
    }

    SystemClock {
        id: clock
        precision: SystemClock.Seconds
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: bar
            required property var modelData
            screen: modelData

            readonly property var monitor: Hyprland.monitorFor(modelData)

            anchors { top: true; left: true; right: true }
            margins { top: 6; left: 10; right: 10 }
            implicitHeight: 38
            color: "transparent"

            Rectangle {
                anchors.fill: parent
                radius: 14
                color: Theme.glassBg
                border.width: 1
                border.color: Theme.edge

                // ---------- left: launcher button, workspaces, window title ----------
                RowLayout {
                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 14

                    Text {
                        text: "◆"
                        color: Theme.accent
                        font.family: Theme.font
                        font.pixelSize: 16
                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -6
                            onClicked: {
                                UiState.clipboardOpen = false;
                                UiState.launcherOpen = !UiState.launcherOpen;
                            }
                        }
                    }

                    Row {
                        spacing: 6
                        Layout.alignment: Qt.AlignVCenter

                        Repeater {
                            model: Hyprland.workspaces

                            Rectangle {
                                id: pill
                                required property var modelData
                                readonly property bool onThisMonitor: modelData.monitor === bar.monitor
                                readonly property bool isActive: bar.monitor && bar.monitor.activeWorkspace === modelData
                                visible: modelData.id > 0 && onThisMonitor
                                width: visible ? (isActive ? 28 : 10) : 0
                                height: 10
                                radius: 5
                                color: isActive ? Theme.accent : Theme.dim
                                anchors.verticalCenter: parent.verticalCenter

                                Behavior on width { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -4
                                    onClicked: Hyprland.dispatch("workspace " + pill.modelData.id)
                                }
                            }
                        }
                    }

                    Text {
                        Layout.maximumWidth: 360
                        text: Hyprland.activeToplevel ? Hyprland.activeToplevel.title : ""
                        color: Theme.dim
                        font.family: Theme.font
                        font.pixelSize: 13
                        elide: Text.ElideRight
                    }
                }

                // ---------- center: clock ----------
                Text {
                    anchors.centerIn: parent
                    text: Qt.formatDateTime(clock.date, "ddd d MMM  ·  hh:mm")
                    color: Theme.fg
                    font.family: Theme.font
                    font.pixelSize: 14
                    font.bold: true
                }

                // ---------- right: media, ram, volume, tray ----------
                RowLayout {
                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 16

                    Text {
                        visible: root.player !== null
                        Layout.maximumWidth: 260
                        text: root.player ? ((root.player.isPlaying ? "▶ " : "⏸ ") + root.player.trackTitle) : ""
                        color: Theme.accent2
                        font.family: Theme.font
                        font.pixelSize: 13
                        elide: Text.ElideRight
                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                            onClicked: mouse => {
                                if (mouse.button === Qt.MiddleButton) {
                                    if (root.player && root.player.canTogglePlaying) root.player.togglePlaying();
                                } else {
                                    UiState.mediaOpen = !UiState.mediaOpen;
                                }
                            }
                        }
                    }

                    Text {
                        text: "RAM " + root.memPercent + "%"
                        color: root.memPercent > 85 ? Theme.urgent : Theme.fg
                        font.family: Theme.font
                        font.pixelSize: 13
                    }

                    Text {
                        text: "VOL " + root.volumeText()
                        color: (root.sink && root.sink.audio && root.sink.audio.muted) ? Theme.dim : Theme.accent
                        font.family: Theme.font
                        font.pixelSize: 13

                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                if (root.sink && root.sink.audio)
                                    root.sink.audio.muted = !root.sink.audio.muted;
                            }
                            onWheel: wheel => {
                                if (!root.sink || !root.sink.audio) return;
                                const step = wheel.angleDelta.y > 0 ? 0.05 : -0.05;
                                root.sink.audio.volume = Math.max(0, Math.min(1.0, root.sink.audio.volume + step));
                            }
                        }
                    }

                    Row {
                        spacing: 8
                        Layout.alignment: Qt.AlignVCenter

                        Repeater {
                            model: SystemTray.items

                            Item {
                                id: trayItem
                                required property var modelData
                                width: 18
                                height: 18

                                Image {
                                    anchors.fill: parent
                                    source: trayItem.modelData.icon
                                    sourceSize.width: 36
                                    sourceSize.height: 36
                                    fillMode: Image.PreserveAspectFit
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    onClicked: mouse => {
                                        if (mouse.button === Qt.LeftButton && !trayItem.modelData.onlyMenu) {
                                            trayItem.modelData.activate();
                                        } else if (trayItem.modelData.hasMenu) {
                                            const p = trayItem.mapToItem(null, 0, trayItem.height + 6);
                                            trayItem.modelData.display(bar, p.x, p.y);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
