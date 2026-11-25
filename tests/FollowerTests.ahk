#Requires AutoHotkey v2
#SingleInstance Off
#Warn All, StdOut
#Warn LocalSameAsGlobal, Off
#Include ..\Lib\OCR.ahk
#Include ..\Lib\TextTools.ahk
#Include ..\Lib\TextFollower.ahk
; Simulates what a reader sees on screen and checks what would be spoken.
OnError((e, m) => (Out("ERR " e.Message " / " e.What " line " e.Line " " e.Extra), ExitApp(1)))
global failed := 0, passed := 0, f := "", now := 0, said := [], slowest := 0

journal := [
    "The third winter was the worst of them. We had", "eaten the last of the barley by midwinter, and", "the hunters came home with nothing but frost on",
    "their cloaks. Elder Maren said the herds had gone", "south. I did not believe her. There were tracks", "in the snow behind the palisade, large ones, and",
    "they did not belong to any beast I know. On the", "ninth night the dogs stopped barking. We found", "them in the morning huddled under the granary",
    "floor, alive but silent. Nobody could coax them", "out again. Tomas went to look for the tracks with", "two others. He carried my father's lantern. It is",
    "still burning on the ridge, but none of them has", "come back to us. If you read this, do not follow", "the light. Seal the gate and wait for the thaw."]
full := Joined(journal)

; --- scrolling a journal, different step sizes, held still for a few polls each
for step in [1, 2, 3, 5] {
    Begin()
    top := 1
    loop {
        Show(Window(journal, top, 6), 4)
        if top + 5 >= journal.Length
            break
        top := Min(top + step, journal.Length - 5)
    }
    Idle()
    Check("scroll by " step, Spoken(), full)
}
; --- quick scroll: every position visible for only two polls
Begin()
loop journal.Length - 5
    Show(Window(journal, A_Index, 6), 2)
Idle()
Check("quick scroll", Spoken(), full)

; --- smooth scrolling: blurred, half cut lines at the edges while moving
Begin()
Show(Window(journal, 1, 6), 3)
loop 9 {
    top := A_Index
    loop 3
        Show(Clipped(Window(journal, top, 6)), 1)
    Show(Window(journal, top + 1, 6), 3)
}
Idle()
Check("smooth scroll with cut lines", Spoken(), full)

; --- scroll to the end, back to the start, and down again: read once
Begin()
for top in [1, 4, 7, 10, 7, 4, 1, 4, 7, 10]
    Show(Window(journal, top, 6), 3)
Idle()
Check("scroll back and forth", Spoken(), full)

; --- starting in the middle and scrolling up must not read backwards
Begin()
for top in [8, 6, 4, 2, 1]
    Show(Window(journal, top, 6), 3)
Idle()
Check("scroll up only", Spoken(), Joined(Window(journal, 8, 6)))

; --- while something is still being spoken, a cut off sentence waits for its end
Begin()
Show(Window(journal, 1, 6), 8, false)
Check("cut off sentence is held", Spoken(), "The third winter was the worst of them. We had eaten the last of the barley by midwinter, and the hunters came home with nothing but frost on their cloaks. Elder Maren said the herds had gone south. I did not believe her.")
Show(Window(journal, 4, 6), 3, false)
Check("and completed after scrolling, as one sentence", Has("There were tracks in the snow behind the palisade, large ones, and they did not belong to any beast I know."), 1)

; --- fast scroll: each position visible for one poll only, moving most of the box at a time
for step in [2, 3, 4, 5] {
    Begin()
    top := 1
    loop {
        Show(Window(journal, top, 6), 1)
        if top + 5 >= journal.Length
            break
        top := Min(top + step, journal.Length - 5)
    }
    Show(Window(journal, top, 6), 3)
    Idle()
    Check("fast scroll by " step, Spoken(), full)
}
; --- fast scroll up from the end does not read backwards, and loses nothing going down again
Begin()
for top in [10, 10, 10, 7, 4, 1, 4, 7, 10, 10, 10]
    Show(Window(journal, top, 6), 1)
Idle()
Check("fast scroll up and down", Spoken(), Joined(Window(journal, 10, 6)))

; --- pages of a book: a sentence goes on over the page break
Begin()
for top in [1, 6, 11]
    Show(Window(journal, top, 5), 3, false)
Idle()
Check("book pages", Spoken(), full)
Check("sentence over the page break", Has("There were tracks in the snow behind the palisade, large ones, and they did not belong to any beast I know."), 1)

; --- an old page comes back after a lot of other text: not read again
Begin()
Show(Window(journal, 1, 5), 3)
vocab := StrSplit("amber bridge candle dagger ember falcon garden harbor island jewel kettle ladder meadow needle orchard pepper quarry ribbon saddle timber velvet wagon yonder zenith", " ")
loop 70 {
    p := ""
    loop 12
        p .= vocab[Random(1, vocab.Length)] (A_Index = 12 ? "." : " ")
    Show(Wrap(StrUpper(SubStr(p, 1, 1)) SubStr(p, 2), 40), 3)
}
Show(Window(journal, 1, 5), 3)
Idle()
Check("old page not read again", StrSplit(Spoken(), "The third winter").Length, 2)

; --- a new page that shares a phrase with something read long ago is read in full
Begin()
Show(["The bell rang twice before dawn, and nobody", "came to the gate of the old mill."], 3)
Show(["We waited."], 3)
Show(["Later the bell rang twice before dawn, and", "this time the miller himself stood there."], 3)
Idle()
Check("page with an old phrase", Spoken(), "The bell rang twice before dawn, and nobody came to the gate of the old mill. We waited. Later the bell rang twice before dawn, and this time the miller himself stood there.")

; --- a health bar and a counter in the corners of a big box
Begin()
for p in ["You should rest before the climb tonight.", "The path is steep and the rope is old."]
    Show([{text: "HP 120/140", x: 10, y: 5, w: 80, h: 18}, {text: p, x: 100, y: 300, w: 400, h: 20},
          {text: "x3 Arrows", x: 520, y: 5, w: 70, h: 18}], 4)
Idle()
Check("bars and counters left out", Spoken(), "You should rest before the climb tonight. The path is steep and the rope is old.")

; --- typewriter text, at several speeds
for speed in [2, 5, 9, 17] {
    Begin()
    line := "You should not have come here. The warden knows your face, and he has a long memory. Leave by the mill gate before the bell."
    n := 0
    while n < StrLen(line) {
        n := Min(n + speed, StrLen(line))
        Show(Wrap(SubStr(line, 1, n), 45), 1, false)
    }
    Show(Wrap(line, 45), 3, false)
    Idle()
    Check("typewriter " speed, Spoken(), line)
}
; --- typewriter that pauses in the middle of words
Begin()
line := "Nothing grows past the old quarry any more."
for n in [3, 9, 9, 9, 12, 12, 12, 21, 21, 21, 30, 30, 43, 43, 43]
    Show([SubStr(line, 1, n)], 1, false)
Idle()
Check("typewriter with pauses inside words", Spoken(), line)

; --- dialogue pages
pages := ["Ah, there you are at last. I was beginning to worry.", "Yes.", "Did you bring the letter? Give it here.", "Hmm.", "This is not my brother's handwriting! Where did you get it from?", "Yes.", "I see. Then we are both in danger now."]
Begin()
for p in pages
    Show(Wrap(p, 40), 4), Show([], 2)
Idle()
Check("dialogue pages", Spoken(), Joined(pages))

; --- same, with a constant speaker name and footer around it
Begin()
for p in pages
    Show(["Elder Maren", Wrap(p, 40)*], 4)
Idle()
for p in pages
    Check("page with speaker name", InStr(Spoken(), p) > 0, 1)
Begin()
for p in ["The road is closed until further notice.", "Nobody leaves the valley without a permit from the steward.", "You may ask for one at the old toll house."]
    Show(Framed("Conversation with the gate captain", Wrap(p, 40), "Press space bar to continue"), 4)
Idle()
Check("footer read once", StrSplit(Spoken(), "Press space bar").Length, 2)
Check("second page with header and footer", InStr(Spoken(), "Nobody leaves the valley without a permit from the steward.") > 0, 1)
Check("third page with header and footer", InStr(Spoken(), "You may ask for one at the old toll house.") > 0, 1)

; --- page that only differs at the end is read as a whole sentence
Begin()
Show(["What do you want to know about the valley?"], 3)
Show(["The valley was settled four hundred years ago."], 3)
Show(["What do you want to know about the mine?"], 3)
Idle()
Check("similar pages in full", Spoken(), "What do you want to know about the valley? The valley was settled four hundred years ago. What do you want to know about the mine?")
Check("similar question again", Has("What do you want to know about the mine?"), 1)

; --- dialogue log that grows at the bottom and drops lines at the top
Begin()
history := ["Who goes there?", "A friend, carrying news from the coast.", "Friends do not come by night.", "Then call me a stranger with good manners.", "Come closer to the fire, stranger.", "Thank you. The wind is cruel tonight."]
loop history.Length
    Show(Window(history, Max(1, A_Index - 3), Min(4, A_Index)), 3)
Idle()
Check("growing log", Spoken(), Joined(history))

; --- the game world behind an empty box
Begin()
Show(["Keep to the lantern road after dark."], 3)
loop 40
    Show(Noise(), 1)
Idle()
Check("world noise is ignored", Spoken(), "Keep to the lantern road after dark.")

; --- text already read by hand: following continues from there
Begin()
said := f.Prime(Rows(Window(journal, 1, 6)), true, now)
for top in [1, 3, 6, 9, 10]
    Show(Window(journal, top, 6), 3)
Idle()
Check("continue after reading by hand", Spoken(), full)

; --- by hand without following reads the unfinished end too
Begin()
said := f.Prime(Rows(Window(journal, 1, 3)), false, now)
Check("read by hand reads everything", Spoken(), Joined(Window(journal, 1, 3)))

; --- a portrait next to the text, read as scraps that change all the time
Begin()
for p in pages {
    loop 4 {
        shown := []
        for t in Wrap(p, 40)
            shown.Push({text: t, x: 140, y: 10 + A_Index * 30, w: 260, h: 20})
        loop Random(0, 2)                  ; one or two scraps of a few letters
            shown.Push({text: SubStr(Noise(1)[1], 1, Random(2, 6)), x: 10 + Random(0, 30), y: 10 + Random(0, 3) * 30, w: 70, h: 20})
        Show(shown, 1)
    }
}
Idle()
Check("portrait next to the text", Spoken(), Joined(pages))

; --- repeated OCR mistakes: nothing lost, hardly anything twice
worst := 0, lost := 0, total := 0
loop 100 {
    Begin()
    top := 1
    loop {
        loop 4
            Show(Mangle(Window(journal, top, 6)), 1)
        if top + 5 >= journal.Length
            break
        top := Min(top + Random(1, 4), journal.Length - 5)
    }
    Idle()
    got := StrSplit(Spoken(), " ").Length, want := StrSplit(full, " ").Length
    if got - want > 12 || want - got > 2
        Out("  sample " got ": " Spoken())
    worst := Max(worst, got - want), total += got - want, lost := Max(lost, want - got)
}
Out("with OCR mistakes in 2% of letters: " want " words, at most " worst " extra and " lost " missing in 100 runs")
Out("  on average " Round(total / 100, 1) " extra words")
Check("few words repeated", total / 100 <= 3, 1)
Check("few words lost", lost <= 8, 1)
Out("slowest step " slowest "ms")
Check("fast enough", slowest < 60, 1)

Out(passed " passed, " failed " failed")
ExitApp(failed ? 1 : 0)

; ---------------------------------------------------------------- helpers
Begin() {
    global f := TextFollower(1500), said := [], now := 100000
}
Show(texts, polls, idle := true) {
    global now, said, slowest
    loop polls {
        now += 250
        DllCall("QueryPerformanceCounter", "int64*", &c0 := 0)
        for s in f.Feed(Rows(texts), 400, idle, now)
            said.Push(s)
        DllCall("QueryPerformanceCounter", "int64*", &c1 := 0), DllCall("QueryPerformanceFrequency", "int64*", &fr := 0)
        slowest := Max(slowest, Round((c1 - c0) * 1000 / fr))
    }
}
Idle() {
    global now, said
    now += 5000
    for s in f.Feed([], 400, true, now)
        said.Push(s)
}
Rows(texts) {
    list := []
    for t in texts
        list.Push(IsObject(t) ? t : {text: t, y: 10 + A_Index * 30, h: 20})
    return list
}
Window(all, top, count) {
    w := []
    loop count
        if top + A_Index - 1 <= all.Length
            w.Push(all[top + A_Index - 1])
    return w
}
Clipped(w) {
    r := Rows(w)
    r[1] := {text: "fke a rn vv oarts " Random(100, 999), y: 0, h: 9}
    r[r.Length] := {text: "ine oo uts nve", y: 391, h: 9}
    return r
}
Wrap(text, width) {
    lines := [], line := ""
    loop parse text, " " {
        if line != "" && StrLen(line " " A_LoopField) > width
            lines.Push(line), line := A_LoopField
        else
            line .= (line = "" ? "" : " ") A_LoopField
    }
    lines.Push(line)
    return lines
}
Framed(head, lines, foot) {
    lines.InsertAt(1, head), lines.Push(foot)
    return lines
}
Mangle(w) {
    out := []
    for t in w {
        s := ""
        loop parse t
            s .= (A_LoopField != " " && Random() < 0.02) ? SubStr("lo0c1rnea", Random(1, 9), 1) : A_LoopField
        out.Push(s)
    }
    return out
}
Noise(count := Random(0, 4)) {
    list := []
    loop count {
        s := ""
        loop Random(2, 14)
            s .= SubStr("ilI|. -oacwvTrnm", Random(1, 16), 1)
        list.Push(s)
    }
    return list
}
Joined(a) {
    s := ""
    for t in a
        s .= (A_Index = 1 ? "" : " ") t
    return s
}
Spoken() => Joined(said)
Has(sentence) {
    for s in said
        if s = sentence
            return 1
    return 0
}
Check(name, got, want) {
    global
    if got == want
        passed++
    else
        failed++, Out("FAIL " name "`n   got  " got "`n   want " want)
}
Out(s) => FileAppend(s "`n", "*", "UTF-8")
