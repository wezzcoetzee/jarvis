import { stat } from "node:fs/promises";
import { basename, join } from "node:path";
import { paths, privateFolders } from "./config";

export type Hit = { path: string; title: string; snippet: string };

// The Dock is on screen during screen shares, so private folders never show up in it.
const EXCLUDED = privateFolders.map((folder) => `${folder}/`);
const SNIPPET = 90;

/**
 * Cloud-synced vaults (OneDrive, iCloud Drive, Dropbox) leave older notes as cloud-only
 * placeholders: a size but no allocated blocks. Reading one forces a download that can take
 * seconds, so those notes are matched on their name only.
 */
async function readIfLocal(file: string): Promise<string | null> {
  const { size, blocks } = await stat(file);
  return size > 0 && blocks === 0 ? null : Bun.file(file).text();
}

/** Every term must appear in the note; a filename match ranks above a body match. */
export async function search(query: string, limit = 5): Promise<Hit[]> {
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean);
  if (terms.length === 0) return [];

  const scored: (Hit & { score: number })[] = [];
  // Glob skips dot folders (.obsidian, .claude) by default.
  for await (const path of new Bun.Glob("**/*.md").scan({ cwd: paths.vault })) {
    if (EXCLUDED.some((prefix) => path.startsWith(prefix))) continue;
    const title = basename(path, ".md");
    const name = title.toLowerCase();
    // Sync can move or lock a note mid-scan; one bad note shouldn't sink the search.
    const text = (await readIfLocal(join(paths.vault, path)).catch(() => null)) ?? "";
    const lower = text.toLowerCase();
    if (!terms.every((t) => name.includes(t) || lower.includes(t))) continue;

    const score = terms.reduce((sum, t) => sum + (name.includes(t) ? 3 : 1), 0);
    const line = text.split("\n").find((l) => terms.some((t) => l.toLowerCase().includes(t))) ?? "";
    scored.push({ path, title, snippet: line.trim().slice(0, SNIPPET), score });
  }

  return scored
    .sort((a, b) => b.score - a.score || b.title.localeCompare(a.title))
    .slice(0, limit)
    .map(({ score: _, ...hit }) => hit);
}
