#Requires AutoHotkey v2
/**
 * Reads a screen area with Windows OCR, with fewer misread letters than a single pass:
 * - The capture is enlarged smoothly (bicubic) instead of by repeating pixels.
 * - It can be read at several sizes. The lines of the passes are compared word by word and
 *   the reading most passes agree on wins, preferring real words.
 * - Words that are not in the dictionary are repaired when a typical OCR confusion explains
 *   them (rn/m, cl/d, l/I/1, ...) or when two words were read as one ("ofthem").
 * Read() returns lines in reading order: [{text, x, y, w, h}], relative to the area.
 * Needs Lib\OCR.ahk and Lib\TextTools.ahk.
 */
class OcrReader {
    /**
     * @param scales enlargement of each pass, e.g. [2, 3]; the first one gives the line positions
     * @param fix repair words with the Windows spell checker
     * @param lang OCR and spell checker language, e.g. "en-US"; empty = first OCR language
     */
    __New(scales := [2], fix := true, lang := "") {
        static started := 0
        if !started {
            si := Buffer(24, 0), NumPut("uint", 1, si)
            DllCall("gdiplus\GdiplusStartup", "ptr*", &token := 0, "ptr", si, "ptr", 0)
            started := 1
        }
        this.scales := scales, this.lang := lang
        this.spell := (fix || scales.Length > 1) ? SpellChecker(lang) : 0
        this.fix := fix && this.spell && this.spell.ok
        this.fixCache := Map()
        this.fixCache.CaseSense := true
    }

    Read(x, y, w, h) {
        src := OcrReader.Capture(x, y, w, h)
        passes := []
        try {
            for s in this.scales {
                if Max(w, h) * s > OCR.MaxImageDimension
                    s := (OCR.MaxImageDimension - 1) / Max(w, h)
                hbm := OcrReader.Enlarge(src, w, h, s)
                try result := this.lang = "" ? OCR.FromBitmap(hbm) : OCR.FromBitmap(hbm, this.lang)
                finally DllCall("DeleteObject", "ptr", hbm)
                OCR.NormalizeCoordinates(result, s)
                passes.Push(GetOrderedLines(result))
            }
        } finally DllCall("gdiplus\GdipDisposeImage", "ptr", src)
        lines := passes.Length > 1 ? this.Vote(passes) : passes[1]
        if this.fix && this.MostlyKnown(lines)
            for ln in lines
                ln.text := this.FixLine(ln.text)
        return lines
    }

    ; Only repair text that is mostly in the dictionary's language
    MostlyKnown(lines) {
        known := 0, total := 0
        for ln in lines
            for wd in StrSplit(ln.text, " ")
                if StrLen(k := RegExReplace(wd, "[^\p{L}]")) >= 2
                    total++, known += this.spell.IsWord(k)
        return total && known >= total * 0.6
    }

    ; --- comparing passes -------------------------------------------------------------

    Vote(passes) {
        known := this.spell && this.spell.ok
        out := []
        for ln in passes[1] {
            others := []
            loop passes.Length - 1 {
                best := "", bestOverlap := 0
                for o in passes[A_Index + 1] {
                    overlap := Min(ln.y + ln.h, o.y + o.h) - Max(ln.y, o.y)
                    ; a row can be split in two pieces side by side, so they must also overlap across
                    if Min(ln.x + ln.w, o.x + o.w) <= Max(ln.x, o.x)
                        continue
                    if overlap > bestOverlap && overlap > Min(ln.h, o.h) / 2
                        best := o, bestOverlap := overlap
                }
                if best
                    others.Push(StrSplit(best.text, " "))
            }
            text := others.Length ? this.VoteWords(StrSplit(ln.text, " "), others, known) : ln.text
            out.Push({text: text, x: ln.x, y: ln.y, w: ln.w, h: ln.h})
        }
        return out
    }

    ; Each word of the first pass against the words the other passes put in its place
    VoteWords(base, others, known) {
        need := (others.Length + 1) // 2 + 1    ; passes that must agree on a word the first one lacks
        subs := [], inserts := []
        for o in others {
            OcrReader.Align(base, o, &sub, &ins)
            subs.Push(sub), inserts.Push(ins)
        }
        words := []
        loop base.Length + 1 {
            i := A_Index
            ; words that the first pass is missing, when all other passes agree on them
            ins := inserts[1][i]
            for list in inserts
                if OcrReader.Key(list[i]) != OcrReader.Key(ins)
                    ins := ""
            if ins != "" && others.Length >= need
                for wd in StrSplit(ins, " ")
                    words.Push(wd)
            if i > base.Length
                break
            ; candidates grouped by their letters, so "shaft," and "shaft" count together
            votes := Map(), forms := Map(), order := []
            for cand in [base[i], subs*] {
                wd := A_Index = 1 ? cand : cand[i]
                k := OcrReader.Key(wd)
                if !votes.Has(k)
                    votes[k] := 0, forms[k] := Map(), order.Push(k)
                votes[k] += 1
                forms[k][wd] := (forms[k].Has(wd) ? forms[k][wd] : 0) + 1
            }
            bestKey := "", bestScore := -1
            for k in order {
                score := votes[k]
                if k != "" && known && this.spell.IsWord(k)
                    score += 0.5
                if k = "" && known && this.spell.IsWord(OcrReader.Key(base[i]))
                    score -= 1                     ; never drop a real word
                if score > bestScore
                    bestKey := k, bestScore := score
            }
            if bestKey = ""
                continue
            bestForm := "", n := 0
            for form, c in forms[bestKey]
                if c > n || (c = n && form = base[i])
                    bestForm := form, n := c
            words.Push(bestForm)
        }
        text := ""
        for wd in words
            text .= (A_Index = 1 ? "" : " ") wd
        return text
    }

    ; Word alignment by edit distance. sub[i]: word of b in place of a[i] ("" = missing),
    ; ins[i]: words of b inserted before a[i] (ins[a.Length+1] = after the end)
    static Align(a, b, &sub, &ins) {
        n := a.Length, m := b.Length
        d := [], op := []
        loop n + 1 {
            i := A_Index - 1, row := [], ops := []
            loop m + 1 {
                j := A_Index - 1
                if i = 0 || j = 0 {
                    row.Push(i + j), ops.Push(i = 0 ? (j = 0 ? 0 : 2) : 1)
                    continue
                }
                c := OcrReader.SubCost(a[i], b[j])
                best := d[i][j] + c, o := 3
                if d[i][j + 1] + 1 < best
                    best := d[i][j + 1] + 1, o := 1        ; a[i] missing in b
                if row[j] + 1 < best
                    best := row[j] + 1, o := 2             ; b[j] inserted
                row.Push(best), ops.Push(o)
            }
            d.Push(row), op.Push(ops)
        }
        sub := [], ins := []
        loop n
            sub.Push("")
        loop n + 1
            ins.Push("")
        i := n, j := m
        while i > 0 || j > 0 {
            o := op[i + 1][j + 1]
            if o = 3
                sub[i] := b[j], i--, j--
            else if o = 1
                i--
            else
                ins[i + 1] := b[j] (ins[i + 1] = "" ? "" : " " ins[i + 1]), j--
        }
    }

    static SubCost(x, y) {
        kx := OcrReader.Key(x), ky := OcrReader.Key(y)
        if kx == ky
            return 0
        common := 0, lx := StrLen(kx), ly := StrLen(ky)
        loop Min(lx, ly)
            common += SubStr(kx, A_Index, 1) == SubStr(ky, A_Index, 1)
        return common * 2 >= Max(lx, ly) ? 0.6 : 1.2
    }

    static Key(word) => RegExReplace(word, "[^\p{L}\p{N}']")

    ; --- repairing words ----------------------------------------------------------------

    FixLine(text) {
        words := StrSplit(text, " ")
        ; one word read as two ("hom e", "m idwinter"): join when only the joined form is a word
        i := 1
        while i < words.Length {
            a := words[i], b := words[i + 1]
            if RegExMatch(a, "[\p{L}]$") && RegExMatch(b, "^[\p{L}]")
                && (!this.IsRealWord(OcrReader.Key(a)) || !this.IsRealWord(OcrReader.Key(b)))
                && this.spell.IsWord(OcrReader.Key(a b)) {
                words[i] := a b, words.RemoveAt(i + 1)
                continue
            }
            i++
        }
        out := ""
        for wd in words
            out .= (A_Index = 1 ? "" : " ") this.FixWord(wd)
        return out
    }

    ; Single letters other than a and I count as fragments
    IsRealWord(k) => StrLen(k) > 1 ? this.spell.IsWord(k) : (k = "a" || k == "I")

    FixWord(word) {
        if this.fixCache.Has(word)
            return this.fixCache[word]
        fixed := word
        if RegExMatch(word, "^([\x22'(\[«“‘]*)(.*?)([\x22'.,;:!?)\]»”’…]*)$", &m) && StrLen(m[2]) >= 2
            && !RegExMatch(m[2], "^[\d.,:%/-]+$") && !this.spell.IsWord(m[2]) {
            core := m[2]
            if (r := this.Unconfuse(core)) != "" || (r := this.SplitWord(core)) != ""
                fixed := m[1] r m[3]
        }
        if this.fixCache.Count > 5000
            this.fixCache.Clear()
        return this.fixCache[word] := fixed
    }

    ; A dictionary word reached by exchanging letters that OCR often confuses: fewest exchanges
    ; first, then the most typical ones (earlier in the list)
    Unconfuse(core) {
        static pairs := OcrReader.ConfusionPairs()
        word := StrLower(core), cap := RegExMatch(core, "^\p{Lu}")
        level := [[word, 0]], seen := Map(word, 1)
        loop 2 {
            next := [], best := "", bestCost := 1e9
            for item in level {
                cand := item[1]
                loop StrLen(cand) {
                    pos := A_Index
                    if !pairs.Has(c := SubStr(cand, pos, 1))
                        continue
                    for p in pairs[c] {
                        if SubStr(cand, pos, StrLen(p[1])) !== p[1]
                            continue
                        nw := SubStr(cand, 1, pos - 1) p[2] SubStr(cand, pos + StrLen(p[1]))
                        if seen.Has(nw)
                            continue
                        seen[nw] := 1, next.Push([nw, cost := item[2] + p[3]])
                        out := cap ? StrUpper(SubStr(nw, 1, 1)) SubStr(nw, 2) : nw
                        if cost < bestCost && this.spell.IsWord(out)
                            best := out, bestCost := cost
                    }
                }
            }
            if best != "" || seen.Count > 4000
                return best
            level := next
        }
        return ""
    }

    ; Two words read as one ("ofthem", "Ifyou"), when one of them is a short common word
    SplitWord(core) {
        static common := " a an and are as at be but by can do for from had has have he her him his i if in is it its me my no not of on or our she so that the them then they this to up us was we were will with you your "
        if StrLen(core) < 3 || !RegExMatch(core, "^\p{L}+$")
            return ""
        loop StrLen(core) - 1 {
            a := SubStr(core, 1, A_Index), b := SubStr(core, A_Index + 1)
            if this.IsRealWord(a) && this.IsRealWord(b)
                && (InStr(common, " " StrLower(a) " ") || InStr(common, " " StrLower(b) " "))
                return a " " b
        }
        return ""
    }

    ; first letter of what was read -> [[as read, meant, rank], ...], lower case, most typical first
    static ConfusionPairs() {
        index := Map()
        for p in ["rn m", "m rn", "cl d", "d cl", "li h", "h li", "vv w", "w vv", "ri n", "in m", "m in", "ii u", "nn m",
                  "1 l", "l 1", "1 i", "| l", "| i", "! l", "! i", "0 o", "o 0", "5 s", "s 5", "8 b", "6 b", "l i", "i l",
                  "c e", "e c", "a e", "e a", "a o", "o a", "u n", "n u", "h b", "b h", "f t", "t f", "y v", "v y", "j i",
                  "g q", "q g", "fi f", "ff f", "f ff", "tl d", "ß fa", "ß ss", "æ ac", "é e", "è e", "ê e", "ë e", "á a",
                  "à a", "â a", "ä a", "å a", "ó o", "ò o", "ô o", "ö o", "ú u", "ü u", "í i", "ì i", "ï i", "î i", "ç c",
                  "ñ n"] {
            ab := StrSplit(p, " "), ab.Push(A_Index), c := SubStr(ab[1], 1, 1)
            if !index.Has(c)
                index[c] := []
            index[c].Push(ab)
        }
        return index
    }

    ; --- image ------------------------------------------------------------------------

    ; Screen area -> GDI+ bitmap
    static Capture(x, y, w, h) {
        screen := DllCall("GetDC", "ptr", 0, "ptr")
        dc := DllCall("CreateCompatibleDC", "ptr", screen, "ptr")
        hbm := DllCall("CreateCompatibleBitmap", "ptr", screen, "int", w, "int", h, "ptr")
        old := DllCall("SelectObject", "ptr", dc, "ptr", hbm, "ptr")
        DllCall("BitBlt", "ptr", dc, "int", 0, "int", 0, "int", w, "int", h, "ptr", screen, "int", x, "int", y, "uint", 0x00CC0020)
        DllCall("SelectObject", "ptr", dc, "ptr", old)
        DllCall("DeleteDC", "ptr", dc), DllCall("ReleaseDC", "ptr", 0, "ptr", screen)
        DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "ptr", hbm, "ptr", 0, "ptr*", &bmp := 0)
        DllCall("DeleteObject", "ptr", hbm)
        return bmp
    }

    ; GDI+ bitmap -> HBITMAP, enlarged with bicubic interpolation and turned grey
    static Enlarge(src, w, h, scale) {
        static gray := 0
        if !gray {
            gray := Buffer(100, 0)
            for i, v in [.299, .299, .299, 0, 0, .587, .587, .587, 0, 0, .114, .114, .114, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1]
                NumPut("float", v, gray, (i - 1) * 4)
        }
        dw := Max(40, Round(w * scale)), dh := Max(40, Round(h * scale))
        DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", dw, "int", dh, "int", 0, "int", 0x26200A, "ptr", 0, "ptr*", &dst := 0)
        DllCall("gdiplus\GdipGetImageGraphicsContext", "ptr", dst, "ptr*", &g := 0)
        DllCall("gdiplus\GdipSetInterpolationMode", "ptr", g, "int", 7)      ; high quality bicubic
        DllCall("gdiplus\GdipSetPixelOffsetMode", "ptr", g, "int", 4)
        DllCall("gdiplus\GdipCreateImageAttributes", "ptr*", &attr := 0)
        DllCall("gdiplus\GdipSetImageAttributesWrapMode", "ptr", attr, "int", 3, "uint", 0, "int", 0)
        DllCall("gdiplus\GdipSetImageAttributesColorMatrix", "ptr", attr, "int", 0, "int", 1, "ptr", gray, "ptr", 0, "int", 0)
        DllCall("gdiplus\GdipDrawImageRectRectI", "ptr", g, "ptr", src, "int", 0, "int", 0, "int", Round(w * scale), "int", Round(h * scale)
            , "int", 0, "int", 0, "int", w, "int", h, "int", 2, "ptr", attr, "ptr", 0, "ptr", 0)
        DllCall("gdiplus\GdipDisposeImageAttributes", "ptr", attr)
        DllCall("gdiplus\GdipDeleteGraphics", "ptr", g)
        DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "ptr", dst, "ptr*", &hbm := 0, "uint", 0xFF000000)
        DllCall("gdiplus\GdipDisposeImage", "ptr", dst)
        return hbm
    }
}

; Windows spell checker (Windows 8 and later). ok = false when the language is not available.
class SpellChecker {
    __New(lang := "") {
        this.ok := false, this.ptr := 0
        this.known := Map(), this.known.CaseSense := true
        try {
            factory := ComObject("{7AB36653-1796-484B-BDFA-E74F1DB7C1DC}", "{8E018A9D-2415-4677-BF08-794EA61F94BB}")
            for tag in [lang, "en-US", "en-GB"] {
                if tag = ""
                    continue
                ComCall(4, factory, "wstr", tag, "int*", &supported := 0)
                if supported {
                    ComCall(5, factory, "wstr", tag, "ptr*", &p := 0)
                    this.ptr := p, this.ok := true
                    break
                }
            }
        }
    }
    __Delete() => this.ptr && ObjRelease(this.ptr)

    IsWord(word) {
        ; the spell checker accepts anything with a digit in it; for OCR "c1ear" is a misread word
        if !this.ok || word = "" || RegExMatch(word, "\d") && RegExMatch(word, "\p{L}")
            return false
        if this.known.Has(word)
            return this.known[word]
        ComCall(4, this.ptr, "wstr", word, "ptr*", &enum := 0)      ; Check
        hr := ComCall(3, enum, "ptr*", &err := 0, "int")            ; IEnumSpellingError::Next
        if err
            ObjRelease(err)
        ObjRelease(enum)
        if this.known.Count > 20000
            this.known.Clear()
        return this.known[word] := (hr != 0)
    }
}
