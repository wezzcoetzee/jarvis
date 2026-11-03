import { createHash } from "node:crypto";
import { copyFile, mkdir, readdir, realpath, rename, rm, stat } from "node:fs/promises";
import { join, relative } from "node:path";
import { paths, settings } from "./config";
import { readJson, readText, writeAtomic } from "./files";

/**
 * One note a run touched. `at` is when the run first went to edit it, `after` its hash when the
 * run ended (null: deleted).
 */
export type Entry = { path: string; backup: string | null; at: number; after?: string | null };
/** Keyed by the note's folded path, so two spellings of one note are one entry. */
type Manifest = Record<string, Entry>;

const runsDir = join(paths.state, "runs");

const RUN_ID = /^[\w-]+$/;

export const runDir = (runId: string) => {
  if (!RUN_ID.test(runId)) throw new Error(`Not a run id: ${runId}`);
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
  const backup = (await Bun.file(path).exists()) ? join(dir, `${Object.keys(manifest).length}.md`) : null;
  if (backup) await copyFile(path, backup);
  manifest[key] = { path, backup, at: Date.now() };
  await writeManifest(runId, manifest);
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
export async function prune(now = Date.now()): Promise<void> {
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
  if (!manifest) throw new Error(`Nothing to undo for ${runId}`);
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
  // A second undo of the same run finds nothing. One that put nothing back can be tried again.
  if (restored.length > 0) await rename(manifestPath(runId), join(runDir(runId), "undone.json"));
  return { restored, skipped };
}
