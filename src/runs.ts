import { createHash } from "node:crypto";
import { copyFile, realpath, rename, rm } from "node:fs/promises";
import { join, relative } from "node:path";
import { paths } from "./config";

/** One note a run touched. `after` is the note's hash when the run ended (null: deleted). */
export type Entry = { path: string; backup: string | null; after?: string | null };
type Manifest = Record<string, Entry>;

export const runDir = (runId: string) => {
  if (!/^[\w-]+$/.test(runId)) throw new Error(`Not a run id: ${runId}`);
  return join(paths.state, "runs", runId);
};

const manifestFile = (runId: string) => Bun.file(join(runDir(runId), "manifest.json"));
// Entries hold real paths (the hook resolves symlinks), so name them relative to the real vault.
const vaultName = async (path: string) => relative(await realpath(paths.vault), path);
const hash = (text: string) => createHash("sha256").update(text).digest("hex");

async function currentHash(path: string): Promise<string | null> {
  const file = Bun.file(path);
  return (await file.exists()) ? hash(await file.text()) : null;
}

export async function readManifest(runId: string): Promise<Manifest> {
  const file = manifestFile(runId);
  return (await file.exists()) ? file.json() : {};
}

/** Records how each note looked when the run ended, so undo can tell if it changed since. */
export async function seal(runId: string): Promise<string[]> {
  const manifest = await readManifest(runId);
  for (const entry of Object.values(manifest)) entry.after = await currentHash(entry.path);
  if (Object.keys(manifest).length > 0) await Bun.write(manifestFile(runId), JSON.stringify(manifest, null, 2));
  return Promise.all(Object.values(manifest).map((e) => vaultName(e.path)));
}

/**
 * Puts each note back the way it was before the run, and removes notes the run created.
 * Notes edited again since the run (by you, Obsidian or another capture) are left alone,
 * because restoring them would throw that newer work away.
 */
export async function undo(runId: string): Promise<{ restored: string[]; skipped: string[] }> {
  const file = manifestFile(runId);
  if (!(await file.exists())) throw new Error(`Nothing to undo for ${runId}`);
  const restored: string[] = [];
  const skipped: string[] = [];

  for (const entry of Object.values((await file.json()) as Manifest)) {
    const name = await vaultName(entry.path);
    if (entry.after !== undefined && (await currentHash(entry.path)) !== entry.after) {
      skipped.push(name);
      continue;
    }
    if (entry.backup) await copyFile(entry.backup, entry.path);
    else await rm(entry.path, { force: true });
    restored.push(name);
  }
  // A second undo of the same run finds nothing.
  await rename(join(runDir(runId), "manifest.json"), join(runDir(runId), "undone.json"));
  return { restored, skipped };
}
