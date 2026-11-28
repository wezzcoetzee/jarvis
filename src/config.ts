import { homedir } from "node:os";
import { join, normalize } from "node:path";
import { z } from "zod";

/** Expands `~` and a leading `~/`, as config paths and Claude's tool paths may use them. */
export const expand = (path: string) =>
  path === "~" ? homedir() : path.startsWith("~/") ? join(homedir(), path.slice(2)) : path;

/** The inverse of `expand`, for paths shown to people: `/Users/me/Vault` reads as `~/Vault`. */
export const tilde = (path: string) => (path.startsWith(`${homedir()}/`) ? `~${path.slice(homedir().length)}` : path);

/** How two spellings of a path are compared: APFS ignores letter case and Unicode form. */
export const fold = (path: string) => path.normalize("NFC").toLowerCase();

/**
 * `config.json` in `~/.config/jarvis/` (or `JARVIS_CONFIG`). Everything is optional; see README
 * "Configure". Keep it mode 600 if it holds a proxy token.
 */
const FileConfig = z
  .object({
    vault: z.string(),
    /** Your name, as it appears in meeting transcripts and notes. */
    owner: z.string(),
    /** Vault-relative paths of the notes and folders Jarvis reads and writes. */
    daily: z.string(),
    /** `false` turns meetings off, whatever folders exist. */
    meetings: z.union([z.string(), z.literal(false)]),
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

/** What a value should have been, in the words someone editing config.json would use. */
const EXPECTED: Record<string, string> = { string: "text", boolean: "true or false", array: "a list", number: "a number", object: "a JSON object" };

/** The types an issue would have accepted. A union (`meetings`: text or false) lists every branch. */
function accepted(issue: z.core.$ZodIssue): string[] {
  if (issue.code === "invalid_type") return [EXPECTED[issue.expected] ?? issue.expected];
  if (issue.code === "invalid_value") return issue.values.map(String);
  if (issue.code === "invalid_union") return issue.errors.flat().flatMap(accepted);
  return [];
}

/** `"vault" should be text`, one per problem, for people who never met zod. */
export function plainIssues(error: z.ZodError): string {
  return error.issues
    .map((issue) => {
      // A list entry reads as `"private" item 2`; the file itself has no name.
      const name = issue.path.map((key, i) => (typeof key === "number" ? ` item ${key + 1}` : `${i > 0 ? "." : ""}"${String(key)}"`)).join("") || "the file";
      const types = accepted(issue);
      return types.length > 0 ? `${name} should be ${[...new Set(types)].join(" or ")}` : `${name} isn't valid`;
    })
    .join("; ");
}

/** The config folder. The Dock reads its own `dock.json` from the same place. */
export const configDir = expand(process.env.JARVIS_CONFIG ?? "~/.config/jarvis");

async function loadConfig(): Promise<z.infer<typeof FileConfig>> {
  const file = Bun.file(join(configDir, "config.json"));
  if (!(await file.exists())) return {};
  // Loaded before main.ts's try, so print the CLI's `error:` and `detail:` lines here. Exit 2,
  // which is what blocks a tool call when this runs as the hook.
  const fail = (why: string, next: string): never => {
    console.error(`error: ${tilde(file.name ?? "config.json")} ${why}`);
    console.error(`detail: ${next}`);
    process.exit(2);
  };
  const parsed = FileConfig.safeParse(await file.json().catch(() => fail("isn't valid JSON", "Fix it in a text editor, then try again.")));
  return parsed.success
    ? parsed.data
    : fail(`isn't valid: ${plainIssues(parsed.error)}`, "Fix that key in config.json, or delete it to use the default.");
}

const fileConfig = await loadConfig();

/** Vault-relative, however it was written: `Meetings`, `./Meetings` and `Meetings/` are one folder. */
const relativePath = (path: string) => normalize(path).replace(/\/$/, "");

/** Vault-relative locations, used in prompts and in what the Dock says it saved. */
export const layout = {
  daily: relativePath(fileConfig.daily ?? "Daily"),
  meetings: relativePath(typeof fileConfig.meetings === "string" ? fileConfig.meetings : "Meetings"),
  workLog: relativePath(fileConfig.workLog ?? "Work Log.md"),
  people: relativePath(fileConfig.people ?? "People.md"),
  inbox: relativePath(fileConfig.inbox ?? "Inbox.md"),
};

/** Meetings turned off in Settings: the watcher drafts nothing until they're turned back on. */
export const meetingsOff = fileConfig.meetings === false;

export const privateFolders = (fileConfig.private ?? ["Private"]).map(relativePath);
export const pluginDirs = (fileConfig.plugins ?? []).map(expand);
export const owner = fileConfig.owner ?? "the vault's owner";

// `||`, not `??`: an empty `JARVIS_VAULT=` or `"vault": ""` means unset, not a vault with no name.
const chosenVault = process.env.JARVIS_VAULT || fileConfig.vault;
const vault = expand(chosenVault || "~/Documents/Vault");

/** Whether a vault was chosen (env or config), as opposed to the fallback path. The folder may not exist. */
export const vaultChosen = Boolean(chosenVault);

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
  // `jarvis hook` blocks the tool call once it has spent this long checking (a cloud vault stalled
  // on a macOS prompt), rather than run into Claude Code's timeout, which lets the call through.
  // Tests shorten it.
  hookDeadlineMs: Number(process.env.JARVIS_HOOK_DEADLINE_MS) || 20_000,
};
