# The radio

`C:\lancer\game\videoreports.cpp` (**Unverified:** the file, placed by the link order) queues the
lines the pilots say and plays them with their faces in the display's window 0, whose films
`C:\lancer\game\hudmovie.cpp` plays ([face films](../formats/fm8.md)). OpenReliant ports both
([`game/videoreports.zig`](../../src/engine/game/videoreports.zig),
[`game/hudmovie.zig`](../../src/engine/game/hudmovie.zig)), and the window's drawing
([`game/hud/radio.zig`](../../src/engine/game/hud/radio.zig)).

## Lines

`radio_say` (`0x004562D0`) takes a film, a speech file ([Speech files](../formats/speech.md)), a
mode, the string that names the speaker, the film's flags, whose line it is (`comms_object`,
`0x0057BDF4`: a ship's slot, a pilot of the pilots' table from `0xFFFF` on, or -1 for nobody) and
how long it keeps, outside a multiplayer mission:

- Mode 0, at once: window 0 opens held unless it is open, with its full time and without the
  display's sound, from however far it had closed; the line playing stops; the window keeps the
  speaker's name (`radio_name`, `0x0057BC4C`), whose the line is and their side (`radio_side`,
  `0x0056993C`: the ship's, the pilot's face's, or friendly for nobody); the speech is read from
  `msspeech.hog` (`radio_speech`, `0x005883CC`) and the film plays (`hudmovie_play`).
- Mode 1, queued. Mode 2, queued unless a line plays or waits (`radio_busy`, `0x004561A0`).

The queue holds five lines (`radio_queue`, `0x005295A0`, `0x74` bytes each: the film's flags, the
speaker's name, the film's path in 50 bytes, the speech file's name in 52, whose it is, and the
tick it expires at, or -1), counted at `0x00529594`, written at `0x00529870` and read at
`0x00529CBE`. `radio_frame` (`0x00456510`), each frame after the controls, while lines wait, window
0 is shut or closing and no speech plays, takes the next and says it unless its time has passed:
the window opens held and names the speaker, and, unless the line is nobody's, the speech is read
and the film plays. A line that is nobody's leaves the window open with nothing in it, which then
closes. The game also leaves out a line of object `0x3E9`, which no slot reaches. A sixth line
queued is dropped.

The pilots' table (`pilot_faces`, `0x005048D8`, 24 bytes each) holds a face for each of the 194
pilots of `pilot_stats`, which `object_set_pilot` points an object at as its pilot record: the
string that names the pilot, a halfword (**Unknown:** `0x53` in every record), the side, a halfword
(**Unknown:** 5 in most, 4 or 0 in a few), and a film for each of four head movements: talking,
laughing, the 45th's own pilot (the same film for every pilot), and dying. `radio_say_pilot`
(`0x00456250`) says a line for a pilot of the table, as `0xFFFF` and its number; `radio_say_ship`
(`0x004561C0`) for a ship, with its pilot's face, unless the ship is a stand-in, exploding, or
without a pilot record. Each names the film `pilots\<film>.fm8` for the head movement the line
asks for. OpenReliant generates the table from the payload (`make face-tables`). **Fix:** for a
head past the four or a pilot past the table, which the game reads beside them, OpenReliant plays
the dead channel's film, with no name.

`radio_reset` (`0x004560F0`) empties the queue and names nobody. **Fix:** the game leaves a film
playing into the next mission, whose first line then starts before its window has opened;
OpenReliant stops it.

## The window

`hudmovie_play` (`0x0048D120`) plays a film and decides when the line starts. With a film playing
already, the line starts at once unless the flags say not (bit 3). Otherwise the line waits for the
window (`hudmovie_waiting`, `0x0057C298`): `hud_draw` counts the frame's ticks
(`hudmovie_waited`, `0x0057C3AC`) and starts the line once they pass 91, 92 ticks after it was said,
as the window has been open for a third of a second. The film's timer holds it at its first frame
meanwhile. Its flags:

| Bit | Meaning |
| --- | --- |
| 0 | the film loops |
| 1 | the film holds for the line: at its end, while the line goes on, the dead channel's film (`pilots\static.fm8`) loops in its place, and once it is over the window closes and the film stops |
| 2 | the film is drawn in its own palette, as every film the game plays is. **Unknown:** the palette the window would draw one without it in (`0x0057BF5C`) |
| 3 | the film starts no line: the dead channel's |

The script's `CommsFromShip` and `CommsFromPilot`, and the radio's own reports, play with 5, the
film looping while the line plays; the `Once` forms with 6, once and then the dead channel's film;
the dead channel's film plays with 13 (`0xD`).

`hud_window_draw`'s case for window 0 (`0x00488035`), from the window's place `(x, y)`:

- In the view ahead while the window closes, the last of its shapes, the emblem.
- A film that has stopped closes the window (and clears `0x00569974`, which nothing reads).
- Once the line has started, a line that is over closes the window and stops the film. While it
  plays, in the view ahead, the speaker's name at `(x + 1, y + 2)` and the film at
  `(x + 13, y + 19)`, each row moved right by a random share of `10 * hit_shake` pixels, drawn
  every pixel, the see-through colour among them.
- While the line waits, in the view ahead, shape `0x131` and on for a friendly speaker, `0x148` and
  on for any other, a shape each 4 ticks of the wait: 23 of them, noise that settles on the emblem
  of the speaker's side.

The window closes with the display's sound. `hud_comms_marker` and the radar mark the ship whose
line it is while the window is open or opening ([The target](hud.md#the-target),
[The radar](hud.md#the-radar)).

**Fix:** the game stops with a fatal error where `pilots.hog` lacks a film, as it does six the
pilots' faces name (`BLKACE`, `C_Scientist` and its death, `Saladin_Cap_D`, `Varygag_Capt` and its
death); OpenReliant plays the dead channel's film in its place. Where `pilots.hog` itself cannot be
opened, which is fatal too, OpenReliant says the lines without the window's films.

## The script's commands

- `PlaySpeech` (`0x06`) plays a speech file at once, without the window or a film, ending the line
  playing; the game reads it into a buffer of its own (`0x005883D0`), which leaves a line waiting
  for the window its own.
- `WaitForSpeech` (`0x07`) waits while a line plays; `WaitForMovie` (`0x09`) while a film plays
  (`hudmovie_playing`, `0x0057C3A8`). The missions wait for the film before each line they say.
- `PlayCommsMovie` (`0x08`) plays the film `pilots\<film>` with a speech file, at once, looping,
  under the string its third argument numbers, the line nobody's. It also sets `0x005373EA`, which
  nothing reads.

The game sets the volumes again as a line first plays in a mission (`0x005297E8`), alike either
way.

## Reports

A report waits its time before it goes to the queue (`0x00529D48`, five of them, `0x7C` bytes
each):

| Offset | Field |
|---|---|
| `+0x00` | In use |
| `+0x04` | Whose it is, as a line's |
| `+0x08` | **Unknown.** Whom it concerns: PERMISSION TO LAND puts the player's ship there, and nothing reads it |
| `+0x0C` | **Unknown.** Its kind: only kind 1 is said |
| `+0x10` | The string that names a pilot of the pilots' table who says it |
| `+0x14` | The game tick past which it is said |
| `+0x18` | The film's path, 50 bytes |
| `+0x4A` | The speech file's name, 50 bytes |

`0x004560D0` finds the first free one, or -1, which stops whatever would queue one. `0x00456050`,
each frame after `radio_frame`, lets each whose tick has passed go, and queues it (`radio_say`,
mode 1, flags 5, no expiry) where it is of kind 1 and neither nobody's, object `0x3E9`'s, nor an
exploding ship's; a ship's is named by its pilot's record, a pilot's by the report. `radio_reset`
empties them.

`0x004566C0` plays the pilot's own line at once through the speech sample, without the window,
ending the line playing, unless the mission is a multiplayer one: `0x004536D0` names it `mp` and the
line for a man, `fp` for a woman (`0x00562F16`, which the front end's new pilot screen sets).

PERMISSION TO LAND ([Landing](orders.md#landing)) has the pilot ask, `hud_012`, and queues the
answer 300 ticks on:

- In a training mission, the flight instructor's, pilot `0x52` named by string `0x100`:
  `pilots\VirtFlt_Ins.fm8` and `trnglnd_001.ut`.
- In any other, the bridge's: pilot `0x54` named by string `0x44` where the carrier is a Yamato,
  pilot `0x3C` otherwise. `0x00453620` makes its line, `yam` and the Yamato's bridge officer's film
  `pilots\Yam_Brdge_Off.fm8` where the carrier is a Yamato or explodes, `rel` and
  `pilots\Rel_Brdge_Off.fm8` otherwise, ending in a suffix `0x00453A50` picks at random by `rand`:
  clearing the ship, from `_lnd_001` to `_lnd_009` for a mission the script rates a success or
  better (`mission_success`), from `_lnd_010` to `_lnd_016` for a partial failure or success, and
  from `_lnd_017` to `_lnd_024` for any other; refusing it, from `_lnd_den_01` to `_lnd_den_04`.
  It also writes "DEBUG: Mission is flagged as a" and the rating's name into a line nothing shows.

Not ported: the reports the wingmen's keys and the radio's menu queue, and the kill remarks
([#99](https://github.com/vdmkenny/openreliant/issues/99)).

## Speech

A line plays through the speech sample ([Sound](sound.md#speech)), its peaks rounded off and in
the cockpit's cabin unless `--original`.
