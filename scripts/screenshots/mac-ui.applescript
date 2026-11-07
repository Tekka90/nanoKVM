-- Usage: osascript mac-ui.applescript <command> [arguments]
--   frame <x> <y> <w> <h>  position and size the window
--   screen                 select Screen in the rail
--   settings               select Settings in the rail
--   kvm <n>                open the KVM pop-up and choose the nth item (1 Media, 2 Wake, 3 Network...); 0 only opens the pop-up
on run argv
    set cmd to item 1 of argv
    tell application "System Events" to tell process "NanoKVM"
        set target to missing value
        repeat with w in windows
            if (count of UI elements of w) > 0 then
                set target to w
                exit repeat
            end if
        end repeat
        if target is missing value then error "no NanoKVM window"
        if cmd is "frame" then
            set position of target to {item 2 of argv as integer, item 3 of argv as integer}
            set size of target to {item 4 of argv as integer, item 5 of argv as integer}
        else if cmd is "screen" then
            click button 1 of scroll area 1 of group 1 of target
        else if cmd is "settings" then
            click button 2 of scroll area 1 of group 1 of target
        else if cmd is "kvm" then
            click menu button "KVM" of scroll area 1 of group 1 of target
            delay 0.6
            if (item 2 of argv as integer) is 0 then return
            -- The pop-up exposes no items to System Events, so pick by position: Media = 1 ... Advanced = 6.
            repeat (item 2 of argv as integer) times
                key code 125
                delay 0.15
            end repeat
            key code 36
        end if
    end tell
end run
