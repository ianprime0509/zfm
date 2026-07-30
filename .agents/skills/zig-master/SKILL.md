---
name: zig-master
description: Use this skill when working with Zig files, to understand changes in the Zig master version used in this project compared to older versions.
---

# Zig master version guidance

This project uses the latest Zig master version, not a tagged release. Some aspects of the language have changed since the latest tagged version in your training data.

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

- `@intFromEnum`, `@enumFromInt`: replaced by `@backingInt` and `@fromBackingInt`, respectively
