#Requires AutoHotkey v2

; Turns an OCR result into reading order: an array of lines {text, x, y, w, h}
GetOrderedLines(result, lineThreshold := 12) {
    words := result.Words.Clone()
    if !words.Length
        return []
    heights := ""
    for word in words
        heights .= (A_Index = 1 ? "" : ",") word.h
    heights := StrSplit(Sort(heights, "N D,"), ",")
    ; Large fonts differ in y by more than the fixed threshold within one line ("on" / "the")
    lineThreshold := Max(lineThreshold, heights[heights.Length // 2 + 1] * 0.4)

    OCR.SortArray(words, (a, b) => a.y - b.y)
    groups := [], current := [], currentY := -1
    for word in words {
        if (currentY == -1 || Abs(word.y - currentY) <= lineThreshold) {
            current.Push(word)
            if (currentY == -1)
                currentY := word.y
        } else {
            groups.Push(current)
            current := [word]
            currentY := word.y
        }
    }
    if current.Length
        groups.Push(current)

    lines := []
    for group in groups {
        OCR.SortArray(group, (a, b) => a.x - b.x)
        text := "", top := group[1].y, bottom := 0
        for word in group {
            text .= word.Text " "
            top := Min(top, word.y), bottom := Max(bottom, word.y + word.h)
        }
        last := group[group.Length]
        lines.Push({text: RTrim(text), x: group[1].x, y: top, w: last.x + last.w - group[1].x, h: bottom - top})
    }
    return lines
}

GetOrderedText(result, lineThreshold := 12) => JoinLines(GetOrderedLines(result, lineThreshold))

JoinLines(lines) {
    text := ""
    for line in lines
        text .= (A_Index = 1 ? "" : "`n") line.text
    return text
}

CleanOcrText(text) {
    text := RegExReplace(text, "[\r\n]+", " ")
    text := RegExReplace(text, "([\.!\?])([A-Za-z])", "$1 $2")
    return Trim(text)
}

/**
 * Splits text into pieces worth speaking on their own: [{text, complete}].
 * Only the last piece can be incomplete, i.e. without closing punctuation.
 * Very short sentences are joined with the next one, very long ones are cut at a comma.
 */
SplitSentences(text, minLen := 18, maxLen := 260) {
    static ABBREV := "i)(?:^|[\s\(\[\x22'])(?:mr|mrs|ms|dr|st|sr|jr|vs|lt|sgt|capt|col|gen|prof|e\.g|i\.e|approx)\.$"
    text := Trim(RegExReplace(text, "\s+", " "))
    raw := [], start := 1, pos := 1
    ; terminators, optional closing quotes or brackets, then a space or the end
    while p := RegExMatch(text, "[.!?…]+[\x22'”’»\)\]]*(?=\s|$)", &m, pos) {
        pos := p + m.Len
        piece := SubStr(text, start, pos - start)
        next := SubStr(text, pos + 1, 1)
        if next != "" {
            if SubStr(m[0], -1) = "." && (RegExMatch(piece, ABBREV) || RegExMatch(piece, "(?:^|\s)\p{Lu}\.$"))
                continue                                     ; "Dr. Who", "J. Smith"
            if RegExMatch(next, "\p{Ll}") && RegExMatch(m[0], "^(\.{2,}|…)")
                continue                                     ; "well... maybe"
        }
        raw.Push({text: Trim(piece), complete: true})
        start := pos + 1
    }
    rest := Trim(SubStr(text, start))
    if rest != ""
        raw.Push({text: rest, complete: false})

    out := []
    for piece in raw {
        if out.Length && out[out.Length].complete && StrLen(out[out.Length].text) < minLen && piece.complete
            out[out.Length].text .= " " piece.text
        else
            out.Push(piece)
    }

    final := []
    for piece in out {
        t := piece.text
        while StrLen(t) > maxLen {
            cut := 0, at := maxLen // 3
            while (at := RegExMatch(t, "[,;:—](?=\s)", , at + 1)) && at <= maxLen
                cut := at
            if !cut
                cut := InStr(SubStr(t, 1, maxLen), " ", , -1) || maxLen
            final.Push({text: Trim(SubStr(t, 1, cut)), complete: true})
            t := Trim(SubStr(t, cut + 1))
        }
        final.Push({text: t, complete: piece.complete})
    }
    return final
}

; The sentences of a text as plain strings, including an unfinished one at the end
SentenceList(text) {
    list := []
    for piece in SplitSentences(text)
        if RegExMatch(piece.text, "[\p{L}\p{N}]")
            list.Push(piece.text)
    return list
}
