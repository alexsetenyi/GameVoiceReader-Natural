#Requires AutoHotkey v2

/**
 * Turns repeated snapshots of one screen area into one continuous text.
 * Needs TextTools.ahk.
 *
 * Feed() gets the lines currently visible and returns the sentences that are new,
 * whether the text scrolled, grew letter by letter or was replaced by the next page.
 *
 *  - Only the column the text is in counts. Pieces of lines beside it, read from a portrait,
 *    a map or a health bar, are left out unless they look like sentences themselves.
 *  - A line counts once two snapshots in a row agree on it. That ignores half typed
 *    lines, frames in the middle of a scroll and the game world behind the text.
 *    While the text scrolls by more than a line at a time, lines that passed by in a
 *    single snapshot are taken too.
 *  - Words are compared with what was read before in groups of three, tolerating
 *    single OCR mistakes. Whatever is not known yet is new.
 *  - A page that shares nothing with the one before is read in full, even when a phrase of
 *    it was read long ago. If it starts in the middle of a sentence, it continues the
 *    sentence that the last page left unfinished.
 *  - A sentence cut off by the edge of the box is held back until the rest appears,
 *    or until nothing changes and there is nothing else left to say.
 */
class TextFollower {
    static Known := 2000         ; how many words to remember, a few pages of a book

    __New(flushMs := 1500) {
        this.flushMs := flushMs
        this.Reset()
    }

    Reset() {
        this.norms := [], this.raws := []     ; everything read so far, word by word
        this.previous := Map()                ; lines of the last snapshot, key -> position
        this.previousList := []               ; [{key, text, y, h}]
        this.column := 0                      ; where the text was: {x1, x2}
        this.lastKey := ""
        this.page := []                       ; words of the last accepted snapshot
        this.pending := ""                    ; unfinished sentence
        this.pendingSince := 0
    }

    ; Starts over with text that is read right away. With holdTail an unfinished last
    ; sentence waits for its continuation.
    Prime(lines, holdTail, now := A_TickCount) {
        this.Reset()
        lines := this._Region(lines)
        this._Remember(lines)
        words := TextFollower.Words(lines)
        this.page := words
        this.lastKey := TextFollower.Key(words)
        out := []
        this._Append(words, out, now)
        if !holdTail
            this._Flush(out)
        return out
    }

    ; lines: [{text, y, h}], height of the area, idle: nothing left to say
    Feed(lines, height, idle, now := A_TickCount) {
        out := []
        lines := this._Region(this._Filter(lines, height))
        stable := this._Stable(lines, height)
        this._Remember(lines)
        if stable.Length {
            words := TextFollower.Words(stable)
            key := TextFollower.Key(words)
            if words.Length && key != this.lastKey {
                this.lastKey := key
                this._Merge(words, out, now)
                this.page := words
            }
        }
        if this.pending != "" && idle && !out.Length && now - this.pendingSince >= this.flushMs
            this._Flush(out)
        return out
    }

    ; -------------------------------------------------------------- snapshots

    _Filter(lines, height) {
        heights := ""
        for l in lines
            heights .= (A_Index = 1 ? "" : ",") l.h
        median := 0
        if lines.Length
            list := StrSplit(Sort(heights, "N D,"), ","), median := list[list.Length // 2 + 1]
        kept := []
        for l in lines {
            ; a line cut through by the edge of the box reads as nonsense
            if lines.Length > 1 && l.h < median * 0.75 && (l.y <= 2 || l.y + l.h >= height - 2)
                continue
            ; scraps of a frame or portrait at the ends of a line (GUESS: which symbols are scraps)
            text := RegExReplace(l.text, "^(?:[^\p{L}\p{N}\x22'“‘«(\[*\s]+\s+)+")
            text := RegExReplace(text, "(?:\s+[|~\\/_=<>°^¦]+)+$")
            letters := TextFollower.Letters(text)
            solid := StrLen(RegExReplace(text, "\s"))
            if letters < 2 || letters / solid < 0.6
                continue
            ; very short lines have to look like a word: "No!" but not "-iI"
            if letters < 4 && !RegExMatch(text, "^\W*\p{L}{2,}[.!?…]")
                continue
            k := l.Clone(), k.text := text, k.key := TextFollower.LineKey(text)
            kept.Push(k)
        }
        return kept
    }

    ; Keeps the column the text is in. Lines beside it, such as scraps read from a portrait,
    ; a map or a health bar, are left out unless they read like sentences themselves.
    ; Text that stays the same from one snapshot to the next weighs more than scraps that change.
    ; GUESS: lines belong to one column when they overlap across by 30% of the narrower one.
    _Region(lines) {
        if lines.Length < 2 || !lines[1].HasOwnProp("w")
            return lines
        columns := []
        for i, l in lines {
            x1 := l.x, x2 := l.x + l.w, home := 0
            for c in columns
                if Min(x2, c.x2) - Max(x1, c.x1) > Min(x2 - x1, c.x2 - c.x1) * 0.3 {
                    home := c
                    break
                }
            if !home
                columns.Push(home := {x1: x1, x2: x2, letters: 0, lines: Map()})
            home.x1 := Min(home.x1, x1), home.x2 := Max(home.x2, x2)
            key := l.HasOwnProp("key") ? l.key : TextFollower.LineKey(l.text)
            home.letters += TextFollower.Letters(l.text) * (this.previous.Has(key) ? 3 : 1), home.lines[i] := 1
        }
        main := columns[1]
        for c in columns
            if c.letters > main.letters
                main := c
        ; stay with the column of before while it still holds a fair part of the text
        if this.column && !this._InColumn(main)
            for c in columns
                if this._InColumn(c) && c.letters >= main.letters / 3 {
                    main := c
                    break
                }
        if main.letters >= 15
            this.column := {x1: main.x1, x2: main.x2}
        out := []
        for i, l in lines
            if main.lines.Has(i) || TextFollower.Prose(l.text)
                out.Push(l)
        return out
    }

    _InColumn(c) => Min(c.x2, this.column.x2) - Max(c.x1, this.column.x1) > Min(c.x2 - c.x1, this.column.x2 - this.column.x1) * 0.3

    _Remember(lines) {
        this.previous := Map(), this.previousList := []
        for l in lines {
            key := l.HasOwnProp("key") ? l.key : TextFollower.LineKey(l.text)
            if !this.previous.Has(key)
                this.previous[key] := A_Index
            item := {key: key, text: l.text}
            if l.HasOwnProp("y")
                item.y := l.y, item.h := l.h
            this.previousList.Push(item)
        }
    }

    ; The lines from the first to the last one that the previous snapshot agrees with.
    ; When the text moved by two lines or more, it scrolls: the new lines that came in are
    ; taken as well, and so are the lines of the previous snapshot that went out of view.
    _Stable(lines, height) {
        prev := this.previousList
        first := 0, last := 0, from := 0, to := 0, shifts := []
        pitch := TextFollower.Pitch(lines)
        for i, l in lines {
            j := this.previous.Get(l.key, 0)
            if !j
                for p in prev {
                    ; the last line may still be growing, so it must not be longer than before
                    if i = lines.Length && StrLen(l.key) > StrLen(p.key)
                        continue
                    ; a line that stayed in place may differ more than one that moved
                    enough := (A_Index = i && lines.Length = prev.Length) ? 0.55 : 0.72
                    if Abs(StrLen(l.key) - StrLen(p.key)) <= 3 && TextFollower.Dice(l.key, p.key) >= enough {
                        j := A_Index
                        break
                    }
                }
            if j {
                first := first || i, from := from || j
                last := i, to := j
                ; how many lines it moved up
                shifts.Push(pitch && l.HasOwnProp("y") && prev[j].HasOwnProp("y") ? (prev[j].y - l.y) / pitch : j - i)
            }
        }
        out := []
        if !first
            return out
        shift := TextFollower.Median(shifts)
        ; GUESS: two lines at once is scrolling, text that is typed or added to a log moves by one
        if shift >= 1.6 {
            loop from - 1                          ; went out at the top
                out.Push(prev[A_Index])
            last := lines.Length
            if last > first && TextFollower.AtEdge(lines[last], height, false)
                last--
        } else if shift <= -1.6 {
            first := 1
            if first < last && TextFollower.AtEdge(lines[first], height, true)
                first++
        }
        loop last - first + 1
            out.Push(lines[first + A_Index - 1])
        if shift <= -1.6
            loop prev.Length - to                  ; went out at the bottom
                out.Push(prev[to + A_Index])
        return out
    }

    ; --------------------------------------------------------------- matching

    _Merge(words, out, now) {
        n := words.Length, known := this.norms.Length
        if !known {
            this._Append(words, out, now)
            return
        }
        at := []                       ; for every word: its position in the known text, 0 = new
        at.Length := n
        loop n
            at[A_Index] := 0

        this._MatchGrowth(words, at)
        this._MatchTriples(words, at)
        this._MatchWithHole(words, at)
        this._MatchOverlap(words, at)
        this._Extend(words, at)

        covered := 0
        for p in at
            covered += p > 0
        ; A page that shares nothing with the one before is a new page, even if some of it
        ; was read long ago. GUESS: less than half of it known.
        if covered && covered < n * 0.5 && !this._FromPage(words) {
            loop n
                at[A_Index] := 0
            covered := 0
        }
        if !covered {
            ; next page; when it starts in the middle of a sentence it goes on with the last one
            if !RegExMatch(words[1].raw, "^[^\p{L}\p{N}]*\p{Ll}")
                this._Flush(out)
            this._Append(words, out, now)
            return
        }

        ; go through the runs of unknown words
        fresh := [], above := 0
        i := 1
        while i <= n {
            if at[i] {
                i++
                continue
            }
            a := i
            while i <= n && !at[i]
                i++
            b := i - 1, len := b - a + 1
            if a = 1 {
                ; Text above something known: scrolled up, or a line that was cut off.
                ; Only if nearly everything is unknown is it a new page with a familiar ending.
                if covered / n >= 0.4 || len < 5
                    above := b                     ; remembered below, positions must not shift yet
                else
                    fresh.Push({a: a, b: this._SentenceEnd(words, b), joined: false})
            } else if b < n {
                ; Unknown words between known ones: an OCR mistake if the gap has the same size
                if len < 4 || Abs((at[b + 1] - at[a - 1]) - (len + 1)) <= 2 || this._SeenNear(words, a, b, at[a - 1], at[b + 1])
                    continue
                fresh.Push({a: this._SentenceStart(words, a), b: this._SentenceEnd(words, b), joined: false})
            } else {
                left := at[a - 1]
                if left >= known
                    fresh.Push({a: a, b: b, joined: true})
                else if (same := this._Misread(words, a, len, left)) {
                    if same < len                  ; the rest comes after everything known
                        fresh.Push({a: a + same, b: b, joined: true})
                } else
                    fresh.Push({a: this._SentenceStart(words, a), b: b, joined: false})
            }
        }
        if above
            this._Learn(words, 1, above)
        last := 0
        for run in fresh {
            run.a := Max(run.a, last + 1)
            if run.a > run.b
                continue
            last := run.b
            part := []
            loop run.b - run.a + 1
                part.Push(words[run.a + A_Index - 1])
            if !run.joined
                this._Flush(out)
            this._Append(part, out, now)
        }
    }

    ; Three words in a row that the last accepted snapshot also had
    _FromPage(words) {
        seen := Map(), m := this.page.Length
        loop m - 2
            seen[this.page[A_Index].norm " " this.page[A_Index + 1].norm " " this.page[A_Index + 2].norm] := 1
        loop words.Length - 2
            if seen.Has(words[A_Index].norm " " words[A_Index + 1].norm " " words[A_Index + 2].norm)
                return true
        return false
    }

    ; How many words from a on are a misread version of what followed there before
    _Misread(words, a, len, left) {
        n := Min(len, this.norms.Length - left)
        if n > 12
            return 0
        got := "", was := ""
        loop n
            got .= words[a + A_Index - 1].norm " ", was .= this.norms[left + A_Index] " "
        ; less doubt is needed when exactly the last word or two are left to compare
        enough := (n = len && left + n = this.norms.Length && n <= 2) ? 0.3 : 0.6
        return TextFollower.Alike(got, was, enough) ? n : 0
    }

    ; Most of these words also occur where their neighbours are known from
    _SeenNear(words, a, b, left, right) {
        len := b - a + 1, hits := 0
        loop len {
            w := words[a + A_Index - 1].norm
            for center in [left, right] {
                j := Max(1, center - len - 3)
                while j <= Min(this.norms.Length, center + len + 3) {
                    if TextFollower.Similar(w, this.norms[j]) {
                        hits++
                        continue 3
                    }
                    j++
                }
            }
        }
        return hits / len >= 0.6
    }

    ; The last snapshot with something added behind it (text appearing letter by letter)
    _MatchGrowth(words, at) {
        m := this.page.Length, known := this.norms.Length
        if !m || m > words.Length || m > known
            return
        loop m - 1
            if !TextFollower.Similar(words[A_Index].norm, this.page[A_Index].norm)
                return
        ; only if that snapshot is also the end of what was read
        loop m
            if !TextFollower.Similar(this.norms[known - m + A_Index], this.page[A_Index].norm)
                return
        if this._CompleteLast(words[m]) || TextFollower.Similar(words[m].norm, this.page[m].norm) {
            loop m
                at[A_Index] := known - m + A_Index
        }
    }

    ; The last word was caught while it was still being typed
    _CompleteLast(word) {
        known := this.norms.Length
        old := this.norms[known], raw := this.raws[known]
        if this.pending = "" || StrLen(word.norm) <= StrLen(old) || SubStr(word.norm, 1, StrLen(old)) != old
            return false
        if SubStr(this.pending, -StrLen(raw)) != raw
            return false
        this.pending := SubStr(this.pending, 1, StrLen(this.pending) - StrLen(raw)) word.raw
        this.norms[known] := word.norm, this.raws[known] := word.raw
        return true
    }

    _MatchTriples(words, at) {
        n := words.Length, known := this.norms.Length
        if n < 3 || known < 3
            return
        index := Map()
        loop known - 2 {
            key := this.norms[A_Index] " " this.norms[A_Index + 1] " " this.norms[A_Index + 2]
            if index.Has(key)
                index[key].Push(A_Index)
            else
                index[key] := [A_Index]
        }
        expected := 0
        loop n - 2 {
            i := A_Index
            key := words[i].norm " " words[i + 1].norm " " words[i + 2].norm
            if !index.Has(key) {
                if expected
                    expected++
                continue
            }
            hits := index[key], best := hits[hits.Length]
            for j in hits                          ; prefer staying in the same passage
                if expected && Abs(j - expected) < Abs(best - expected)
                    best := j
            loop 3
                at[i + A_Index - 1] := at[i + A_Index - 1] || best + A_Index - 1
            expected := best + 1
        }
    }

    ; Four words in a row of which one in the middle was misread
    _MatchWithHole(words, at) {
        n := words.Length, known := this.norms.Length
        if n < 4 || known < 4
            return
        index := Map()
        loop known - 3 {
            a := this.norms[A_Index], d := this.norms[A_Index + 3]
            index[a " " this.norms[A_Index + 1] " ~ " d] := A_Index
            index[a " ~ " this.norms[A_Index + 2] " " d] := A_Index
        }
        loop n - 3 {
            i := A_Index
            if at[i] && at[i + 1] && at[i + 2] && at[i + 3]
                continue
            a := words[i].norm, d := words[i + 3].norm
            j := index.Get(a " " words[i + 1].norm " ~ " d, 0) || index.Get(a " ~ " words[i + 2].norm " " d, 0)
            if j
                loop 4
                    at[i + A_Index - 1] := at[i + A_Index - 1] || j + A_Index - 1
        }
    }

    ; Short overlap: the end of the known text is the start of this snapshot
    _MatchOverlap(words, at) {
        for p in at
            if p
                return
        n := words.Length, known := this.norms.Length
        k := Min(n, known, 8)
        while k >= 1 {
            ok := true
            loop k
                if !TextFollower.Similar(words[A_Index].norm, this.norms[known - k + A_Index]) {
                    ok := false
                    break
                }
            ; one or two words prove nothing, unless they are all there is or a sentence is open
            if ok && (k >= 3 || (k = 2 && this.pending != "") || k = n || k = known) {
                loop k
                    at[A_Index] := known - k + A_Index
                return
            }
            k--
        }
    }

    ; Grows every known stretch in both directions, tolerating misread words
    _Extend(words, at) {
        n := words.Length, known := this.norms.Length
        i := 1
        while i < n {
            if !at[i] || at[i + 1] {
                i++
                continue
            }
            p := i + 1, j := at[i] + 1
            while p <= n && !at[p] && j <= known {
                w := words[p].norm
                if TextFollower.Similar(w, this.norms[j]) {
                    at[p] := j, p++, j++
                } else if j < known && w = this.norms[j] this.norms[j + 1] {
                    at[p] := j + 1, p++, j += 2                    ; two words read as one
                } else if p < n && !at[p + 1] && words[p].norm words[p + 1].norm = this.norms[j] {
                    at[p] := j, at[p + 1] := j, p += 2, j++        ; one word read as two
                } else if p < n && j < known && !at[p + 1] && TextFollower.Similar(words[p + 1].norm, this.norms[j + 1])
                    && TextFollower.Alike(w, this.norms[j], 0.3) {
                    at[p] := j, at[p + 1] := j + 1, p += 2, j += 2 ; one badly misread word
                } else if j = known && this._CompleteLast(words[p]) {
                    at[p] := j, p++, j++
                } else
                    break
            }
            i := p
        }
        i := n
        while i > 1 {
            if at[i] > 1 && !at[i - 1] {
                p := i - 1, j := at[i] - 1
                while p >= 1 && !at[p] && j >= 1 && TextFollower.Similar(words[p].norm, this.norms[j])
                    at[p] := j, p--, j--
                i := p + 1
            }
            i--
        }
    }

    ; A new run that starts in the middle of a sentence is widened to the whole sentence
    _SentenceStart(words, i) {
        steps := 0
        while i > 1 && steps < 15 && !RegExMatch(words[i - 1].raw, "[.!?…][\x22'”’)]*$")
            i--, steps++
        return i
    }

    _SentenceEnd(words, i) {
        steps := 0
        while i < words.Length && steps < 15 && !RegExMatch(words[i].raw, "[.!?…][\x22'”’)]*$")
            i++, steps++
        return i
    }

    ; ----------------------------------------------------------------- output

    ; Known from now on, but not spoken. Goes in front, so the end stays the end.
    _Learn(words, a, b) {
        i := b
        while i >= a {
            this.norms.InsertAt(1, words[i].norm), this.raws.InsertAt(1, words[i].raw)
            i--
        }
        this._Trim()
    }

    _Append(words, out, now) {
        for w in words {
            this.norms.Push(w.norm), this.raws.Push(w.raw)
            this.pending .= (this.pending = "" ? "" : " ") w.raw
        }
        this._Trim()
        if words.Length
            this.pendingSince := now
        pieces := SplitSentences(this.pending)
        this.pending := ""
        for piece in pieces
            if piece.complete
                this._Say(piece.text, out)
            else
                this.pending := piece.text
    }

    _Flush(out) {
        if this.pending != ""
            this._Say(this.pending, out)
        this.pending := ""
    }

    _Say(text, out) {
        if RegExMatch(text, "[\p{L}\p{N}]")
            out.Push(text)
    }

    _Trim() {
        extra := this.norms.Length - TextFollower.Known
        if extra > 0
            this.norms.RemoveAt(1, extra), this.raws.RemoveAt(1, extra)
    }

    ; ------------------------------------------------------------------ words

    ; Words of some lines as [{raw, norm}]. Pure punctuation stays with the word before it.
    static Words(lines) {
        list := []
        for l in lines
            loop parse CleanOcrText(l.text), " " {
                norm := TextFollower.Norm(A_LoopField)
                if norm != ""
                    list.Push({raw: A_LoopField, norm: norm})
                else if list.Length && A_LoopField != ""
                    list[list.Length].raw .= " " A_LoopField
            }
        return list
    }

    ; Only for comparing: without case, punctuation and the usual OCR confusions
    static Norm(word) {
        word := RegExReplace(StrLower(word), "[^\p{L}\p{N}|]")
        word := StrReplace(StrReplace(StrReplace(word, "0", "o"), "rn", "m"), "vv", "w")
        return RegExReplace(word, "[1l|]", "i")
    }

    static Letters(text) => StrLen(RegExReplace(text, "[^\p{L}]"))

    ; Reads like a sentence: at least three words, nearly all of them made of letters
    static Prose(text) {
        words := 0, real := 0
        loop parse text, " " {
            if A_LoopField = ""
                continue
            words++
            real += RegExMatch(A_LoopField, "^\W*\p{L}{2,}\W*$") > 0
        }
        return real >= 3 && real >= words * 0.8
    }

    ; Distance from one line to the next
    static Pitch(lines) {
        if lines.Length < 2 || !lines[1].HasOwnProp("y")
            return 0
        steps := []
        loop lines.Length - 1
            if (d := lines[A_Index + 1].y - lines[A_Index].y) > 0
                steps.Push(d)
        return steps.Length ? TextFollower.Median(steps) : 0
    }

    static AtEdge(line, height, top) {
        if !line.HasOwnProp("y")
            return false
        return top ? line.y <= 2 : line.y + line.h >= height - 2
    }

    static Median(list) {
        if !list.Length
            return 0
        s := ""
        for v in list
            s .= (A_Index = 1 ? "" : ",") v
        sorted := StrSplit(Sort(s, "N D,"), ",")
        return Number(sorted[sorted.Length // 2 + 1])
    }

    static LineKey(text) => Trim(RegExReplace(TextFollower.Norm(text), "\s+"))

    static Key(words) {
        s := ""
        for w in words
            s .= w.norm " "
        return s
    }

    static Similar(a, b) {
        if a = b
            return true
        la := StrLen(a), lb := StrLen(b)
        if Min(la, lb) < 4 || Abs(la - lb) > 1
            return false
        return TextFollower.Distance(a, b) <= (Min(la, lb) >= 8 ? 2 : 1)
    }

    ; Loosely the same word
    static Alike(a, b, part) => 1 - TextFollower.Distance(a, b) / Max(StrLen(a), StrLen(b), 1) >= part

    static Distance(a, b) {
        la := StrLen(a), lb := StrLen(b), row := []
        loop lb + 1
            row.Push(A_Index - 1)
        loop parse a {
            diagonal := row[1], row[1] := A_Index, c := A_LoopField
            loop parse b {
                above := row[A_Index + 1]
                row[A_Index + 1] := Min(above + 1, row[A_Index] + 1, diagonal + (c != A_LoopField))
                diagonal := above
            }
        }
        return row[lb + 1]
    }

    ; Similarity of two lines by shared pairs of letters, 0 to 1
    static Dice(a, b) {
        la := StrLen(a) - 1, lb := StrLen(b) - 1
        if la < 1 || lb < 1
            return a = b
        pairs := Map()
        loop la {
            p := SubStr(a, A_Index, 2)
            pairs[p] := pairs.Get(p, 0) + 1
        }
        shared := 0
        loop lb {
            p := SubStr(b, A_Index, 2)
            if pairs.Get(p, 0) > 0
                pairs[p]--, shared++
        }
        return 2 * shared / (la + lb)
    }
}
