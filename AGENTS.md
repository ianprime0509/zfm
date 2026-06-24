# ZFM

An FM synthesizer and MML (music macro language) compiler.

## Project layout

Code:

- `core` - core library containing synth and MML compiler
- `cli` - CLI for playing and rendering tracks
- `web` - web interface

Resources:

- `patches` - sample patches (synth voice parameters)
- `tracks` - sample tracks/songs

## Terminology

- Sample - amplitude of a single audio channel at a point in time (one f32)
- Frame - samples for both channels (left and right) at a point in time

## Formatting

- `.zig` files - always run `zig fmt FILE...` after modifying files
- `.ts`, `.tsx`, `.html`, `.css`, `.json`, `.yaml` files - always run `vp fmt --write FILE...` after modifying files

## Code style

### Comments

- Avoid comments that merely describe _what_ code does: prefer comments that describe _why_ code does something that may otherwise be confusing.
- Avoid mentioning changes from previous versions of the code in comments.
- Avoid mentioning the prompt in comments (e.g. no "...as required by the prompt...").
