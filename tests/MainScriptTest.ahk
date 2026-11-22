#Requires AutoHotkey v2
; Runs the real main script against a window that behaves like a game: a journal that
; is scrolled and a conversation that advances by itself. Checks what would be spoken.
; Uses its own settings file and plays silence. The hotkeys are active while it runs.
#Warn All, StdOut
#Warn LocalSameAsGlobal, Off
OnError((e, m) => (Out("ERR " e.Message " / " e.What " line " e.Line " " e.Extra), ExitApp(1)))
SetTimer(Scenario, -700)
#Include ..\Game Voice Reader.ahk

Scenario() {
    global sX, sY, sW, sH, hasSavedArea
    Out("started, voice: " Speech.activeName)
    Speech.mute := true
    if Speech.voiceName = ""
        Speech.SetVoice("Steffan")

    journal := "The third winter was the worst of them.`nWe had eaten the last of the barley by`nmidwinter, and the hunters came home`nwith nothing but frost on their cloaks.`nElder Maren said the herds had gone`nsouth. I did not believe her. There were`ntracks in the snow behind the palisade,`nlarge ones, and they did not belong to`nany beast I know. On the ninth night the`ndogs stopped barking."
    g := Gui("+AlwaysOnTop -Caption -DPIScale +ToolWindow")
    g.BackColor := "14171C"
    g.SetFont("s16 cE8E0D0", "Segoe UI")
    box := g.Add("Text", "x20 y10 w560 h640", journal)
    g.Show("NA x80 y80 w600 h160")          ; only the first lines are visible
    Sleep 500
    sX := 80, sY := 80, sW := 600, sH := 160, hasSavedArea := 1

    ; manual reading with F8's function, continuous reading off
    RunOCRAndSpeak(sX, sY, sW, sH)
    manual := Speech.Text
    Check("manual reading", InStr(manual, "The third winter was the worst of them.") = 1 && InStr(manual, "midwinter"))
    WaitIdle(30000)
    Check("manual reading finished", Speech.IsIdle)
    n := Speech.items.Length
    Check("rewind after the end", Speech.Skip(-1) && Speech.Index = n)
    Speech.Stop()

    ; continuous reading while scrolling
    ToggleFollow()
    RunOCRAndSpeak(sX, sY, sW, sH)
    loop 12 {
        Sleep 900
        box.Move(, 10 - A_Index * 24)        ; scrolls by less than a line
        ToolTip("Rewind", 300, 120), _ToolTip("Fast forward")   ; must not be read
        if A_Index = 4
            Speech.Pause()
        if A_Index = 6
            Speech.Resume()
    }
    Sleep 2500
    ToolTip()
    WaitIdle(60000)
    Sleep 2500
    WaitIdle(20000)
    got := StrReplace(Speech.Text, "`n", " "), want := StrReplace(journal, "`n", " ")
    Check("scrolled journal read once and completely", got = want)
    if got != want
        Out("   got  " got "`n   want " want)

    ; a conversation that moves on
    Speech.Stop(), Follower.Reset()
    box.Move(, 10)
    pages := ["Ah, there you are at last. I was beginning to worry about you.", "Did you bring the letter? Give it here.", "This is not my brother's handwriting! Where did you get it from?"]
    for p in pages {
        box.Value := ""
        loop parse p {                        ; typed letter by letter
            box.Value .= A_LoopField
            Sleep 25
        }
        Sleep 1200
    }
    Sleep 2000
    WaitIdle(30000)
    got := StrReplace(Speech.Text, "`n", " "), want := pages[1] " " pages[2] " " pages[3]
    Check("conversation", got = want)
    if got != want
        Out("   got  " got "`n   want " want)
    Out("first audio of the last part after " Speech.firstAudioMs "ms, underruns " Speech.underruns)
    ToggleFollow()
    Check("following can be switched off", !followEnabled)
    ExitApp
}
WaitIdle(ms) {
    t := A_TickCount
    while !Speech.IsIdle && A_TickCount - t < ms
        Sleep 50
}
Check(name, ok) => Out((ok ? "ok    " : "FAIL  ") name)
Out(s) => FileAppend(s "`n", "*", "UTF-8")
