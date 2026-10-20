# Vlog Editor

A minimal Mac app: drop in your raw clips, describe the vlog you want, and Final Cut Pro gets a finished edit. Then answer three export questions (platform, shape, quality) and get an MP4 ready to post.

## How it works

0. **Connect (first launch).** The Connect screen sets up the free AI editor (Ollama and its vision model, or Apple Intelligence), checks that Final Cut Pro 10.6 or later is installed, and asks for speech recognition (for captions). Final Cut Pro has no account to sign in to: the app talks to it through project files. Reopen this screen with the **Connect** button.
1. **Drop.** Drag videos (MP4, MOV, M4V) onto the window, or choose them. A song dropped in alongside becomes the music bed.
2. **Describe.** Type what you want in plain words, e.g. *"A fast 60 second travel vlog titled 'Lisbon Weekend' with smooth transitions"*.
3. **Edit in Final Cut Pro.** The app watches and listens through each clip. A free AI running on your Mac looks at sample frames, loudness and timing, follows your description, and picks the shots; if none is set up, the keyword planner below does. Cuts then move onto the beats of your music, and captions are made from what people say. The app writes a Final Cut Pro project (FCPXML). Final Cut opens it with every cut, dissolve, title and the music already in place, in an event called "Vlog Editor". Tweak anything there if you like.
4. **Export.** Where will you post it (YouTube, Shorts, Reels, Instagram feed, TikTok)? Which shape (16:9, 9:16, 1:1, 4:5, pre-picked from the platform)? What quality (720p, 1080p, 4K)? The app renders the MP4 and also saves a Final Cut project in that exact format.

### What each step uses

| Feature | How |
|---|---|
| Smarter descriptions | Free and on your Mac, nothing is uploaded. First choice: [Ollama](https://ollama.com) with the `qwen2.5vl:7b` vision model (about 6 GB; `gemma3:4b` for 8 GB Macs), which sees 24 sample frames plus loudness, picture notes and clip details, and answers in a fixed JSON shape. Second choice: Apple Intelligence's on-device model (macOS 26), which reads the same notes as text. Falls back to the keyword planner if neither is available or the answer is unusable. |
| Better shot picking | Vision face detection, sharpness (edge strength) and steadiness (change between frames 0.15s apart), blended 40/60 with loudness. |
| Cuts on the beat | Beat tracking on the first music track; each cut moves to the nearest beat (at most 0.75s) when the clip has footage to spare. Say "ignore the beat" to turn it off. |
| Auto captions | On-device speech recognition, grouped into lines of up to six words. They're Basic Titles in the Final Cut project and burned into the MP4. Ask for "captions" or "subtitles". |

Everything lands in `~/Movies/Vlog Editor/<project name>/`.

## Design choices

- **Native macOS app (SwiftUI).** Final Cut Pro only runs on macOS, so the app does too. Requires macOS 14+.
- **Final Cut Pro is driven through FCPXML.** Final Cut has no scripting API for editing. It does import FCPXML, Apple's documented project format, so the app writes the whole edit as FCPXML 1.10 (Final Cut Pro 10.6 or later) and asks Final Cut to open it.
- **The app renders the final MP4 itself.** Final Cut can't be told to export from outside the app, so the deliverable is rendered with AVFoundation from the same edit. The matching Final Cut project is saved alongside, so you can also use Final Cut's Share menu.

## What the description understands (v0.1)

| You write | It does |
|---|---|
| `60 seconds`, `2 min`, `1:30` | Target length |
| `fast`, `upbeat`, `snappy` / `calm`, `cinematic`, `slow` | Shot length: ~2s / ~4s / ~6.5s |
| `smooth transitions`, `dissolve` / `hard cuts` | Cross dissolves on or off |
| `titled "..."`, `called "..."` | Opening title |
| `same order`, `as uploaded` | Keep your order (default: by recording time) |
| `keep everything`, `just stitch` | No trimming, clips joined whole |
| `quiet music` / `loud music` | Music level |

With no length given it aims for about 40% of the footage (between 30 seconds and 10 minutes). Shots are chosen from the loudest stretches of each clip, which is usually where someone is talking or something is happening.

## Run it

On a Mac with Xcode 15 or later:

```sh
swift run VlogEditor          # run straight from source
sh scripts/make-app.sh        # or build "build/Vlog Editor.app"
swift test                    # edit-engine tests
```

## Code map

- `Sources/VlogEditorCore/` holds the edit engine, plain Swift with no UI: `EditBrief.swift` reads the description, `EditPlanner.swift` picks the shots, `AIPlanner.swift` holds the editing instructions, builds the Ollama request and checks every AI answer, `Beats.swift` finds the beat and snaps cuts, `Captions.swift` turns words into captions, `FCPXML.swift` writes the Final Cut project, `Models.swift` has the clip and export types.
- `Sources/VlogEditor/` is the app: SwiftUI screens (`Views.swift`), flow (`AppModel.swift`), reading clips and their audio (`MediaProbe.swift`), picture scoring and speech recognition (`Analysis.swift`), the free AI planners and frame sampling (`LocalAI.swift`), opening Final Cut (`FinalCutBridge.swift`) and rendering the MP4 (`VideoRenderer.swift`).

## Next steps

- Colour presets and LUTs.
- Cross dissolves in the rendered MP4 (today they're in the Final Cut project only).
- MKV/AVI support (needs a converter; AVFoundation can't read them).
