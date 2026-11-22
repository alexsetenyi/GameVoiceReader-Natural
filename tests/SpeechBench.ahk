#Requires AutoHotkey v2
#SingleInstance Off
#Warn All, StdOut
#Warn LocalSameAsGlobal, Off
#Include ..\Lib\SpeechEngine.ahk
; Measures delays with real voices. Plays silence through the default audio device.
; Every sentence is new, because the online service answers repeated text faster.
;   AutoHotkey64.exe SpeechBench.ahk [voice] [sentences]
OnError((e, m) => (Out("ERR " e.Message " / " e.What " line " e.Line " " e.Extra), ExitApp(1)))
voice := A_Args.Length ? A_Args[1] : ""
count := A_Args.Length > 1 ? Integer(A_Args[2]) : 8
verbose := A_Args.Length > 2

Pick(a) => a[Random(1, a.Length)]
Sentence() => Pick(["The warden", "A pale raven", "Old Merrick", "Your brother", "The ferryman"]) " "
    . Pick(["carried", "buried", "traded", "guarded", "repaired"]) " " Pick(["nine silver keys", "a broken compass", "seven jars of salt", "the copper bell"]) " "
    . Pick(["beneath the mill", "past the northern ford", "behind the chapel", "near the quarry"]) " about " Random(11, 98) " days ago."

engine := SpeechEngine({voice: voice, mute: true, log: verbose ? ((t) => Out("   " t)) : ""})
Out("voice: " engine.activeName)
engine.Warm()
Wait(() => !Busy(), 15000)

list := []
loop count
    list.Push(Sentence())
t0 := A_TickCount
engine.Load(list)
; log when each sentence becomes audible, and every moment of silence between them
gaps := "", last := 0, drySince := 0, dry := 0
while !engine.IsIdle && A_TickCount - t0 < 90000 {
    if engine.blocks.Length {
        if drySince && last
            dry += A_TickCount - drySince, gaps .= (A_TickCount - drySince) "ms before #" engine.Index "  "
        drySince := 0
        last := engine.Index
    } else if !drySince
        drySince := A_TickCount
    Sleep 5
}
Out("first audio after " engine.firstAudioMs "ms | " count " sentences in " Round((A_TickCount - t0) / 1000, 1) "s | silence waiting for the voice: " (gaps = "" ? "none" : dry "ms (" gaps ")"))

; going back to a rendered sentence
engine.Load(list)
Wait(() => engine.blocks.Length, 3000)
Out("reload of known text: first audio after " engine.firstAudioMs "ms")
engine.Skip(1), Sleep(60)
engine.Skip(1), Sleep(60)
Out("forward x2: sentence " engine.Index ", audio after " engine.firstAudioMs "ms")
engine.Skip(-1), Sleep(60)
Out("back x1: sentence " engine.Index ", audio after " engine.firstAudioMs "ms")
engine.Pause()
Sleep 100
p := Position()
Sleep 800
Out("pause holds: " (Position() = p ? "yes" : "NO"))
engine.Resume()
Sleep 900
Out("resume plays on: " (Position() > p ? "yes" : "NO"))
engine.Skip(99)
engine.Stop()
Out("stop: " (engine.IsIdle ? "idle" : "NOT IDLE"))
ExitApp

; samples played so far
Position() {
    mmt := Buffer(12, 0), NumPut("uint", 4, mmt)
    DllCall("winmm\waveOutGetPosition", "ptr", engine.hwo, "ptr", mmt, "uint", 12)
    return NumGet(mmt, 4, "uint")
}

Busy() {
    for w in engine.workers
        if w.clip
            return true
    return false
}
Wait(cond, ms) {
    t := A_TickCount
    while !cond() && A_TickCount - t < ms
        Sleep 10
}
Out(s) => FileAppend(s "`n", "*", "UTF-8")
