import { homedir } from "node:os";
import { join, normalize } from "node:path";
import { z } from "zod";

/** Expands `~` and a leading `~/`, as config paths and Claude's tool paths may use them. */
export const expand = (path: string) =>
  path === "~" ? homedir() : path.startsWith("~/") ? join(homedir(), path.slice(2)) : path;

/** How two spellings of a path are compared: APFS ignores letter case and Unicode form. */
export const fold = (path: string) => path.normalize("NFC").toLowerCase();

/**
 * `config.json` in `~/.config/jarvis/` (or `JARVIS_CONFIG`). Everything is optional; see README
 * "Configure". Keep it mode 600 if it holds a proxy token.
 */
const FileConfig = z
  .object({
    /** The Obsidian vault. `~` is expanded. */
    vault: z.string(),
    /** Your name, as it appears in meeting transcripts and notes. */
    owner: z.string(),
    /** Vault-relative paths of the notes and folders Jarvis reads and writes. */
    daily: z.string(),
    meetings: z.string(),
    workLog: z.string(),
    people: z.string(),
    inbox: z.string(),
    /** Vault-relative folders Jarvis never reads, searches or edits. */
    private: z.array(z.string()),
    /** Claude Code plugin folders to load for `jarvis ask`, for skills that live outside the vault. */
    plugins: z.array(z.string()),
    proxyUrl: z.string(),
    proxyToken: z.string(),
    model: z.string(),
  })
  .partial();

/** The config folder. The Dock reads its own `dock.json` from the same place. */
const configDir = expand(process.env.JARVIS_CONFIG ?? "~/.config/jarvis");

async function loadConfig(): Promise<z.infer<typeof FileConfig>> {
  const file = Bun.file(join(configDir, "config.json"));
  if (!(await file.exists())) return {};
  // Loaded before main.ts's try, so print the CLI's one `error:` line here. Exit 2, which is
  // what blocks a tool call when this runs as the hook.
  const fail = (why: string): never => {
    console.error(`error: ${file.name} ${why}`);
    process.exit(2);
  };
  const parsed = FileConfig.safeParse(await file.json().catch(() => fail("isn't valid JSON")));
  return parsed.success ? parsed.data : fail(`isn't valid: ${z.prettifyError(parsed.error).replace(/\n/g, " ")}`);
}

const fileConfig = await loadConfig();

/** Vault-relative, however it was written: `Meetings`, `./Meetings` and `Meetings/` are one folder. */
const relativePath = (path: string) => normalize(path).replace(/\/$/, "");

/** Vault-relative locations, used in prompts and in what the Dock says it saved. */
export const layout = {
  daily: relativePath(fileConfig.daily ?? "Daily"),
  meetings: relativePath(fileConfig.meetings ?? "Meetings"),
  workLog: relativePath(fileConfig.workLog ?? "Work Log.md"),
  people: relativePath(fileConfig.people ?? "People.md"),
  inbox: relativePath(fileConfig.inbox ?? "Inbox.md"),
};

export const privateFolders = (fileConfig.private ?? ["Private"]).map(relativePath);
export const pluginDirs = (fileConfig.plugins ?? []).map(expand);
export const owner = fileConfig.owner ?? "the vault's owner";

const vault = expand(process.env.JARVIS_VAULT ?? fileConfig.vault ?? "~/Documents/Vault");

export const paths = {
  vault,
  meetings: join(vault, layout.meetings),
  daily: join(vault, layout.daily),
  workLog: join(vault, layout.workLog),
  people: join(vault, layout.people),
  inbox: join(vault, layout.inbox),
  // Raw activity stays on this Mac, outside the vault, so vault searches never see it.
  state: expand(process.env.JARVIS_STATE ?? "~/.local/share/jarvis"),
};

export const proxy =
  fileConfig.proxyUrl && fileConfig.proxyToken ? { url: fileConfig.proxyUrl, token: fileConfig.proxyToken } : null;

export const settings = {
  model: fileConfig.model ?? "sonnet",
  pollMs: 15_000,
  // The recorder writes the note in one go, but a cloud-synced vault can touch it right after.
  settleMs: 20_000,
  // A recording that fails to draft (offline, the API busy) is tried this many times in all,
  // this far apart, before it's given up on.
  draftAttempts: 3,
  retryMs: 5 * 60_000,
  // Undo is for the minutes after an ask. Older runs, and the note copies they hold, are deleted.
  keepRunsMs: 7 * 24 * 60 * 60_000,
};
