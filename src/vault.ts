import { rename } from "node:fs/promises";
import { join } from "node:path";
import { layout, paths } from "./config";

const PLACEHOLDER = "_(nothing yet)_";

function sectionBounds(lines: string[], heading: string): [number, number] | null {
  const start = lines.findIndex((l) => l.trim() === heading);
  if (start === -1) return null;
  const next = lines.findIndex((l, i) => i > start && l.startsWith("## "));
  return [start, next === -1 ? lines.length : next];
}

export function section(doc: string, heading: string): string {
  const lines = doc.split("\n");
  const bounds = sectionBounds(lines, heading);
  return bounds ? lines.slice(bounds[0] + 1, bounds[1]).join("\n").trim() : "";
}

/**
 * Adds lines to a `## Heading` section, either straight under the heading or after
 * its last non-blank line. Drops the vault's `_(nothing yet)_` placeholder.
 */
export function insertInSection(
  doc: string,
  heading: string,
  added: string[],
  where: "start" | "end",
): string | null {
  const lines = doc.split("\n");
  const bounds = sectionBounds(lines, heading);
  if (!bounds) return null;
  const [start, end] = bounds;

  const body = lines.slice(start + 1, end).filter((l) => l.trim() !== PLACEHOLDER);
  let at = 0;
  if (where === "end") {
    at = body.findLastIndex((l) => l.trim() !== "") + 1;
    if (at === 0 && body[0] === "") at = 1;
  }
  body.splice(at, 0, ...added);
  return [...lines.slice(0, start + 1), ...body, ...lines.slice(end)].join("\n");
}

async function readOrNull(path: string): Promise<string | null> {
  const file = Bun.file(path);
  return (await file.exists()) ? file.text() : null;
}

export const dailyPath = (date: string) => join(paths.daily, `${date}.md`);
export const readDaily = (date: string) => readOrNull(dailyPath(date));

/** A planned edit. Plan everything first, then commit, so a failure never leaves half a capture. */
export type Write = { path: string; label: string; content: string };

type TodoOptions = { today: string; link?: string; inboxOnly?: boolean };

/** Todos land in today's Daily `## Todo`, or Inbox.md when day-start hasn't run yet. */
export async function planTodos(todos: string[], { today, link, inboxOnly = false }: TodoOptions): Promise<Write | null> {
  if (todos.length === 0) return null;

  const daily = inboxOnly ? null : await readDaily(today);
  const updated =
    daily && insertInSection(daily, "## Todo", todos.map((t) => `- [ ] ${t}${link ? ` (${link})` : ""}`), "end");
  if (updated) return { path: dailyPath(today), label: `${layout.daily}/${today}.md`, content: updated };

  const inbox = (await readOrNull(paths.inbox)) ?? "# Inbox\n\n## Items\n";
  const lines = todos.map((t) => `- ${today} — ${t}${/[.!?]$/.test(t) ? "" : "."}${link ? ` ${link}` : ""}`);
  const content = insertInSection(inbox, "## Items", lines, "end") ?? `${inbox}\n${lines.join("\n")}\n`;
  return { path: paths.inbox, label: layout.inbox, content };
}

/** Decisions go on top of the Work Log, newest first, as `- date · #decision · text · [[note]]`. */
export async function planDecisions(decisions: string[], meetingDate: string, noteName: string): Promise<Write | null> {
  if (decisions.length === 0) return null;
  const log = await readOrNull(paths.workLog);
  const lines = decisions.map((d) => `- ${meetingDate} · #decision · ${d} · [[${noteName}]]`);
  const updated = log && insertInSection(log, "## Entries", lines, "start");
  if (!updated) throw new Error(`${layout.workLog} has no \`## Entries\` section`);
  return { path: paths.workLog, label: layout.workLog, content: updated };
}

/** Writes each file via a temp file and rename, so Obsidian or a skill never reads a half-written note. */
export async function commit(writes: (Write | null)[]): Promise<string[]> {
  const planned = writes.filter((w) => w !== null);
  for (const { path, content } of planned) {
    await Bun.write(`${path}.jarvis-tmp`, content);
    await rename(`${path}.jarvis-tmp`, path);
  }
  return planned.map((w) => w.label);
}
