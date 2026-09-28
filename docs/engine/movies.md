# Movies

The game plays its movies with RAD's Bink (`BINKW32.DLL`), their sound through Miles
(`BinkSetSoundSystem` with `BinkOpenMiles`). The movies are Bink files ([`.bik`](../formats/bink.md)).

## Playing a movie

Two functions play a movie in a loop of their own, in `xtrabits.cpp`:

| Function | Plays | Over | At |
|---|---|---|---|
| `play_bink_movie` (`0x004AB850`) | The intro | A screen cleared to black once | The movie's own rate, at full volume (`BinkSetVolume`, `0x8000`) |
| `play_bink_movie_no_clear` (`0x004AB6E0`) | The front end's transitions | What the screen last showed | 15 frames a second (`BinkSetFrameRate(15, 1)` and `BINKFRAMERATE`) |

A pass of the loop (`0x004AB7B2`) runs the message pump, reads the keyboard and moves the pointer.
Escape, the pointer's right button down, the movie's end (`0x005D6C90`) or the game quitting
(`0x005D60BC`) ends it; otherwise, once `BinkWait` says the next frame is due, `bink_frame`
(`0x004AC510`) decodes it (`BinkDoFrame`), copies it into the middle of the screen
(`BinkCopyToBuffer`), and moves on to the next (`BinkNextFrame`), or marks the movie ended at its
last. The message pump pauses the movie while the window is away (`BinkPause`). A movie whose file
cannot be opened stops the game with a message (`play_bink_movie: error loading %s.`).

The video settings' `Transitions` (`[Device]`, 1 unless set, read at `0x004A9081`) turns the
transitions off; the intro plays whatever it says on a hardware renderer (`sr + 0x1AC`).

## The movies played

- As the renderer first starts, before its loading screens, `renderer_load` plays the intro:
  `new_nms.bik`, `new_dalogo_fs_uncmpr.bik` and `warty_.bik`, from the game's folder.
- As `WinMain` opens the front end, `0x004AB6A0` plays `splash to mm.bik`, the splash turning into
  the main menu.
- The front end's screens play their transitions from its `interface` folder as they lead from
  one to another: SINGLE PLAYER `main2sin.bik`, MULTI PLAYER `main2mul.bik` and GAME OPTIONS
  `main2opt.bik` from the main menu; the pilot roster's MAIN MENU and Escape `sin2main.bik`, and
  LOAD GAME `sinfade.bik`.

## In OpenReliant

[`engine/bink.zig`](../../src/engine/bink.zig) stands in for Bink, each function for the call it
names; [`engine/bink/picture.zig`](../../src/engine/bink/picture.zig) turns a decoded picture into
colours, by BT.601 in its limited range. It reads the container itself and hands the packets to a `Codec`: FFmpeg's decoders, in the
platform ([Platform](../port/platform.md#movies)). It decodes a movie's sound whole as the movie
opens and plays it as a Miles stream, where Bink fills a Miles sample as it plays; the sound starts
with the first frame, and OpenAL Soft resamples it as it resamples every sound
([Sound](../port/sound.md#openal-soft)).

[`game/xtrabits/movie.zig`](../../src/engine/game/xtrabits/movie.zig) holds the game's loop and
`bink_frame`, and the driver runs it, each frame drawn over an empty scene and put on the window,
the window's messages read as the message pump reads them. The intro, the splash's movie and the
transitions of the screens ported play as the game plays them; a mission `--mission` names, or a
screenshot, starts without the intro. A movie the game's folder lacks, or that cannot be decoded,
is left out, and the game goes on.

**Improvements**, each left out under `--original`:

- The steps at the edges of the 8 by 8 blocks Bink codes a picture in are smoothed where they are
  small (up to 12 levels) and the levels either side are even (within 3): the blocks that show in
  a dark or flat area once a movie is drawn large, as in the front end's transitions. Where three
  levels either side are even, the step is spread over the four nearest it, as H.264's strong
  filter spreads one; otherwise the two at the edge are brought nearer. Steps past that are edges
  of the picture's own, and stay.
- Each pixel's colour is blended from the four nearest samples of the half-size colour planes,
  three quarters of the nearer and a quarter of the farther each way, where Bink gives a 2 by 2
  block of pixels one colour, which shows as steps along a coloured edge.
- A movie is drawn as large as fits in the window, as the front end is, so that a 16:9 movie fills
  a wide window. `--original` draws it at its size in the middle of the front end's screen, as the
  game draws it on a screen 640 by 480.
- On the GPU, a movie is magnified with FSR 1's edge-adaptive upscale (EASU, from AMD's FidelityFX
  Super Resolution 1.0), which keeps its edges sharp without steps
  ([Renderer](../port/renderer.md#improvements)).

Not ported: the other movies, each with what plays it: the Reliant's rooms'
([#398](https://github.com/vdmkenny/openreliant/issues/398)), the briefings'
([#73](https://github.com/vdmkenny/openreliant/issues/73)), the launches', landings' and chapters'
(`0x004AB9D0`, [#403](https://github.com/vdmkenny/openreliant/issues/403)), and the transitions of
the screens not yet ported ([#43](https://github.com/vdmkenny/openreliant/issues/43)).
