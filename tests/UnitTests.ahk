#Requires AutoHotkey v2
#SingleInstance Off
#Include ..\Lib\TextTools.ahk
; Text splitting and reading order. No voice, no screen.
OnError((e, m) => (Out("ERR " e.Message " / " e.What " line " e.Line " " e.Extra), ExitApp(1)))
global failed := 0, passed := 0

; --- sentence splitting
Split("The door was open. The stairs were wet. Who was here?", "The door was open.|The stairs were wet.|Who was here?")
Split("No! Get out of my house right now. And never come back here.", "No! Get out of my house right now.|And never come back here.")
Split("Dr. Harrow met J. Vance by the old well. Nobody else came.", "Dr. Harrow met J. Vance by the old well.|Nobody else came.")
Split("It costs 3.5 gold pieces per barrel. Take it or leave it, friend.", "It costs 3.5 gold pieces per barrel.|Take it or leave it, friend.")
Split("Well... maybe you are right after all. I will think about it.", "Well... maybe you are right after all.|I will think about it.")
Split('She said "Run away from here!" Then she was gone forever.', 'She said "Run away from here!"|Then she was gone forever.')
Split("Wait… Something moved in the dark. Did you see it there?", "Wait… Something moved in the dark.|Did you see it there?")
Split("A sentence without an end", "A sentence without an end?")
Split("First one is done here. Second one is not", "First one is done here.|Second one is not?")
Split("", "")
long := ""
loop 60
    long .= "word" A_Index (Mod(A_Index, 10) = 0 ? ", " : " ")
for piece in SplitSentences(long)
    Check("long piece under limit", StrLen(piece.text) <= 260, 1)
Check("only symbols are not spoken", SentenceList("--- . ***").Length, 0)

; --- cleaning keeps the old behaviour
Check("clean", CleanOcrText("One line`r`nnext line.Then more"), "One line next line. Then more")

; --- reading order
w(t, x, y, h := 20) => {Text: t, x: x, y: y, w: 30, h: h}
class OCR {      ; stand-in for the library's sort
    static SortArray(a, f) {
        loop a.Length - 1 {
            i := A_Index + 1, v := a[i], j := i - 1
            while j >= 1 && f(a[j], v) > 0
                a[j + 1] := a[j], j--
            a[j + 1] := v
        }
    }
}
Check("order", GetOrderedText({Words: [w("world", 60, 3), w("second", 10, 40), w("Hello", 10, 0), w("line", 60, 44)]}), "Hello world`nsecond line")
Check("order, large font", GetOrderedText({Words: [w("the", 60, 0, 50), w("on", 10, 16, 34), w("top", 120, 14, 50), w("below", 10, 80, 50)]}), "on the top`nbelow")
Check("no words", GetOrderedText({Words: []}), "")

Out(passed " passed, " failed " failed")
ExitApp(failed ? 1 : 0)

Split(text, expected) {
    s := ""
    for p in SplitSentences(text)
        s .= (A_Index = 1 ? "" : "|") p.text (p.complete ? "" : "?")
    Check("split", s, expected)
}
Check(name, got, want) {
    global
    if got == want
        passed++
    else
        failed++, Out("FAIL " name "`n   got  " got "`n   want " want)
}
Out(s) => FileAppend(s "`n", "*", "UTF-8")
