import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// App launcher and clipboard history picker (same window, two modes).
// Clipboard mode needs `cliphist` + `wl-clipboard` and the watcher from hyprland.conf.
PanelWindow {
    id: win

    readonly property bool clipMode: UiState.clipboardOpen
    visible: UiState.launcherOpen || UiState.clipboardOpen

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-launcher"
    WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"

    property var clipLines: []

    Process {
        id: clipProc
        command: ["cliphist", "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                win.clipLines = this.text.split("\n").filter(l => l.length > 0).slice(0, 200).map(l => {
                    const tab = l.indexOf("\t");
                    return { id: parseInt(l.substring(0, tab)), label: l.substring(tab + 1) };
                });
            }
        }
    }

    onVisibleChanged: {
        if (!visible) return;
        input.text = "";
        list.currentIndex = 0;
        input.forceActiveFocus();
        if (clipMode) clipProc.running = true;
    }

    // Matching entries, best first.
    readonly property var results: {
        const q = input.text.toLowerCase().trim();
        if (clipMode) {
            return win.clipLines
                .filter(c => q === "" || c.label.toLowerCase().indexOf(q) >= 0)
                .slice(0, 50)
                .map(c => ({ title: c.label, sub: "", clipId: c.id, entry: null }));
        }
        const out = [];
        for (const e of DesktopEntries.applications.values) {
            if (e.noDisplay) continue;
            const name = e.name.toLowerCase();
            let score = -1;
            if (q === "") score = 1000;
            else if (name.startsWith(q)) score = 0;
            else if (name.indexOf(q) >= 0) score = 10;
            else if ((e.genericName || "").toLowerCase().indexOf(q) >= 0) score = 20;
            else if ((e.keywords || []).join(" ").toLowerCase().indexOf(q) >= 0) score = 30;
            if (score >= 0) out.push({ score: score, e: e });
        }
        out.sort((a, b) => a.score - b.score || a.e.name.localeCompare(b.e.name));
        return out.slice(0, 50).map(o => ({ title: o.e.name, sub: o.e.genericName || "", clipId: -1, entry: o.e }));
    }

    function close() { UiState.closeAll(); }

    function activate(i) {
        if (i < 0 || i >= results.length) return;
        const r = results[i];
        if (r.entry) {
            r.entry.execute();
        } else if (r.clipId >= 0) {
            Quickshell.execDetached(["sh", "-c", "cliphist decode " + r.clipId + " | wl-copy"]);
        }
        close();
    }

    // Click outside the panel closes it.
    MouseArea {
        anchors.fill: parent
        onClicked: win.close()
    }

    Rectangle {
        id: panel
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height * 0.18
        width: Math.min(620, parent.width - 40)
        height: Math.min(parent.height * 0.6, 76 + Math.min(win.results.length, 9) * 46)
        radius: 18
        color: Theme.glassBg
        border.width: 1
        border.color: Theme.edge

        MouseArea { anchors.fill: parent }   // swallow clicks

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 14
            spacing: 10

            Rectangle {
                Layout.fillWidth: true
                height: 44
                radius: 12
                color: Theme.glassSurface

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    text: win.clipMode ? "clip" : "run"
                    color: Theme.accent
                    font.family: Theme.font
                    font.pixelSize: 14
                    font.bold: true
                }

                TextInput {
                    id: input
                    anchors.fill: parent
                    anchors.leftMargin: 64
                    anchors.rightMargin: 14
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.fg
                    selectionColor: Theme.accent2
                    font.family: Theme.font
                    font.pixelSize: 16
                    clip: true
                    onTextChanged: list.currentIndex = 0

                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Escape) {
                            win.close(); event.accepted = true;
                        } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_N && (event.modifiers & Qt.ControlModifier))) {
                            list.currentIndex = Math.min(list.count - 1, list.currentIndex + 1); event.accepted = true;
                        } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_P && (event.modifiers & Qt.ControlModifier))) {
                            list.currentIndex = Math.max(0, list.currentIndex - 1); event.accepted = true;
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            win.activate(list.currentIndex); event.accepted = true;
                        }
                    }
                }
            }

            ListView {
                id: list
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: win.results
                currentIndex: 0
                highlightMoveDuration: 90
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                    id: row
                    required property var modelData
                    required property int index
                    width: list.width
                    height: 42
                    radius: 10
                    color: ListView.isCurrentItem ? Theme.glassSurface : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 12

                        Image {
                            visible: row.modelData.entry !== null
                            Layout.preferredWidth: 26
                            Layout.preferredHeight: 26
                            source: row.modelData.entry ? Quickshell.iconPath(row.modelData.entry.icon, "application-x-executable") : ""
                            sourceSize.width: 52
                            sourceSize.height: 52
                            fillMode: Image.PreserveAspectFit
                        }

                        Text {
                            Layout.fillWidth: true
                            text: row.modelData.title
                            color: row.ListView.isCurrentItem ? Theme.accent : Theme.fg
                            font.family: Theme.font
                            font.pixelSize: 14
                            elide: Text.ElideRight
                        }

                        Text {
                            text: row.modelData.sub
                            color: Theme.dim
                            font.family: Theme.font
                            font.pixelSize: 11
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: list.currentIndex = row.index
                        onClicked: win.activate(row.index)
                    }
                }
            }
        }
    }
}
