# Performance

How fast the app is on a real phone, how it's measured, and what was done.

## Measuring

- `scripts/perf-test.sh` runs `OmakeyUITests/PerformanceTour` on a connected
  iPhone, Release build, no debugger (the "Omakey Performance" scheme).
  Safe on your own phone: demo computer only, no reset, nothing picked or
  changed. The phone must be unlocked to start; the app keeps it awake
  (`OMAKEY_STAY_AWAKE=1`) and is left open afterwards. Keep the phone lying
  flat and still: turning it mid-run rotates the screen under the taps.
- `scripts/perf-summary.sh <log>` prints the averages.
- `scripts/perf-trace.sh <template> <out.trace> [seconds]` records an
  Instruments trace of a launch ('App Launch', 'Time Profiler', ...) and
  reopens the app awake afterwards.
- The app's signposts (`Perf`, subsystem `com.gladimdim.omakey`, category
  `perf`): Start, Keyboard build, Keyboard open (animation), Sheet, Sheet
  slide (animation), Key, Key model, Key haptic, Key draw, Typing and
  Touchpad (animations). They show in Instruments' os_signpost track.
- The portrait tests switch the phone's layout choice to portrait mode and
  put it back in `tearDown`, checked. Should a run be cut short, put it
  back with `TEST_RUNNER_OMAKEY_LAYOUT="Omakey Pro" scripts/perf-test.sh
  -only-testing:OmakeyUITests/PerformanceTour/testChooseLayout`.
- Instruments on the phone: attaching to the app by name or pid fails on
  iOS 27; record `--all-processes` for 30 s while a test runs, then
  `xctrace symbolicate --dsym` with the Release dSYM before exporting.
  Accessibility shows up heavily in such traces: it's XCUITest's, not the
  app's.
- Never run the other UI tours on someone's phone: they reset the app
  (`OMAKEY_RESET`), which unpairs it.

## Results

iPhone 11 (60 Hz), iOS 27.0.1, averages of 5–10 runs.

| | Before | After |
|---|---|---|
| Launch to the first responsive frame | 614 ms | 582 ms |
| App init (stores, model) | 20 ms | 4 ms |
| A key going down (main thread) | 3.0 ms | 0.8 ms |
| … of which redrawing the keyboard | 2.3 ms | 0.08 ms |
| Keyboard opening, tap to up | 612 ms | 299 ms |
| … hitches while it opens | 5.7 ms | 0 |
| Portrait mode opening: hitches | 16.7 ms | 5.6 ms |
| Portrait key pages swiped | | no hitches |
| Layouts page, drag scrolling | 38 fps, 25 ms/s hitching | 43 fps, no hitches |

What's left is mostly the system's: the process starting (most of the
launch), SwiftUI's sheets (Settings takes 60 ms to come up, nearly all of
it the sheet and its navigation bar), and the phone's own keyboard
setting itself up in portrait mode. The iPhone 11 draws at 60 Hz; the
120 Hz budget is 8.3 ms a frame, and a key press now takes a tenth of it.

## What was done

- **Keys**: a key's layers are set only when something changed (a color or
  legend set again makes Core Animation draw its text again), with the
  theme's few colors made once. Corner and Fn legend layers stay hidden on
  keys without them, and text draws off the main thread.
- **Haptics**: after a buzz, only that generator is prepared again, not all
  four.
- **Start-up**: no JSON is parsed before the first frame. The connect
  screen shows the chosen layout's remembered name; keycodes.json and the
  layouts are listed and parsed in the background (`LayoutStore.prewarm`),
  or just the one needed if the keyboard is opened sooner. The layouts
  folder is made with the first import. The system paste control
  comes a frame after the first one: setting it up waits on the pasteboard.
- **Opening the keyboard**: a 0.2 s fade (`QuickFade`) instead of the
  system's full-screen slide, which took half a second and more while the
  screen turned. In landscape the touchpad joins its (hidden) panel only
  once the keyboard is up: Core Animation draws hidden views too, and the
  touchpad was some 20 ms of the keyboard's first frame. Haptics warm up a
  moment later, not while the screen is built.
- **The touchpad's drawing**: its dot grid is one path filled once (it was
  some 450 fills), and its texts are drawn once into small pictures and
  pasted, so a button press or the speed slider redraws without laying out
  a dozen strings again.
- **Portrait mode**: the phone's keyboard is asked for before the screen
  fades in, so iOS sets it up first and it rises with the screen instead
  of stalling the fade halfway (16 ms of hitches, now 6).
- **The status pill**: the ping arrives every second, mostly unchanged; the
  button's configuration (costly to set) is set only when its text or
  color changes.
- **Layouts page**: each card is a picture of the layout (`LayoutPicture`),
  drawn off the main thread once per layout, theme and width, instead of a
  live keyboard of some 450 layers. `KeyGeometry` keeps the two alike.
- **120 Hz**: `CADisableMinimumFrameDurationOnPhone` is on; the panel and
  page animations ask for 120 Hz, and the typed text ticker is a tape of
  text layers that slides (nothing redrawn per frame), so it runs at 120 Hz
  for little. The key strip's trembling stays at 60, each frame draws it.
