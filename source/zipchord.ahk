﻿/*

ZipChord

A customizable hybrid keyboard input method that augments regular typing with
chords and shorthands.

Copyright (c) 2021-2023 Pavel Soukenik

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

*/

#NoEnv
#SingleInstance Force
#MaxThreadsPerHotkey 1
#MaxThreadsBuffer On
#KeyHistory 0
ListLines Off
SetKeyDelay -1, -1
CoordMode ToolTip, Screen
OnExit("CloseApp")

#Include version.ahk
if (A_Args[1] == "dev") {
    #Include *i visualizer.ahk
    #Include *i testing.ahk
}

#Include shared.ahk
#Include app_shortcuts.ahk
#Include locale.ahk
#Include dictionaries.ahk

OutputKeys(output) {
    if (A_Args[1] == "dev") {
        test.Log(output)
        if (test.mode == TEST_RUNNING)
            return
    }
    SendInput % output
}

CloseApp() {
    WireHotkeys("Off")
    ExitApp
}

;; Classes and Variables
; -----------------------


; This is used in code dynamically to store complex keys that are defined as "{special_key:*}" or "{special_key=*}" (which can be used in the definition of all keys in the UI). The special_key can be something like "PrintScreen" and the asterisk is the character of how it's interpreted (such as "|").
special_key_map := {}

; affixes constants
global AFFIX_NONE := 0 ; no prefix or suffix
    , AFFIX_PREFIX := 1 ; expansion is a prefix
    , AFFIX_SUFFIX := 2 ; expansion is a suffix

; Settings constants and class

; capitalization constants
global CAP_OFF = 1 ; no auto-capitalization,
    , CAP_CHORDS = 2 ; auto-capitalize chords only
    , CAP_ALL = 3 ; auto-capitalize all typing
; smart spacing constants
global SPACE_BEFORE_CHORD := 1
    , SPACE_AFTER_CHORD := 2
    , SPACE_PUNCTUATION := 4
; Chord recognition constants
global CHORD_DELETE_UNRECOGNIZED := 1 ; Delete typing that triggers chords that are not in dictionary?
    , CHORD_ALLOW_SHIFT := 2  ; Allow Shift in combination with at least two other keys to form unique chords?
    , CHORD_RESTRICT := 4      ; Disallow chords (except for suffixes) if the chord isn't separated from typing by a space, interruption, or defined punctuation "opener" 
    , CHORD_IMMEDIATE_SHORTHANDS := 8   ; Shorthands fire without waiting for space or punctuation 

; Hints preferences and object
global HINT_ON := 1
    , HINT_ALWAYS := 2
    , HINT_NORMAL := 4
    , HINT_RELAXED := 8
    , HINT_OSD := 16
    , HINT_TOOLTIP := 32
global GOLDEN_RATIO := 1.618
global DELAY_AT_START := 2000

Class HintTimingClass {
    ; private variables
    _delay := DELAY_AT_START   ; this varies based on the hint frequency and hints shown
    _next_tick := A_TickCount  ; stores tick time when next hint is allowed
    ; public functions
    HasElapsed() {
        if (settings.hints & HINT_ALWAYS || A_TickCount > this._next_tick)
            return True
        else
            return False
    }
    Extend() {
        if (settings.hints & HINT_ALWAYS)
            Return
        this._delay := Round( this._delay * ( GOLDEN_RATIO**(OrdinalOfHintFrequency(-1) ) ) )
        this._next_tick := A_TickCount + this._delay
    }
    Shorten() {
        if (settings.hints & HINT_ALWAYS)
            Return
        if (settings.hints & HINT_NORMAL)
            this.Reset()
        else
            this._delay := Round( this._delay / 3 )
    }
    Reset() {
        this._delay := DELAY_AT_START
        this._next_tick := A_TickCount + this._delay
    }
}
hint_delay := New HintTimingClass

; Other preferences constants
global PREF_PREVIOUS_INSTALLATION := 1  ; this registry value means that the app has been installed before
    , PREF_SHOW_CLOSING_TIP := 2        ; show tip about re-opening the main dialog and adding chords
    , PREF_FIRST_RUN := 4               ; this value means this is the first run of 2.1.0-beta.2 or higher)

global MODE_CHORDS_ENABLED := 1
    , MODE_SHORTHANDS_ENABLED := 2
    , MODE_ZIPCHORD_ENABLED := 4

; Current application settings
Class settingsClass {
    version := zc_version
    mode := MODE_ZIPCHORD_ENABLED | MODE_CHORDS_ENABLED | MODE_SHORTHANDS_ENABLED
    preferences := PREF_FIRST_RUN | PREF_SHOW_CLOSING_TIP
    locale := "English US"
    hints := HINT_ON | HINT_NORMAL | HINT_OSD
    hint_offset_x := 0
    hint_offset_y := 0
    hint_size := 32
    hint_color := "3BD511"
    capitalization := CAP_CHORDS
    spacing := SPACE_BEFORE_CHORD | SPACE_AFTER_CHORD | SPACE_PUNCTUATION  ; smart spacing options 
    chording := CHORD_RESTRICT ; Chord recognition options
    chord_file := "chords-en-starting.txt" ; file name for the chord dictionary
    shorthand_file := "shorthands-en-starting.txt" ; file name for the shorthand dictionary
    dictionary_dir := A_ScriptDir
    input_delay := 70
    output_delay := 0
    Read() {
        For key in this
        {
            RegRead new_value, HKEY_CURRENT_USER\Software\ZipChord, %key%
            if (! ErrorLevel)
                this[key] := new_value
        }
        this.mode |= MODE_ZIPCHORD_ENABLED ; settings are read at app startup, so we re-enable ZipChord if it was paused when closed 
    }
    Write() {
        For key, value in this
            SaveVarToRegistry(key, value)       
    }
}
global settings := New settingsClass

; Processing input and output 
chord_buffer := ""   ; stores the sequence of simultanously pressed keys
chord_candidate := ""    ; chord candidate which qualifies for chord
shorthand_buffer := ""   ; stores the sequence of uninterrupted typed keys
capitalize_shorthand := false  ; should the shorthand be capitalized
global start := 0 ; tracks start time of two keys pressed at once

; constants to track the difference between key presses and output (because of smart spaces and punctuation)
global DIF_NONE := 0
    , DIF_EXTRA_SPACE := 1
    , DIF_REMOVED_SMART_SPACE := 2
    , DIF_IGNORED_SPACE := 4
    , difference := DIF_NONE   ; tracks the difference between keys pressed and output (because of smart spaces and punctuation)
    , final_difference := DIF_NONE
; Constants for characteristics of last output
global OUT_CHARACTER := 1     ; output is a character
    , OUT_SPACE := 2         ; output was a space
    , OUT_PUNCTUATION := 4   ; output was a punctuation
    , OUT_AUTOMATIC := 8     ; output was automated (i.e. added by ZipChord, instead of manual entry). In combination with OUT_CHARACTER, this means a chord was output, in combination with OUT_SPACE, it means a smart space.
    , OUT_CAPITALIZE := 16   ; output requires capitalization of what follows
    , OUT_PREFIX := 32       ; output is a prefix (or opener punctuation) and doesn't need space in next chord (and can be followed by a chard in restricted mode)
    , OUT_SPACE_AFTER := 64  ; output is a punctuation that needs a space after it
    , OUT_INTERRUPTED := 128   ; output is unknown or it was interrupted by moving the cursor using cursor keys, mouse click etc.
; Because some of the typing is dynamically changed after it occurs, we need to distinguish between the last keyboard output which is already finalized, and the last entry which can still be subject to modifications.
global fixed_output := OUT_INTERRUPTED ; fixed output that preceded any typing currently being processed 
global last_output := OUT_INTERRUPTED  ; last output in the current typing sequence that could be in flux. It is set to fixed_input when there's no such output.
; also "new_output" local variable is used to track the current key / output


; UI string constants
global UI_STR_PAUSE := "&Pause ZipChord"
    , UI_STR_RESUME := "&Resume ZipChord"

Initialize()
Return   ; To prevent execution of any of the following code, except for the always-on keyboard shortcuts below:

; The rest of the code from here on behaves like in normal programming languages: It is not executed unless called from somewhere else in the code, or triggered by dynamically defined hotkeys.

;; Initilization and Wiring
; ---------------------------

Initialize() {
    global app_shortcuts
    ; save license file
    ini.SaveLicense()
    app_shortcuts.Init()
    settings.Read()
    SetWorkingDir, % settings.dictionary_dir
    settings.chord_file := CheckDictionaryFileExists(settings.chord_file, "chord")
    settings.shorthand_file := CheckDictionaryFileExists(settings.shorthand_file, "shorthand")
    settings.Write()
    UI_locale_InitLocale()
    UI_Locale_Load(settings.locale)
    UI_Main_Build()
    Gui, UI_Main:+Disabled ; for loading
    UI_Main_Show()
    UI_Tray_Build()
    UI_Locale_Build()
    UI_OSD_Build()
    chords.Load(settings.chord_file)
    shorthands.Load(settings.shorthand_file)
    UpdateDictionaryUI()
    Gui, UI_Main:-Disabled
    WireHotkeys("On")
}

; WireHotKeys(["On"|"Off"]): Creates or releases hotkeys for tracking typing and chords
WireHotkeys(state) {
    global keys
    global special_key_map
    global app_shortcuts
    interrupts := "Del|Ins|Home|End|PgUp|PgDn|Up|Down|Left|Right|LButton|RButton|BS|Tab" ; keys that interrupt the typing flow
    new_keys := {}
    bypassed_keys := {}
    ParseKeys(keys.all, new_keys, bypassed_keys, special_key_map)
    For _, key in new_keys
    {
        Hotkey, % "~" key, KeyDown, %state% UseErrorLevel
        If ErrorLevel {
            if (state=="On")     
                unrecognized .= key 
            Continue
        }
        Hotkey, % "~+" key, KeyDown, %state%
        Hotkey, % "~" key " Up", KeyUp, %state%
        Hotkey, % "~+" key " Up", KeyUp, %state%
    }
    if (unrecognized) {
        key_str := StrLen(unrecognized)>1 ? "keys" : "key"
        MsgBox, , % "ZipChord", % Format("The current keyboard layout does not match ZipChord's Keyboard and Language settings. ZipChord will not detect the following {}: {}`n`nEither change your keyboard layout, or change the custom keyboard layout for your current ZipChord dictionary.", key_str, unrecognized)
    }
    Hotkey, % "~Space", KeyDown, %state%
    Hotkey, % "~+Space", KeyDown, %state%
    Hotkey, % "~Space Up", KeyUp, %state%
    Hotkey, % "~+Space Up", KeyUp, %state%
    Hotkey, % "~Enter", Enter_key, %state%
    Loop Parse, % interrupts , |
    {
        Hotkey, % "~" A_LoopField, Interrupt, %state%
        Hotkey, % "~^" A_LoopField, Interrupt, %state%
    }
    For _, key in bypassed_keys
    {
        Hotkey, % key, KeyDown, %state% UseErrorLevel
        If ErrorLevel {
            MsgBox, , ZipChord, The current keyboard layout does not include the unmodified key '%key%'. ZipChord will not be able to recognize this key.`n`nEither change your keyboard layout, or change the custom keyboard layout for your current ZipChord dictionary.
            Continue
        }
        Hotkey, % "+" key, KeyDown, %state%
        Hotkey, % key " Up", KeyUp, %state%
        Hotkey, % "+" key " Up", KeyUp, %state%
    }
    app_shortcuts._WireHotkeys("On")
}

; Main code. This is where the magic happens. Tracking keys as they are pressed down and released:

;; Shortcuts Detection
; ---------------------

KeyDown:
    key := A_ThisHotkey
    tick := A_TickCount
    if (A_Args[1] == "dev") {
        if (test.mode == TEST_RUNNING) {
            key := test_key
            tick := test_timestamp
        }
        if (test.mode > TEST_STANDBY) {
            test.Log(key, true)
            test.Log(key)
        }
    }
    key := StrReplace(key, "Space", " ")
    if (SubStr(key, 1, 1) == "~")
        key := SubStr(key, 2)
    ; First, we differentiate if the key was pressed while holding Shift, and store it under 'key':
    if ( StrLen(key)>1 && SubStr(key, 1, 1) == "+" ) {
        shifted := true
        key := SubStr(key, 2)
    } else {
        shifted := false
    }
    if (special_key_map.HasKey(key))
        key := special_key_map[key]
    if (visualizer.IsOn())
        visualizer.Pressed(key)
    if (chord_candidate != "") {  ; if there is an existing potential chord that is being interrupted with additional key presses
        start := 0
        chord_candidate := ""
    }
    if (settings.mode & MODE_CHORDS_ENABLED)
        chord_buffer .= key ; adds to the keys pressed so far (the buffer is emptied upon each key-up)
    ; and when we have two keys, we start the clock for chord recognition sensitivity:
    if (StrLen(chord_buffer)==2) {
        start := tick
        if (shifted)
            chord_buffer .= "+"  ; hack to communicate Shift was pressed
    }
    ; Deal with shorthands and showing hints for defined shortcuts if needed
    if ( (settings.mode & MODE_SHORTHANDS_ENABLED) || (settings.hints & HINT_ON) ) {
        if (last_output & OUT_AUTOMATIC)
            shorthand_buffer := ""
        if (last_output & OUT_INTERRUPTED & ~OUT_AUTOMATIC)
            shorthand_buffer := "<<SHORTHAND_BLOCKED>>"
        if (key == " " || (! shifted && InStr(keys.remove_space_plain . keys.space_after_plain . keys.capitalizing_plain . keys.other_plain, key)) || (shifted && InStr(keys.remove_space_shift . keys.space_after_shift . keys.capitalizing_shift . keys.other_shift, key)) ) {
            if (shorthand_buffer != "") {
                ; first, we show a hint for a shortcut, if applicable
                if (settings.hints & HINT_ON) {
                    chord_hint := ""
                    shorthand_hint := ""
                    if (hint_delay.HasElapsed()) {
                        if (settings.mode & MODE_CHORDS_ENABLED)
                            chord_hint := chords.ReverseLookUp(shorthand_buffer)
                        if (settings.mode & MODE_SHORTHANDS_ENABLED)
                            shorthand_hint := shorthands.ReverseLookUp(shorthand_buffer)
                        chord_hint := chord_hint ? chord_hint : "" 
                        shorthand_hint := shorthand_hint ? shorthand_hint : "" 
                        if (chord_hint || shorthand_hint)
                            ShowHint(shorthand_buffer, chord_hint, shorthand_hint)
                    }
                }
                ; then, we test if it's a shorthand to be expanded 
                if ( (settings.mode & MODE_SHORTHANDS_ENABLED) && expanded := shorthands.LookUp(shorthand_buffer) )
                    OutputShorthand(expanded, key, shifted)
            }
            shorthand_buffer := ""
        } else {    ; i.e. it was not the end of the word
            if (last_output & OUT_AUTOMATIC)
                shorthand_buffer := key
            else
                shorthand_buffer .= key
            ; now, the slightly chaotic immediate mode allowing shorthands triggered as soon as they are completed:
            if ( (settings.chording & CHORD_IMMEDIATE_SHORTHANDS) && (expanded := shorthands.LookUp(shorthand_buffer)) ) {
                OutputShorthand(expanded, key, shifted, true)
                shorthand_buffer := ""
            }
        }
        if ( (settings.capitalization != CAP_OFF) && (StrLen(shorthand_buffer) == 1) ) {
            if ( (last_output & OUT_CAPITALIZE) || shifted )
                capitalize_shorthand := true
            else
                capitalize_shorthand := false
        }
    } ; end of shorhands and hints section

    if (!start)
        difference := DIF_NONE   ; a chord is not being formed, so we reset the diff between keys and output.
    
    ; Now, we carry over capitalization and categorize the new output on the fly as needed:
    new_output := OUT_CHARACTER | (last_output & OUT_CAPITALIZE)
    
    ; if the key pressed is a space
    if (key==" ") {
        if ( (last_output & OUT_SPACE) && (last_output & OUT_AUTOMATIC) ) {  ; i.e. if last output is a smart space
            DelayOutput()
            OutputKeys("{Backspace}") ; delete any smart-space
            difference |= DIF_IGNORED_SPACE  ; and account for the output being one character shorter than the chord
        }
        if (visualizer.IsOn())
            visualizer.NewLine()
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
            OutputKeys("{Backspace 2}")
            difference |= DIF_REMOVED_SMART_SPACE
            if (shifted)
                OutputKeys("+" . key)
            else
                OutputKeys(key)
        }
    }

    ; if it's punctuation that should be followed by a space
     if ( (!shifted && InStr(keys.space_after_plain, key)) || (shifted && InStr(keys.space_after_shift, key)) ) {
        new_output := new_output & ~OUT_CHARACTER | OUT_PUNCTUATION
        ; if smart spacing for punctuation is enabled, insert a smart space
        if ( settings.spacing & SPACE_PUNCTUATION ) {
            DelayOutput()
            OutputKeys("{Space}")
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
                OutputKeys("{Backspace}{Text}" . RegExReplace(key, "(.*)", "$U1")) ; deletes the character and sends its uppercase version. Uses {Text} because otherwise, Unicode extended characters could not be upper-cased correctly
                new_output := new_output & ~OUT_CAPITALIZE  ; automatically capitalized, and the flag gets turned off
            }
    }
    last_output := new_output
Return

KeyUp:
    Critical
    tick_up := A_TickCount
    if (A_Args[1] == "dev") {
        if (test.mode == TEST_RUNNING)
            tick_up := test_timestamp
        if (test.mode > TEST_STANDBY)
            test.Log(A_ThisHotkey, true)
    }

    if (visualizer.IsOn()) {
        key := StrReplace(A_ThisHotkey, "Space", " ")
        if (SubStr(key, 1, 1) == "~")
            key := SubStr(key, 2)
        if ( StrLen(key)>1 && SubStr(key, 1, 1) == "+" ) {
            shifted := true
            key := SubStr(key, 2)
        } else {
            shifted := false
        }
        if (special_key_map.HasKey(key))
            key := special_key_map[key]
        visualizer.Lifted(SubStr(key, 1, 1))
    }

    ; if at least two keys were held at the same time for long enough, let's save our candidate chord and exit
    if ( start && chord_candidate == "" && (tick_up - start > settings.input_delay) ) {
        chord_candidate := chord_buffer
        final_difference := difference
        chord_buffer := ""
        start := 0
        chord_shifted := false
        Critical Off
        Return
    }
    chord_buffer := ""
    start := 0
    ; when another key is lifted (so we could check for false triggers in rolls) we test and expand the chord
    if (chord_candidate != "") {
        if (InStr(chord_candidate, "+")) {
            ;if Shift is not allowed as a chord key, and it's pressed within a chord, we should capitalize the output.
            if (!(settings.chording & CHORD_ALLOW_SHIFT)) {
                chord_shifted := true
                chord_candidate := StrReplace(chord_candidate, "+")
            }
        }
        chord := Arrange(chord_candidate)
        if ( expanded := chords.LookUp(chord)) {
            affixes := ProcessAffixes(expanded)
            ; if we aren't restricted, we print a chord
            if ( (affixes & AFFIX_SUFFIX) || IsUnrestricted()) {
                DelayOutput()
                hint_delay.Shorten()
                RemoveRawChord(chord)
                if (visualizer.IsOn())
                    visualizer.NewLine()
                OpeningSpace(affixes & AFFIX_SUFFIX)
                if (InStr(expanded, "{")) {
                    ; we send any expanded text that includes { as straight directives:
                    OutputKeys(expanded)
                } else {
                    ; and there rest as {Text} that gets capitalized if needed:
                    if ( ((fixed_output & OUT_CAPITALIZE) && (settings.capitalization != CAP_OFF)) || chord_shifted )
                        OutputKeys("{Text}" . RegExReplace(expanded, "(^.)", "$U1"))
                    else
                        OutputKeys("{Text}" . expanded)
                }
                last_output := OUT_CHARACTER | OUT_AUTOMATIC  ; i.e. a chord (automated typing)
                ; ending smart space
                if (affixes & AFFIX_PREFIX) {
                    last_output |= OUT_PREFIX
                } else if (settings.spacing & SPACE_AFTER_CHORD) {
                    OutputKeys("{Space}")
                    last_output := OUT_SPACE | OUT_AUTOMATIC
                }
            }
            else {
                ; output was restricted
                fixed_output := last_output
                chord_candidate := ""
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
    Critical Off
Return

;; Helper functions
; ------------------

; Delay output by defined delay
DelayOutput() {
    if (settings.output_delay)
        Sleep settings.output_delay
}

OutputShorthand(expanded, key, shifted, immediate := false) {
    ; needs to access the following variables
    global capitalize_shorthand
    global shorthand_buffer
    global hint_delay
    global special_key_map
    DelayOutput()
    if (visualizer.IsOn())
        visualizer.NewLine()
    hint_delay.Shorten()
    affixes := ProcessAffixes(expanded)
    For _, k in special_key_map
        shorthand_buffer := StrReplace(shorthand_buffer, k)
    adj := StrLen(shorthand_buffer)
    if (! immediate)
        adj++
    if (affixes & AFFIX_SUFFIX)
        adj++
    OutputKeys("{Backspace " . adj . "}")
    if (capitalize_shorthand)
        OutputKeys("{Text}" . RegExReplace(expanded, "(^.)", "$U1"))
    else
        OutputKeys("{Text}" . expanded)
    if (immediate) {
        if ( (settings.spacing & SPACE_AFTER_CHORD) && !(affixes & AFFIX_PREFIX) ) {
            OutputKeys("{Space}")
            last_output := OUT_SPACE | OUT_AUTOMATIC
        }
    } else {
        if (shifted)
            OutputKeys("+" . key)
        else
            OutputKeys(key)
        if (key == " " && (affixes & AFFIX_PREFIX))
            OutputKeys("{Backspace}")
    }
}

; detect and adjust expansion for suffixes and prefixes
ProcessAffixes(ByRef phrase) {
    affixes := AFFIX_NONE
    if (SubStr(phrase, 1, 1) == "~") {
        phrase := SubStr(phrase, 2)
        affixes |= AFFIX_SUFFIX
    }
    if (SubStr(phrase, StrLen(phrase), 1) == "~") {
        phrase := SubStr(phrase, 1, StrLen(phrase)-1)
        affixes |= AFFIX_PREFIX
    }
    Return affixes
}

;remove raw chord output
RemoveRawChord(output) {
    global special_key_map
    adj :=0
    ; we remove any Shift from the chord because that is not a real character...
    output := StrReplace(output, "+")
    ; ...and any complex keys because these should also not produce any text output
    For _, key in special_key_map
        output := StrReplace(output, key)
    if (final_difference & DIF_EXTRA_SPACE)
        adj++
    if (final_difference & DIF_IGNORED_SPACE)
        adj--
    adj += StrLen(output)
    OutputKeys("{Backspace " . adj . "}")
    if (final_difference & DIF_REMOVED_SMART_SPACE)
        OutputKeys("{Space}")
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
            OutputKeys("{Backspace}")
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
    OutputKeys("{Space}")
}

; Sort the string alphabetically
Arrange(raw) {
    raw := RegExReplace(raw, "(.)", "$1`n")
    Sort raw
    Return StrReplace(raw, "`n")
}

ReplaceWithVariants(text, enclose_latin_letters:=false) {
    new_str := text
    new_str := StrReplace(new_str, "+", Chr(0x21E7))
    new_str := StrReplace(new_str, " ", Chr(0x2423))
    if (enclose_latin_letters) {
        Loop, 26
            new_str := StrReplace(new_str, Chr(96 + A_Index), Chr(0x1F12F + A_Index))
        new_str := RegExReplace(new_str, "(?<=.)(?=.)", " ")
    }
    Return new_str
}

; Translates the raw "old" list of keys into two new lists usable for setting hotkeys ("new" and "bypassed"), returning the special key mapping in the process
ParseKeys(old, ByRef new, ByRef bypassed, ByRef map) {
    new := StrSplit( RegExReplace(old, "\{(.*?)\}", "") )   ; array with all text in between curly braces removed
    segments := StrSplit(old, "{")
    For i, segment in segments {
        if (i > 1) {
            key_definition := StrSplit(segment, "}", , 2)[1] ; the text which was in curly braces
            if (InStr(key_definition, ":")) {
                divider := ":"
                target := new
            } else {
                divider := "="
                target := bypassed
            }
            def_components := StrSplit(key_definition, divider)
            target.push(def_components[1])
            ObjRawSet(map, def_components[1], def_components[2])
        }
    }
} 

Interrupt:
    last_output := OUT_INTERRUPTED
    fixed_output := last_output
    if (A_Args[1] == "dev") {
        if (test.mode > TEST_STANDBY) {
            test.Log("*Interrupt*", true)
            test.Log("*Interrupt*")
        }
    }
Return

Enter_key:
    last_output := OUT_INTERRUPTED | OUT_CAPITALIZE | OUT_AUTOMATIC  ; the automatic flag is there to allow shorthands after Enter 
    fixed_output := last_output
    if (A_Args[1] == "dev") {
        if (test.mode > TEST_STANDBY) {
            test.Log("~Enter", true)
            test.Log("~Enter")
        }
        if (visualizer.IsOn())
            visualizer.NewLine()
    }
Return

;;  Adding shortcuts 
; -------------------

; Define a new shortcut for the selected text (or check what it is for existing)
AddShortcut() {
    ; we try to copy any currently selected text into the Windows clipboard (while backing up and restoring its content)
    clipboard_backup := ClipboardAll
    Clipboard := ""
    Send ^c
    ClipWait, 1
    copied_text := Trim(Clipboard)
    Clipboard := clipboard_backup
    clipboard_backup := ""
    UI_AddShortcut_Show(copied_text)
}

;; Main Dialog UI
; ----------------

; variables holding the UI elements and selections (These should technically all be named UI_Main_xyz but I am using UI_xyz as a shortcut for the main dialog vars)
global UI_input_delay
    , UI_output_delay
    , UI_space_before, UI_space_after, UI_space_punctuation
    , UI_delete_unrecognized
    , UI_hints_show, UI_hint_destination, UI_hint_frequency
    , UI_hint_offset_x, UI_hint_offset_y, UI_hint_size, UI_hint_color 
    , UI_btnCustomize, UI_hint_1, UI_hint_2, UI_hint_3, UI_hint_4, UI_hint_5
    , UI_immediate_shorthands
    , UI_capitalization
    , UI_allow_shift
    , UI_restrict_chords
    , UI_chord_file, UI_shorthand_file
    , UI_chord_entries
    , UI_shorthand_entries
    , UI_zipchord_btnPause, UI_chords_enabled, UI_shorthands_enabled
    , UI_tab
    , UI_selected_locale
    , UI_debugging

; Prepare UI
UI_Main_Build() {
    global zc_version
    Gui, UI_Main:New, , ZipChord
    Gui, Font, s10, Segoe UI
    Gui, Margin, 15, 15
    Gui, Add, Tab3, vUI_tab, % " Dictionaries | Detection | Hints | Output | About "
    Gui, Add, Text, y+20 Section, % "&Keyboard and language"
    Gui, Add, DropDownList, y+10 w150 vUI_selected_locale
    Gui, Add, Button, x+20 w100 gButtonCustomizeLocale, % "C&ustomize"
    Gui, Add, GroupBox, xs y+20 w310 h135 vUI_chord_entries, % "Chord dictionary"
    Gui, Add, Text, xp+20 yp+30 Section vUI_chord_file w270, % "Loading..."
    Gui, Add, Button, xs Section gBtnSelectChordDictionary w80, % "&Open"
    Gui, Add, Button, gBtnEditChordDictionary ys w80, % "&Edit"
    Gui, Add, Button, gBtnReloadChordDictionary ys w80, % "Rel&oad"
    Gui, Add, Checkbox, vUI_chords_enabled xs, % "Use &chords"
    Gui, Add, GroupBox, xs-20 y+30 w310 h135 vUI_shorthand_entries, % "Shorthand dictionary"
    Gui, Add, Text, xp+20 yp+30 Section vUI_shorthand_file w270, % "Loading..."
    Gui, Add, Button, xs Section gBtnSelectShorthandDictionary w80, % "Op&en"
    Gui, Add, Button, gBtnEditShorthandDictionary ys w80, % "Edi&t"
    Gui, Add, Button, gBtnReloadShorthandDictionary ys w80, % "Reloa&d"
    Gui, Add, Checkbox, vUI_shorthands_enabled xs, % "Use &shorthands"
    Gui, Tab, 2
    Gui, Add, GroupBox, y+20 w310 h175, Chords
    Gui, Add, Text, xp+20 yp+30 Section, % "&Detection delay (ms)"
    Gui, Add, Edit, vUI_input_delay Right xp+200 yp-2 w40 Number, 99
    Gui, Add, Checkbox, vUI_restrict_chords xs, % "&Restrict chords while typing"
    Gui, Add, Checkbox, vUI_allow_shift, % "Allow &Shift in chords"
    Gui, Add, Checkbox, vUI_delete_unrecognized, % "Delete &mistyped chords"
    Gui, Add, GroupBox, xs-20 y+40 w310 h70, % "Shorthands"
    Gui, Add, Checkbox, vUI_immediate_shorthands xp+20 yp+30 Section, % "E&xpand shorthands immediately"
    Gui, Tab, 3
    Gui, Add, Checkbox, y+20 vUI_hints_show Section, % "&Show hints for shortcuts in dictionaries"
    Gui, Add, Text, , % "Hint &location"
    Gui, Add, DropDownList, vUI_hint_destination AltSubmit xp+150 w140, % "On-screen display|Tooltips"
    Gui, Add, Text, xs, % "Hints &frequency"
    Gui, Add, DropDownList, vUI_hint_frequency AltSubmit xp+150 w140, % "Always|Normal|Relaxed"
    Gui, Add, Button, gShowHintCustomization vUI_btnCustomize xs w100, % "&Adjust >>"
    Gui, Add, GroupBox, vUI_hint_1 xs y+20 w310 h200 Section, % "Hint customization"
    Gui, Add, Text, vUI_hint_2 xp+20 yp+30 Section, % "Horizontal offset (px)"
    Gui, Add, Text, vUI_hint_3, % "Vertical offset (px)"
    Gui, Add, Text, vUI_hint_4, % "OSD font size (pt)"
    Gui, Add, Text, vUI_hint_5, % "OSD color (hex code)"
    Gui, Add, Edit, vUI_hint_offset_x ys xp+200 w70 Right
    Gui, Add, Edit, vUI_hint_offset_y w70 Right
    Gui, Add, Edit, vUI_hint_size w70 Right Number
    Gui, Add, Edit, vUI_hint_color w70 Right
    Gui, Tab, 4
    Gui, Add, GroupBox, y+20 w310 h120 Section, Smart spaces
    Gui, Add, Checkbox, vUI_space_before xs+20 ys+30, % "In &front of chords"
    Gui, Add, Checkbox, vUI_space_after xp y+10, % "&After chords and shorthands"
    Gui, Add, Checkbox, vUI_space_punctuation xp y+10, % "After &punctuation"
    Gui, Add, Text, xs y+30, % "Auto-&capitalization"
    Gui, Add, DropDownList, vUI_capitalization AltSubmit xp+150 w130, % "Off|For shortcuts|For all input"
    Gui, Add, Text, xs y+m, % "&Output delay (ms)"
    Gui, Add, Edit, vUI_output_delay Right xp+150 w40 Number, % "99"
    Gui, Tab
    Gui, Add, Button, vUI_zipchord_btnPause Hwndtemp xm ym+450 w130, % UI_STR_PAUSE
    fn := Func("PauseApp").Bind(true)
    GuiControl +g, % temp, % fn
    Gui, Add, Button, w80 xm+160 ym+450 gUI_btnApply, % "Apply"
    Gui, Add, Button, Default w80 xm+260 ym+450 gUI_btnOK, % "OK"
    Gui, Tab, 5
    Gui, Add, Text, Y+20, % "ZipChord"
    Gui, Add, Text, , % "Copyright © 2021-2023 Pavel Soukenik"
    Gui, Add, Text, , % "version " . zc_version
    ; Gui, Add, Text, +Wrap w300, % "This program comes with ABSOLUTELY NO WARRANTY. This is free software, and you are welcome to redistribute it under certain conditions."
    Gui, Font, Underline cBlue
    Gui, Add, Text, gLinkToLicense, % "License information"
    Gui, Add, Text, gLinkToDocumentation, % "Help and documentation"
    Gui, Add, Text, gLinkToReleases, % "Latest releases (check for updates)"
    Gui, Font, norm cDefault
    if (A_Args[1] == "dev")
        Gui, Add, Checkbox, y+30 vUI_debugging, % "&Log this session (debugging)"
}

    ; Create taskbar tray menu:
UI_Tray_Build() {
    global app_shortcuts
    Menu, Tray, NoStandard
    Menu, Tray, Add, % "Open ZipChord", UI_Main_Show
    Menu, Tray, Add, % "Add Shortcut", AddShortcut
    Menu, Tray, Add, % "Pause ZipChord", PauseApp
    Menu, Tray, Add  ;  adds a horizontal line
    fn := ObjBindMethod(app_shortcuts, "ShowUI")
    Menu, Tray, Add, % "Customize app shortcuts", % fn
    Menu, Tray, Add  ;  adds a horizontal line
    if (A_Args[1] == "dev") {
        Menu, Tray, Add, % "Open Key Visualizer", OpenKeyVisualizer
        Menu, Tray, Add, % "Open Test Console", OpenTestConsole
        Menu, Tray, Add
    }
    Menu, Tray, Add, % "Quit", QuitApp
    Menu, Tray, Default, 1&
    Menu, Tray, Tip, % "ZipChord"
    Menu, Tray, Click, 1
    UI_Tray_Update()
}

UI_Tray_Update() {
    global app_shortcuts
    Menu, Tray, Rename, 1&, % "Open ZipChord`t" . app_shortcuts.GetHotkeyText("UI_Main_Show")
    Menu, Tray, Rename, 2&, % "Add Shortcut`t" . app_shortcuts.GetHotkeyText("AddShortcut")
    string :=  (settings.mode & MODE_ZIPCHORD_ENABLED) ? "Pause" : "Resume"
    Menu, Tray, Rename, 3&, % string . " ZipChord`t" . app_shortcuts.GetHotkeyText("PauseApp")
    i := 7
    if (A_Args[1] == "dev")
        i += 3
    Menu, Tray, Rename, %i%&, % "Quit`t" . app_shortcuts.GetHotkeyText("QuitApp")
}

PauseApp(from_button := false) {
    Gui, UI_Main:Default
    if (settings.mode & MODE_ZIPCHORD_ENABLED) {
        settings.mode := settings.mode & ~MODE_ZIPCHORD_ENABLED
        mode := false
    } else {
        settings.mode := settings.mode | MODE_ZIPCHORD_ENABLED
        mode := true
    }
    state := mode ? UI_STR_PAUSE : UI_STR_RESUME
    GuiControl , , UI_zipchord_btnPause, % state
    state := mode ? "On" : "Off"
    if (from_button != true) {
        ShowHint("ZipChord Keyboard", state, , false)
    }
    WireHotkeys(state)
    UI_Tray_Update()
    UI_Main_EnableTabs(mode)
}

UI_Main_EnableTabs(mode) {
    Gui, UI_Main:Default
    GuiControl, Enable%mode%, UI_tab
}

QuitApp() {
    WireHotkeys("Off")
    ShowHint("Closing ZipChord", state, , false)
    Sleep 1100
    ExitApp
}

UI_Main_Show() {
    if (A_Args[1] == "dev")
        if (UI_debugging)
            FinishDebugging() 
    Hotkey, F1, UI_MainHelp, On
    Gui, UI_Main:Default
    GuiControl Text, UI_input_delay, % settings.input_delay
    GuiControl Text, UI_output_delay, % settings.output_delay
    GuiControl , , UI_allow_shift, % (settings.chording & CHORD_ALLOW_SHIFT) ? 1 : 0
    GuiControl , , UI_restrict_chords, % (settings.chording & CHORD_RESTRICT) ? 1 : 0
    GuiControl , , UI_immediate_shorthands, % (settings.chording & CHORD_IMMEDIATE_SHORTHANDS) ? 1 : 0
    GuiControl , , UI_delete_unrecognized, % (settings.chording & CHORD_DELETE_UNRECOGNIZED) ? 1 : 0
    GuiControl , Choose, UI_capitalization, % settings.capitalization
    GuiControl , , UI_space_before, % (settings.spacing & SPACE_BEFORE_CHORD) ? 1 : 0
    GuiControl , , UI_space_after, % (settings.spacing & SPACE_AFTER_CHORD) ? 1 : 0
    GuiControl , , UI_space_punctuation, % (settings.spacing & SPACE_PUNCTUATION) ? 1 : 0
    GuiControl , , UI_zipchord_btnPause, % (settings.mode & MODE_ZIPCHORD_ENABLED) ? UI_STR_PAUSE : UI_STR_RESUME
    GuiControl , , UI_chords_enabled, % (settings.mode & MODE_CHORDS_ENABLED) ? 1 : 0
    GuiControl , , UI_shorthands_enabled, % (settings.mode & MODE_SHORTHANDS_ENABLED) ? 1 : 0
    ; debugging is always set to disabled
    GuiControl , , UI_debugging, 0
    GuiControl , , UI_hints_show, % (settings.hints & HINT_ON) ? 1 : 0
    GuiControl , Choose, UI_hint_destination, % Round((settings.hints & (HINT_OSD | HINT_TOOLTIP)) / 16)
    GuiControl , Choose, UI_hint_frequency, % OrdinalOfHintFrequency()
    GuiControl Text, UI_hint_offset_x, % settings.hint_offset_x
    GuiControl Text, UI_hint_offset_y, % settings.hint_offset_y
    GuiControl Text, UI_hint_size, % settings.hint_size
    GuiControl Text, UI_hint_color, % settings.hint_color
    ShowHintCustomization(false)
    GuiControl, Choose, UI_tab, 1 ; switch to first tab
    UpdateLocaleInMainUI(settings.locale)
    Gui, Show,, ZipChord
}

UI_MainHelp() {
    Gui, UI_Main:Default
    ; Gui, Submit, NoHide
    GuiControlGet, current_tab,, UI_tab
    OpenHelp("Main-" . Trim(current_tab))
}

OpenKeyVisualizer() {
    visualizer.Init()
}
OpenTestConsole() {
    if (test.mode==TEST_OFF)
        test.Init()
}
FinishDebugging() {
    global zc_version
    test.Stop()
    test.Path("restore")
    test._mode := TEST_OFF
    FileDelete, % "debug.txt"
    FileAppend % "Configuration Settings`n----------------------`nZipChord version: " . zc_version . "`n", % "debug.txt", UTF-8
    FileRead file_content, % A_Temp . "\debug.cfg"
    FileAppend % file_content, % "debug.txt", UTF-8
    FileAppend % "`nInput`n-----`n", % "debug.txt", UTF-8
    FileRead file_content, % A_Temp . "\debug.in"
    FileAppend % file_content, % "debug.txt", UTF-8
    FileAppend % "`nOutput`n------`n", % "debug.txt", UTF-8
    FileRead file_content, % A_Temp . "\debug.out"
    FileAppend % file_content, % "debug.txt", UTF-8
    Run % "debug.txt"
}

OrdinalOfHintFrequency(offset := 0) {
    hint_frequency := settings.hints & (HINT_ALWAYS | HINT_NORMAL | HINT_RELAXED )
    hint_frequency := Round(Log(hint_frequency) / Log(2))  ; i.e. log base 2 gives us the desired setting as 1, 2 or 3
    Return hint_frequency + offset
}

; Shows or hides controls for hints customization (1 = show, 0 = hide)
ShowHintCustomization(show_controls := true) {
    GuiControl, Disable%show_controls%, UI_btnCustomize
    GuiControl, Show%show_controls%, UI_hint_offset_x
    GuiControl, Show%show_controls%, UI_hint_offset_y
    GuiControl, Show%show_controls%, UI_hint_size
    GuiControl, Show%show_controls%, UI_hint_color
    Loop 5 
    {
        GuiControl, Show%show_controls%, UI_hint_%A_Index%
    }
}

UpdateLocaleInMainUI(selected_loc) {
    sections := UI_Locale_GetSectionNames()
    Gui, UI_Main:Default
    GuiControl, , UI_selected_locale, % "|" StrReplace(sections, "`n", "|")
    GuiControl, Choose, UI_selected_locale, % selected_loc
}

UI_btnOK:
    if (ApplyMainSettings())
        UI_Main_Close()    
return

UI_btnApply:
    ApplyMainSettings()
return

ApplyMainSettings() {
    global hint_delay
    previous_mode := settings.mode 
    Gui, Submit, NoHide
    ; gather new settings from UI...
    settings.input_delay := UI_input_delay + 0
    settings.output_delay := UI_output_delay + 0
    settings.capitalization := UI_capitalization
    settings.spacing := UI_space_before * SPACE_BEFORE_CHORD + UI_space_after * SPACE_AFTER_CHORD + UI_space_punctuation * SPACE_PUNCTUATION
    settings.chording := UI_delete_unrecognized * CHORD_DELETE_UNRECOGNIZED + UI_allow_shift * CHORD_ALLOW_SHIFT + UI_restrict_chords * CHORD_RESTRICT + UI_immediate_shorthands * CHORD_IMMEDIATE_SHORTHANDS
    settings.locale := UI_selected_locale
    settings.mode := (settings.mode & MODE_ZIPCHORD_ENABLED) + UI_chords_enabled * MODE_CHORDS_ENABLED + UI_shorthands_enabled * MODE_SHORTHANDS_ENABLED  ; carries over the current ZIPCHORD_ENABLED setting 
    settings.hints := UI_hints_show + 16 * UI_hint_destination + 2**UI_hint_frequency ; translates to HINT_ON, OSD/Tooltip, and frequency ( ** means ^ in AHK)
    if ( (temp:=SanitizeNumber(UI_hint_offset_x)) == "ERROR") {
        MsgBox ,, % "ZipChord", % "The offset needs to be a positive or negative number."
        Return false
    } else settings.hint_offset_x := temp
    if ( (temp:=SanitizeNumber(UI_hint_offset_y)) == "ERROR") {
        MsgBox ,, % "ZipChord", % "The offset needs to be a positive or negative number."
        Return false
    } else settings.hint_offset_y := temp
    settings.hint_size := UI_hint_size
    if ( (temp:=SanitizeNumber(UI_hint_color, true)) =="ERROR") {
        MsgBox ,, % "ZipChord", % "The color needs to be entered as hex code, such as '34cc97' or '#34cc97'."
        Return false
    } else settings.hint_color := temp
    ; ...and save them to Windows Registry
    settings.Write()
    ; We always want to rewire hotkeys in case the keys have changed.
    WireHotkeys("Off")
    UI_Locale_Load(settings.locale)
    if (settings.mode > MODE_ZIPCHORD_ENABLED) {
        if (previous_mode-1 < MODE_ZIPCHORD_ENABLED)
            ShowHint("ZipChord Keyboard", "On", , false)
        WireHotkeys("On")
    }
    else if (settings.mode & MODE_ZIPCHORD_ENABLED)
        ShowHint("ZipChord Keyboard", "Off", , false)
    if (A_Args[1] == "dev") {
        if (UI_debugging) {
            if (FileExist("debug.txt")) {
                MsgBox, 4, % "ZipChord", % "This will overwrite an existing file with debugging output (debug.txt). Would you like to continue?`n`nSelect Yes to start debugging and overwrite the file.`nSelect No to cancel."
                IfMsgBox No
                    Return false
            }
            FileDelete, % A_Temp . "\debug.cfg"
            FileDelete, % A_Temp . "\debug.in"
            FileDelete, % A_Temp . "\debug.out"
            test.Path("set", A_Temp)
            test.Config("save", "debug")
            test.Record("both", "debug")
        }
    }
    ; to reflect any changes to OSD UI
    SetTimer,  UI_OSD_Reset, -2000
    Return true
}

UI_MainGuiClose() {
    UI_Main_Close()
}
UI_MainGuiEscape() {
    UI_Main_Close()
}

UI_Main_Close() {
    Hotkey, F1, Off
    Gui, UI_Main:Default
    Gui, Submit
    if (settings.preferences & PREF_SHOW_CLOSING_TIP)
        UI_ClosingTip_Show()
}

LinkToLicense() {
    ini.ShowLicense()
}
Return
LinkToDocumentation:
    Run https://github.com/psoukie/zipchord/wiki
Return
LinkToReleases:
    Run https://github.com/psoukie/zipchord/releases
Return

; Functions supporting UI

; Update UI with dictionary details
UpdateDictionaryUI() {
    Gui, UI_Main:Default
    GuiControl Text, UI_chord_file, % str.Ellipsisize(settings.chord_file, 270)
    entriesstr := "Chord dictionary (" chords.entries
    entriesstr .= (chords.entries==1) ? " chord)" : " chords)"
    GuiControl Text, UI_chord_entries, %entriesstr%
    GuiControl Text, UI_shorthand_file, % str.Ellipsisize(settings.shorthand_file, 270)
    entriesstr := "Shorthand dictionary (" shorthands.entries
    entriesstr .= (shorthands.entries==1) ? " shorthand)" : " shorthands)"
    GuiControl Text, UI_shorthand_entries, %entriesstr%
}

; Run Windows File Selection to open a dictionary
BtnSelectChordDictionary() {
    FileSelectFile dict, , % settings.dictionary_dir , Open Chord Dictionary, Text files (*.txt)
    if (dict != "") {
        settings.chord_file := dict
        chords.Load(dict)
        UpdateDictionaryUI()
    }
    Return
}

BtnSelectShorthandDictionary() {
    FileSelectFile dict, , % settings.dictionary_dir, Open Shorthand Dictionary, Text files (*.txt)
    if (dict != "") {
        settings.shorthand_file := dict
        shorthands.Load(dict)
        UpdateDictionaryUI()
    }
    Return
}

; Edit a dictionary in default editor
BtnEditChordDictionary() {
    Run % settings.chord_file
}
BtnEditShorthandDictionary() {
    Run % settings.shorthand_file
}

; Reload a (modified) dictionary file; rewires hotkeys because of potential custom keyboard setting
BtnReloadChordDictionary() {
    chords.Load()
    UpdateDictionaryUI()
}
BtnReloadShorthandDictionary() {
    shorthands.Load()
    UpdateDictionaryUI()
}

ButtonCustomizeLocale() {
    WireHotkeys("Off")  ; so the user can edit the values without interference
    Gui, Submit, NoHide ; to get the currently selected UI_selected_locale
    Gui, +Disabled
    UI_Locale_Show(UI_selected_locale)
}

;; Closing Tip UI
; ----------------

global UI_ClosingTip_dont_show := 0

UI_ClosingTip_Show() {
    global app_shortcuts
    Gui, UI_ClosingTip:New, , % "ZipChord"
    Gui, Margin, 20, 20
    Gui, Font, s10, Segoe UI
    Gui, Add, Text, +Wrap w430, % Format("Select a word and {} to define a shortcut for it or to see its existing shortcuts.`n`n{} to open the ZipChord menu again.`n", app_shortcuts.GetHotkeyText("AddShortcut", "press ", "press and hold "), app_shortcuts.GetHotkeyText("UI_Main_Show", "Press ", "Press and hold "))
    Gui, Add, Checkbox, vUI_ClosingTip_dont_show, % "Do &not show this tip again."
    Gui, Add, Button, gUI_ClosingTip_btnOK x370 w80 Default, OK
    Gui, Show, w470
}
UI_ClosingTip_btnOK() {
    Gui, UI_ClosingTip:Submit
    if (UI_ClosingTip_dont_show) {
        settings.preferences &= ~PREF_SHOW_CLOSING_TIP
        settings.Write()
    }
}
UI_ClosingTipGuiClose() {
    Gui, UI_ClosingTip:Submit
}
UI_ClosingTipGuiEscape() {
    Gui, UI_ClosingTip:Submit
}

;; Add Shortcut UI
; -----------------

global UI_AddShortcut_text
    , UI_AddShortcut_chord
    , UI_AddShortcut_shorthand
    , UI_AddShortcut_btnSaveChord
    , UI_AddShortcut_btnSaveShorthand
    , UI_AddShortcut_btnAdjust
UI_AddShortcut_Build() {
    Gui, UI_AddShortcut:New, , % "Add Shortcut"
    Gui, Margin, 25, 25
    Gui, Font, s10, Segoe UI
    Gui, Add, Text, Section, % "&Expanded text"
    Gui, Margin, 15, 15
    Gui, Add, Edit, y+10 w220 vUI_AddShortcut_text
    Gui, Add, Button, x+20 yp w100 vUI_AddShortcut_btnAdjust gUI_AddShortcut_Adjust, % "&Adjust"
    Gui, Add, GroupBox, xs h120 w360, % "&Chord"
    Gui, Font, s10, Consolas
    Gui, Add, Edit, xp+20 yp+30 Section w200 vUI_AddShortcut_chord gUI_AddShortcut_Focus_Chord
    Gui, Font, s10, Segoe UI
    Gui, Add, Button, x+20 yp w100 gUI_AddShortcut_SaveChord vUI_AddShortcut_btnSaveChord, % "&Save"
    Gui, Add, Text, xs +Wrap w320, % "Individual keys that make up the chord, without pressing Shift or other modifier keys."
    Gui, Add, GroupBox, xs-20 y+30 h120 w360, % "S&horthand"
    Gui, Font, s10, Consolas
    Gui, Add, Edit, xp+20 yp+30 Section w200 vUI_AddShortcut_shorthand gUI_AddShortcut_Focus_Shorthand
    Gui, Font, s10, Segoe UI
    Gui, Add, Button, x+20 yp w100 gUI_AddShortcut_SaveShorthand vUI_AddShortcut_btnSaveShorthand, % "Sa&ve"
    Gui, Add, Text, xs +Wrap w320, % "Sequence of keys of the shorthand, without pressing Shift or other modifier keys."
    Gui, Margin, 25, 25
    Gui, Add, Button, gUI_AddShortcut_Close Default x265 y+30 w100, % "Close" 
}
UI_AddShortcut_Show(exp) {
    call := Func("OpenHelp").Bind("AddShortcut")
    Hotkey, F1, % call, On
    WireHotkeys("Off")  ; so the user can edit values without interference
    UI_AddShortcut_Build()
    Gui, UI_AddShortcut:Default
    if (exp=="") {
        GuiControl, Hide, UI_AddShortcut_btnAdjust
        GuiControl, Focus, UI_AddShortcut_text
    } else {
        GuiControl, Disable, UI_AddShortcut_text
        GuiControl,, UI_AddShortcut_text, % exp
        if (shorthand := shorthands.ReverseLookUp(exp)) {
            GuiControl, Disable, UI_AddShortcut_shorthand
            GuiControl, , UI_AddShortcut_shorthand, % shorthand
            GuiControl, Disable, UI_AddShortcut_btnSaveShorthand
        } else GuiControl, Focus, UI_AddShortcut_shorthand
        if (chord := chords.ReverseLookUp(exp)) {
            GuiControl, Disable, UI_AddShortcut_chord
            GuiControl, , UI_AddShortcut_chord, % chord
            GuiControl, Disable, UI_AddShortcut_btnSaveChord
        } else GuiControl, Focus, UI_AddShortcut_chord
    }
    Gui, Show, w410
}
UI_AddShortcut_Focus_Chord() {
        GuiControlGet, isEnabled, Enabled, UI_AddShortcut_chord
    GuiControlGet, UI_AddShortcut_chord
    if (isEnabled && UI_AddShortcut_chord != "")
        GuiControl, +Default, UI_AddShortcut_btnSaveChord
}
UI_AddShortcut_Focus_Shorthand() {
    GuiControlGet, isEnabled, Enabled, UI_AddShortcut_shorthand
    GuiControlGet, UI_AddShortcut_shorthand
    if (isEnabled && UI_AddShortcut_shorthand != "")
        GuiControl, +Default, UI_AddShortcut_btnSaveShorthand
}
UI_AddShortcutGuiClose() {
    UI_AddShortcut_Close()
}
UI_AddShortcutGuiEscape() {
    UI_AddShortcut_Close()
}
UI_AddShortcut_Close() {
    Hotkey, F1, Off
    Gui, UI_AddShortcut:Destroy
    if (settings.mode > MODE_ZIPCHORD_ENABLED)
        WireHotkeys("On")  ; resume normal mode
}
UI_AddShortcut_SaveChord(){
    Gui, Submit, NoHide
    if (chords.Add(UI_AddShortcut_chord, UI_AddShortcut_text)) {
        UI_AddShortcut_Close()
        UpdateDictionaryUI()
    }
}
UI_AddShortcut_SaveShorthand(){
    Gui, Submit, NoHide
    if (shorthands.Add(UI_AddShortcut_shorthand, UI_AddShortcut_text)) {
        UI_AddShortcut_Close()
        UpdateDictionaryUI()
    }
}
UI_AddShortcut_Adjust(){
    GuiControl, Disable, UI_AddShortcut_btnAdjust
    GuiControl, , UI_AddShortcut_chord, % ""
    GuiControl, , UI_AddShortcut_shorthand, % ""
    Sleep 10
    GuiControl, Enable, UI_AddShortcut_chord
    GuiControl, Enable, UI_AddShortcut_btnSaveChord
    GuiControl, Enable, UI_AddShortcut_shorthand
    GuiControl, Enable, UI_AddShortcut_btnSaveShorthand
    GuiControl, Enable, UI_AddShortcut_text
    GuiControl, Focus, UI_AddShortcut_text
}

;; Shortcut Hint UI
; -------------------

global UI_OSD_line1
    , UI_OSD_line2
    , UI_OSD_line3
    , UI_OSD_transparency
    , UI_OSD_fading
    , UI_OSD_transparent_color  ; gets calculated from settings.hint_color for a nicer effect
    , UI_OSD_pos_x, UI_OSD_pos_y
    , UI_OSD_hwnd

UI_OSD_Build() {
    hint_color := settings.hint_color
    UI_OSD_transparent_color := ShiftHexColor(hint_color, 1)
    Gui, UI_OSD:Default
    Gui +LastFound +AlwaysOnTop -Caption +ToolWindow +HwndUI_OSD_hwnd ; +ToolWindow avoids a taskbar button and an alt-tab menu item.
    size := settings.hint_size
    Gui, Margin, Round(size/3), Round(size/3)
    Gui, Color, %UI_OSD_transparent_color%
    Gui, Font, s%size%, Consolas  ; Set a large font size (32-point).
    Gui, Add, Text, c%hint_color% Center vUI_OSD_line1, WWWWWWWWWWWWWWWWWWWWW  ; to auto-size the window.
    Gui, Add, Text, c%hint_color% Center vUI_OSD_line2, WWWWWWWWWWWWWWWWWWWWW
    Gui, Add, Text, c%hint_color% Center vUI_OSD_line3, WWWWWWWWWWWWWWWWWWWWW
    Gui, Show, NoActivate Center, ZipChord_OSD
    WinSet, TransColor, %UI_OSD_transparent_color% 150, ZipChord_OSD
    ; Get position of the window in case our fancy detection for multiple monitors fails
    WinGetPos UI_OSD_pos_x, UI_OSD_pos_y, , , ZipChord_OSD
    UI_OSD_pos_x += settings.hint_offset_x
    UI_OSD_pos_y += settings.hint_offset_y
    Gui, Hide
}
ShowHint(line1, line2:="", line3 :="", follow_settings := true) {
    active_window_handle := WinExist("A")
    global hint_delay
    if (A_Args[1] == "dev")
        if (test.mode > TEST_STANDBY)
            test.Log("*Hint*")
    hint_delay.Extend()
    if ( (settings.hints & HINT_TOOLTIP) && follow_settings) {
        GetCaret(x, y, , h)
        ToolTip % " " . ReplaceWithVariants(line2) . " `n " . ReplaceWithVariants(line3) . " ", x-1.5*h+settings.hint_offset_x, y+1.5*h+settings.hint_offset_y
        SetTimer, HideToolTip, -1800
    } else {
        UI_OSD_fading := False
        UI_OSD_transparency := 150
        Gui, UI_OSD:Default
        GuiControl,, UI_OSD_line1, % line1
        GuiControl,, UI_OSD_line2, % ReplaceWithVariants(line2, follow_settings)
        GuiControl,, UI_OSD_line3, % ReplaceWithVariants(line3)
        Gui, %UI_OSD_hwnd%: Show, Hide NoActivate, ZipChord_OSD
        GetMonitorCenterForWindow(active_window_handle, UI_OSD_hwnd, pos_x, pos_y)
        pos_x := pos_x ? pos_x+settings.hint_offset_x : UI_OSD_pos_x
        pos_y := pos_y ? pos_y+settings.hint_offset_y : UI_OSD_pos_y
        Gui, %UI_OSD_hwnd%: Show, NoActivate X%pos_x% Y%pos_y%, ZipChord_OSD
        WinSet, TransColor, %UI_OSD_transparent_color% %UI_OSD_transparency%, ZipChord_OSD
        SetTimer, UI_OSD_Hide, -1900
    }
}

UI_OSD_Reset() {
    hint_delay.Reset()
    Gui, UI_OSD:Destroy
    UI_OSD_Build()
}

HideToolTip:
    ToolTip
Return

UI_OSD_Hide:
    UI_OSD_fading := true
    Gui, UI_OSD:Default
    if (UI_OSD_fading && UI_OSD_transparency > 1) {
        UI_OSD_transparency -= 10
        WinSet, TransColor, %UI_OSD_transparent_color% %UI_OSD_transparency%, ZipChord_OSD
        SetTimer, UI_OSD_Hide, -100
        Return
    }
    Gui, Hide
Return

; Process input to ensure it is an integer (or a color hex code if the second parameter is true), return number or "ERROR" 
SanitizeNumber(orig, hex_color := false) {
    sanitized := Trim(orig)
    format := "integer"
    if (hex_color) {
        format := "xdigit"
        if (SubStr(orig, 1, 1) == "#")
            sanitized := SubStr(orig, 2)
        if (StrLen(sanitized)!=6)
            return "ERROR"
    }
    if sanitized is %format%
        return sanitized
    else
        return "ERROR"
}

ShiftHexColor(source_color, offset) {
    Loop 3
    {
        component := "0x" . SubStr(source_color, 2 * A_Index - 1, 2)
        component := component > 0x7f ? component - offset : component + offset
        new_color .= Format("{:02x}", component)
    }
    return new_color
}

; The following function for getting caret position more reliably is from a post by plankoe at https://www.reddit.com/r/AutoHotkey/comments/ysuawq/get_the_caret_location_in_any_program/
GetCaret(ByRef X:="", ByRef Y:="", ByRef W:="", ByRef H:="") {
    ; UIA caret
    static IUIA := ComObjCreate("{ff48dba4-60ef-4201-aa87-54103eef594e}", "{30cbe57d-d9d0-452a-ab13-7ac5ac4825ee}")
    ; GetFocusedElement
    DllCall(NumGet(NumGet(IUIA+0)+8*A_PtrSize), "ptr", IUIA, "ptr*", FocusedEl:=0)
    ; GetCurrentPattern. TextPatternElement2 = 10024
    DllCall(NumGet(NumGet(FocusedEl+0)+16*A_PtrSize), "ptr", FocusedEl, "int", 10024, "ptr*", patternObject:=0), ObjRelease(FocusedEl)
    if patternObject {
        ; GetCaretRange
        DllCall(NumGet(NumGet(patternObject+0)+10*A_PtrSize), "ptr", patternObject, "int*", 1, "ptr*", caretRange:=0), ObjRelease(patternObject)
        ; GetBoundingRectangles
        DllCall(NumGet(NumGet(caretRange+0)+10*A_PtrSize), "ptr", caretRange, "ptr*", boundingRects:=0), ObjRelease(caretRange)
        ; VT_ARRAY = 0x20000 | VT_R8 = 5 (64-bit floating-point number)
        Rect := ComObject(0x2005, boundingRects)
        if (Rect.MaxIndex() = 3) {
            X:=Round(Rect[0]), Y:=Round(Rect[1]), W:=Round(Rect[2]), H:=Round(Rect[3])
            return
        }
    }
    ; Acc caret
    static _ := DllCall("LoadLibrary", "Str","oleacc", "Ptr")
    idObject := 0xFFFFFFF8 ; OBJID_CARET
    if DllCall("oleacc\AccessibleObjectFromWindow", "Ptr", WinExist("A"), "UInt", idObject&=0xFFFFFFFF, "Ptr", -VarSetCapacity(IID,16)+NumPut(idObject==0xFFFFFFF0?0x46000000000000C0:0x719B3800AA000C81,NumPut(idObject==0xFFFFFFF0?0x0000000000020400:0x11CF3C3D618736E0,IID,"Int64"),"Int64"), "Ptr*", pacc:=0)=0 {
        oAcc := ComObjEnwrap(9,pacc,1)
        oAcc.accLocation(ComObj(0x4003,&_x:=0), ComObj(0x4003,&_y:=0), ComObj(0x4003,&_w:=0), ComObj(0x4003,&_h:=0), 0)
        X:=NumGet(_x,0,"int"), Y:=NumGet(_y,0,"int"), W:=NumGet(_w,0,"int"), H:=NumGet(_h,0,"int")
        if (X | Y) != 0
            return
    }
    ; default caret
    CoordMode Caret, Screen
    X := A_CaretX
    Y := A_CaretY
    W := 4
    H := 20
}

GetMonitorCenterForWindow(window_Handle, OSD_handle, ByRef pos_x, ByRef pos_y ) {
    ; Uses code for getting monitor info by "kon" from https://www.autohotkey.com/boards/viewtopic.php?t=15501
    VarSetCapacity(monitor_info, 40), NumPut(40, monitor_info)
    if ((monitorHandle := DllCall("MonitorFromWindow", "Ptr", window_Handle, "UInt", 1)) 
        && DllCall("GetMonitorInfo", "Ptr", monitorHandle, "Ptr", &monitor_info)) {
        monitor_left   := NumGet(monitor_info,  4, "Int")
        monitor_top    := NumGet(monitor_info,  8, "Int")
        monitor_right  := NumGet(monitor_info, 12, "Int")
        monitor_bottom := NumGet(monitor_info, 16, "Int")
        ; From code for multiple monitors by DigiDon from https://www.autohotkey.com/boards/viewtopic.php?t=31716 
        VarSetCapacity(rc, 16)
        DllCall("GetClientRect", "uint", OSD_handle, "uint", &rc)
        window_width := NumGet(rc, 8, "int")
        window_height := NumGet(rc, 12, "int")
        pos_x := (( monitor_right - monitor_left - window_width ) / 2) + monitor_left
        pos_y := (( monitor_bottom - monitor_top - window_height ) / 2) + monitor_top
    } else {
        pos_x := 0
        pos_y := 0
    }
}