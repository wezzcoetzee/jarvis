import { homedir } from "node:os";
import { join } from "node:path";

/**
 * `~/.config/jarvis/config.json`. Everything is optional; see README "Configure". Keep it mode
 * 600 if it holds a proxy token.
 */
type FileConfig = {
  /** The Obsidian vault. `~` is expanded. */
  vault?: string;
  /** Your name, as it appears in meeting transcripts and notes. */
  owner?: string;
  /** Vault-relative paths of the notes and folders Jarvis reads and writes. */
  daily?: string;
  meetings?: string;
  workLog?: string;
  people?: string;
  inbox?: string;
  /** Vault-relative folders Jarvis never reads, searches or edits. */
  private?: string[];
  /** Claude Code plugin folders to load for `jarvis ask`, for skills that live outside the vault. */
  plugins?: string[];
  proxyUrl?: string;
  proxyToken?: string;
  model?: string;
};

const configFile = Bun.file(join(homedir(), ".config/jarvis/config.json"));
const fileConfig: FileConfig = (await configFile.exists()) ? await configFile.json() : {};
const expand = (path: string) => (path.startsWith("~/") ? join(homedir(), path.slice(2)) : path);

/** Vault-relative locations, used in prompts and in what the Dock says it saved. */
export const layout = {
  daily: fileConfig.daily ?? "Daily",
  meetings: fileConfig.meetings ?? "Meetings",
  workLog: fileConfig.workLog ?? "Work Log.md",
  people: fileConfig.people ?? "People.md",
  inbox: fileConfig.inbox ?? "Inbox.md",
};

export const privateFolders = fileConfig.private ?? ["Private"];
export const pluginDirs = (fileConfig.plugins ?? []).map(expand);
export const owner = fileConfig.owner ?? "the vault's owner";

const vault = process.env.JARVIS_VAULT ?? expand(fileConfig.vault ?? "~/Documents/Vault");

export const paths = {
  vault,
  meetings: join(vault, layout.meetings),
  daily: join(vault, layout.daily),
  workLog: join(vault, layout.workLog),
  people: join(vault, layout.people),
  inbox: join(vault, layout.inbox),
  // Raw activity stays on this Mac, outside the vault, so vault searches never see it.
  state: process.env.JARVIS_STATE ?? join(homedir(), ".local/share/jarvis"),
};

export const proxy =
  fileConfig.proxyUrl && fileConfig.proxyToken ? { url: fileConfig.proxyUrl, token: fileConfig.proxyToken } : null;

export const settings = {
  model: fileConfig.model ?? "sonnet",
  pollMs: 15_000,
  // The recorder writes the note in one go, but a cloud-synced vault can touch it right after.
  settleMs: 20_000,
};
