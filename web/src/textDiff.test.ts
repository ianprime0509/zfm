import { describe, expect, it } from "vite-plus/test";
import { textDiff } from "./textDiff.ts";

describe("textDiff", () => {
  it("returns no change for identical strings", () => {
    expect(textDiff("abc", "abc")).toEqual({ from: 0, to: 0, insert: "" });
  });

  it("replaces only the insertion when text is appended at the end", () => {
    expect(textDiff("abc", "abcd")).toEqual({ from: 3, to: 3, insert: "d" });
  });

  it("replaces only the differing span when a block is inserted mid-file", () => {
    expect(textDiff("a\nb\nc", "a\nPATCH\nb\nc")).toEqual({ from: 2, to: 2, insert: "PATCH\n" });
  });

  it("replaces only the differing span when a block is removed mid-file", () => {
    expect(textDiff("a\nPATCH\nb\nc", "a\nb\nc")).toEqual({ from: 2, to: 8, insert: "" });
  });

  it("falls back to a full replacement for completely different text", () => {
    expect(textDiff("abc", "xyz")).toEqual({ from: 0, to: 3, insert: "xyz" });
  });
});
