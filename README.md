# Game Voice Reader (natural voices, continuous reading)

Reads text from any area of the screen aloud: journals, dialogue, quest logs, in any game
that runs in a window or borderless full screen. AutoHotkey v2 script using Windows OCR and
SAPI 5 voices.

Based on [GameVoiceReader](https://github.com/KnightDevRedEmber/GameVoiceReader) by
KnightDevRedEmber. Differences to the original:

- speaks through SAPI 5 instead of a browser window, including natural voices
- no delays between sentences, even with online voices
- rewind and fast forward by sentence
- continuous reading: follows text while it scrolls, is typed out, or moves to the next page
- fewer misread letters: smooth enlarging, two reading passes compared word by word, and repair
  of typical OCR confusions with the Windows spell checker

## Requirements

- Windows 10 or 11
- [AutoHotkey v2](https://www.autohotkey.com/)
- Optional, for natural voices:
  [NaturalVoiceSAPIAdapter](https://github.com/gexgd0419/NaturalVoiceSAPIAdapter) or the
  [fork by dengxibo](https://github.com/dengxibo/NaturalVoiceSAPIAdapter), which this project was developed with

Download this repository and start `Game Voice Reader.ahk`. If the game runs as administrator,
the script has to as well.

## Keys

| Key | Function |
|---|---|
| Right Ctrl + move mouse, then left click | Select an area and read it |
| F2 | Continuous reading on / off (key can be changed in `settings.ini`) |
| F3 / F4 | Previous / next sentence |
| F6 | Show the saved area |
| F7 | Read when the mouse enters the saved area, on / off |
| F8 | Read the saved area again |
| F9 | Pause / resume |
| F10 | Exit |

The voice is chosen from the tray icon. Other settings are in `settings.ini`, which is created
on the first start.

## Choosing a voice

Online voices differ a lot in how fast Microsoft's server answers. Time until the first audio for
text that was not requested before, measured in November 2026 on one connection, 4 to 9 requests each:

| Voice | Answers after | |
|---|---|---|
| Jenny, Aria, Steffan | 0.3 - 1.1 s | |
| Roger, Guy | 0.4 - 1.5 s | |
| Christopher, Ava, Eric, Michelle | 0.4 - 2.0 s | |
| Emma | 1.4 - 4.7 s | |
| Brian, BrianMultilingual, AvaMultilingual | 1.6 - 5.8 s | |
| Andrew, AndrewMultilingual | 2 - 7 s | about 40% of requests returned no audio |

With a slow voice only the start of a text is delayed, since the following sentences are prepared
in advance. Voices installed on the computer (Narrator natural voices, or the classic Windows voices)
need no connection at all. See the adapter's
[list of downloadable voices](https://github.com/gexgd0419/NaturalVoiceSAPIAdapter/wiki/Narrator-natural-voice-download-links).

Text read with an online voice is sent to Microsoft.

## Continuous reading

1. Select the area the text appears in, or press F8 for the saved one.
2. Press F2 (before or after).
3. Scroll, or continue the conversation. New text is added to what is being spoken.

- Text that was already read is not repeated, also when scrolling back.
- A sentence cut off by the edge of the box waits for the rest. If nothing happens and there is nothing
  else to say, the part that is visible is spoken after 1.5 s.
- Scroll less than a full box at a time, so that at least one line stays visible. Every position should be
  visible for about half a second.
- F8 or a new selection starts over.
- Select only the text, not portraits or moving parts around it.

## Reading accuracy

Windows OCR confuses similar letters more often the smaller the text is. Measured with `tests/OcrBench.ahk`
on light text over a dark, textured background, six fonts, wrong words out of 1,530 per row (punctuation not counted):

| Text height | Previous version | Now |
|---|---|---|
| about 12 px | 261 | 240 |
| about 13 px | 146 | 105 |
| about 16 px | 63 | 9 |
| about 20 px | 42 | 4 |

How large the selection is, and frames or icons inside it, made no difference. A larger selection just holds
more text that can be misread. Below about 14 px OCR stays unreliable; if the game lets you, make its text
larger.

Settings in the `[OCR]` section of `settings.ini`:

- `Passes=2,1.5` - how much the area is enlarged for each reading pass. `Passes=2` is faster
  (about 200 instead of 340 ms for a nearly full-screen area, 50 instead of 90 ms for a dialogue box),
  `Passes=2,3,1.5` is a little more accurate.
- `FixWords=1` - repair words with the spell checker. Only used when most of the text is English, so text
  in other languages is left as OCR read it. Names that are not in the dictionary are kept unless a typical
  confusion turns them into a dictionary word.

## How it works

`Lib/SpeechEngine.ahk` - SAPI asks a voice for the next sentence only when the previous one has finished,
so each sentence costs one round trip to the server. The engine uses several voice objects to render the
next sentences in parallel into memory, and plays them through one `waveOut` queue. Playback starts with
the first audio that arrives. Sentences without audio, which the adapter reports as success, are requested
again. Rendered sentences are kept, so going back is immediate. SAPI's own `Skip` is
not used because the adapter does not implement it.

`Lib/TextFollower.ahk` - Compares repeated OCR results with the text read so far, word by word and tolerating
OCR mistakes, to find what is new. A line is accepted once two results in a row agree on it, except while
the text scrolls by two lines or more at a time: then lines that went out of view after only one result are
taken too.
Only the column the text is in is read, so scraps that OCR finds in a portrait, a map or a health bar next to
it are left out, unless they look like sentences. A page that shares nothing with the one before is read in
full, and when it starts in the middle of a sentence it continues the one the last page left open.

`Lib/OcrReader.ahk` - The previous version enlarged the capture by repeating pixels, which made OCR read
"on" as "an" and "for" as "far" in some fonts. The capture is now enlarged with bicubic interpolation and read
twice at different sizes. The two readings are aligned word by word, and where they differ the dictionary word
wins. Words that are still not in the dictionary are repaired when exchanging typical confusions (rn/m, cl/d,
li/h, l/I/1, o/0, ...) gives a dictionary word, when two words were read as one ("ofthem"), or when one word
was read as two ("hom e").

`Lib/TextTools.ahk` - Reading order, clean-up and sentence splitting.

## Tests

`tests/run.sh <script>` from Git Bash, or run the scripts with AutoHotkey and redirect their output.

| Script | |
|---|---|
| `UnitTests.ahk` | Sentence splitting, reading order, word repair |
| `OcrBench.ahk [fonts] [sizes] [methods]` | Misread words for several fonts, sizes and selections. Takes a few minutes |
| `FollowerTests.ahk` | Simulated scrolling, typing, dialogue and OCR mistakes |
| `SpeechBench.ahk [voice] [sentences]` | Delays with real voices, silent |
| `EndToEnd.ahk` | Window, OCR and speech, silent |
| `MainScriptTest.ahk` | The main script following a scrolling window, silent. Takes about 100 s |

## License

MIT, see [LICENSE](LICENSE), which keeps the copyright notice of the original project.
Third-party components are listed in [NOTICE.md](NOTICE.md).
