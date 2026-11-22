#Requires AutoHotkey v2
#SingleInstance Off
#Warn All, StdOut
#Warn LocalSameAsGlobal, Off
#Include ..\Lib\OCR.ahk
#Include ..\Lib\TextTools.ahk
#Include ..\Lib\SpeechEngine.ahk
; Draws a dialog on screen, reads it back with OCR and speaks it muted.
OnError((e, m) => (Out("ERR " e.Message " / " e.What " line " e.Line " " e.Extra), ExitApp(1)))
DllCall("SetThreadDpiAwarenessContext", "ptr", -3)
g := Gui("+AlwaysOnTop -Caption -DPIScale +ToolWindow")
g.BackColor := "14171C"
g.SetFont("s16 cE8E0D0", "Segoe UI")
g.Add("Text", "x20 y15 w660 h160", "Welcome back, traveller. The bridge to the north has fallen again, and the ferry will not run until spring. If you still mean to cross, speak with Merrick at the mill!")
g.Show("NA x60 y60 w700 h190")
Sleep 400
t := A_TickCount
r := OCR.FromRect(60, 60, 700, 190,, {scale: 2, grayscale: 1})
ocrMs := A_TickCount - t
list := SentenceList(CleanOcrText(GetOrderedText(r)))
g.Destroy()
Out("ocr " ocrMs "ms")
for s in list
    Out("  [" s "]")
e := SpeechEngine({voice: "Steffan", mute: true})
e.Load(list)
while !e.IsIdle && A_Index < 2500
    Sleep 10
Out("first audio " e.firstAudioMs "ms after OCR")
ExitApp
Out(s) => FileAppend(s "`n", "*", "UTF-8")
