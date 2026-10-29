import type { Proposal } from "./extract";

export type Capture = { todos: string[]; decisions: string[] };

const DECISION = "decision:";
const TRACKED = "# already on your list:";

/** The editable text shown in the prompt. One line per item; delete a line to drop it. */
export function draft({ followUps, decisions }: Proposal): string {
  return [
    ...followUps.filter((f) => !f.alreadyTracked).map((f) => `[ ] ${f.task}`),
    ...decisions.map((d) => `${DECISION} ${d}`),
    ...followUps.filter((f) => f.alreadyTracked).map((f) => `${TRACKED} ${f.task}`),
  ].join("\n");
}

export function parseDraft(text: string): Capture {
  const capture: Capture = { todos: [], decisions: [] };
  for (const raw of text.split(/\r\n|\r|\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    if (line.toLowerCase().startsWith(DECISION)) {
      capture.decisions.push(line.slice(DECISION.length).trim());
    } else {
      capture.todos.push(line.replace(/^(-\s*)?(\[ \]\s*)?/, ""));
    }
  }
  return capture;
}

export async function notify(message: string): Promise<void> {
  await Bun.spawn([
    "osascript", "-e", "on run argv", "-e", 'display notification (item 1 of argv) with title "Jarvis"', "-e", "end run",
    message,
  ]).exited;
}
