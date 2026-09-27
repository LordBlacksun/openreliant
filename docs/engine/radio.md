# The radio

`C:\lancer\game\videoreports.cpp` (**Unverified:** the file, placed by the link order) queues the
lines the pilots say and plays them with their faces in the display's window 0. OpenReliant plays
the lines ([`game/videoreports.zig`](../../src/engine/game/videoreports.zig)); the window and the
faces' films are not ported yet ([#99](https://github.com/vdmkenny/openreliant/issues/99)).

## Lines

`radio_say` (`0x004562D0`) takes a film, a speech file ([Speech files](../formats/speech.md)), a
mode, the speaker's name, the film's flags, whose line it is (`comms_object`, `0x0057BDF4`: a
ship's slot, or a pilot of the pilots' table from `0xFFFF` on) and how long it keeps, outside a
multiplayer mission:

- Mode 0, at once: the window opens unless it is closing, the line playing stops, the speech is
  read from `msspeech.hog`, and the film plays with it (`hudmovie_play`, `0x0048D120`).
- Mode 1, queued. Mode 2, queued unless a line plays or waits (`radio_busy`, `0x004561A0`).

The queue holds five lines (`radio_queue`, `0x005295A0`, `0x74` bytes each: the film's flags, the
speaker's name, the film, the speech, whose it is, and the tick it expires at, or -1), counted at
`0x00529594`, written at `0x00529870` and read at `0x00529CBE`. `radio_frame` (`0x00456510`), each
frame after the controls, while lines wait, the window is shut or open and no speech plays, takes
the next and says it unless its time has passed; a sixth line queued is dropped.

`radio_say_pilot` (`0x00456250`) says a line for a pilot of the pilots' table (`pilot_faces`,
`0x005048D8`, 24 bytes each: the string that names the pilot, the side, and a film for each of
four head movements); `radio_say_ship` (`0x004561C0`) for a ship, unless it is a stand-in,
exploding, or without a pilot record, with the films the record names. The script's
`CommsFromShip` and `CommsFromPilot` say a line at once, with film flags 5, and their `Once` forms
with 6, the film not looping ([Script VM](script-vm.md#the-commands)).

Not ported: the window and the films; the delayed reports (`0x00529D48`, `0x7C` bytes each,
stepped by `0x00456050`) that the wingmen's keys, PERMISSION TO LAND and the kill remarks queue;
and the flag `0x005297E8`, set while a line is said.

## Speech

A line plays through the speech sample ([Sound](sound.md#speech)), its peaks rounded off and in
the cockpit's cabin unless `--original`.
