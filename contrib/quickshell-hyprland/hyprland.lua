-- Append this to ~/.config/hypr/hyprland.lua (Hyprland >= 0.55 Lua config).
-- Syntax taken from the Hyprland wiki / published Lua configs; not yet run on your machine.

-- start the shell and the clipboard history watchers
hl.on("hyprland.start", function()
  hl.exec_cmd("quickshell")
  hl.exec_cmd("wl-paste --type text --watch cliphist store")
  hl.exec_cmd("wl-paste --type image --watch cliphist store")
end)

-- keybinds
hl.bind("SUPER + SPACE", hl.dsp.exec_cmd("qs ipc call launcher toggle"))
hl.bind("SUPER + V",     hl.dsp.exec_cmd("qs ipc call clipboard toggle"))
hl.bind("SUPER + M",     hl.dsp.exec_cmd("qs ipc call media toggle"))
hl.bind("Print",         hl.dsp.exec_cmd("qs-shot area"))
hl.bind("SHIFT + Print", hl.dsp.exec_cmd("qs-shot full"))
hl.bind("SUPER + SHIFT + S", hl.dsp.exec_cmd("qs-shot area"))
hl.bind("SUPER + SHIFT + W", hl.dsp.exec_cmd("qs-theme next ~/Pictures/Wallpapers"))

-- volume / media keys (skip these if your config already has them)
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),      { locked = true, repeating = true })
hl.bind("XF86AudioMute",        hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),     { locked = true })
hl.bind("XF86AudioPlay",        hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioNext",        hl.dsp.exec_cmd("playerctl next"),       { locked = true })
hl.bind("XF86AudioPrev",        hl.dsp.exec_cmd("playerctl previous"),   { locked = true })

-- glass blur on the shell's panels (the bar's namespace is "quickshell")
hl.layer_rule({
  match = { namespace = "^(quickshell|qs-launcher|qs-media|qs-notifications|qs-osd)$" },
  name = "qs-glass",
  blur = true,
  ignore_alpha = 0.2,
})
