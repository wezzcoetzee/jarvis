import { mkdir, readdir, stat } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";
import { configDir, expand, fold, layout, meetingsOff, paths, privateFolders, tilde, vaultChosen } from "./config";
import { findClaude } from "./claude";
import { isFolder, readJson, writeAtomic } from "./files";
import { RECORDING } from "./meetings";

/** Where Obsidian keeps its list of vaults. `JARVIS_OBSIDIAN` points elsewhere, for tests and screenshots. */
const obsidianDir = expand(process.env.JARVIS_OBSIDIAN ?? "~/Library/Application Support/obsidian");

type Vault = { name: string; path: string };

type ObsidianJson = { vaults?: Record<string, { path?: unknown; ts?: number } | null> };

export async function listVaults(dir = obsidianDir): Promise<Vault[]> {
  const known = await readJson<ObsidianJson>(join(dir, "obsidian.json")).catch(() => null);
  const entries = Object.values(known?.vaults ?? {})
    // It's another app's file: skip anything that isn't a vault with a path.
    .filter((entry): entry is { path: string; ts?: number } => typeof entry?.path === "string")
    .sort((a, b) => (b.ts ?? 0) - (a.ts ?? 0));
  const present = await Promise.all(entries.map((entry) => isFolder(entry.path)));
  return entries.filter((_, index) => present[index]).map(({ path }) => ({ name: basename(path), path }));
}

/** For first run and Settings. A vault that moved counts as not ready, so it gets the same help. */
export async function setupStatus(): Promise<{
  /** A vault is chosen, whether or not its folder is there. `configured && !ready` is a vault that went missing, not first run. */
  configured: boolean;
  ready: boolean;
  vault: string;
  vaultLabel: string;
  vaults: Vault[];
  meetings: string | null;
  claude: boolean;
}> {
  return {
    configured: vaultChosen,
    ready: await isFolder(paths.vault),
    vault: paths.vault,
    vaultLabel: tilde(paths.vault),
    vaults: await listVaults(),
    meetings: meetingsOff ? null : layout.meetings,
    claude: findClaude() !== null,
  };
}

const configFile = join(configDir, "config.json");

export const NOT_A_FOLDER = "Choose a folder that exists.";

/** Sets keys in config.json, keeping every other key and the file's permissions. */
async function updateConfig(file: string, changes: Record<string, string | boolean>): Promise<void> {
  const config = { ...(await readJson<Record<string, unknown>>(file)), ...changes };
  // A config may hold a proxy token, so a new one starts private and an existing one keeps its mode.
  const mode = await stat(file).then(
    (found) => found.mode & 0o777,
    () => 0o600,
  );
  await mkdir(dirname(file), { recursive: true });
  await writeAtomic(file, `${JSON.stringify(config, null, 2)}\n`, mode);
}

export async function chooseVault(folder: string, file = configFile): Promise<{ vault: string }> {
  // Absolute, so the CLI finds it again from whatever folder the Dock runs it in.
  const vault = resolve(expand(folder));
  if (!(await isFolder(vault))) throw new Error(`${folder} isn't a folder`, { cause: NOT_A_FOLDER });
  await updateConfig(file, { vault: tilde(vault) });
  return { vault };
}

const PRIVATE = privateFolders.map(fold);
const isPrivate = (folder: string) => PRIVATE.some((root) => fold(folder) === root || fold(folder).startsWith(`${root}/`));

type MeetingFolder = { folder: string; recordings: number };

/**
 * Folders in the vault that already hold call recordings, most first, so first run can offer
 * the call recorder's folder rather than ask for it. Never looks in private or dot-folders, and
 * only a few levels down, so a big cloud vault stays quick.
 */
export async function meetingFolders(vault = paths.vault): Promise<MeetingFolder[]> {
  const found: MeetingFolder[] = [];
  // A vault with thousands of folders shouldn't mean thousands of reads at once.
  let budget = 500;
  const visit = async (folder: string, depth: number): Promise<void> => {
    if (budget-- <= 0) return;
    const entries = await readdir(join(vault, folder), { withFileTypes: true }).catch(() => []);
    const recordings = entries.filter((entry) => entry.isFile() && RECORDING.test(entry.name)).length;
    if (folder && recordings > 0) found.push({ folder, recordings });
    if (depth === 0) return;
    const children = entries
      .filter((entry) => entry.isDirectory() && !entry.name.startsWith("."))
      .map((entry) => (folder ? `${folder}/${entry.name}` : entry.name))
      .filter((child) => !isPrivate(child));
    await Promise.all(children.map((child) => visit(child, depth - 1)));
  };
  await visit("", 3);
  return found.sort((a, b) => b.recordings - a.recordings || a.folder.localeCompare(b.folder));
}

/** Makes `folder` (in the vault, absolute or vault-relative) the meetings folder in config.json. */
export async function chooseMeetings(folder: string, vaultFolder = paths.vault, file = configFile): Promise<{ meetings: string }> {
  const vault = resolve(expand(vaultFolder));
  const path = isAbsolute(expand(folder)) ? expand(folder) : join(vault, folder);
  const meetings = relative(vault, path) || ".";
  if (meetings === ".." || meetings.startsWith("../") || isAbsolute(meetings)) {
    throw new Error(`${folder} isn't in your vault`, { cause: "Choose a folder inside your vault." });
  }
  if (isPrivate(meetings)) throw new Error(`${meetings} is private to Jarvis`);
  if (!(await isFolder(path))) throw new Error(`${folder} isn't a folder`, { cause: NOT_A_FOLDER });
  await updateConfig(file, { meetings });
  return { meetings };
}

export async function turnMeetingsOff(file = configFile): Promise<{ meetings: null }> {
  await updateConfig(file, { meetings: false });
  return { meetings: null };
}
