# ZFM

## Project layout

- Root (`.zig` files) - the core audio processing engine written in Zig
- `web/` - the web interface (HTML, CSS, JS)

## Terminology

- Sample - amplitude of a single audio channel at a point in time (one f32)
- Frame - samples for both channels (left and right) at a point in time

## Code formatting

- `.zig` files - always run `zig fmt FILE` after modifying `FILE`
- `.html`, `.css`, `.js`, `.json`, `.yaml` files - always run `pnpm prettier --write FILE` after modifying `FILE`

## Zig (root)

### Zig language version

This project tracks the latest Zig master branch, so certain features may be different compared to earlier versions of the language:

- Decl literals: the syntax `.decl`, `.decl(args)`, or `try .decl(args)` may be used to reference a declaration `decl` of the _result type_ of the expression. Prefer this form (with an explicitly specified result type) over using `Type.decl` if possible:

  ```zig
  // Before:
  var values = std.ArrayList(u8).empty;
  var obj = try MyType.init(1, 2, 3);
  // After:
  var values: std.ArrayList(u8) = .empty;
  var obj: MyType = try .init(1, 2, 3);
  ```

- The `**` operator no longer exists. Use `@splat` instead:
  ```zig
  // Before:
  const arr: [4]u8 = .{0} ** 4;
  // After:
  const arr: [4]u8 = @splat(0);
  ```

## Web interface (`web/`)

Run commands with the `web` directory as the working directory.

### Build

- Run `zig build` to build `audio.wasm`

### Linting

- Run `pnpm lint` to lint HTML, CSS, and JS files
