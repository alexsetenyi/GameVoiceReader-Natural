#Requires AutoHotkey v2
#include .\Lib\OCR.ahk
InstallKeybdHook 1, 1
#UseHook 1

CoordMode "Mouse", "Screen"
CoordMode "ToolTip", "Screen"

; Initialize Windows TTS Voice
global Voice := ComObject("SAPI.SpVoice")
DllCall("SetThreadDpiAwarenessContext", "ptr", -3)
OCR.PerformanceMode := 1 

; --- Global Variables ---
global sX := 0, sY := 0, sW := 0, sH := 0, hasSavedArea := 0
global lastHoverState := 0 
global hoverEnabled := 0 ; On/Off Switch for hover detection
global highlightEnabled := 0
global paused := 0

; Sentence tracking & state control
global sentences := []
global currentSentenceIndex := 1
global targetStreamNum := 0

F3:: {
    _ToolTip("Rewind")
    SkipSentence(-1)
    KeyWait "F3"
}

F4:: {
    _ToolTip("Fast forward")
    SkipSentence(1)
    KeyWait "F4"
}

F5:: {
    _ToolTip(sentences[1])
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
    RunOCRAndSpeak(sX, sY, sW, sH)
}

; --- PAUSE / RESUME (F9) ---
F9:: {
    global paused := !paused
    if (paused) {
        _ToolTip("Voice paused")
        Voice.Pause()
    } else {
        Voice.Resume()
        _ToolTip("Voice resumed")
    }
}

F10::exitapp


Loop {
    ; ==============================================================================
    ; PHASE 1: XButton2 Logic (Selection or Single Click Trigger)
    ; ==============================================================================
    if GetKeyState("RCtrl", "P") {
        
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
        else if (!isDrag && hasSavedArea) {
            ; RunOCRAndSpeak(sX, sY, sW, sH)
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
    global sentences, currentSentenceIndex, paused    
    try {
        paused := 0        
        Voice.Resume()        
        result := OCR.FromRect(x, y, w, h,, {scale: 2, grayscale: 1})        
        text := GetOrderedText(result)                
        if StrLen(text) > 0 {
            text := CleanOcrText(text)
            
            ; Split cleaned text into sentence array using ending punctuation
            delimitedText := RegExReplace(text, "([\.!\?])\s*", "$1`n")
            sentences := []
            ; for line in StrSplit(delimitedText, "`n") {
            ;     line := Trim(line)
            ;     if (line != "")
            ;         sentences.Push(line)
            ; }
            sentences.Push(text)
            
            if (sentences.Length > 0) {                       
                ; SpeakSentence(1)                
                Voice.Speak(sentences[1], 3)
            }
        }
    } catch as err {
        ; OCR Error
    }
}

SpeakSentence(index) {
    global sentences, currentSentenceIndex, Voice, targetStreamNum
    if (index < 1 || index > sentences.Length)
        return

    currentSentenceIndex := index
    
    ; Strip trailing punctuation ( . ! ? ) to eliminate SAPI's trailing silence delay
    cleanText := RegExReplace(sentences[index], "[\.!\?]+\s*$", "")
    
    ; Flag 3 = Async (1) | PurgeBeforeSpeak (2)
    Voice.Speak(cleanText, 3)
    targetStreamNum := Voice.Status.LastStreamNumberQueued
    
    ; Buffer the next sentence without trailing silence
    if (index + 1 <= sentences.Length) {
        nextText := RegExReplace(sentences[index + 1], "[\.!\?]+\s*$", "")
        Voice.Speak(nextText, 1)
    }
    
    SetTimer(SpeechMonitor, 30)
}

; Background pipeline monitor: keeps SAPI's queue filled 1 sentence ahead
SpeechMonitor() {
    global Voice, sentences, currentSentenceIndex, paused, targetStreamNum

    if (paused || sentences.Length == 0)
        return

    try {
        curStream := Voice.Status.CurrentStreamNumber
        runState := Voice.Status.RunningState

        ; Detect when SAPI seamlessly transitions from targetStreamNum to the next queued sentence
        if (curStream > targetStreamNum) {
            currentSentenceIndex++
            targetStreamNum := curStream
            
            ; Buffer the sentence that comes after the one now actively playing
            nextIndex := currentSentenceIndex + 1
            if (nextIndex <= sentences.Length) {
                Voice.Speak(sentences[nextIndex], 1)
            }
        }
        ; Stop monitoring once the end of the text is reached and speech goes dormant
        else if (runState == 1 && currentSentenceIndex == sentences.Length && curStream == targetStreamNum) {
            SetTimer(SpeechMonitor, 0)
        }
    }
}

SkipSentence(step := 1) {
    global sentences, currentSentenceIndex, paused, Voice
    if (sentences.Length == 0)
        return

    newIndex := currentSentenceIndex + step

    if (newIndex < 1)
        newIndex := 1

    if (newIndex >= 1 && newIndex <= sentences.Length) {
        if (paused) {
            paused := 0
            Voice.Resume()
        }
        SpeakSentence(newIndex)
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

CleanOcrText(text) {
    text := RegExReplace(text, "[\r\n]+", " ")
    text := RegExReplace(text, "([\.!\?])([A-Za-z])", "$1 $2")
    return Trim(text)
}

_ToolTip(text) {
    ToolTip(text)
    SetTimer(() => ToolTip(), -1500)
}

GetOrderedText(result, lineThreshold := 12) {
    if !result.Words.Length
        return ""
    
    words := result.Words.Clone()
    OCR.SortArray(words, (a, b) => a.y - b.y)
    
    lines := []
    currentLine := []
    currentY := -1
    
    for word in words {
        if (currentY == -1 || Abs(word.y - currentY) <= lineThreshold) {
            currentLine.Push(word)
            if (currentY == -1)
                currentY := word.y
        } else {
            lines.Push(currentLine)
            currentLine := [word]
            currentY := word.y
        }
    }
    if currentLine.Length
        lines.Push(currentLine)
    
    fullText := ""
    for lineWords in lines {
        OCR.SortArray(lineWords, (a, b) => a.x - b.x)
        lineStr := ""
        for word in lineWords
            lineStr .= word.Text " "
        fullText .= RTrim(lineStr) "`n"
    }
    return RTrim(fullText, "`n")
}