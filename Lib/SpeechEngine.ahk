#Requires AutoHotkey v2

/**
 * Low-latency, skippable speech on top of SAPI 5.
 *
 * SAPI only requests the next sentence from the voice once the previous one has
 * finished, which for online voices means one network round trip of silence per
 * sentence. This class instead
 *   - renders several sentences ahead, in parallel, into memory streams
 *   - starts playing a sentence as soon as its first audio arrives
 *   - plays through one waveOut queue, so sentences follow each other without gaps
 *   - retries when the online voice returns no audio (which SAPI reports as success)
 *   - keeps rendered sentences, which makes going back and forward immediate
 *
 *   engine := SpeechEngine({voice: "Steffan", rate: 0})
 *   engine.Load(["First sentence.", "Second sentence."])
 *   engine.Append(["Third sentence."])
 *   engine.Skip(1), engine.Skip(-1), engine.Pause(), engine.Resume(), engine.Stop()
 */
class SpeechEngine {
    static BytesPerMs := 48          ; 24 kHz, 16 bit, mono
    static Silence := 250            ; samples below this amplitude count as silence
    static BlockMs := 400            ; size of one queued audio block
    static QueueMs := 1600           ; how much audio to keep queued in the device
    static PrerollMs := 250          ; audio needed before starting a partial sentence
    static CacheClips := 120         ; rendered sentences to keep

    __New(opts := {}) {
        this.voiceName := this._Opt(opts, "voice", "")
        this.rate      := this._Opt(opts, "rate", 0)
        this.gapMs     := this._Opt(opts, "gapMs", 220)
        this.prefetch  := this._Opt(opts, "prefetch", 4)
        this.stallMs   := this._Opt(opts, "stallMs", 9000)
        this.maxTries  := this._Opt(opts, "maxTries", 3)
        this.mute      := this._Opt(opts, "mute", false)       ; for tests: run everything, play silence
        this.log       := this._Opt(opts, "log", "")           ; optional callback(text)
        this.onSlow    := this._Opt(opts, "onSlow", "")        ; optional callback(avgMs)

        this.items := [], this.feed := 1, this.pos := 0
        this.paused := false, this.underruns := 0
        this.clips := Map(), this.clipOrder := []
        this.blocks := [], this.hwo := 0, this.lastActive := 0
        this.loadedAt := 0, this.firstAudioMs := -1
        this.latencies := [], this.slowReported := false, this.lastRequest := 0

        this.fallback := this._FindFallback()
        this.workers := []
        loop Max(2, this.prefetch + 1)
            this.workers.Push(SpeechEngine.Worker())
        this.SetVoice(this.voiceName)
        this.tick := ObjBindMethod(this, "_Tick")
        this.ticking := false
    }

    __Delete() {
        try SetTimer(this.tick, 0)
        try this._CloseDevice()
    }

    ; ---------------------------------------------------------------- public

    ; True when there is nothing left to say
    IsIdle => this.blocks.Length == 0 && this.feed > this.items.Length

    ; Number of the sentence being heard, or the last one when finished
    Index {
        get {
            if this.blocks.Length
                return this.blocks[1].item
            return Min(this.feed, this.items.Length)
        }
    }

    Text {
        get {
            s := ""
            for t in this.items
                s .= (s = "" ? "" : "`n") t
            return s
        }
    }

    ; Replaces everything and starts speaking
    Load(sentences) {
        crit := Critical("On")
        this._Flush()
        this.items := sentences.Clone()
        this.feed := 1, this.pos := 0, this.paused := false
        this.loadedAt := A_TickCount, this.firstAudioMs := -1
        this._Wake()
        Critical(crit)
    }

    ; Adds sentences to the end without disturbing what is being spoken
    Append(sentences) {
        crit := Critical("On")
        if this.IsIdle
            this.loadedAt := A_TickCount, this.firstAudioMs := -1
        for s in sentences
            this.items.Push(s)
        this._Wake()
        Critical(crit)
    }

    ; Moves by a number of sentences. After the end, going back repeats the last one.
    Skip(step) {
        if !this.items.Length
            return false
        target := (this.IsIdle && step < 0) ? this.items.Length + 1 + step : this.Index + step
        if target > this.items.Length
            return false
        crit := Critical("On")
        this._Flush()
        this.feed := Max(1, target), this.pos := 0, this.paused := false
        this.loadedAt := A_TickCount, this.firstAudioMs := -1
        this._Wake()
        Critical(crit)
        return true
    }

    Pause() {
        this.paused := true
        if this.hwo
            DllCall("winmm\waveOutPause", "ptr", this.hwo)
    }

    Resume() {
        this.paused := false
        if this.hwo
            DllCall("winmm\waveOutRestart", "ptr", this.hwo)
        this._Wake()
    }

    Stop() {
        crit := Critical("On")
        this._Flush()
        this.items := [], this.feed := 1, this.pos := 0, this.paused := false
        Critical(crit)
    }

    ; Opens the connection of an online voice before it is needed. Online
    ; connections are dropped after about 30 s without use.
    Warm() {
        if A_TickCount - this.lastRequest < 20000
            return
        crit := Critical("On")
        this._Request(this._NewClip("Ready."))   ; never cached, or there would be no request
        this._Wake()
        Critical(crit)
    }

    SetVoice(name) {
        this.voiceName := name, this.token := ""
        this.latencies := [], this.slowReported := false
        if name != ""
            for t in SpeechEngine.Voices()
                if InStr(t.name, name) {
                    this.token := t.token
                    break
                }
        ; "" means the Windows default voice
        this.activeName := this.token ? this.token.GetDescription() : ComObject("SAPI.SpVoice").Voice.GetDescription()
        return this.activeName
    }

    ; All installed voices as [{name, token}]
    static Voices() {
        list := []
        for t in ComObject("SAPI.SpVoice").GetVoices()
            list.Push({name: t.GetDescription(), token: t})
        return list
    }

    ; ------------------------------------------------------------- rendering

    ; One SAPI voice that renders one sentence at a time into memory
    class Worker {
        __New() {
            this.voice := ComObject("SAPI.SpVoice")
            this.sp := ComObjQuery(this.voice, "{6C44DF74-72B9-4992-A1EC-EF996E0422D4}")   ; ISpVoice
            this.clip := "", this.reader := 0, this.draining := false
            this.defaultToken := this.voice.Voice
        }
        __Delete() => this._CloseReader()

        _CloseReader() {
            if this.reader
                ObjRelease(this.reader), this.reader := 0
        }

        Free {
            get {
                if this.clip
                    return false
                if this.draining
                    this.draining := !this.voice.WaitUntilDone(0)
                return !this.draining
            }
        }

        Start(clip, token, rate) {
            static fmt := 0, guid := 0
            if !fmt {
                fmt := Buffer(18, 0), guid := Buffer(16)
                NumPut("ushort", 1, "ushort", 1, "uint", 24000, "uint", 48000, "ushort", 2, "ushort", 16, fmt)
                DllCall("ole32\CLSIDFromString", "str", "{C31ADBAE-527F-4FF5-A230-F62BB61FF70C}", "ptr", guid)  ; SPDFID_WaveFormatEx
            }
            this._CloseReader()
            ; SAPI's thread writes into the stream while a clone of it is read here.
            ; SHCreateMemStream streams are thread safe, SpMemoryStream is not.
            mem := DllCall("shlwapi\SHCreateMemStream", "ptr", 0, "uint", 0, "ptr")
            ComCall(13, mem, "ptr*", &reader := 0)                        ; IStream::Clone
            stream := ComObject("{715D9C59-4442-11D2-9605-00C04F8EE628}", "{12E3CCA9-7518-44C5-A5E7-BA5A79CB929E}")
            ComCall(15, stream, "ptr", mem, "ptr", guid, "ptr", fmt)      ; ISpStream::SetBaseStream
            ObjRelease(mem)
            this.reader := reader
            this.voice.Voice := token ? token : this.defaultToken
            this.voice.Rate := rate
            ComCall(13, this.sp, "ptr", stream, "int", 0)                 ; ISpVoice::SetOutput
            this.clip := clip, this.t0 := A_TickCount, this.tFirst := 0
            this.voice.Speak(clip.text, 1 | 16)                           ; async, not XML
        }

        ; Moves new audio into the clip. Returns true once rendering has ended.
        Poll() {
            static buf := Buffer(65536)
            ended := this.voice.WaitUntilDone(0)   ; must be read before the stream
            loop {
                n := 0
                DllCall(NumGet(NumGet(this.reader, "ptr"), 3 * A_PtrSize, "ptr"), "ptr", this.reader, "ptr", buf, "uint", buf.Size, "uint*", &n, "int")
                if !n
                    break
                if !this.tFirst
                    this.tFirst := A_TickCount
                clip := this.clip
                if clip.len + n > clip.pcm.Size
                    clip.pcm.Size := Max(clip.pcm.Size * 2, clip.len + n)
                DllCall("ntdll\RtlMoveMemory", "ptr", clip.pcm.Ptr + clip.len, "ptr", buf, "uptr", n)
                clip.len += n
            }
            return ended
        }

        Abort() {
            this.clip := "", this.draining := true
            try this.voice.Speak("", 1 | 2)         ; purge
        }
    }

    _Clip(text) {
        key := this.activeName "|" this.rate "|" text
        if this.clips.Has(key)
            return this.clips[key]
        clip := this._NewClip(text, key)
        this.clips[key] := clip
        this.clipOrder.Push(key)
        if this.clipOrder.Length > SpeechEngine.CacheClips {
            oldest := this.clipOrder.RemoveAt(1)
            if this._Wanted(oldest)
                this.clipOrder.Push(oldest)
            else
                this.clips.Delete(oldest)
        }
        return clip
    }

    ; Is this the sentence being played or one of the next?
    _Wanted(key) {
        i := Max(1, this.feed)
        while i <= Min(this.feed + this.prefetch, this.items.Length) {
            if this.activeName "|" this.rate "|" this.items[i] == key
                return true
            i++
        }
        return false
    }

    _NewClip(text, key := "") => {text: text, key: key, pcm: Buffer(96000), len: 0, done: false, tries: 0, busy: false, start: -1, stop: -1, notBefore: 0, used: false}

    _Request(clip) {
        if clip.done || clip.busy || A_TickCount < clip.notBefore
            return true
        for w in this.workers {
            if !w.Free
                continue
            ; The offline voice only steps in for a sentence that playback is waiting for
            useFallback := this.fallback && clip.tries >= this.maxTries && this._Urgent(clip)
            try {
                w.Start(clip, useFallback ? this.fallback : this.token, this.rate)
                clip.busy := true
                this.lastRequest := A_TickCount
            } catch as e {
                w.clip := ""
                this._Log("start failed: " e.Message)
                this._Failed(clip)
            }
            return true
        }
        return false
    }

    ; Playback has run dry and this sentence is next
    _Urgent(clip) => !this.blocks.Length && this.feed <= this.items.Length && this._Clip(this.items[this.feed]) == clip

    _Reset(clip) {
        clip.len := 0, clip.start := -1, clip.stop := -1, clip.used := false
    }

    _Failed(clip) {
        clip.busy := false, clip.tries++
        clip.notBefore := A_TickCount + 100
        if clip.tries >= this.maxTries * 3
            clip.done := true
        this._Log((clip.done ? "gave up on: " : "retry " clip.tries ": ") SubStr(clip.text, 1, 50))
    }

    _PollWorkers() {
        busy := 0
        for w in this.workers {
            if !w.clip
                continue
            clip := w.clip
            try ended := w.Poll()
            catch as e {
                this._Log("poll failed: " e.Message)
                w.Abort(), this._Reset(clip), this._Failed(clip)
                continue
            }
            if ended {
                w.clip := ""
                ; The adapter reports success when the server sends nothing or hangs up early
                if clip.len < this._MinBytes(clip.text) && !clip.used {
                    this._Reset(clip)
                    this._Failed(clip)
                } else {
                    clip.busy := false, clip.done := true
                    this._Measure(w, clip)
                }
            } else if !clip.len && A_TickCount - w.t0 > this.stallMs {
                w.Abort(), this._Failed(clip)
            } else
                busy++
        }
        return busy
    }

    _Measure(w, clip) {
        ms := w.tFirst - w.t0
        this._Log("rendered " Round(clip.len / SpeechEngine.BytesPerMs) "ms of audio, first after " ms "ms, all after " (A_TickCount - w.t0) "ms: " SubStr(clip.text, 1, 50))
        if clip.key = ""       ; only warming up
            return
        this.latencies.Push(ms)
        if this.slowReported || this.latencies.Length < 4
            return
        sum := 0
        for v in this.latencies
            sum += v
        if sum / this.latencies.Length > 2500 && this.onSlow {
            this.slowReported := true
            this.onSlow.Call(Round(sum / this.latencies.Length))
        }
    }

    ; Shortest believable audio for a text. Anything shorter was cut off.
    _MinBytes(text) {
        chars := StrLen(RegExReplace(text, "[^\p{L}\p{N}]"))
        return chars < 8 ? 2400 : Integer(chars * 22 * SpeechEngine.BytesPerMs / (3 ** (this.rate / 10)))
    }

    ; Keeps the next few sentences rendering, nearest first
    _Schedule() {
        last := Min(this.feed + this.prefetch, this.items.Length)
        i := this.feed
        while i <= last {
            clip := this._Clip(this.items[i])
            if !this._Request(clip) {
                ; Every worker is taken. Only the sentence needed right now may displace old work.
                if i > this.feed || !this._Displace()
                    break
            }
            i++
        }
    }

    _Displace() {
        for w in this.workers
            if w.clip && !this._Wanted(w.clip.key) {
                clip := w.clip
                w.Abort()
                clip.busy := false
                this._Reset(clip)
                return true
            }
        return false
    }

    ; A plain Windows voice that works offline
    _FindFallback() {
        for t in SpeechEngine.Voices()
            if !InStr(t.token.Id, "NaturalVoice")
                return t.token
        return ""
    }

    ; -------------------------------------------------------------- playback

    _Wake() {
        if !this.ticking {
            this.ticking := true
            SetTimer(this.tick, 15)
        }
        this._Tick()
    }

    _Tick() {
        static running := false
        if running
            return
        crit := Critical("On")      ; a hotkey must not change the queue half way through
        running := true
        try {
            this._Reap()
            rendering := this._PollWorkers()
            this._Schedule()
            this._Feed()
            if !this.IsIdle || rendering
                this.lastActive := A_TickCount
            else if A_TickCount - this.lastActive > 3000 {
                ; Nothing to do: release the device, so the next reading follows the default output
                this.ticking := false
                SetTimer(this.tick, 0)
                this._CloseDevice()
            }
        } catch as e
            this._Log("tick: " e.Message " line " e.Line)
        running := false
        Critical(crit)
    }

    _Feed() {
        loop {
            if this.feed > this.items.Length || this._QueuedMs() >= SpeechEngine.QueueMs
                return
            clip := this._Clip(this.items[this.feed])
            if clip.done && !clip.len {            ; could not be rendered at all
                this.feed++, this.pos := 0
                continue
            }
            if clip.start < 0 && !this._FindStart(clip)
                return
            if this.pos < clip.start
                this.pos := clip.start
            stop := this._AudibleEnd(clip)
            avail := stop - this.pos
            if avail <= 0 {
                if !clip.done
                    return
                this._QueueSilence(this.gapMs)
                this.feed++, this.pos := 0
                continue
            }
            if !clip.done && !this.blocks.Length && avail < SpeechEngine.PrerollMs * SpeechEngine.BytesPerMs {
                if this.pos > clip.start
                    this.underruns++
                return
            }
            n := Min(avail, SpeechEngine.BlockMs * SpeechEngine.BytesPerMs)
            clip.used := true
            if !this._Queue(clip.pcm.Ptr + this.pos, n)
                return
            if this.firstAudioMs < 0 {
                this.firstAudioMs := A_TickCount - this.loadedAt
                this._Log("first audio after " this.firstAudioMs "ms")
            }
            this.pos += n
        }
    }

    ; Voices pad every sentence with 100-150 ms of silence in front and 300-770 ms behind
    _FindStart(clip) {
        o := 0
        while o + 32 <= clip.len {
            if Abs(NumGet(clip.pcm, o, "short")) > SpeechEngine.Silence {
                clip.start := Max(0, o - 960)      ; keep 20 ms
                return true
            }
            o += 16
        }
        if clip.done
            clip.start := 0
        return clip.done
    }

    _AudibleEnd(clip) {
        if clip.stop >= 0
            return clip.stop
        o := clip.len & ~1
        while o > this.pos + 16 && Abs(NumGet(clip.pcm, o - 2, "short")) <= SpeechEngine.Silence
            o -= 16
        if clip.done
            return clip.stop := Min(clip.len & ~1, o + 2400)    ; keep 50 ms of decay
        return o > this.pos + 16 ? o : this.pos
    }

    _QueuedMs() {
        total := 0
        for b in this.blocks
            total += b.bytes
        return total / SpeechEngine.BytesPerMs
    }

    _QueueSilence(ms) {
        n := ms * SpeechEngine.BytesPerMs
        if n > 0
            this._Queue(Buffer(n, 0), n)
    }

    _Queue(src, n, retry := true) {
        if !this._OpenDevice()
            return false
        data := Buffer(n, 0)
        if !this.mute
            DllCall("ntdll\RtlMoveMemory", "ptr", data, "ptr", src, "uptr", n)
        hdr := Buffer(A_PtrSize = 8 ? 48 : 32, 0)
        NumPut("ptr", data.Ptr, "uint", n, hdr)
        rc := DllCall("winmm\waveOutPrepareHeader", "ptr", this.hwo, "ptr", hdr, "uint", hdr.Size)
        if !rc
            rc := DllCall("winmm\waveOutWrite", "ptr", this.hwo, "ptr", hdr, "uint", hdr.Size)
        if rc {
            this._Log("waveOutWrite error " rc)
            this._CloseDevice()                     ; e.g. headset unplugged: try the new default device
            return retry ? this._Queue(src, n, false) : false
        }
        this.blocks.Push({hdr: hdr, data: data, bytes: n, item: this.feed})
        return true
    }

    ; Drops blocks the device has finished
    _Reap() {
        flagsAt := A_PtrSize = 8 ? 24 : 16
        while this.blocks.Length && (NumGet(this.blocks[1].hdr, flagsAt, "uint") & 1) {
            b := this.blocks.RemoveAt(1)
            DllCall("winmm\waveOutUnprepareHeader", "ptr", this.hwo, "ptr", b.hdr, "uint", b.hdr.Size)
        }
    }

    _Flush() {
        if !this.hwo
            return
        DllCall("winmm\waveOutReset", "ptr", this.hwo)
        for b in this.blocks
            DllCall("winmm\waveOutUnprepareHeader", "ptr", this.hwo, "ptr", b.hdr, "uint", b.hdr.Size)
        this.blocks := []
        DllCall("winmm\waveOutRestart", "ptr", this.hwo)
    }

    _OpenDevice() {
        if this.hwo
            return true
        fmt := Buffer(18, 0)
        NumPut("ushort", 1, "ushort", 1, "uint", 24000, "uint", 48000, "ushort", 2, "ushort", 16, fmt)
        rc := DllCall("winmm\waveOutOpen", "ptr*", &h := 0, "uint", -1, "ptr", fmt, "ptr", 0, "ptr", 0, "uint", 0)
        if rc {
            this._Log("waveOutOpen error " rc)
            return false
        }
        this.hwo := h
        if this.paused
            DllCall("winmm\waveOutPause", "ptr", h)
        return true
    }

    _CloseDevice() {
        if !this.hwo
            return
        this._Flush()
        DllCall("winmm\waveOutClose", "ptr", this.hwo)
        this.hwo := 0
    }

    _Log(text) {
        if this.log
            this.log.Call(text)
    }

    _Opt(o, name, default) => o.HasOwnProp(name) ? o.%name% : default
}
