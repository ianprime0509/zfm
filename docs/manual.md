# ZFM

ZFM is an FM synthesizer and MML (music macro language) compiler and driver.

[FM synthesis](https://en.wikipedia.org/wiki/Frequency_modulation_synthesis) is
a form of audio synthesis that makes sound by modulating the frequency of an
audio signal (a _carrier_, such as a sine wave) using the output of another
signal (a _modulator_). ZFM implements FM synthesis using eight operators and a
variety of base waves, allowing for flexibility in creating sounds.

## Synthesizer

A ZFM synth may use any number of _voices_. A voice controls a single note. The
number of voices used in the synth controls the maximum polyphony, or the
maximum number of notes that can be playing at any given time.

Each voice is controlled by the following parameters:

- Frequency: the frequency of the note being played, in Hz (for example,
  standard A4 = 440 Hz).

- Pan: how far to the left or right the sound is. -1 is completely left, 0 is
  middle (equal parts left and right), and 1 is completely right. Values in
  between can be used as well.

- Volume: how loud the sound is, from 0 to 1.

Each voice controls 8 _slots_ (FM operators). Each slot is fundamentally a
simple wave, such as a sine wave, with an _envelope_ controlling the total
amount of output from the slot over time. Although each slot by itself can only
produce a simple wave, slots can be connected to other slots to modulate them
(the fundamental mechanism of FM synthesis). This allows combinations of slots
to produce complex sounds.

Each slot is controlled by the following parameters:

- TL (total level): the maximum output level of the slot.

  For carriers, TL acts as a weight: the total output signal across all carriers
  is a weighted average, with TL as the weight.

  For modulators, TL directly controls the amount of modulation applied to the
  other slots the modulator feeds into.

- ML (multiplier): applied to the base note frequency to produce the actual
  frequency of the slot wave (before any modulation).

  For example, if ML is set to 2 and the note A4 is played (440 Hz), the slot's
  wave frequency becomes 880 Hz (A5).

- FB (feedback): multiplied by the slot's previous output level and added to its
  own modulation.

- WS (wave-specific): has a different meaning depending on the wave.

  For sine, triangle, and saw waves: unused.

  For square waves: duty cycle (between 0 and 1, exclusive). Controls the
  fraction of time per cycle the wave is high.

  For noise waves: noise quality factor (at least 0.1). Lower values produce
  closer to white noise, while higher values produce a clearer pitch.

The slot's envelope controls the "shape" of its output level over time. When a
key is pressed, the slot's output starts at 0 in the attack phase.

- AR (attack rate): the number of seconds until the slot's output reaches 1 (its
  maximum output). The output increases linearly from 0 to 1. Once the output
  reaches 1, the envelope enters the decay phase.

- DR (decay rate): the number of seconds until the slot's output reaches the
  sustain level. The output decreases exponentially from 1 to the sustain level.
  Once the output reaches the sustain level, the envelope enters the sustain
  phase.

- SL (sustain level): the output level targeted during the decay phase, between
  0 and 1.

- SR (sustain rate): the number of seconds until the slot's output reaches 0.
  The output decreases exponentially from the sustain level to 0. Once the
  output reaches 0, the envelope becomes idle (no output).

- RR (release rate): after the key is released, the number of seconds until the
  slot's output reaches 0. The output decreases exponentially from whatever
  level it was at when the key is released to 0. Once the output reaches 0, the
  envelope becomes idle (no output).

(TODO: add visual diagram)

For any of the rate parameters, 0 is a special value: it means that the envelope
will not progress past that phase. For example, an envelope with DR set to 0
will stay at output level 1 (full output) once the attack phase completes, until
the key is released.

## Driver

A ZFM _driver_ wraps around a synth and controls it. The control typically comes
from a predefined sequence of commands, defined in a ZFM MML (music macro
language) source file. MML is described in more detail in a subsequent section.

The driver also controls _LFOs_ (low-frequency oscillators) which can apply
continuous changes to synth parameters. A total of four user-defined LFOs are
available for each voice. An example of an LFO use-case is applying vibrato via
a sine wave LFO applied to the voice's frequency parameter.

The driver executes commands using _ticks_ as time units. A single whole note
consists of 96 ticks. Hence, the current tempo defines how quickly commands are
executed.

## MML

_MML_ (music macro language) is the standard way to create music with ZFM. An
MML track is a plain text file defining commands to be executed by the driver.
Here is an example of an MML track that plays a C major scale:

```zfm
#title C major scale
#composer Your Name

@electric-piano 0 1, 2 3.
  sine 0.1 11 0.5 0.00001 0 0 0 0.00001
  sine 0.3 12 0 0.00001 0.5 0 0 0.00001
  sine 0.1 1 0 0.00001 2 0.2 0 2
  sine 1 1 0 0.00001 4 0 0 1

; A C major scale played on an electric piano.
A @electric-piano cdefgab>c
```

This example illustrates several of the core concepts of MML:

- The lines beginning with `#` (such as `#title`) are _directives_. They define
  properties of the track, such as the title and initial tempo.

- The line beginning with `@` defines a _patch_. A patch defines all the
  parameters for a voice and its slots.

- The line beginning with `;` is a _comment_. Comments may appear almost
  anywhere in MML (they are not recognized within textual content, such as the
  track title). Comments are ignored by the MML compiler, so they can be used to
  mark sections of the track for organization, explain tricky sequences, etc.

  Comments do not need to be at the beginning of a line: they can also be placed
  at the end of a line. Everything including and after the `;` is ignored.

- The line beginning with `A` defines commands to be played on a part (in this
  case, part `A`). Briefly, the commands defined here set the voice parameters
  for the part to `electric-piano` and then play a C major scale.

The available directives, commands, and additional syntax will be described in
the following sections.

### Syntax

MML is processed line by line. The meaning of each line is determined by the
first character in the line:

- `#`: directive
- `@`: patch definition
- `!`: macro definition
- `A-Z`, `a-z`: part definition

Comments may be added using `;`: all characters starting with the `;` and
continuing to the end of the line are ignored by the compiler. As an exception,
comments are not recognized in text directive values (such as `#title`) so that
the character `;` can be used in the text.

Lines beginning with one or more spaces or tabs are _continuation lines_,
continuing the content of the previous line. For example, these two MML part
definitions are equivalent:

```zfm
A cdef
```

and

```zfm
A cd
  ef
```

### Directives

#### Metadata

- `#title`: defines the title of the track.

- `#composer`: defines the composer of the track (the author of the original
  musical work).

- `#arranger`: defines the arranger of the track (the author of the ZFM MML
  rendition of the work, if different from the composer).

#### Initial playback settings

- `#tempo`: defines the initial tempo of the track, in beats per minute (BPM). A
  "beat" for the purpose of tempo is defined as a quarter note.

### Patch definitions

Patches specify the slot parameters for a voice, including how the slots are
connected.

The text immediately following the `@` of a patch definition specifies the patch
name, which may consist of alphanumeric characters, `-`, and `_`.

After the patch name, the slot connections are defined. Slot numbers (0-7)
separated by spaces are connected left to right. These runs of slots may be
separated by commas. The entire connection string is terminated with a period.
Here are some examples:

- `.`: no slot connections, all slots are carriers.
- `0 1.`: slot 0 modulates slot 1, all other slots are carriers.
- `0 1 2, 0 3.`: slot 0 modulates slot 1, which in turn modulates slot 2. Slot 0
  also modulates slot 3. All other slots are carriers.

After the slot connections, the slot parameters are defined in order for each slot:

1. Wave (`sine`, `square`, `triangle`, `saw`, `noise`)
2. TL
3. ML
4. FB
5. WS (only for `square` and `noise` waves, must be omitted for others)
6. AR
7. DR
8. SL
9. SR
10. RR

It is not required to specify all eight slots explicitly in the patch
definition. Any omitted slots are defined with all zero parameters
(unused/silent).

Here is an example of a patch definition illustrating several of these points:

```zfm
@breathy-flute 0 1.
  sine 0.2 2 0 0.04 0 0 0 0.00001
  sine 1 2 0 0.04 0.1 0.8 0 0.00001
  noise 0.3 4 0 30 0.04 0.5 0 0 0.00001
```

The patch name is `breathy-flute`. The slot connections are defined such that
slot 0 modulates slot 1, and all other slots are carriers. Slots 0 and 1 are
defined as sine waves, and slot 2 is defined as noise (note the WS parameter is
present for slot 2 but not slots 0 and 1). The remaining slots are zero and
unused.

### Macro definitions

Macros define repeatable sequences of MML commands.

The text immediately following the `!` of a macro definition specifies the macro
name, which may consist of alphanumeric characters, `-`, and `_`.

Everything after the macro name is the body of the macro. The body is not
processed or validated in any way when the macro is defined, only when the macro
is used.

For example, the following MML snippets are equivalent:

```zfm
!riff abcabc

A !riff !riff
```

and

```zfm
A abcabc abcabc
```

A macro may reference other macros in its definition, but there is a limit of at
most 32 levels of nested macro usage.

### Part definitions

Lines starting with a part letter (`A`-`Z`, `a`-`z`) define commands for that
part. Each part is allocated its own voice in the synth, and all parts execute
their commands in parallel.

Part definition lines may define commands for multiple parts at once, by listing
more than one part letter at the start of the line. For example, the following
MML plays the same sequence of notes on two parts simultaneously with different
patches:

```zfm
A @patch-1
B @patch-2
AB cdefgab>c
```

In this example, parts A and B are defined with different patches, but the
sequence of commands `cdefgab>c` is applied to both parts via the third line.

Every part in MML starts with the following default settings, which may be
changed by commands:

- Default note length: quarter note
- Octave: 4
- Key signature: none

### Commands

Some commands are defined as _compile-only_. This means that they are processed
directly by the compiler in the order they are read and do not apply iteratively
in loops. For example, the `>` (increase octave) command is compile-only,
meaning that in the following MML, `c` and `d` are played at octave 4 and `e`
and `f` at octave 5 for all iterations of the loop:

```zfm
A o4 [cd > ef]4
```

#### Note (`a`-`g`)

The commands `a`-`g` define notes. Several modifiers may follow the note, in order:

1. Accidentals: `+` (sharp, increases pitch by one half step), `-` (flat,
   decreases pitch by one half step), `=` (natural, cancels out any default from
   the key signature). Multiple accidentals may be applied to a single note (for
   example, `++`, double sharp, increases pitch by one whole step).

   If no accidentals are provided explicitly, they will be applied from the
   part's current key signature.

2. Note length: a plain number (e.g. `1`, `2`, `3`, etc.) defines the length in
   terms of a fraction of a whole note. The number must be a divisor of 96 (the
   total number of ticks in a whole note).

   `%` followed by a number (e.g. `%96`) defines the length directly in terms of
   ticks.

   A `.` following the length multiplies the length by 1.5 (the same as a dot in
   traditional music notation). It is an error if the new length cannot be
   represented using an integer number of ticks. Multiple `.` may be used.

   If no note length is provided explicitly, the part's default note length is
   used (defaults to a quarter note).

   The note length may be followed by operators `+` and `-` followed by a
   length, adding to and subtracting from the base length, respectively.

The note will be played according to the part's current octave at the time the
note command is processed.

Examples:

- `c`: C (at the part's default note length and using its current key signature)
- `c4`: quarter note C (using the part's current key signature)
- `c4.`: dotted quarter note C (quarter note plus eighth note, using the part's
  current key signature)
- `c4..`: double dotted quarter note C (quarter plus eighth plus sixteenth note,
  using the part's current key signature)
- `c=4`: quarter note C natural
- `c1+1+1+1`: C held for four whole notes (using the part's current key signature)
- `c+4+%1`: C# held for a quarter note plus one tick

#### Rest (`r`)

Defines a rest. May be followed by a length using the same syntax as for note
length (using the part's default note length if none is specified).

Examples:

- `r`: rest using the part's default note length
- `r4`: quarter note rest

#### Set default length (`l`)

Sets the part's default note length. This is a compile-only command. Should be
followed by the default note length to set, using the same syntax as for note
length. (It is technically possible to write just `l` to set the part's default
note length to itself, but this is pointless.)

Examples:

- `l4`: set the part's default note length to a quarter note (all notes, rests,
  etc. following without an explicit length will be given quarter note length)

#### Tie (`&`)

Removes the key off from the end of the directly preceding note. If the previous
command (excluding compile-only commands) was not a note, it is an error.

Examples:

- `c&d`: plays key on for note C, followed by note D, without playing key off
  for note C in between

#### Set octave (`o`)

Sets the part's current octave. This is a compile-only command. Must be followed
by the octave number to set.

Examples:

- `o4`: set the part's current octave to 4

#### Octave up/down (`>`, `<`)

`>` increases the part's current octave by 1, and `<` decreases the part's
current octave by 1. These are compile-only commands.

#### Set patch (`@`)

Sets the slot connections and all slot parameters of the part's underlying voice
using the provided patch. Must be followed by the patch name. It is an error to
refer to a patch which has not yet been defined.

Because MML is processed line by line, patch definitions must precede their
usage in part commands.

Examples:

- `@electric-piano`: sets the part's voice parameters using the `electric-piano`
  patch

#### Call macro (`!`)

Calls the provided macro. Must be followed by the macro name. It is an error to
refer to a macro which has not yet been defined.

Because MML is processed line by line, macro definitions must precede their
usage in part commands.

The behavior of calling a macro is to start processing the commands specified in
the macro definition, exactly as if they were interpolated directly into the
part where the macro is called. When the macro definition ends, commands
continue to be processed following the point where the macro was called.

Example:

```zfm
!a cd
!b !a !a
A !b !b
```

is equivalent to

```zfm
A cd cd cd cd
```

#### Change volume (`v`)

When followed by a number without a sign, sets the absolute volume of the voice.
When followed by a number with a sign (`+` or `-`), changes the volume of the
voice by that amount.

Examples:

- `v0.5`: sets the voice volume to 0.5
- `v+0.5`: increases the voice volume by 0.5
- `v-0.5`: decreases the voice volume by 0.5

#### Change tempo (`t`)

When followed by a number without a sign, sets the absolute tempo of the driver.
When followed by a number with a sign (`+` or `-`), changes the tempo of the
driver by that amount.

Note that the tempo applies to the entire driver, not each part individually, so
this command also affects all the other parts.

Examples:

- `t120`: sets the tempo to 120 BPM
- `t+20`: increases the tempo by 20 BPM
- `t-20`: decreases the tempo by 20 BPM

#### Set pan (`p`)

Sets the pan of the voice. Must be followed by the pan to set (between -1 and 1,
inclusive).

Examples:

- `p-1`: sets the pan to -1 (hard left)
- `p0`: sets the pan to 0 (center)
- `p1`: sets the pan to 1 (hard right)

#### Set global loop point (`L`)

Sets the global loop point of the part. When the part ends, it will repeat
starting from this point.

#### Loop (`[]`)

Defines a command loop. Commands within the `[]` will execute for the number of
iterations specified by the number following the `]`, or infinitely if no number
is specified.

Examples:

- `[abc]2`: plays `abc` twice
- `[abc]`: plays `abc` infinitely

#### Portamento (`{}`)

Plays a portamento (smooth pitch slide from one note to another). There must be
exactly two notes (optionally including accidentals) within the `{}`. May be
followed by a note length, or uses the part's default note length if none is
provided. The note length defines the length of the entire portamento.

Examples:

- `{ab}`: plays key on with note A, and smoothly slides to note B, using the
  part's default note length and key signature
- `{c+d=}2.`: plays key on with note C# and smoothly slides to note D natural,
  lasting for a dotted half note

#### Toggle/set LFO (`*`)

Toggles the state (on/off) of an LFO. Must be followed by the number (0-3) of
the LFO to toggle. May optionally be followed by a comma and `on` or `off` to
explicitly set the desired state of the LFO rather than toggling it.

Examples:

- `*0`: toggles LFO 0 (turns it on if it's off, or off if it's on)
- `*1,on`: turns LFO 1 on
- `*2,off`: turns LFO 2 off

#### LFO configuration (`M`)

Sets LFO configurations. These commands have a uniform format: the letter
following `M` specifies which LFO configuration to set. Then, the LFO number
(0-3) must be provided. Following the LFO number is a sequence of
comma-separated parameters, depending on the configuration being set.

Subcommands:

- `MTn,target`: sets the LFO target
  - `MTn,freq`: targets frequency
  - `MTn,pan`: targets pan
  - `MTn,vol`: targets volume
- `MSn,scale,offset`: sets the LFO scale and offset
- `MWn,wave,params`: sets the LFO wave and any associated parameters
  - `MWn,constant`: sets a constant wave (no change over time)
  - `MWn,sine,freq`: sets a sine wave with the given frequency
  - `MWn,exp,mul`: sets an exponential shape with the given multiplier
- `MOn,trigger`: sets the LFO trigger
  - `MOn,none`: never retriggers the LFO (constant effect)
  - `MOn,key_on`: retriggers the LFO with every key on
- `MAn,adjust`: sets whether the LFO shape is adjusted proportionally to a
  reference pitch of 440 Hz (`adjust` must be either `on` or `off`)

Examples:

- `MT0,freq MS0,3,0 MW0,sine,5 MO0,key_on MA0,on`: configures LFO 0 for a
  vibrato effect. The pitch oscillates at a rate of 5 Hz, with a variation of
  +/- 3 Hz at a 440 Hz reference pitch and adjusted proportionally (so playing
  A5, at 880 Hz, uses a variation of +/- 6 Hz instead).

#### Update key signature (`_{}`)

Updates the part's key signature. The content within the `{}` delimiters must
consist of accidentals, followed by note names to apply those accidentals to in
the key signature.

Notes not explicitly mentioned in the key signature are unchanged.

Examples:

- `_{+f}`: sets F to sharp in the part's key signature
- `_{+fc}`: sets F and C to sharp in the part's key signature
- `_{+f=c-b}`: sets F to sharp, C to natural, and B to flat in the part's key
  signature
- `_{++f}`: sets F to two sharps in the part's key signature
