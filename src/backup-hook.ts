// The PreToolUse hook for `jarvis ask`, run as `jarvis hook`. Fails closed: anything it can't check is blocked.
// - Edit and Write: an allowlist. Only `.md` notes inside the vault, outside the private folders,
//   with no dot-folder in the path and not CLAUDE.md or AGENTS.md (agent instructions). A copy is
//   taken before the first edit so the run can be undone.
//   Never a recording in the meetings folder, which the watcher would take for a new meeting.
// - Read, Grep and Glob: inside the vault and out of the private folders. Searches with no path
//   are covered by the `Read(./<private>/**)` deny rules `jarvis ask` passes in settings.
import { lstat, realpath } from "node:fs/promises";
import { basename, dirname, join, relative, resolve } from "node:path";
import { expand, fold, layout, paths, pluginDirs, privateFolders } from "./config";
import { RECORDING } from "./meetings";
import { backUp } from "./runs";

/** Exit code 2 blocks the tool call and shows Claude the reason. */
function block(reason: string): never {
  console.error(reason);
  process.exit(2);
}

/**
 * Resolves `~`, `..` and symlinks (via the nearest existing parent, for files not created yet).
 * A symlink that points nowhere is refused: a write through it would land wherever it points.
 */
async function canonical(path: string): Promise<string> {
  const expanded = expand(path);
  let current = resolve(paths.vault, expanded);
  const tail: string[] = [];
  while (true) {
    try {
      return join(await realpath(current), ...tail.reverse());
    } catch {
      if (await lstat(current).then((s) => s.isSymbolicLink(), () => false)) throw new Error(`${current} is a broken link`);
      if (dirname(current) === current) return resolve(expanded);
      tail.push(basename(current));
      current = dirname(current);
    }
  }
}

/** Runs as `jarvis hook`. Reads the tool call on stdin; exits 0 to allow it, 2 to block it. */
export async function hook(): Promise<void> {
  try {
    const input = await Bun.stdin.json();
    const run = process.env.JARVIS_RUN;
    if (!run) block("Jarvis's hook ran outside a Jarvis run.");

    const raw: string | undefined = input.tool_input?.file_path ?? input.tool_input?.path;
    const isEdit = ["Edit", "Write", "MultiEdit"].includes(input.tool_name);
    // Grep's `glob` and Glob's `pattern`. This is an early refusal, not the safeguard: wildcards
    // like `Pri*/**` get past it. The `Read(./<private>/**)` deny rules are what keep private
    // folders out, by filtering every search's results (tested against such wildcards). Don't
    // expand patterns here to block "anything that could match": every broad search would match.
    const searchPattern: string = `${input.tool_input?.glob ?? ""} ${input.tool_name === "Glob" ? (input.tool_input?.pattern ?? "") : ""}`;
    const names = privateFolders.map((folder) => fold(basename(folder)));
    if (names.some((name) => fold(searchPattern).includes(name))) block("Jarvis stays out of private notes.");
    // Braces and extglobs can hide an absolute or `..` alternative (`{/etc/*,x}`), and vault
    // searches never need them, so refuse them rather than expand them.
    if (/[{}]|[@!+*?]\(/.test(searchPattern)) block("Use plain wildcards (* ** ?) in search patterns.");
    if (/(^|\s)[/~]|(^|[\s/])\.\.(\/|$)/.test(searchPattern)) block("Search patterns stay relative to the vault.");
    if (!raw) {
      if (isEdit) block("No file path to check.");
      process.exit(0); // Searches from the vault root; the private-folder deny rules filter them.
    }

    // realpath returns the on-disk spelling, and the config may spell folders differently.
    // Compare folded, since APFS ignores case and Unicode form.
    const vault = fold(await canonical(paths.vault));
    const target = await canonical(raw);
    const lower = fold(target);
    const privateRoots = privateFolders.map((folder) => fold(join(vault, folder)));
    /** The folder itself counts: a Grep aimed at a private folder is as bad as a Read inside it. */
    const inside = (dir: string) => {
      const root = fold(join(vault, dir));
      return lower === root || lower.startsWith(`${root}/`);
    };

    // Skills from configured plugins may read their own reference files, but never edit them,
    // even when a plugin folder sits inside the vault.
    // A plugin folder that's gone (a broken link) just isn't one; it doesn't block every call.
    const plugins = await Promise.all(pluginDirs.map((dir) => canonical(dir).then(fold, () => null)));
    const inPlugin = plugins.some((dir) => dir !== null && (lower === dir || lower.startsWith(`${dir}/`)));
    if (inPlugin && isEdit) block("Jarvis doesn't edit plugins.");
    if (inPlugin) process.exit(0);
    if (lower !== vault && !lower.startsWith(`${vault}/`)) block("Jarvis stays inside the vault.");
    if (privateFolders.some(inside)) block("Jarvis stays out of private notes.");
    if (!isEdit) {
      // A search over a folder that holds a private folder relies on the deny rules to filter it
      // out, and they compare case exactly. So the path has to be spelled the way it is on disk.
      const covers = lower === vault || privateRoots.some((root) => root.startsWith(`${lower}/`));
      const asGiven = resolve(paths.vault, expand(raw));
      const onDisk = relative(await canonical(paths.vault), target);
      if (covers && relative(resolve(paths.vault), asGiven) !== onDisk) {
        block(`Spell the folder exactly as it is on disk: "${onDisk || "."}".`);
      }
      process.exit(0);
    }

    const segments = relative(vault, lower).split("/");
    if (!lower.endsWith(".md")) block("Jarvis only edits Markdown notes.");
    if (segments.some((s) => s.startsWith("."))) block("Jarvis doesn't edit vault configuration.");
    if (/^(claude|agents)(\.local)?\.md$/.test(segments.at(-1) ?? "")) block("Jarvis doesn't edit agent instructions.");
    if (inside(layout.meetings) && RECORDING.test(basename(target))) block("Jarvis doesn't write recordings.");

    await backUp(run, lower, target);
  } catch (error) {
    block(`Jarvis couldn't check this edit: ${error}`);
  }
}
