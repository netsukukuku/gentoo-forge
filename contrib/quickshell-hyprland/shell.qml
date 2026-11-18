//@ pragma UseQApplication
import QtQuick
import Quickshell
import Quickshell.Io

// Hyprland shell: bar, launcher, clipboard picker, media panel, notifications,
// volume OSD and wallpaper. Colors follow the wallpaper (see bin/qs-theme).
// There is intentionally no lock screen.
ShellRoot {
    Wallpaper {}
    Bar {}
    Launcher {}
    MediaPanel {}
    Notifications {}
    VolumeOsd {}

    IpcHandler {
        target: "launcher"
        function toggle(): void {
            UiState.clipboardOpen = false;
            UiState.launcherOpen = !UiState.launcherOpen;
        }
    }

    IpcHandler {
        target: "clipboard"
        function toggle(): void {
            UiState.launcherOpen = false;
            UiState.clipboardOpen = !UiState.clipboardOpen;
        }
    }

    IpcHandler {
        target: "media"
        function toggle(): void { UiState.mediaOpen = !UiState.mediaOpen; }
    }
}
