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

const TRACK_KEY = "track";
const BANK_KEY = "bank";

function App() {
  const [bankOpen, setBankOpen] = useState(false);

  const [source, setSource] = useState(() => loadString(TRACK_KEY, INITIAL_TRACK));
  useEffect(() => saveString(TRACK_KEY, source), [source]);

  const [playing, setPlaying] = useState(false);
  // Currently executing command spans (null means nothing is executing).
  const [commandSpans, setCommandSpans] = useState<([number, number] | null)[] | null>(null);

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

  const loadTrack = (file: File) => void file.text().then(setSource);

  const play = async () => {
    if (!compiler || !synth) return;
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

  const stop = async () => {
    if (!synth) return;
    await synth.reset({ voices: N_VOICES });
    setPlaying(false);
  };

  const onPlayStop = async () => {
    if (playing) {
      await stop();
    } else {
      await play();
    }
  };

  const onInsertPatch = (patch: Patch) => {
    setSource((src) => insertPatch(src, patch));
  };

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
