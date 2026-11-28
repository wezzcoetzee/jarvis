import { createHash } from "node:crypto";
import { copyFile, mkdir, readdir, realpath, rename, rm, stat } from "node:fs/promises";
import { join, relative } from "node:path";
import { fold, paths, settings } from "./config";
import { exists, readJson, readText, writeAtomic } from "./files";
import { type Write, commit, localDate } from "./vault";

/**
 * One note a run touched. `at` is when the run first went to edit it, `after` its hash when the
 * run ended (null: deleted).
 */
type Entry = { path: string; backup: string | null; at: number; after?: string | null };
/** Keyed by the note's folded path, so two spellings of one note are one entry. */
type Manifest = Record<string, Entry>;

const runsDir = join(paths.state, "runs");

const RUN_ID = /^[\w-]+$/;
const NOT_A_RUN = "Copy an id from jarvis runs.";

export const runDir = (runId: string) => {
  if (!RUN_ID.test(runId)) throw new Error(`Not a run id: ${runId}`, { cause: NOT_A_RUN });
  return join(runsDir, runId);
};

const manifestPath = (runId: string) => join(runDir(runId), "manifest.json");
// Entries hold real paths (the hook resolves symlinks), so name them relative to the real vault.
const vaultName = async (path: string) => relative(await realpath(paths.vault), path);
const hash = (text: string) => createHash("sha256").update(text).digest("hex");

async function currentHash(path: string): Promise<string | null> {
  const text = await readText(path);
  return text === null ? null : hash(text);
}

export async function readManifest(runId: string): Promise<Manifest> {
  return (await readJson<Manifest>(manifestPath(runId))) ?? {};
}

const writeManifest = (runId: string, manifest: Manifest) => writeAtomic(manifestPath(runId), JSON.stringify(manifest, null, 2));

/** Called by the hook before each edit. Copies the note the first time this run edits it. */
export async function backUp(runId: string, key: string, path: string): Promise<void> {
  const dir = runDir(runId);
  await mkdir(dir, { recursive: true });
  const manifest = await readManifest(runId);
  if (manifest[key]) return;
  // Named after the note, not a count of the manifest, so two hooks that read the same manifest
  // can never copy two notes to one backup. The manifest itself isn't locked: Claude Code runs
  // Edit and Write one at a time, so a run's hooks that reach here never overlap.
  const backup = (await Bun.file(path).exists()) ? join(dir, `${hash(key).slice(0, 16)}.md`) : null;
  if (backup) await copyFile(path, backup);
  manifest[key] = { path, backup, at: Date.now() };
  await writeManifest(runId, manifest);
}

/** A new run id, once runs older than a week are cleared out. Shared by `ask` and `capture`. */
export async function startRun(): Promise<string> {
  await prune().catch((error) => console.error(`couldn't clear old runs: ${error}`));
  return new Date().toISOString().replace(/[:.]/g, "-");
}

/**
 * `commit` as an undoable run, for writes Jarvis makes itself: each note is copied first and
 * sealed after, just as the hook does for Claude's edits. `run` is there only when something was
 * written. A failed write drops the run, since an unsealed one would block undoing earlier ones.
 */
export async function commitRun(writes: (Write | null)[]): Promise<{ written: string[]; run?: string }> {
  const planned = writes.filter((w) => w !== null);
  if (planned.length === 0) return { written: [] };
  const run = await startRun();
  try {
    // The hook's entries are keyed by real path, so name the notes the same way.
    const vault = await realpath(paths.vault);
    for (const { path } of planned) {
      const real = join(vault, relative(paths.vault, path));
      await backUp(run, fold(real), real);
    }
    const written = await commit(planned);
    await seal(run);
    return { written, run };
  } catch (error) {
    await rm(runDir(run), { recursive: true, force: true });
    throw error;
  }
}

/** Records how each note looked when the run ended, so undo can tell if it changed since. */
export async function seal(runId: string): Promise<string[]> {
  const manifest = await readManifest(runId);
  for (const entry of Object.values(manifest)) entry.after = await currentHash(entry.path);
  if (Object.keys(manifest).length > 0) await writeManifest(runId, manifest);
  return Promise.all(Object.values(manifest).map((e) => vaultName(e.path)));
}

/**
 * Deletes runs older than `keepRunsMs`. Each holds full copies of the notes it edited, which
 * otherwise pile up outside the vault and outside whatever sync or retention covers it.
 */
export async function prune(): Promise<void> {
  const now = Date.now();
  for (const id of await readdir(runsDir).catch(() => [])) {
    if (!RUN_ID.test(id)) continue;
    const { mtimeMs } = await stat(join(runsDir, id));
    if (now - mtimeMs > settings.keepRunsMs) await rm(join(runsDir, id), { recursive: true, force: true });
  }
}

/** Whether a run really changed the note. One still running is assumed to. */
async function changed(entry: Entry): Promise<boolean> {
  if (entry.after === undefined) return true;
  const before = entry.backup ? hash(await Bun.file(entry.backup).text()) : null;
  return entry.after !== before;
}

/** The next step when there's no run to undo, said by `undo` and by `undo --last`. */
export const NO_RUN = "Runs are kept for a week; jarvis runs lists them.";

/** `kept`: an undo already ran and kept every note, because each was edited since. */
export type RecentRun = { id: string; at: number; changed: string[]; kept: boolean };

const keptPath = (runId: string) => join(runDir(runId), "kept.json");

/**
 * Runs that can still be undone and really changed a note, newest first. A run still going is
 * left out (it has no end state yet), and so is one already undone (its manifest was renamed).
 */
export async function recentRuns(limit = 10): Promise<RecentRun[]> {
  const found: RecentRun[] = [];
  for (const id of await readdir(runsDir).catch(() => [])) {
    if (!RUN_ID.test(id)) continue;
    const entries = Object.values(await readManifest(id).catch(() => ({}) as Manifest));
    if (entries.length === 0 || entries.some((e) => e.after === undefined)) continue;
    const touched = [];
    for (const entry of entries) if (await changed(entry)) touched.push(entry);
    if (touched.length === 0) continue;
    const at = Math.min(...touched.map((e) => e.at));
    found.push({ id, at, changed: await Promise.all(touched.map((e) => vaultName(e.path))), kept: await exists(keptPath(id)) });
  }
  return found.sort((a, b) => b.at - a.at).slice(0, limit);
}

/**
 * What `undo --last` undoes: the newest run an undo hasn't already kept as is (one that would
 * only say "Kept … as is" again would hide every run behind it), made no later than `before`
 * (the Dock passes the moment you pressed ⌥⌘Z, so an ask that saves after that isn't picked).
 */
export async function lastRun(before = Number.POSITIVE_INFINITY): Promise<string | undefined> {
  return (await recentRuns(Number.POSITIVE_INFINITY)).find((run) => !run.kept && run.at <= before)?.id;
}

const clock = (d: Date) => d.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });

/** "today 15:46", "yesterday 09:12", and for anything older just the date. */
export function relativeWhen(at: number, now = new Date()): string {
  const when = new Date(at);
  const day = localDate(when);
  if (day === localDate(now)) return `today ${clock(when)}`;
  if (day === localDate(new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1))) return `yesterday ${clock(when)}`;
  return day;
}

/** `jarvis runs` for a person: a header, then a row per run, in columns. */
export function formatRuns(runs: RecentRun[], now = new Date()): string {
  const rows: [string, string, string][] = [
    ["Run id", "When", "Changed"],
    ...runs.map(({ id, at, changed, kept }): [string, string, string] => [id, relativeWhen(at, now), `${changed.join(", ")}${kept ? "  (edited since)" : ""}`]),
  ];
  const idWidth = Math.max(...rows.map(([id]) => id.length));
  const whenWidth = Math.max(...rows.map(([, when]) => when.length));
  return rows.map(([id, when, changed]) => `${id.padEnd(idWidth)}  ${when.padEnd(whenWidth)}  ${changed}`).join("\n");
}

/** `jarvis undo` for a person at a terminal. The Dock gets the result as JSON instead. */
export function describeUndo({ restored, skipped }: { restored: string[]; skipped: string[] }): string {
  const lines = [];
  if (restored.length > 0) lines.push(`Put back ${restored.join(", ")}`);
  if (skipped.length > 0) lines.push(`Kept ${skipped.join(", ")} as is: edited since`);
  return lines.join("\n") || "Nothing to undo";
}

/**
 * Notes another run (one not undone) went on to change after this one first edited them. Two
 * asks at once can both edit today's note before either ends, so the hash alone can't tell
 * that one's work sits on top of the other's.
 */
async function editedLater(runId: string, manifest: Manifest): Promise<Set<string>> {
  const others = (await readdir(runsDir).catch(() => [])).filter((id) => id !== runId && RUN_ID.test(id));
  const later = new Set<string>();
  for (const other of others) {
    // A run whose manifest can't be read can't say what it did; it doesn't stop this undo.
    const entries = await readManifest(other).catch(() => ({}) as Manifest);
    for (const [key, entry] of Object.entries(entries)) {
      const mine = manifest[key];
      if (mine && entry.at > mine.at && (await changed(entry))) later.add(key);
    }
  }
  return later;
}

/**
 * Puts each note back the way it was before the run, and removes notes the run created.
 * Notes edited again since the run (by you, Obsidian or another capture) are left alone,
 * because restoring them would throw that newer work away.
 */
export async function undo(runId: string): Promise<{ restored: string[]; skipped: string[] }> {
  const manifest = await readJson<Manifest>(manifestPath(runId));
  if (!manifest) {
    if (await exists(join(runDir(runId), "undone.json"))) throw new Error("Already undone", { cause: "jarvis runs lists what's left to undo." });
    // Run ids are start times (startRun); "Daily" or a note name was never one.
    if (!/^\d{4}-\d{2}-\d{2}T/.test(runId)) throw new Error(`Not a run id: ${runId}`, { cause: NOT_A_RUN });
    throw new Error(`Nothing to undo for ${runId}`, { cause: NO_RUN });
  }
  const later = await editedLater(runId, manifest);
  const restored: string[] = [];
  const skipped: string[] = [];

  for (const [key, entry] of Object.entries(manifest)) {
    const name = await vaultName(entry.path);
    const changed = entry.after !== undefined && (await currentHash(entry.path)) !== entry.after;
    if (changed || later.has(key)) {
      skipped.push(name);
      continue;
    }
    if (entry.backup) await copyFile(entry.backup, entry.path);
    else await rm(entry.path, { force: true });
    restored.push(name);
  }
  // A second undo of the same run finds nothing. One that put nothing back can be tried again by
  // id (after putting your edit back yourself), but `--last` moves on past it.
  if (restored.length > 0) await rename(manifestPath(runId), join(runDir(runId), "undone.json"));
  else if (skipped.length > 0) await Bun.write(keptPath(runId), `${JSON.stringify({ skipped, at: Date.now() })}\n`);
  return { restored, skipped };
}
