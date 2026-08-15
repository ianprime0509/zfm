import {
  HighlightStyle,
  StreamLanguage,
  syntaxHighlighting,
  type StreamParser,
  type StringStream,
} from "@codemirror/language";
import { Tag } from "@lezer/highlight";

// Highlight tags for the MML token types.
const comment = Tag.define();
const number = Tag.define();
const string = Tag.define();
const note = Tag.define();
const accidental = Tag.define();
const command = Tag.define();
const partName = Tag.define();
const patchName = Tag.define();
const macroName = Tag.define();
const patchDefinition = Tag.define();
const macroDefinition = Tag.define();
const directiveName = Tag.define();
const waveName = Tag.define();
const enumName = Tag.define();
const operator = Tag.define();

// Words that read as values rather than single-letter commands. These must be
// matched before individual letters, otherwise `freq` would tokenize as `f`
// (note) + `r` (rest) + `e` (note) + `q`.
const WAVE_WORDS = new Set(["sin", "squ", "tri", "saw", "noi", "con", "exp"]);
const ENUM_WORDS = new Set(["on", "off", "freq", "pan", "vol", "key_on", "none"]);

type Kind = "directive" | "patch" | "macro" | "part" | "none";

interface MmlState {
  kind: Kind;
  // The kind a continuation line (one beginning with whitespace) should use.
  continueKind: Kind;
  directiveName: string | undefined;
  continueDirectiveName: string | undefined;
  // In a part definition, part names come first, before any commands.
  readingPartNames: boolean;
  // Whether the previous token was a note, so `+`, `-`, and `=` are accidentals.
  prevWasNote: boolean;
  // Inside a `_{...}` key signature, letters are notes and `+`/`-`/`=` are accidentals.
  inKeySignature: boolean;
}

const WORD_CHAR = /[A-Za-z0-9_-]/;
const NOTE_CHAR = /[a-g]/;
const ACCIDENTAL_CHAR = /[+\-=]/;
const COMMAND_CHARS = "rl&ovtpL<>[]{}*MTSWOA";

function peekWord(stream: StringStream): string {
  return stream.string.slice(stream.pos).match(/^[A-Za-z0-9_-]+/)?.[0] ?? "";
}

function readNumber(stream: StringStream): boolean {
  return stream.match(/[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)/) !== null;
}

function beginLine(stream: StringStream, state: MmlState): void {
  state.readingPartNames = false;
  state.inKeySignature = false;
  state.prevWasNote = false;
  state.directiveName = undefined;

  const ch = stream.peek();
  if (ch === "#") {
    state.kind = "directive";
    state.continueKind = "directive";
  } else if (ch === "@") {
    state.kind = "patch";
    state.continueKind = "patch";
  } else if (ch === "!") {
    state.kind = "macro";
    state.continueKind = "macro";
  } else if (ch !== undefined && /[A-Za-z]/.test(ch)) {
    state.kind = "part";
    state.continueKind = "part";
    state.readingPartNames = true;
  } else if (ch === " " || ch === "\t") {
    state.kind = state.continueKind;
    state.directiveName = state.continueDirectiveName;
  } else {
    state.kind = "none";
  }
}

function readDirective(stream: StringStream, state: MmlState): string | null {
  if (stream.peek() === "#") {
    stream.next();
    const start = stream.pos;
    stream.eatWhile(WORD_CHAR);
    const name = stream.string.slice(start, stream.pos);
    state.directiveName = name;
    state.continueDirectiveName = name;
    return "directiveName";
  }

  if (stream.eatSpace()) return null;
  const name = state.directiveName;
  if (name === "title" || name === "composer" || name === "arranger") {
    // Text directives consume the rest of the line, including `;`.
    stream.skipToEnd();
    return "string";
  }

  if (stream.peek() === ";") {
    stream.skipToEnd();
    return "comment";
  }
  if (stream.match(/[0-9]+(?:\.[0-9]+)?/)) {
    return "number";
  }
  stream.next();
  return null;
}

function readPatch(stream: StringStream): string | null {
  if (stream.peek() === "@") {
    stream.next();
    stream.eatWhile(WORD_CHAR);
    return "patchDefinition";
  }
  return readPatchBody(stream);
}

function readPatchBody(stream: StringStream): string | null {
  if (stream.eatSpace()) return null;
  const ch = stream.peek();
  if (ch === undefined) return null;
  if (ch === ";") {
    stream.skipToEnd();
    return "comment";
  }

  const word = peekWord(stream);
  if (WAVE_WORDS.has(word)) {
    stream.eatWhile(WORD_CHAR);
    return "waveName";
  }
  if (readNumber(stream)) {
    return "number";
  }
  if (ch === "," || ch === ".") {
    stream.next();
    return "operator";
  }
  stream.next();
  return null;
}

function readMacro(stream: StringStream, state: MmlState): string | null {
  if (stream.peek() === "!") {
    stream.next();
    stream.eatWhile(WORD_CHAR);
    return "macroDefinition";
  }
  return readCommands(stream, state);
}

function readPartNames(stream: StringStream, state: MmlState): string | null {
  if (stream.match(/[A-Za-z]+/)) {
    state.readingPartNames = false;
    return "partName";
  }
  state.readingPartNames = false;
  stream.next();
  return null;
}

function readCommands(stream: StringStream, state: MmlState): string | null {
  if (stream.eatSpace()) {
    state.prevWasNote = false;
    return null;
  }
  const ch = stream.peek();
  if (ch === undefined) return null;
  if (ch === ";") {
    stream.skipToEnd();
    state.prevWasNote = false;
    return "comment";
  }

  if (state.inKeySignature) {
    return readKeySignature(stream, state);
  }

  const word = peekWord(stream);
  if (WAVE_WORDS.has(word)) {
    stream.eatWhile(WORD_CHAR);
    state.prevWasNote = false;
    return "waveName";
  }
  if (ENUM_WORDS.has(word)) {
    stream.eatWhile(WORD_CHAR);
    state.prevWasNote = false;
    return "enumName";
  }

  if (NOTE_CHAR.test(ch)) {
    stream.next();
    state.prevWasNote = true;
    return "note";
  }

  if (ACCIDENTAL_CHAR.test(ch) && state.prevWasNote) {
    stream.eatWhile(ACCIDENTAL_CHAR);
    state.prevWasNote = false;
    return "accidental";
  }

  state.prevWasNote = false;

  // Signed numbers, e.g. volume/tempo/pan changes and negative parameters.
  if ((ch === "+" || ch === "-") && /[0-9.]/.test(stream.string.charAt(stream.pos + 1))) {
    if (readNumber(stream)) return "number";
  }
  if (/[0-9]/.test(ch)) {
    stream.match(/[0-9]+(?:\.[0-9]+)?/);
    return "number";
  }
  if (ch === "%") {
    stream.next();
    return "operator";
  }
  if (ch === "." || ch === "," || ch === "+" || ch === "-" || ch === "=") {
    stream.next();
    return "operator";
  }
  if (ch === "@") {
    stream.next();
    stream.eatWhile(WORD_CHAR);
    return "patchName";
  }
  if (ch === "!") {
    stream.next();
    stream.eatWhile(WORD_CHAR);
    return "macroName";
  }
  if (ch === "_") {
    stream.next();
    if (stream.peek() === "{") state.inKeySignature = true;
    return "command";
  }
  if (COMMAND_CHARS.includes(ch)) {
    stream.next();
    return "command";
  }
  stream.next();
  return null;
}

function readKeySignature(stream: StringStream, state: MmlState): string | null {
  if (stream.eatSpace()) return null;
  const ch = stream.peek();
  if (ch === undefined) return null;
  if (ch === "{") {
    stream.next();
    return "command";
  }
  if (ch === "}") {
    stream.next();
    state.inKeySignature = false;
    return "command";
  }
  if (NOTE_CHAR.test(ch)) {
    stream.next();
    return "note";
  }
  if (ACCIDENTAL_CHAR.test(ch)) {
    stream.eatWhile(ACCIDENTAL_CHAR);
    return "accidental";
  }
  stream.next();
  return null;
}

function readToken(stream: StringStream, state: MmlState): string | null {
  if (stream.sol()) beginLine(stream, state);

  if (stream.peek() === ";") {
    stream.skipToEnd();
    return "comment";
  }

  switch (state.kind) {
    case "directive":
      return readDirective(stream, state);
    case "patch":
      return readPatch(stream);
    case "macro":
      return readMacro(stream, state);
    case "part":
      if (state.readingPartNames) return readPartNames(stream, state);
      return readCommands(stream, state);
    default:
      stream.next();
      return null;
  }
}

const mmlParser: StreamParser<MmlState> = {
  name: "zfm",
  startState: () => ({
    kind: "none",
    continueKind: "none",
    directiveName: undefined,
    continueDirectiveName: undefined,
    readingPartNames: false,
    prevWasNote: false,
    inKeySignature: false,
  }),
  token: (stream, state) => readToken(stream, state),
  blankLine: (state) => {
    state.readingPartNames = false;
    state.inKeySignature = false;
    state.prevWasNote = false;
    state.directiveName = undefined;
  },
  languageData: {
    commentTokens: { line: ";" },
  },
  tokenTable: {
    comment,
    number,
    string,
    note,
    accidental,
    command,
    partName,
    patchName,
    macroName,
    patchDefinition,
    macroDefinition,
    directiveName,
    waveName,
    enumName,
    operator,
  },
};

export const zfmLanguage = StreamLanguage.define(mmlParser);

export const zfmHighlightStyle = HighlightStyle.define([
  { tag: comment, color: "var(--color-syntax-comment)" },
  { tag: number, color: "var(--color-syntax-number)" },
  { tag: string, color: "var(--color-syntax-string)" },
  { tag: note, color: "var(--color-syntax-note)" },
  { tag: accidental, color: "var(--color-syntax-accidental)" },
  { tag: command, color: "var(--color-syntax-command)" },
  { tag: partName, color: "var(--color-syntax-part)", fontWeight: "600" },
  { tag: patchName, color: "var(--color-syntax-patch)" },
  { tag: macroName, color: "var(--color-syntax-macro)" },
  { tag: patchDefinition, color: "var(--color-syntax-patch)", fontWeight: "600" },
  { tag: macroDefinition, color: "var(--color-syntax-macro)", fontWeight: "600" },
  { tag: directiveName, color: "var(--color-syntax-directive)", fontWeight: "600" },
  { tag: waveName, color: "var(--color-syntax-wave)" },
  { tag: enumName, color: "var(--color-syntax-enum)" },
  { tag: operator, color: "var(--color-syntax-operator)" },
]);

export const zfm = [zfmLanguage, syntaxHighlighting(zfmHighlightStyle)];
