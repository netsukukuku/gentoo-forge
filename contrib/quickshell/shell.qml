import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Services.SystemTray

// Lavender / black floating bar for niri.
Scope {
    id: root

    // ---- palette ----
    readonly property color cBg:      "#d90b0b10"   // #AARRGGBB, ~85% opaque near-black
    readonly property color cEdge:    "#33c4bee6"
    readonly property color cAccent:  "#c4bee6"     // lavender
    readonly property color cText:    "#e6e3f5"
    readonly property color cDim:     "#6d6a8a"
    readonly property string fontName: "monospace"

    // ---- state ----
    property var workspaces: []
    property string windowTitle: ""
    property int memPercent: 0

    // ---- niri: workspaces + focused window, refreshed on every niri event ----
    Process {
        id: wsProc
        command: ["niri", "msg", "--json", "workspaces"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.workspaces = JSON.parse(this.text); } catch (e) { }
            }
        }
    }

    Process {
        id: winProc
        command: ["niri", "msg", "--json", "focused-window"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const w = JSON.parse(this.text);
                    root.windowTitle = (w && w.title) ? w.title : "";
                } catch (e) {
                    root.windowTitle = "";
                }
            }
        }
    }

    Timer {
        id: refresh
        interval: 60
        onTriggered: {
            wsProc.running = true;
            winProc.running = true;
        }
    }

    Process {
        command: ["niri", "msg", "--json", "event-stream"]
        running: true
        stdout: SplitParser {
            onRead: refresh.restart()
        }
    }

    // ---- memory usage ----
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

    // ---- audio ----
    readonly property var sink: Pipewire.defaultAudioSink
    PwObjectTracker { objects: [root.sink] }

    function volumeText() {
        if (!root.sink || !root.sink.audio) return "--";
        return root.sink.audio.muted ? "muted" : Math.round(root.sink.audio.volume * 100) + "%";
    }

    SystemClock {
        id: clock
        precision: SystemClock.Seconds
    }

    // ---- one bar per monitor ----
    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: bar
            required property var modelData
            screen: modelData

            readonly property string outName: modelData.name

            anchors {
                top: true
                left: true
                right: true
            }
            margins {
                top: 6
                left: 10
                right: 10
            }
            implicitHeight: 38
            color: "transparent"

            Rectangle {
                anchors.fill: parent
                radius: 14
                color: root.cBg
                border.width: 1
                border.color: root.cEdge

                // ---------- left: workspaces + window title ----------
                RowLayout {
                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 14

                    Row {
                        spacing: 6
                        Layout.alignment: Qt.AlignVCenter

                        Repeater {
                            model: root.workspaces
                                .filter(w => w.output === bar.outName)
                                .sort((a, b) => a.idx - b.idx)

                            Rectangle {
                                width: modelData.is_active ? 28 : 10
                                height: 10
                                radius: 5
                                color: modelData.is_active ? root.cAccent : root.cDim
                                anchors.verticalCenter: parent.verticalCenter

                                Behavior on width { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -4
                                    onClicked: Quickshell.execDetached(["niri", "msg", "action", "focus-workspace", String(modelData.idx)])
                                }
                            }
                        }
                    }

                    Text {
                        Layout.maximumWidth: 380
                        text: root.windowTitle
                        color: root.cDim
                        font.family: root.fontName
                        font.pixelSize: 13
                        elide: Text.ElideRight
                    }
                }

                // ---------- center: clock ----------
                Text {
                    anchors.centerIn: parent
                    text: Qt.formatDateTime(clock.date, "ddd d MMM  ·  hh:mm")
                    color: root.cText
                    font.family: root.fontName
                    font.pixelSize: 14
                    font.bold: true
                }

                // ---------- right: ram, volume, tray ----------
                RowLayout {
                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 16

                    Text {
                        text: "RAM " + root.memPercent + "%"
                        color: root.memPercent > 85 ? "#f08aa9" : root.cText
                        font.family: root.fontName
                        font.pixelSize: 13
                    }

                    Text {
                        id: volLabel
                        text: "VOL " + root.volumeText()
                        color: (root.sink && root.sink.audio && root.sink.audio.muted) ? root.cDim : root.cAccent
                        font.family: root.fontName
                        font.pixelSize: 13

                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton
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
                                width: 18
                                height: 18

                                Image {
                                    anchors.fill: parent
                                    source: modelData.icon
                                    sourceSize.width: 36
                                    sourceSize.height: 36
                                    fillMode: Image.PreserveAspectFit
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    onClicked: mouse => {
                                        if (mouse.button === Qt.LeftButton && !modelData.onlyMenu) {
                                            modelData.activate();
                                        } else if (modelData.hasMenu) {
                                            const p = parent.mapToItem(null, 0, parent.height + 6);
                                            modelData.display(bar, p.x, p.y);
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
