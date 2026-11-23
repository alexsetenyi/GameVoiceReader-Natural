#Requires AutoHotkey v2
#SingleInstance Off
#Warn All, StdOut
#Warn LocalSameAsGlobal, Off
#Include ..\Lib\OCR.ahk
#Include ..\Lib\TextTools.ahk
#Include ..\Lib\OcrReader.ahk
; Draws known text in several fonts over a dark, textured background and measures how many
; words OCR gets wrong, for small and large selections and several ways of preparing the image.
; Arguments (all optional): fonts sizes(pt) methods [show]
;   OcrBench.ahk "Georgia,Segoe UI" 10,12 s2g,R2_1.5f show
; Methods: s<scale>[g]  OCR library, enlarged by repeating pixels (s2g = previous version)
;          b<scale>[g|i|c] smooth enlarging; g grey, i inverted, c more contrast
;          R<scale>_<scale>...[f] OcrReader with these passes, f = repair words (R2_1.5f = default)
OnError((e, m) => (Out("ERR " e.Message " / " e.What " line " e.Line " " e.Extra), ExitApp(1)))
DllCall("SetThreadDpiAwarenessContext", "ptr", -3)
si := Buffer(24, 0), NumPut("uint", 1, si), DllCall("gdiplus\GdiplusStartup", "ptr*", &gdipToken := 0, "ptr", si, "ptr", 0)

SHORT := "Bring the lantern oil to Elmira before nightfall. The miners swear they heard climbing below the old shaft, and nobody will go down without light. If you find the cart, tell them it is clear."
LONG := "The third winter was the worst of them. We had eaten the last of the barley by midwinter, and the hunters came home with nothing but frost on their cloaks. Elder Maren said the herds had gone south. I did not believe her. There were tracks in the snow behind the palisade, large ones, and they did not belong to any beast I know. On the ninth night the dogs stopped barking. We found them in the morning huddled under the granary floor, alive but silent. Nobody could coax them out again. Tomas went to look for the tracks with two others. He carried my father's lantern. It is still burning on the ridge, but none of them has come back to us. If you read this, do not follow the light. Seal the gate and wait for the thaw, and burn the willow charms we hung above the doors."
fonts := A_Args.Length > 0 ? StrSplit(A_Args[1], ",") : ["Georgia", "Palatino Linotype", "Segoe UI", "Constantia", "Trebuchet MS"]
sizes := A_Args.Length > 1 ? StrSplit(A_Args[2], ",") : [10, 12, 15]
variants := A_Args.Length > 2 ? StrSplit(A_Args[3], ",") : ["s2g", "b2g", "R2", "R2f", "R2_1.5f"]
WX := 40, WY := 40, WW := 1300, WH := 860
bgFile := A_Temp "\ocrbench_bg.bmp"
MakeBackground(bgFile, WW, WH)
Out("MaxImageDimension " OCR.MaxImageDimension)

total := Map(), count := Map()
for font in fonts
    for size in sizes {
        g := Gui("+AlwaysOnTop -Caption -DPIScale +ToolWindow")
        g.MarginX := 0, g.MarginY := 0
        g.Add("Picture", "x0 y0 w" WW " h" WH, bgFile)
        g.SetFont("s" size " q4 cE6D8B8", font)
        small := g.Add("Text", "BackgroundTrans x80 y60 w" (size * 40), SHORT)
        big := g.Add("Text", "BackgroundTrans x80 y" 60 + 0 " w1120 Hidden", LONG)
        g.Show("NA x" WX " y" WY " w" WW " h" WH)
        small.GetPos(&sx, &sy, &sw, &sh)
        ; game graphics around the text: frame, scroll bar, ornaments, icons, a portrait
        clutter := [
            g.Add("Progress", "Hidden x" sx - 30 " y" sy - 30 " w" sw + 60 " h3 cB89A60 Background000000", 100),
            g.Add("Progress", "Hidden x" sx - 30 " y" sy + sh + 25 " w" sw + 60 " h3 cB89A60 Background000000", 100),
            g.Add("Progress", "Hidden x" sx + sw + 20 " y" sy - 20 " w10 h" sh + 200 " Vertical c8A7048 Background20160C", 35),
            g.Add("Progress", "Hidden x" sx + sw + 120 " y" sy " w260 h340 cA08868 Background000000", 100),
            g.Add("Progress", "Hidden x" sx + sw + 160 " y" sy + 60 " w180 h200 c403020 Background000000", 100),
        ]
        g.SetFont("s26 q4 cF0C060", "Segoe UI Symbol")
        clutter.Push(g.Add("Text", "Hidden BackgroundTrans x" sx " y" sy + sh + 50, "◆   ✦   ⚔   ❖   ✧"))
        g.SetFont("s" size " q4 cE6D8B8", font)
        areas := Map("small", [WX + sx - 12, WY + sy - 12, sw + 24, sh + 24], "smallWide", [WX + 10, WY + 10, WW - 20, WH - 20])
        Sleep 300
        line := font " " size "pt:"
        for areaName, a in areas
            for v in variants
                line .= Score(areaName, v, a, SHORT)
        for c in clutter
            c.Visible := true
        Sleep 300
        for v in variants
            line .= Score("busy", v, areas["smallWide"], SHORT)
        for c in clutter
            c.Visible := false
        small.Visible := false, big.Visible := true
        big.GetPos(&bx, &by, &bw, &bh)
        Sleep 300
        for v in variants
            line .= Score("big", v, [WX + bx - 12, WY + by - 12, bw + 24, bh + 24], LONG)
        Out(line)
        g.Destroy()
    }
Out("`nwrong words in % per area and method (all fonts and sizes)")
hdr := "          "
for v in variants
    hdr .= Format("{:7}", v)
Out(hdr)
for areaName in ["small", "smallWide", "busy", "big"] {
    row := Format("{:-10}", areaName)
    for v in variants
        row .= Format("{:7.1f}", total.Has(areaName v) ? total[areaName v] / count[areaName v] : -1)
    Out(row)
}
ExitApp

Score(areaName, v, a, truth) {
    global total, count
    t := A_TickCount
    text := ReadArea(a[1], a[2], a[3], a[4], v)
    ms := A_TickCount - t
    if text = "-"
        return ""
    ; letters and digits only: dropped commas do not change what is spoken
    err := WordErrors(Letters(text), Letters(truth))
    if err && A_Args.Length > 3
        Out("  " areaName "/" v ": " StrReplace(text, "`n", " | "))
    rate := 100 * err / StrSplit(truth, " ").Length
    total[areaName v] := (total.Has(areaName v) ? total[areaName v] : 0) + rate
    count[areaName v] := (count.Has(areaName v) ? count[areaName v] : 0) + 1
    return " " areaName "/" v "=" err (ms > 400 ? "(" ms "ms)" : "")
}

ReadArea(x, y, w, h, v) {
    static readers := Map()
    ; R<scale>_<scale>...[f]: OcrReader with these passes, f = repair words
    if RegExMatch(v, "^R([\d._]+)(f?)$", &mm) {
        if !readers.Has(v) {
            scales := []
            for s in StrSplit(mm[1], "_")
                scales.Push(Number(s))
            readers[v] := OcrReader(scales, mm[2] = "f")
        }
        return JoinLines(readers[v].Read(x, y, w, h))
    }
    RegExMatch(v, "^([sb])([\d.]+)(\w*)$", &mm), kind := mm[1], scale := Number(mm[2]), mode := mm[3]
    if Max(w, h) * scale > OCR.MaxImageDimension
        return "-"
    if kind = "s"
        r := OCR.FromRect(x, y, w, h,, {scale: scale, grayscale: InStr(mode, "g") > 0})
    else {
        hbm := CaptureScaled(x, y, w, h, scale, mode)
        r := OCR.FromBitmap(hbm)
        DllCall("DeleteObject", "ptr", hbm)
    }
    return GetOrderedText(r)
}

; Screen area -> HBITMAP, enlarged with bicubic interpolation; mode g = grayscale, i = inverted grayscale
CaptureScaled(x, y, w, h, scale, mode) {
    screen := DllCall("GetDC", "ptr", 0, "ptr")
    dc := DllCall("CreateCompatibleDC", "ptr", screen, "ptr")
    hbm := DllCall("CreateCompatibleBitmap", "ptr", screen, "int", w, "int", h, "ptr")
    old := DllCall("SelectObject", "ptr", dc, "ptr", hbm, "ptr")
    DllCall("BitBlt", "ptr", dc, "int", 0, "int", 0, "int", w, "int", h, "ptr", screen, "int", x, "int", y, "uint", 0x00CC0020)
    DllCall("SelectObject", "ptr", dc, "ptr", old), DllCall("DeleteDC", "ptr", dc), DllCall("ReleaseDC", "ptr", 0, "ptr", screen)
    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "ptr", hbm, "ptr", 0, "ptr*", &src := 0)
    DllCall("DeleteObject", "ptr", hbm)
    dw := Round(w * scale), dh := Round(h * scale)
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", dw, "int", dh, "int", 0, "int", 0x26200A, "ptr", 0, "ptr*", &dst := 0)
    DllCall("gdiplus\GdipGetImageGraphicsContext", "ptr", dst, "ptr*", &gr := 0)
    DllCall("gdiplus\GdipSetInterpolationMode", "ptr", gr, "int", 7)
    DllCall("gdiplus\GdipSetPixelOffsetMode", "ptr", gr, "int", 4)
    DllCall("gdiplus\GdipCreateImageAttributes", "ptr*", &attr := 0)
    DllCall("gdiplus\GdipSetImageAttributesWrapMode", "ptr", attr, "int", 3, "uint", 0, "int", 0)
    ; i = inverted, c = more contrast
    k := mode = "i" ? -1 : mode = "c" ? 1.8 : 1, o := mode = "i" ? 1 : mode = "c" ? -0.4 : 0
    m := Buffer(100, 0)
    for i, val in [.299*k, .299*k, .299*k, 0, 0,  .587*k, .587*k, .587*k, 0, 0,  .114*k, .114*k, .114*k, 0, 0,  0, 0, 0, 1, 0,  o, o, o, 0, 1]
        NumPut("float", val, m, (i - 1) * 4)
    DllCall("gdiplus\GdipSetImageAttributesColorMatrix", "ptr", attr, "int", 0, "int", 1, "ptr", m, "ptr", 0, "int", 0)
    DllCall("gdiplus\GdipDrawImageRectRectI", "ptr", gr, "ptr", src, "int", 0, "int", 0, "int", dw, "int", dh, "int", 0, "int", 0, "int", w, "int", h, "int", 2, "ptr", attr, "ptr", 0, "ptr", 0)
    DllCall("gdiplus\GdipDisposeImageAttributes", "ptr", attr)
    DllCall("gdiplus\GdipDeleteGraphics", "ptr", gr)
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "ptr", dst, "ptr*", &out := 0, "uint", 0xFF000000)
    DllCall("gdiplus\GdipDisposeImage", "ptr", dst), DllCall("gdiplus\GdipDisposeImage", "ptr", src)
    return out
}

Letters(s) => Trim(RegExReplace(RegExReplace(s, "[^\p{L}\p{N}\s]"), "\s+", " "))

; Word level edit distance between OCR text and the truth
WordErrors(text, truth) {
    a := StrSplit(Trim(RegExReplace(text, "\s+", " ")), " "), b := StrSplit(truth, " ")
    prev := []
    loop b.Length + 1
        prev.Push(A_Index - 1)
    for wa in a {
        cur := [A_Index]
        for wb in b
            cur.Push(Min(prev[A_Index + 1] + 1, cur[A_Index] + 1, prev[A_Index] + (wa == wb ? 0 : 1)))
        prev := cur
    }
    return prev[b.Length + 1]
}

; Dark brown parchment-like texture with noise and soft blotches, saved as a 24 bit BMP
MakeBackground(file, w, h) {
    if FileExist(file)
        return
    stride := (w * 3 + 3) & ~3, size := 54 + stride * h
    buf := Buffer(size, 0)
    NumPut("ushort", 0x4D42, "uint", size, "uint", 0, "uint", 54, "uint", 40, "int", w, "int", h, "ushort", 1, "ushort", 24, "uint", 0, "uint", stride * h, buf)
    blot := []
    loop 14
        blot.Push([Random(0, w), Random(0, h), Random(60, 260), Random(-18, 22)])
    loop h {
        y := A_Index - 1, p := 54 + y * stride
        loop w {
            x := A_Index - 1
            v := 34 + 14 * x / w + Random(-9, 9)
            if !Mod(x, 7) || !Mod(y, 5)
                for b in blot
                    if Abs(x - b[1]) < b[3] && Abs(y - b[2]) < b[3]
                        v += b[4] / 3
            v := Max(0, Min(255, v))
            NumPut("uchar", Round(v * 0.75), "uchar", Round(v * 0.95), "uchar", Round(v * 1.15), buf, p + x * 3)
        }
    }
    FileOpen(file, "w").RawWrite(buf)
}

Out(s) => FileAppend(s "`n", "*", "UTF-8")
