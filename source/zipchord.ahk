﻿#NoEnv
#SingleInstance Force
#MaxThreadsPerHotkey 10
SetWorkingDir %A_ScriptDir%

; ZipChord by Pavel Soukenik
; Licensed under GPL-3.0
; See https://github.com/psoukie/zipchord/
global version = "1.9.5"

; ------------------
;; Global Variables
; ------------------

; Locale settings (keyboard and language settings) with default values (US English)
Class localeClass {
    all := "``1234567890-=qwertyuiop[]\asdfghjkl;'zxcvbnm,./" ; ; keys tracked by ZipChord for typing and chords; should be all keys that produce a character when pressed
    remove_space_plain := ".,;'-/=\]"  ; unmodified keys that delete any smart space before them.
    remove_space_shift := "1/;'-.235678]=\"  ; keys combined with Shift that delete any smart space before them.
    space_after_plain := ".,;"  ; unmodified keys that should be followed by smart space
    space_after_shift := "1/;" ; keys that -- when modified by Shift -- should be followed by smart space
    capitalizing_plain := "." ; unmodified keys that capitalize the text that folows them
    capitalizing_shift := "1/"  ; keys that -- when modified by Shift --  capitalize the text that folows them
    other_plain := "[" ; unmodified keys for other punctuation
    other_shift := "9,["  ; other punctuation keys when modified by Shift
}
; stores current locale information 
keys := New localeClass

; capitalization constants
global CAP_OFF = 1 ; no auto-capitalization,
global CAP_CHORDS = 2 ; auto-capitalize chords only
global CAP_ALL = 3 ; auto-capitalize all typing

; smart spacing constants
global SPACE_BEFORE_CHORD := 1
global SPACE_AFTER_CHORD := 2
global SPACE_PUNCTUATION := 4

; Chord recognition constants
global CHORD_DELETE_UNRECOGNIZED := 1 ; Delete typing that triggers chords that are not in dictionary?
global CHORD_ALLOW_SHIFT := 2  ; Allow Shift in combination with at least two other keys to form unique chords?
global CHORD_RESTRICT := 4      ; Disallow chords (except for suffixes) if the chord isn't separated from typing by a space, interruption, or defined punctuation "opener" 

; Current application settings
Class settingsClass {
    chords_enabled := 1 ; maps to UI_chords_enabled for whether the chord recognition is enabled
    locale := "English US"
    capitalization := CAP_CHORDS
    spacing := SPACE_BEFORE_CHORD | SPACE_AFTER_CHORD | SPACE_PUNCTUATION  ; smart spacing options 
    chording := 0 ; Chord recognition options
    chord_file := "" ; file name for the chord dictionary
    input_delay := 0
    output_delay := 0
    debugging := false
}
; stores current settings
global settings := New settingsClass

; Processing input and output 

global chords := {} ; holds pairs of chord key combinations and their full texts
chord_buffer := ""   ; stores the sequence of simultanously pressed keys
chord_candidate := ""    ; chord candidate which qualifies for chord
global start := 0 ; tracks start time of two keys pressed at once

; constants and variable to track the difference between key presses and output (because of smart spaces and punctuation)
global DIF_NONE := 0
global DIF_EXTRA_SPACE := 1
global DIF_REMOVED_SMART_SPACE := 2
global DIF_IGNORED_SPACE := 4
global difference := DIF_NONE   ; tracks the difference between keys pressed and output (because of smart spaces and punctuation)
global final_difference := DIF_NONE

; Characteristics of last output: constants and variables
global OUT_CHARACTER := 1     ; output is a character
global OUT_SPACE := 2         ; output was a space
global OUT_PUNCTUATION := 4   ; output was a punctuation
global OUT_AUTOMATIC := 8     ; output was automated (i.e. added by ZipChord, instead of manual entry). In combination with OUT_CHARACTER, this means a chord was output, in combination with OUT_SPACE, it means a smart space.
global OUT_CAPITALIZE := 16   ; output requires capitalization of what follows
global OUT_PREFIX := 32       ; output is a prefix (or opener punctuation) and doesn't need space in next chord (and can be followed by a chard in restricted mode)
global OUT_SPACE_AFTER := 64  ; output is a punctuation that needs a space after it
global OUT_INTERRUPTED := 128   ; output is unknown or it was interrupted by moving the cursor using cursor keys, mouse click etc.
; Because some of the typing is dynamically changed after it occurs, we need to distinguish between the last keyboard output which is already finalized, and the last entry which can still be subject to modifications.
global fixed_output := OUT_INTERRUPTED ; fixed output that preceded any typing currently being processed 
global last_output := OUT_INTERRUPTED  ; last output in the current typing sequence that could be in flux. It is set to fixed_input when there's no such output.
; new_output local variable is used to track the current key / output

global debug := New DebugClass

Initialize()
Return   ; To prevent execution of any of the following code, except for the always-on keyboard shortcuts below:

; -------------------
;; Permanent Hotkeys
; -------------------

; An always enabled Ctrl+Shift+C hotkey held long to open ZipChord menu.
~^+c::
    Sleep 300
    if GetKeyState("c","P")
        ShowMainDialog()
    Return

; An always-on Ctrl+C hotkey held long to add a new chord to the dictionary.
~^c::
    Sleep 300
    if GetKeyState("c","P")
        AddChord()
    Return

; The rest of the code from here on behaves like in normal programming languages: It is not executed unless called from somewhere else in the code, or triggered by dynamically defined hotkeys.

; ---------------------------
;; Initilization and Wiring
; ---------------------------

Initialize() {
    FileInstall, ..\dictionaries\chords-en-qwerty.txt, % "chords-en-starting.txt"
    ReadSettings()
    BuildMainDialog()
    BuildLocaleDialog()
    LoadChords(settings.chord_file)
    WireHotkeys("On")
    ShowMainDialog()
}

; WireHotKeys(["On"|"Off"]): Creates or releases hotkeys for tracking typing and chords
WireHotkeys(state) {
    global keys
    interrupts := "Del|Ins|Home|End|PgUp|PgDn|Up|Down|Left|Right|LButton|RButton|BS|Tab" ; keys that interrupt the typing flow
    Loop Parse, % keys.all
    {
        Hotkey, % "~" A_LoopField, KeyDown, %state% UseErrorLevel
        If ErrorLevel {
            MsgBox, , ZipChord, The current keyboard layout does not include the unmodified key '%A_LoopField%'. ZipChord will not be able to recognize this key.`n`nEither change your keyboard layout, or change the custom keyboard layout for your current ZipChord dictionary.
            Break
        }
        Hotkey, % "~+" A_LoopField, KeyDown, %state%
        Hotkey, % "~" A_LoopField " Up", KeyUp, %state%
        Hotkey, % "~+" A_LoopField " Up", KeyUp, %state%
    }
    Hotkey, % "~Space", KeyDown, %state%
    Hotkey, % "~+Space", KeyDown, %state%
    Hotkey, % "~Space Up", KeyUp, %state%
    Loop Parse, % interrupts , |
    {
        Hotkey, % "~" A_LoopField, Interrupt, %state%
        Hotkey, % "~^" A_LoopField, Interrupt, %state%
    }
    Hotkey, % "~Enter", Enter_key, %state%
}

; Main code. This is where the magic happens. Tracking keys as they are pressed down and released:

; ------------------
;; Chord Detection
; ------------------

KeyDown:
    key := StrReplace(A_ThisHotkey, "Space", " ")
    debug.Log("KeyDown " key)
    ; First, we differentiate if the key was pressed while holding Shift, and store it under 'key':
    if ( StrLen(A_ThisHotkey)>2 && SubStr(A_ThisHotkey, 2, 1) == "+" ) {
        shifted := true
        key := SubStr(key, 3, 1)
    } else {
        shifted := false
        key := SubStr(key, 2, 1)
    }

    if (chord_candidate != "") {  ; if there is an existing potential chord that is being interrupted with additional key presses
        start := 0
        chord_candidate := ""
    }

    chord_buffer .= key ; adds to the keys pressed so far (the buffer is emptied upon each key-up)
    ; and when we have two keys, we start the clock for chord recognition sensitivity:
    if (StrLen(chord_buffer)==2) {
        start := A_TickCount 
        if (shifted)
            chord_buffer .= "+"  ; hack to communicate Shift was pressed
        debug.Log("Two keys in chord buffer.")
    }

    if (!start)
        difference := DIF_NONE   ; a chord is not being formed, so we reset the diff between keys and output.

    ; Now, we carry over capitalization and categorize the new output on the fly as needed:
    new_output := OUT_CHARACTER | (last_output & OUT_CAPITALIZE)

    ; if the key pressed is a space
    if (key==" ") {
        if ( (last_output & OUT_SPACE) && (last_output & OUT_AUTOMATIC) ) {  ; i.e. if last output is a smart space
            DelayOutput()
            SendInput {Backspace} ; delete any smart-space
            difference |= DIF_IGNORED_SPACE  ; and account for the output being one character shorter than the chord
        }
        new_output := new_output & ~OUT_AUTOMATIC & ~OUT_CHARACTER | OUT_SPACE
    }

    ; if it's punctuation which doesn't do anything but separates words
    if ( (! shifted && InStr(keys.other_plain, key)) || (shifted && InStr(keys.other_shift, key)) )
        new_output := new_output & ~OUT_CHARACTER | OUT_PUNCTUATION

    ; if it's punctuation that removes a smart space before it 
    if ( (! shifted && InStr(keys.remove_space_plain, key)) || (shifted && InStr(keys.remove_space_shift, key)) ) {
        new_output := new_output & ~OUT_CHARACTER | OUT_PUNCTUATION
        if ( (last_output & OUT_SPACE) && (last_output & OUT_AUTOMATIC) ) {  ; i.e. a smart space
            DelayOutput()
            SendInput {Backspace}{Backspace}
            difference |= DIF_REMOVED_SMART_SPACE
            if (shifted)
                SendInput +%key%
            else
                SendInput %key%
        }
    }

    ; if it's punctuation that should be followed by a space
     if ( (!shifted && InStr(keys.space_after_plain, key)) || (shifted && InStr(keys.space_after_shift, key)) ) {
        new_output := new_output & ~OUT_CHARACTER | OUT_PUNCTUATION
        ; if smart spacing for punctuation is enabled, insert a smart space
        if ( settings.spacing & SPACE_PUNCTUATION ) {
            DelayOutput()
            SendInput {Space}
            difference |= DIF_EXTRA_SPACE
            new_output |= OUT_SPACE | OUT_AUTOMATIC
        } else {
            new_output |= OUT_SPACE_AFTER ; we might need to add a space before a chord.
        }
    }

    ; if the user had ben manually typing a word and completed it (which we know because some non-letter was just typed), we reset the auto-capitalization so we don't capitalize the following word 
    if ( (fixed_output & OUT_CHARACTER) && ! (new_output & OUT_CHARACTER) )
         new_output &= ~OUT_CAPITALIZE

    ; set 'uppercase' for punctuation that capitalizes following text 
    if ( (! shifted && InStr(keys.capitalizing_plain, key)) || (shifted && InStr(keys.capitalizing_shift, key)) )
        new_output |= OUT_CAPITALIZE

    ; if it's neither, it should be a regural character, and it might need capitalization
    if ( !(new_output & OUT_PUNCTUATION) && !(new_output & OUT_SPACE) ) {
        if (shifted)
            new_output := new_output & ~OUT_CAPITALIZE ; manually capitalized, so the flag get turned off
        else
            if ( settings.capitalization==CAP_ALL && (! shifted) && (last_output & OUT_CAPITALIZE) ) {
                DelayOutput()
                cap_key := RegExReplace(key, "(.*)", "$U1")
                SendInput % "{Backspace}{Text}" RegExReplace(key, "(.*)", "$U1") ; deletes the character and sends its uppercase version. Uses {Text} because otherwise, Unicode extended characters could not be upper-cased correctly
                new_output := new_output & ~OUT_CAPITALIZE  ; automatically capitalized, and the flag gets turned off
            }
    }

    last_output := new_output
Return

KeyUp:
    Critical
    debug.Log("KeyUp")
    ; if at least two keys were held at the same time for long enough, let's save our candidate chord and exit
    if ( start && chord_candidate == "" && (A_TickCount - start > settings.input_delay) ) {
        chord_candidate := chord_buffer
        final_difference := difference
        chord_buffer := ""
        start := 0
        debug.Log("/KeyUp-chord")
        Critical Off
        Return
    }
    chord_buffer := ""
    start := 0
    ; when another key is lifted (so we could check for false triggers in rolls) we test and expand the chord
    if (chord_candidate != "") {
        if (InStr(chord_candidate, "+")) {
            ;if Shift is not allowed as a chord key, we just capitalize the chord.
            if (!(settings.chording & CHORD_ALLOW_SHIFT)) {
            fixed_output |= OUT_CAPITALIZE
            chord_candidate := StrReplace(chord_candidate, "+")
            }
        }
        chord := Arrange(chord_candidate)
        if (chords.HasKey(chord)) {
            expanded := chords[chord] ; store the expanded text
            debug.Log("Chord for:" expanded)
            ; detect and adjust expansion for suffixes and prefixes
            if (SubStr(expanded, 1, 1) == "~") {
                expanded := SubStr(expanded, 2)
                suffix := true
            } else {
                suffix := false
            }
             if (SubStr(expanded, StrLen(expanded), 1) == "~") {
                expanded := SubStr(expanded, 1, StrLen(expanded)-1)
                prefix := true
            } else {
                prefix := false
            }
            ; if we aren't restricted, we print a chord
            if (suffix || IsUnrestricted()) {
                DelayOutput()
                debug.Log("OUTPUTTING")
                RemoveRawChord(chord)
                OpeningSpace(suffix)
                if (InStr(expanded, "{")) {
                    ; we send any expanded text that includes { as straight directives:
                    SendInput % expanded
                } else {
                    ; and there rest as {Text} that gets capitalized if needed:
                    if ( (fixed_output & OUT_CAPITALIZE) && (settings.capitalization != CAP_OFF) )
                        SendInput % "{Text}" RegExReplace(expanded, "(^.)", "$U1")
                    else
                        SendInput % "{Text}" expanded
                }
                last_output := OUT_CHARACTER | OUT_AUTOMATIC  ; i.e. a chord (automated typing)
                ; ending smart space
                if (prefix) {
                    last_output |= OUT_PREFIX
                } else if (settings.spacing & SPACE_AFTER_CHORD) {
                    SendInput {Space}
                    last_output := OUT_SPACE | OUT_AUTOMATIC
                }
            }
            else {
                ; output was restricted
                fixed_output := last_output
                chord_candidate := ""
                debug.Log("RESTRICTED")
            }
            ; Here, we are not deleting the keys because we assume it was rolled typing.
        }
        else {
            if (settings.chording & CHORD_DELETE_UNRECOGNIZED)
                RemoveRawChord(chord)
        }
        chord_candidate := ""
    }
    fixed_output := last_output ; and this last output is also the last fixed output.
    debug.Log("/KeyUp-fixed")
    Critical Off
Return

; Helper functions

; Delay output by defined delay
DelayOutput() {
    if (settings.output_delay)
        Sleep settings.output_delay
}

;remove raw chord output
RemoveRawChord(output) {
    adj :=0
    ; we remove any Shift from the chord because that is not a real character
    output := StrReplace(output, "+")
    if (final_difference & DIF_EXTRA_SPACE)
        adj++
    if (final_difference & DIF_IGNORED_SPACE)
        adj--
    adj += StrLen(output)
    SendInput {Backspace %adj%}
    if (final_difference & DIF_REMOVED_SMART_SPACE)
        SendInput {Space}
}

; check we can output chord here
IsUnrestricted() {
    ; If we're in unrestricted mode, we're good
    if (!(settings.chording & CHORD_RESTRICT))
        Return true
    ; If last output was automated (smart space or chord), punctuation, a 'prefix' (which  includes opening punctuation), it was interrupted, or it was a space, we can also go ahead.
    if ( (fixed_output & OUT_AUTOMATIC) || (fixed_output & OUT_PUNCTUATION) || (fixed_output & OUT_PREFIX) || (fixed_output & OUT_INTERRUPTED) || (fixed_output & OUT_SPACE) )
        Return true
    Return false
}

; Handles opening spacing as needed (single-use helper function)
OpeningSpace(attached) {
    ; if there is a smart space, we remove it for suffixes, and we're done
    if ( (fixed_output & OUT_SPACE) && (fixed_output & OUT_AUTOMATIC) ) {
        if (attached)
            SendInput {Backspace}
        Return
    }
    ; if adding smart spaces before is disabled, we are done too
    if (! (settings.spacing & SPACE_BEFORE_CHORD))
        Return
    ; if the last output was punctuation that does not ask for a space, we are done 
    if ( (fixed_output & OUT_PUNCTUATION) && ! (fixed_output & OUT_SPACE_AFTER) )
        Return
    ; and we don't start with a smart space after intrruption, a space, after a prefix, and for suffix
    if (fixed_output & OUT_INTERRUPTED || fixed_output & OUT_SPACE || fixed_output & OUT_PREFIX || attached)
        Return
    ; if we get here, we probably need a space in front of the chord
    SendInput {Space}
}

; Sort the string alphabetically
Arrange(raw) {
    raw := RegExReplace(raw, "(.)", "$1`n")
    Sort raw
    Return StrReplace(raw, "`n")
}

Interrupt:
    last_output := OUT_INTERRUPTED
    fixed_output := last_output
    debug.Write("Interrupted")
Return

Enter_key:
    last_output := OUT_INTERRUPTED | OUT_CAPITALIZE
    fixed_output := last_output
Return


; -----------------
;;  Adding chords 
; -----------------

; Define a new chord for the selected text (or check what it is for existing)
AddChord() {
    newword := Trim(Clipboard)
    if (!StrLen(newword)) {
        MsgBox ,, ZipChord, % "First, select a word you would like to define a chord for, and then press and hold Ctrl+C again."
        Return
    }
    For ch, wd in chords
        if (wd==newword) {
            MsgBox    ,, ZipChord, % Format("The text '{}' already has the chord {:U} associated with it.", wd, ch)
            Return
        }
    Loop {
        InputBox, newch, ZipChord, % Format("Type the individual keys that will make up the chord for '{}'.`n(Only lowercase letters, numbers, space, and other alphanumerical keys without pressing Shift or function keys.)", newword)
        if ErrorLevel
            Return
    } Until RegisterChord("" newch, "" newword, true)  ; force to be interpreted as string
    UpdateDictionaryUI()
}

; RegisterChord(chord, expanded[, true|false])  Adds a new pair of chord and its expanded text to 'chords' and to the dictionary file
RegisterChord(newch, newword, write_to_dictionary := false) {
    newch := Arrange(newch)
    if chords.HasKey(newch) {
        MsgBox ,, ZipChord, % "The chord '" newch "' is already in use for '" chords[newch] "'.`nPlease use a different chord for '" newword "'."
        Return false
    }
    if (StrLen(newch)<2) {
        MsgBox ,, ZipChord, The chord needs to be at least two characters.
        Return false
    }
    if (StrLen(RegExReplace(newch,"(.)(?=.*\1)")) != StrLen(newch)) {
        MsgBox ,, ZipChord, Each key can be entered only once in the same chord.
        Return false
    }
    ObjRawSet(chords, newch, newword)
    if (write_to_dictionary)
        WriteToDictionary(newch, newword, settings.chord_file)
    return true
}

; ------------------
;;      GUI
; ------------------

; variables holding the UI elements and selections

global UI_input_delay
global UI_output_delay
global UI_space_before
global UI_space_after
global UI_space_punctuation
global UI_delete_unrecognized
global UI_capitalization
global UI_allow_shift
global UI_restrict_chords
global UI_chord_file := "none"
global UI_entries := "0"
global UI_chords_enabled := 1
global UI_tab := 0
global UI_locale
global UI_debugging

; Prepare UI
BuildMainDialog() {
    Gui, UI_main_window:New, , ZipChord
    Gui, Font, s10, Segoe UI
    Gui, Margin, 15, 15
    Gui, Add, Tab3, vUI_tab, Dictionary|Detection|Output|About
    Gui, Add, GroupBox, w310 h80, Keyboard and language
    Gui, Add, DropDownList, xp+20 yp+30 Section w150 vUI_locale
    Gui, Add, Button, x+40 w80 gButtonCustomizeLocale, &Customize
    Gui, Add, GroupBox, xs-20 ym+140 w310 h130, Chord dictionary
    Gui, Add, Text, xp+20 yp+30 Section w260 vUI_chord_file Left, [file name]
    Gui, Add, Text, xs+10 y+5 w240 vUI_entries Left, (999 chords)
    Gui, Add, Button, xs Section gBtnSelectChordDictionary w80, &Open
    Gui, Add, Button, gBtnEditChordDictionary ys w80, &Edit
    Gui, Add, Button, gBtnReloadChordDictionary ys w80, &Reload
    Gui, Tab, 2
    Gui, Add, Text, Section, &Detection delay (ms):
    Gui, Add, Edit, vUI_input_delay Right xp+150 w40, 99
    Gui, Add, Checkbox, vUI_restrict_chords xs, &Restrict chords while typing
    Gui, Add, Checkbox, vUI_allow_shift, Allow &Shift in chords 
    Gui, Add, Checkbox, vUI_delete_unrecognized, Delete &mistyped chords
    Gui, Tab, 3
    Gui, Add, GroupBox, w310 h120 Section, Smart spaces
    Gui, Add, Checkbox, vUI_space_before xs+20 ys+30, In &front of chords
    Gui, Add, Checkbox, vUI_space_after xp y+10, &After chords
    Gui, Add, Checkbox, vUI_space_punctuation xp y+10, After &punctuation
    Gui, Add, Text, xs y+30, Auto-&capitalization:
    Gui, Add, DropDownList, vUI_capitalization AltSubmit Right xp+150 w130, Off|For chords only|For all input
    Gui, Add, Text, xs y+m, O&utput delay (ms):
    Gui, Add, Edit, vUI_output_delay Right xp+150 w40, 99
    Gui, Tab
    Gui, Add, Checkbox, gEnableDisableControls vUI_chords_enabled xs Y+m Checked%UI_chords_enabled%, Use &chord detection
    Gui, Add, Button, Default w80 xs+220 yp gButtonOK, OK
    Gui, Tab, 4
    Gui, Add, Text, X+m Y+m, ZipChord`nversion %version%
    Gui, Add, Checkbox, vUI_debugging, Log this session (debugging)
    Gui, Font, Underline cBlue
    Gui, Add, Text, xp Y+m gWebsiteLink, Help and documentation
    Gui, Add, Text, xp Y+m gReleaseLink, Latest releases (check for updates)

    ; Create taskbar tray menu:
    Menu, Tray, Add, Open Settings, ShowMainDialog
    Menu, Tray, Default, Open Settings
    Menu, Tray, Tip, ZipChord
    Menu, Tray, Click, 1
}

ShowMainDialog() {
    debug.Stop()
    Gui, UI_main_window:Default
    GuiControl Text, UI_input_delay, % settings.input_delay
    GuiControl Text, UI_output_delay, % settings.output_delay
    GuiControl , , UI_allow_shift, % (settings.chording & CHORD_ALLOW_SHIFT) ? 1 : 0
    GuiControl , , UI_restrict_chords, % (settings.chording & CHORD_RESTRICT) ? 1 : 0
    GuiControl , , UI_delete_unrecognized, % (settings.chording & CHORD_DELETE_UNRECOGNIZED) ? 1 : 0
    GuiControl , Choose, UI_capitalization, % settings.capitalization
    GuiControl , , UI_space_before, % (settings.spacing & SPACE_BEFORE_CHORD) ? 1 : 0
    GuiControl , , UI_space_after, % (settings.spacing & SPACE_AFTER_CHORD) ? 1 : 0
    GuiControl , , UI_space_punctuation, % (settings.spacing & SPACE_PUNCTUATION) ? 1 : 0
    GuiControl , , UI_chords_enabled, % settings.chords_enabled
    GuiControl , , UI_debugging, 0
    GuiControl, Choose, UI_tab, 1 ; switch to first tab
    UpdateLocaleInMainUI(settings.locale)
    EnableDisableControls()
    Gui, Show,, ZipChord
}

UpdateLocaleInMainUI(selected_loc) {
    IniRead, sections, locales.ini
    Gui, UI_main_window:Default
    GuiControl, , UI_locale, % "|" StrReplace(sections, "`n", "|")
    GuiControl, Choose, UI_locale, % selected_loc
}

; sets UI controls to enabled/disabled to reflect chord recognition setting 
EnableDisableControls() {
    Gui, UI_main_window:Default
    GuiControlGet, checked,, UI_chords_enabled
    GuiControl, Enable%checked%, UI_input_delay
    GuiControl, Enable%checked%, UI_output_delay
    GuiControl, Enable%checked%, UI_restrict_chords
    GuiControl, Enable%checked%, UI_allow_shift
    GuiControl, Enable%checked%, UI_space_before
    GuiControl, Enable%checked%, UI_space_after
    GuiControl, Enable%checked%, UI_space_punctuation
    GuiControl, Enable%checked%, UI_capitalization
    GuiControl, Enable%checked%, UI_delete_unrecognized
}

ButtonOK() {
    Gui, Submit, NoHide
    global keys
    if (SetDelays(UI_input_delay, UI_output_delay) == false)
        Return
    settings.capitalization := UI_capitalization
    RegWrite REG_SZ, HKEY_CURRENT_USER\Software\ZipChord, Capitalization, % settings.capitalization
    settings.spacing := UI_space_before * SPACE_BEFORE_CHORD + UI_space_after * SPACE_AFTER_CHORD + UI_space_punctuation * SPACE_PUNCTUATION
    RegWrite REG_SZ, HKEY_CURRENT_USER\Software\ZipChord, Spacing, % settings.spacing
    settings.chording := UI_delete_unrecognized * CHORD_DELETE_UNRECOGNIZED + UI_allow_shift * CHORD_ALLOW_SHIFT + UI_restrict_chords * CHORD_RESTRICT
    RegWrite REG_SZ, HKEY_CURRENT_USER\Software\ZipChord, Chording, % settings.chording
    settings.locale := UI_locale
    RegWrite REG_SZ, HKEY_CURRENT_USER\Software\ZipChord, Locale, % settings.locale
    ; We always want to rewire hotkeys in case the keys have changed.
    WireHotkeys("Off")
    LoadPropertiesFromIni(keys, UI_locale, "locales.ini")
    if (UI_chords_enabled)
        WireHotkeys("On")
    settings.chords_enabled := UI_chords_enabled
    if (UI_debugging)
        debug.Start()
    CloseMainDialog()
}

UI_main_windowGuiClose() {
    CloseMainDialog()
}
UI_main_windowGuiEscape() {
    CloseMainDialog()
}

CloseMainDialog() {
    Gui, UI_main_window:Default
    Gui, Submit
    static intro := true
    if intro {
        MsgBox ,, ZipChord, % "Select a word and press and hold Ctrl-C to define a chord for it or to see its existing chord.`n`nPress and hold Ctrl-Shift-C to open the ZipChord menu again."
        intro := false
    }
}

WebsiteLink:
Run https://github.com/psoukie/zipchord#readme
Return

ReleaseLink:
Run https://github.com/psoukie/zipchord/releases
Return

; Functions supporting UI

; Update UI with dictionary details
UpdateDictionaryUI() {
    if StrLen(settings.chord_file) > 35
        filestr := "..." SubStr(settings.chord_file, -34)
    else
        filestr := settings.chord_file
    Gui, UI_main_window:Default
    GuiControl Text, UI_chord_file, %filestr%
    entriesstr := "(" chords.Count()
    entriesstr .= (chords.Count()==1) ? " chord)" : " chords)"
    GuiControl Text, UI_entries, %entriesstr%
}

; Run Windows File Selection to open a dictionary
BtnSelectChordDictionary() {
    FileSelectFile dict, , %A_ScriptDir%, Open Dictionary, Text files (*.txt)
    if (dict != "") {
        settings.chord_file := dict
        RegWrite REG_SZ, HKEY_CURRENT_USER\Software\ZipChord, ChordFile, % dict
        LoadChords(dict)
    }
    Return
}

; Edit a dictionary in default editor
BtnEditChordDictionary() {
    Run % settings.chord_file
}

; Reload a (modified) dictionary file; rewires hotkeys because of potential custom keyboard setting
BtnReloadChordDictionary() {
    LoadChords(settings.chord_file)
}

ButtonCustomizeLocale() {
    WireHotkeys("Off")  ; so the user can edit the values without interference
    Gui, Submit, NoHide ; to get the currently selected UI_locale
    ShowLocaleDialog(UI_locale)
}

global UI_locale_window
global UI_loc_name
global UI_loc_all
global UI_loc_space_after_plain
global UI_loc_space_after_shift
global UI_loc_capitalizing_plain
global UI_loc_capitalizing_shift
global UI_loc_remove_space_plain
global UI_loc_remove_space_shift
global UI_loc_other_plain
global UI_loc_other_shift

BuildLocaleDialog() {
    Gui, UI_locale_window:New, , Keyboard and language settings
    Gui, Margin, 15, 15
    Gui, Font, s10, Segoe UI
    Gui, Add, Text, Section, &Locale name
    Gui, Add, DropDownList, w120 vUI_loc_name gChangeLocaleUI
    Gui, Add, Button, y+30 w80 gButtonRenameLocale, &Rename
    Gui, Add, Button, w80 gButtonDeleteLocale, &Delete 
    Gui, Add, Button, w80 gButtonNewLocale, &New
    Gui, Add, Button, y+90 w80 gClose_Locale_Window Default, Close
    Gui, Add, GroupBox, ys h330 w460, Locale settings
    Gui, Add, Text, xp+20 yp+30 Section, &All keys (except dead keys)
    Gui, Font, s10, Consolas
    Gui, Add, Edit, y+10 w420 r1 vUI_loc_all
    Gui, Font, s10 w700, Segoe UI
    Gui, Add, Text, yp+40, Punctuation
    Gui, Add, Text, xs+160 yp, Unmodified keys
    Gui, Add, Text, xs+300 yp, If Shift was pressed
    Gui, Font, w400
    Gui, Add, Text, xs Section, Remove space before
    Gui, Add, Text, y+20, Follow by a space
    Gui, Add, Text, y+20, Capitalize after
    Gui, Add, Text, y+20, Other
    Gui, Add, Button, xs+240 yp+40 w100 gButtonSaveLocale, Save Changes
    Gui, Font, s10, Consolas
    Gui, Add, Edit, xs+160 ys Section w120 r1 vUI_loc_remove_space_plain
    Gui, Add, Edit, xs w120 r1 vUI_loc_space_after_plain
    Gui, Add, Edit, xs w120 r1 vUI_loc_capitalizing_plain
    Gui, Add, Edit, xs w120 r1 vUI_loc_other_plain
    Gui, Add, Edit, xs+140 ys Section w120 r1 vUI_loc_remove_space_shift
    Gui, Add, Edit, xs w120 r1 vUI_loc_space_after_shift
    Gui, Add, Edit, xs w120 r1 vUI_loc_capitalizing_shift
    Gui, Add, Edit, xs w120 r1 vUI_loc_other_shift
}

; Shows the locale dialog with existing locale matching locale_name; or (if set to 'false') the first available locale.  
ShowLocaleDialog(locale_name) {
    Gui, UI_locale_window:Default
    loc_obj := new localeClass
    IniRead, sections, locales.ini
    if (locale_name) {
        LoadPropertiesFromIni(loc_obj, locale_name, "locales.ini")
    } else {
        locales := StrSplit(sections, "`n")
        locale_name := locales[1]
    }
    GuiControl, , UI_loc_name, % "|" StrReplace(sections, "`n", "|")
    GuiControl, Choose, UI_loc_name, % locale_name
    GuiControl, , UI_loc_all, % loc_obj.all
    GuiControl, , UI_loc_remove_space_plain, % loc_obj.remove_space_plain
    GuiControl, , UI_loc_remove_space_shift, % loc_obj.remove_space_shift
    GuiControl, , UI_loc_space_after_plain, % loc_obj.space_after_plain
    GuiControl, , UI_loc_space_after_shift, % loc_obj.space_after_shift
    GuiControl, , UI_loc_capitalizing_plain, % loc_obj.capitalizing_plain
    GuiControl, , UI_loc_capitalizing_shift, % loc_obj.capitalizing_shift
    GuiControl, , UI_loc_other_plain, % loc_obj.other_plain
    GuiControl, , UI_loc_other_shift, % loc_obj.other_shift
    Gui Submit, NoHide
    Gui, Show
}

; when the locale name dropdown changes: 
ChangeLocaleUI() {
    Gui, UI_locale_window:Submit
    ShowLocaleDialog(UI_loc_name)
}

ButtonNewLocale() {
    InputBox, new_name, ZipChord, % "Enter a name for the new keyboard and language setting."
        if ErrorLevel
            Return
    new_loc := New localeClass
    SavePropertiesToIni(new_loc, new_name, "locales.ini")
    ShowLocaleDialog(new_name)
}

ButtonDeleteLocale(){
    IniRead, sections, locales.ini
    If (! InStr(sections, "`n")) {
        MsgBox ,, % "ZipChord", % Format("The setting '{}' is the only setting on the list and cannot be deleted.", UI_loc_name)
        Return
    }
    MsgBox, 4, % "ZipChord", % Format("Do you really want to delete the keyboard and language settings for '{}'?", UI_loc_name)
    IfMsgBox Yes
    {
        IniDelete, locales.ini, % UI_loc_name
        ShowLocaleDialog(false)
    }
}

ButtonRenameLocale() {
    temp_loc := new localeClass
    InputBox, new_name, ZipChord, % Format("Enter a new name for the locale '{}':", UI_loc_name)
    if ErrorLevel
        Return
    IniRead, locale_exists, locales.ini, % locale_name, all
    if (locale_exists == "ERROR") {
        MsgBox, 4, % "ZipChord", % Format("There are already settings under the name '{}'. Do you wish to overwrite them?", new_name)
            IfMsgBox No
                Return
    }
    LoadPropertiesFromIni(temp_loc, UI_loc_name, "locales.ini")
    IniDelete, locales.ini, % UI_loc_name
    SavePropertiesToIni(temp_loc, new_name, "locales.ini")
    ShowLocaleDialog(new_name)
}

UI_locale_windowGuiClose() {
    Close_Locale_Window()
}
UI_locale_windowGuiEscape() {
    Close_Locale_Window()
}

Close_Locale_Window() {
    Gui, UI_locale_window:Submit
    UpdateLocaleInMainUI(global UI_loc_name)
}

ButtonSaveLocale() {
    new_loc := new localeClass
    Gui, UI_locale_window:Submit, NoHide
    new_loc.all := UI_loc_all
    new_loc.space_after_plain := UI_loc_space_after_plain
    new_loc.space_after_shift := UI_loc_space_after_shift
    new_loc.capitalizing_plain := UI_loc_capitalizing_plain
    new_loc.capitalizing_shift := UI_loc_capitalizing_shift
    new_loc.remove_space_plain := UI_loc_remove_space_plain
    new_loc.remove_space_shift := UI_loc_remove_space_shift
    new_loc.other_plain := UI_loc_other_plain
    new_loc.other_shift := UI_loc_other_shift
    SavePropertiesToIni(new_loc, UI_loc_name, "locales.ini")
}

; -----------------------------
;; File and registry functions
; -----------------------------

; Read settings from Windows Registry and locate dictionary file
ReadSettings() {
    default_locale := new localeClass
    RegRead locale, HKEY_CURRENT_USER\Software\ZipChord, Locale
    if ErrorLevel
        locale := "English US"
    RegRead input_delay, HKEY_CURRENT_USER\Software\ZipChord, InputDelay
    if ErrorLevel
        input_delay := 90
    RegRead output_delay, HKEY_CURRENT_USER\Software\ZipChord, OutputDelay
    if ErrorLevel
        output_delay := 0
    RegRead chording, HKEY_CURRENT_USER\Software\ZipChord, Chording
    if ErrorLevel
        chording := 0
    RegRead spacing, HKEY_CURRENT_USER\Software\ZipChord, Spacing
    if ErrorLevel
        spacing := SPACE_BEFORE_CHORD | SPACE_AFTER_CHORD
    RegRead capitalization, HKEY_CURRENT_USER\Software\ZipChord, Capitalization
    if ErrorLevel
        capitalization := CAP_CHORDS
    if (!FileExist("locales.ini"))
       SavePropertiesToIni(default_locale, "English US", "locales.ini")
    RegRead chord_file, HKEY_CURRENT_USER\Software\ZipChord, ChordFile
    if (ErrorLevel || !FileExist(chord_file)) {
        errmsg := ErrorLevel ? "" : Format("The last used dictionary '{}' could not be found.`n`n", chord_file)
        ; If we don't have the dictionary, try opening the first file with chords* structure.
        chord_file := "chords*.txt"
        if FileExist(chord_file) {
            Loop, Files, %chord_file%
                flist .= SubStr(A_LoopFileName, 1, StrLen(A_LoopFileName)-4) "`n"
            Sort flist
            chord_file := SubStr(flist, 1, InStr(flist, "`n")-1) ".txt"
            errmsg .= Format("ZipChord detected the dictionary '{}' and is going to open it.", chord_file)
        }
        else {
            errmsg .= "ZipChord is going to create a new 'chords.txt' dictionary in its own folder."
            chord_file := "chords.txt"
            FileAppend % "This is a dictionary for ZipChord. Define chords and corresponding words in a tab-separated list (one entry per line).`nSee https://github.com/psoukie/zipchord for details.`n`ndm`tdemo", %chord_file%, UTF-8
        }
        chord_file := A_ScriptDir "\" chord_file
        MsgBox ,, ZipChord, %errmsg%
    }
    ; I couldn't find a way to read the values directly into the settings object, so assigning below:
    settings.locale := locale
    settings.input_delay := input_delay
    settings.output_delay := output_delay
    settings.chording := chording
    settings.spacing := spacing
    settings.capitalization := capitalization
    settings.chord_file := chord_file
}

SavePropertiesToIni(object_to_save, ini_section, ini_filename) {
    For key, value in object_to_save
        IniWrite %value%, %ini_filename%, %ini_section%, %key%
}

LoadPropertiesFromIni(object_destination, ini_section, ini_filename) {
    IniRead, properties, %ini_filename%, %ini_section%
    Loop, Parse, properties, `n
    {
        key := SubStr(A_LoopField, 1, InStr(A_LoopField, "=")-1)
        value := SubStr(A_LoopField, InStr(A_LoopField, "=")+1)
        object_destination[key] := value
    }
}

; Save delay settings
SetDelays(new_input_delay, new_output_delay) {
    ; first check we have integers
    if (RegExMatch(new_input_delay,"^\d+$") && RegExMatch(new_output_delay,"^\d+$")) {
            settings.input_delay := new_input_delay + 0
            RegWrite REG_SZ, HKEY_CURRENT_USER\Software\ZipChord, InputDelay, % settings.input_delay
            settings.output_delay := new_output_delay + 0
            RegWrite REG_SZ, HKEY_CURRENT_USER\Software\ZipChord, OutputDelay, % settings.output_delay
            Return true
    }
    MsgBox ,, ZipChord, % "The chord sensitivity needs to be entered as a whole number."
    Return false
}

; Load chords from a dictionary file
LoadChords(file_name) {
    pause_loading := true
    chords := {}
    raw_chords := LoadDictionary(file_name)
    For chord, text in raw_chords
    {
        if (! RegisterChord(chord, text))  {
            if (pause_loading) {
                MsgBox, 4, ZipChord, Would you like to continue loading the dictionary file?`n`nIf Yes, you'll see all errors in the dictionary.`nIf No, the rest of the dictionary will be ignored.
                IfMsgBox Yes
                    pause_loading := false
                else
                    Break
            }
        }
    }
    UpdateDictionaryUI()
}

; Load Tab-separated key-value pairs from a file  
LoadDictionary(file_name) {
    entries := {}
    Loop, Read, % file_name
    {
        pos := InStr(A_LoopReadLine, A_Tab)
        if (pos)
             ObjRawSet(entries, "" SubStr(A_LoopReadLine, 1, pos-1), "" SubStr(A_LoopReadLine, pos+1))  ; the "" forces the value to be treated as text, even if it's something like " 1"
    }
    Return entries
}

WriteToDictionary(shortcut, word, file_name) {
    FileAppend % "`r`n" shortcut "`t" word, % file_name, UTF-8
}

;; Debugging
; -----------

Class DebugClass {
    static debug_file := ""
    Start() {
        global keys
        FileDelete, "debug.txt"
        this.debug_file := FileOpen("debug.txt", "w")
        this.Write("Please copy the actual text output of your typing below:`n`OUTPUT:`n`nZIPCHORD SETTINGS:")
        For key, value in settings
            this.Write(key "=" value)
        this.Write("LOCALE SETTINGS:")
        For key, value in keys
            this.Write(key "=" value)
        this.Write("`nINPUT LOG:`nEvent`tTimestamp`tlast_output`tfixed_output`tchord_buffer`tchord`tstart")       
    }
    Log(output) {
        global chord_buffer
        global chord
        if ( (this.debug_file != "") || (A_Args[1] == "debug-vs") ) {
            output .= "`t" A_TickCount "`t" last_output "`t" fixed_output "`t" chord_buffer "`t" chord "`t" start
            this.Write(output)
        }
    }
    Write(output) {
        if (A_Args[1] == "debug-vs")
            OutputDebug, % output "`n"
        if (this.debug_file != "")
            this.debug_file.Write(output "`n")
    }
    Stop() {
        if (this.debug_file != "") {
            this.debug_file.Close()
            this.debug_file := ""
            Run % "debug.txt"
        }
    }
}