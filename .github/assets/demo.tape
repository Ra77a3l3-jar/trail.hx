# VHS tape for trail.hx — https://github.com/charmbracelet/vhs
# Run with: vhs demo.tape
#
# Uses ~/Dev/ziglings as the target project: since this session has launched
# Helix inside it repeatedly, it's already the most-recently-tracked entry in
# trail's own recent-projects list.
#
# Ctrl+x (remove project) mutates trail's real persisted recent-projects
# file, not a throwaway sandbox — so after demonstrating it, the hidden
# teardown briefly relaunches Helix inside ziglings just to re-trigger
# trail's own tracking hook and restore it to the top of the list.
#
# Keybind read from ~/.config/helix/init.scm: (space (p ":trail-open")).

Require hx

Output "/home/raffaele/Dev/plugins/demos/trail-demo-catpp.gif"

Set Shell "bash"
Set Theme "VibrantInk"
Set FontFamily "JetBrainsMono Nerd Font Mono"
Set FontSize 18
Set Width 1600
Set Height 1000
Set Padding 20
Set TypingSpeed 60ms
Set WindowBar Colorful

Hide
Type "cd ~/Dev/ziglings && hx README.md"
Enter
Sleep 1.5s
Type ":theme catppuccin_mocha_transparent"
Enter
Sleep 1s
Show

Sleep 500ms

# open the picker — projects pane is focused first, files pane updates live
# to whatever project is highlighted
Space
Type "p"
Sleep 1s

Down@300ms 2
Sleep 400ms
Up@300ms 1
Sleep 400ms

# filter projects down to ziglings, clear it, then filter again
Type@80ms "zig"
Sleep 700ms
Backspace@60ms 3
Sleep 500ms
Type@80ms "zig"
Sleep 700ms

# select it: cds into the project, focus auto-switches to the files pane
Enter
Sleep 800ms

# search a nested file (proves the file search covers the whole tree)
Type@80ms "hello"
Sleep 700ms
Backspace@60ms 5
Sleep 400ms
Type@80ms "readme"
Sleep 700ms

# Tab manually toggles focus between panes without losing either query
Tab
Sleep 500ms
Tab
Sleep 500ms

# open the match — closes the picker
Enter
Sleep 800ms

# reopen to demonstrate removing a project from the recent list
Space
Type "p"
Sleep 800ms
Ctrl+x
Sleep 900ms
Escape
Sleep 500ms

Hide
Type ":q!"
Enter
Sleep 800ms
# re-track ziglings so this demo doesn't permanently alter the real list
Type "cd ~/Dev/ziglings && hx README.md"
Enter
Sleep 1.5s
Type ":q!"
Enter
Sleep 500ms
