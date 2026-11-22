#Requires AutoHotkey v2
#SingleInstance Force
#Include Lib\OCR.ahk
#Include Lib\TextTools.ahk
#Include Lib\SpeechEngine.ahk
InstallKeybdHook 1, 1
#UseHook 1

CoordMode "Mouse", "Screen"
CoordMode "ToolTip", "Screen"

DllCall("SetThreadDpiAwarenessContext", "ptr", -3)
OCR.PerformanceMode := 1

; --- Settings (settings.ini next to the script, created on first start) ---
global SettingsFile := A_ScriptDir "\settings.ini"
global Config := LoadSettings()

; --- Voice ---
global Speech := SpeechEngine({
    voice: Config.voice, rate: Config.rate, gapMs: Config.gapMs, prefetch: Config.prefetch,
    log: DebugLog, onSlow: SlowVoiceHint
})
BuildTrayMenu()

; --- Global Variables ---
global sX := 0, sY := 0, sW := 0, sH := 0, hasSavedArea := 0
global lastHoverState := 0
global hoverEnabled := 0 ; On/Off Switch for hover detection
global highlightEnabled := 0

F3:: {
    _ToolTip("Rewind")
    Speech.Skip(-1)
    KeyWait "F3"
}

F4:: {
    _ToolTip("Fast forward")
    Speech.Skip(1)
    KeyWait "F4"
}

F5:: {
    text := Speech.Text
    _ToolTip(text = "" ? "Nothing read yet" : SubStr(text, -1500))
}

F6:: {
    global highlightEnabled := !highlightEnabled
}

; --- F7 Toggle Switch ---
F7:: {
    global hoverEnabled := !hoverEnabled
    _ToolTip("Hover Detection: " . (hoverEnabled ? "ON" : "OFF"))
}

F8:: {
    if (hasSavedArea)
        RunOCRAndSpeak(sX, sY, sW, sH)
    else
        _ToolTip("No area selected: hold Right Ctrl, drag, then left click")
}

; --- PAUSE / RESUME (F9) ---
F9:: {
    if (Speech.paused) {
        Speech.Resume()
        _ToolTip("Voice resumed")
    } else {
        _ToolTip("Voice paused")
        Speech.Pause()
    }
}

F10::ExitApp


Loop {
    ; ==============================================================================
    ; PHASE 1: RCtrl Logic (Selection)
    ; ==============================================================================
    if GetKeyState("RCtrl", "P") {
        Speech.Warm() ; connect to the online voice while the area is being drawn

        MouseGetPos(&startX, &startY)
        confirmed := false
        isDrag := false
        nx := 0, ny := 0, nw := 0, nh := 0

        while GetKeyState("RCtrl", "P") {
            MouseGetPos(&currX, &currY)

            nw := Abs(currX - startX), nh := Abs(currY - startY)
            nx := Min(currX, startX),  ny := Min(currY, startY)

            if (nw > 5 || nh > 5)
                isDrag := true

            if (isDrag)
                Highlight("new", nx, ny, nw, nh, "Red")

            if (hasSavedArea && GetKeyState("F8", "P"))
                Highlight("old", sX, sY, sW, sH, "Blue")
            else
                Highlight("old")

            if (isDrag && GetKeyState("LButton", "P")) {
                confirmed := true
                break
            }
            Sleep 10
        }

        Highlight("new")

        if (confirmed) {
            sX := nx, sY := ny, sW := nw, sH := nh
            hasSavedArea := 1
            RunOCRAndSpeak(sX, sY, sW, sH)
            KeyWait "LButton"
        }
    }

    ; ==============================================================================
    ; PHASE 2: VISIBILITY & HOVER LOGIC
    ; ==============================================================================
    if (hasSavedArea) {
        if (highlightEnabled) {
            Highlight("old", sX, sY, sW, sH, "Blue")
        }
        else {
            Highlight("old")
        }

        if (hoverEnabled) {
            MouseGetPos(&mX, &mY)
            if (mX >= sX && mX <= (sX + sW) && mY >= sY && mY <= (sY + sH)) {
                if (lastHoverState == 0) {
                    lastHoverState := 1
                    RunOCRAndSpeak(sX, sY, sW, sH)
                }
            } else {
                lastHoverState := 0
            }
        }
    }

    Sleep 50
}

; --- Helper Functions ---

RunOCRAndSpeak(x, y, w, h) {
    try {
        Speech.Resume()
        result := OCR.FromRect(x, y, w, h,, {scale: 2, grayscale: 1})
        sentences := SentenceList(CleanOcrText(GetOrderedText(result)))
        if sentences.Length
            Speech.Load(sentences)
    } catch as err {
        DebugLog("OCR: " err.Message)
    }
}

Highlight(id, x?, y?, w?, h?, color:="Red", d:=2) {
    static guiMap := Map()
    if !guiMap.Has(id)
        guiMap[id] := []
    if !IsSet(x) {
        for _, r in guiMap[id]
            r.Destroy()
        guiMap.Delete(id)
        return
    }
    if !guiMap[id].Length {
        Loop 4
            guiMap[id].Push(Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08000000"))
    }
    Loop 4 {
        i := A_Index
        x1 := (i=2 ? x+w : x-d)
        y1 := (i=3 ? y+h : y-d)
        w1 := (i=1 or i=3 ? w+2*d : d)
        h1 := (i=2 or i=4 ? h+2*d : d)
        guiMap[id][i].BackColor := color
        guiMap[id][i].Show("NA x" . x1 . " y" . y1 . " w" . w1 . " h" . h1)
    }
}

_ToolTip(text) {
    ToolTip(text)
    SetTimer(() => ToolTip(), -1500)
}

; --- Settings and tray menu ---

LoadSettings() {
    if !FileExist(SettingsFile) {
        FileAppend("
        (
            [Speech]
            ; Part of a voice name, e.g. Steffan, Roger, Aria, Jenny, Guy. Empty = Windows default voice.
            ; Can also be chosen from the tray icon. Voices differ a lot in how fast they answer, see README.
            Voice=
            ; -10 (slow) to 10 (fast)
            Rate=0
            ; Pause between sentences in milliseconds
            SentenceGapMs=220
            ; How many sentences to prepare in advance
            Prefetch=4

            [General]
            ; 1 = write timings and errors to debug.log
            Debug=0

        )", SettingsFile, "UTF-16")
    }
    num(section, key, default, lo, hi) {
        v := IniRead(SettingsFile, section, key, default)
        return IsNumber(v) ? Max(lo, Min(hi, Integer(v))) : default
    }
    return {
        voice: IniRead(SettingsFile, "Speech", "Voice", ""),
        rate: num("Speech", "Rate", 0, -10, 10),
        gapMs: num("Speech", "SentenceGapMs", 220, 0, 3000),
        prefetch: num("Speech", "Prefetch", 4, 1, 8),
        debug: num("General", "Debug", 0, 0, 1)
    }
}

BuildTrayMenu() {
    static voices := Menu()
    voices.Delete()
    AddVoiceItem(voices, "(Windows default)", "")
    for v in SpeechEngine.Voices()
        AddVoiceItem(voices, v.name, v.name)
    tray := A_TrayMenu
    tray.Delete()
    tray.Add("Voice", voices)
    tray.Add("Edit settings", (*) => Run('notepad.exe "' SettingsFile '"'))
    tray.Add("Reload", (*) => Reload())
    tray.Add("Exit", (*) => ExitApp())
    A_IconTip := "Game Voice Reader`n" SubStr(Speech.activeName, 1, 90)
}

AddVoiceItem(menuObj, label, name) {
    menuObj.Add(label, (*) => ChooseVoice(name))
    if (name = "" ? !Speech.token : Speech.token && Speech.activeName = name)
        menuObj.Check(label)
}

ChooseVoice(name) {
    IniWrite(name, SettingsFile, "Speech", "Voice")
    active := Speech.SetVoice(name)
    BuildTrayMenu()
    _ToolTip("Voice: " active)
}

SlowVoiceHint(avgMs) {
    TrayTip("This voice takes " Round(avgMs / 1000, 1) " s to answer. Pick a faster one, such as Steffan, Roger, Aria or Jenny, from the tray icon.", "Slow voice")
}

DebugLog(text) {
    if Config.debug
        try FileAppend(FormatTime(, "HH:mm:ss") "." Format("{:03}", A_MSec) "  " text "`n", A_ScriptDir "\debug.log", "UTF-8")
}
