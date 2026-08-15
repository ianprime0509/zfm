import { useEffect, useState } from "preact/hooks";
import { TrackEditor } from "./TrackEditor.tsx";
import { BankEditor, type Bank } from "./bank/BankEditor.tsx";
import { sanitizeBank } from "./bank/sanitize.ts";
import { Compiler } from "./compiler.ts";
import { Synth } from "./synth.ts";
import { N_VOICES } from "./patch/keyboard.ts";
import { insertPatch } from "./patch/format.ts";
import type { Patch } from "./patch/types.ts";
import { loadString, saveString, loadJSON, saveJSON } from "./storage.ts";
import classes from "./App.module.css";
import { PanelRightClose, PanelRightOpen, Play, Square, Download } from "lucide-preact";
import { Button } from "./components/Button.tsx";
import { LoadButton } from "./components/LoadButton.tsx";
import { downloadText } from "./download.ts";
import INITIAL_TRACK from "../../tracks/lofi.zfm?raw";

// App shell: a fixed "ZFM" header above a body that pairs a Monaco text
// editor with the bank editor.
//
//   - Large screens: the bank editor is a persistent sidebar on the right;
//     the editor fills the rest. The header's bank toggle is hidden.
//   - Small screens: the editor fills the body; the header's bank toggle
//     shows/hides the bank editor as a right-hand overlay.
//
// A single BankEditor instance is rendered and CSS relocates it between the
// sidebar and the overlay (rather than mounting two copies), because two
// copies would each attach their own keyboard listeners.
//
// App owns the single `Compiler` and `Synth` instances so they can be shared
// between the track editor (compilation/linting + playback) and the bank
// editor (keyboard play). The header's play/stop button compiles the current
// track and loads it into the synth; while playing, keyboard play in the bank
// editor is disabled so the two never drive the synth at once.

const TRACK_KEY = "track";
const BANK_KEY = "bank";

function App() {
  // `bankOpen` only matters on small screens (overlay mode). On large
  // screens the sidebar is always shown via CSS regardless of this state.
  const [bankOpen, setBankOpen] = useState(false);

  // The track source lives here so the play button can compile the exact
  // text currently in the editor. Restore the last-edited track from local
  // storage so the user resumes where they left off.
  const [source, setSource] = useState(() => loadString(TRACK_KEY, INITIAL_TRACK));
  useEffect(() => saveString(TRACK_KEY, source), [source]);

  const [playing, setPlaying] = useState(false);
  // Per-part source ranges of the currently executing command, refreshed
  // periodically while a track plays. `null` means nothing is playing.
  const [commandSpans, setCommandSpans] = useState<(number[] | null)[] | null>(null);

  // Single shared compiler (Web Worker) and synth (AudioWorklet). Created in
  // an effect so cleanup terminates them; the `ready` flag lets the play
  // button stay disabled until they're live.
  const [compiler, setCompiler] = useState<Compiler | null>(null);
  const [synth, setSynth] = useState<Synth | null>(null);
  useEffect(() => {
    const c = new Compiler();
    const s = new Synth();
    setCompiler(c);
    setSynth(s);
    return () => {
      c.close();
      void s.close();
    };
  }, []);

  // Poll the synth while playing so the track editor can keep the currently
  // executing commands highlighted.
  useEffect(() => {
    if (!playing || !synth) {
      setCommandSpans(null);
      return;
    }
    const poll = async () => setCommandSpans(await synth.currentCommandSpans());
    void poll();
    const id = setInterval(() => void poll(), 100);
    return () => clearInterval(id);
  }, [playing, synth]);

  // Load track: prompt for a .zfm file and replace the editor source with
  // its contents. The linter surfaces any compile errors in the editor.
  const loadTrack = (file: File) => void file.text().then(setSource);

  const onPlayStop = async () => {
    if (!compiler || !synth) return;
    if (playing) {
      // Stop: clear the loaded module and return the synth to its idle
      // (keyboard-ready) state with 8 voices.
      await synth.reset({ voices: N_VOICES });
      setPlaying(false);
      return;
    }
    // Play: compile the current track and load the resulting module. The
    // linter surfaces compile errors in the editor; on failure just leave
    // the synth untouched.
    const ok = await compiler.compile(source);
    if (!ok) {
      // TODO: display a modal with these errors or do something to signal it to the user
      console.error(await compiler.errors());
      return;
    }
    const mod = await compiler.module();
    await synth.load({ mod });
    setPlaying(true);
  };

  // Insert a patch from the bank editor into the track source at the best
  // position (see insertPatch). The track editor is a controlled CodeMirror,
  // so updating `source` here flows straight back into the editor.
  const onInsertPatch = (patch: Patch) => {
    setSource((src) => insertPatch(src, patch));
  };

  // Persist the bank whenever it changes so it can be restored on reload.
  // The initial bank is loaded once from storage (empty array falls back to
  // the editor's default inside BankEditor).
  const [initialBank] = useState<Bank | undefined>(() =>
    sanitizeBank(loadJSON<unknown>(BANK_KEY, null)),
  );
  const onBankChange = (b: Bank) => saveJSON(BANK_KEY, b);

  return (
    <div class={classes.root}>
      <header class={classes.header}>
        <img class={classes.logo} src="/favicon.svg" alt="ZFM" title="ZFM" />
        <div class={classes.headerActions}>
          <LoadButton title="Load track" onFile={loadTrack} />
          <Button title="Download track" onClick={() => downloadText("track.zfm", source)}>
            <Download />
          </Button>
          <Button
            disabled={!compiler || !synth}
            onClick={onPlayStop}
            aria-pressed={playing}
            title={playing ? "Stop" : "Play"}
          >
            {playing ? <Square /> : <Play />}
          </Button>
          <Button
            class={classes.toggle}
            aria-expanded={bankOpen}
            aria-controls="bank-pane"
            onClick={() => setBankOpen((o) => !o)}
            title={bankOpen ? "Hide bank" : "Show bank"}
          >
            {bankOpen ? <PanelRightClose /> : <PanelRightOpen />}
          </Button>
        </div>
      </header>
      <div class={classes.body}>
        <div class={classes.editorPane}>
          {compiler && (
            <TrackEditor
              compiler={compiler}
              value={source}
              onChange={setSource}
              readOnly={playing}
              currentCommandSpans={commandSpans}
            />
          )}
        </div>
        <aside
          id="bank-pane"
          class={`${classes.bankPane}${bankOpen ? ` ${classes.bankOpen}` : ""}`}
        >
          {compiler && synth && (
            <BankEditor
              initialBank={initialBank}
              compiler={compiler}
              synth={synth}
              disabled={playing}
              onInsertPatch={onInsertPatch}
              onChange={onBankChange}
            />
          )}
        </aside>
      </div>
    </div>
  );
}

export default App;
