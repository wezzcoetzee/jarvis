/**
 * What `capture`, `resolve`, `process` and `undo` print. The Dock pipes stdout and parses JSON, so
 * piped output stays JSON (or empty); a person at a terminal gets a sentence.
 */
import type { ask } from "./ask";

type AskResult = Awaited<ReturnType<typeof ask>>;

/** The run just made is the newest, so `--last` undoes it. */
const UNDO = "Undo: jarvis undo --last";

export const describeCapture = (savedTo: string | null) => (savedTo ? `Added to ${savedTo}. ${UNDO}` : "Nothing added");

export const describeSave = (savedTo: string[]) => (savedTo.length > 0 ? `Saved to ${savedTo.join(", ")}. ${UNDO}` : "Nothing to save");

export const describeSkip = (noteName: string) => `Skipped ${noteName}`;

export const describeQueued = (title: string) => `Queued “${title}”: review it in the Dock`;

/** The answer, then what it found or changed: the headline, its detail, the notes a find turned up, and the undo for a save. */
export const describeAsk = ({ kind, message, detail, notes }: Pick<AskResult, "kind" | "message" | "detail" | "notes">) =>
  [message, detail, kind === "found" ? notes.map(({ title, path }) => `${title} (${path})`).join("\n") : "", kind === "saved" ? UNDO : ""]
    .filter(Boolean)
    .join("\n");

/** JSON when piped, `sentence` at a terminal. */
export const print = (json: unknown, sentence: string) => console.log(process.stdout.isTTY ? sentence : JSON.stringify(json));
