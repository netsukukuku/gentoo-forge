# Quickshell for Hyprland

Glass bar, app launcher, clipboard history, now-playing panel, notifications, volume pill and
a wallpaper whose colors drive the whole shell. No lock screen on purpose.

**Status:** written against the Quickshell QML API and syntax-checked, but not yet run on a real
Hyprland session. Expect to fix small things on first launch (run `quickshell` in a terminal and
read its output).

## Install (Gentoo)

    sudo emerge --ask gui-apps/quickshell      # GURU overlay; check `equery uses quickshell` for the hyprland and pipewire flags
    sudo emerge --ask gui-apps/grim gui-apps/slurp gui-apps/wl-clipboard app-misc/cliphist media-gfx/imagemagick media-sound/playerctl

    mkdir -p ~/.config/quickshell ~/.local/bin ~/Pictures/Wallpapers
    cp -r contrib/quickshell-hyprland/*.qml ~/.config/quickshell/
    cp contrib/quickshell-hyprland/bin/qs-* ~/.local/bin/        # make sure ~/.local/bin is in PATH
    cat contrib/quickshell-hyprland/hyprland.conf               # paste into ~/.config/hypr/hyprland.conf

    qs-theme set ~/Pictures/Wallpapers/your-wallpaper.png        # generates the colors
    quickshell                                                   # or just log into Hyprland again

Notifications: stop `mako`/`dunst` if running, the shell is the notification daemon.

## Keys (from hyprland.conf)

| Key | Action |
|---|---|
| Super+Space | launcher |
| Super+V | clipboard history |
| Super+M | media panel |
| Print / Super+Shift+S | area screenshot (saved + copied) |
| Shift+Print | full screenshot |
| Super+Shift+W | next wallpaper from ~/Pictures/Wallpapers (re-colors everything) |

`qs-theme glass 55` makes the panels more see-through (20-100).
