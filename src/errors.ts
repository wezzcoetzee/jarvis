import { basename } from "node:path";

/** What a few system failures mean, said the way the Dock's failure bubble says things. `file` names the one involved, when the error knows. */
const PLAIN: Record<string, (file?: string) => string> = {
  ENOENT: (file) => (file ? `Couldn't find ${file}` : "Couldn't find a file Jarvis needed"),
  EACCES: (file) => `macOS didn't let Jarvis open ${file ?? "a file"}`,
  EPERM: (file) => `macOS didn't let Jarvis open ${file ?? "a file"}`,
  ENOSPC: () => "Your disk is full",
  // Reading a folder as a note, or a path through a file.
  EISDIR: (file) => `${file ?? "That"} isn't a note`,
  ENOTDIR: (file) => `${file ?? "That"} isn't a note`,
};

/** What to do about each of those, in place of the system's own wording. */
const NEXT_STEP: Record<string, string> = {
  ENOENT: "Check the path, then try again.",
  EACCES: "Check the file's permissions, then try again.",
  EPERM: "Check the file's permissions, then try again.",
  ENOSPC: "Free some space, then try again.",
  EISDIR: "Choose a .md file.",
  ENOTDIR: "Choose a .md file.",
};

/**
 * A detail reads as a sentence, so it ends with a full stop. A `Usage:` line is the exception:
 * it's meant to be copied into a terminal.
 */
const sentence = (text: string | undefined) => (!text || /^Usage: |[.!?]$/.test(text) ? text : `${text}.`);

/**
 * The `error:` and `detail:` lines the Dock shows for a failure. Errors Jarvis throws itself
 * are already plain sentences and pass through. A system error with a code gets a plain headline
 * and a next step (or its cause, if it has one). Anything else (a TypeError, a thrown string) gets
 * a plain headline, with its own words kept as the detail.
 */
export function explain(error: unknown): { message: string; detail?: string } {
  const raw = error instanceof Error ? error.message : String(error);
  const cause = error instanceof Error && error.cause !== undefined ? String(error.cause) : undefined;
  const code = error instanceof Error && "code" in error && typeof error.code === "string" ? error.code : undefined;
  if (error instanceof Error && error.constructor === Error && code === undefined) return { message: raw, detail: sentence(cause) };
  const file = error instanceof Error && "path" in error && typeof error.path === "string" ? basename(error.path) : undefined;
  const plain = code ? PLAIN[code] : undefined;
  if (code && plain) return { message: plain(file), detail: sentence(cause ?? NEXT_STEP[code]) };
  return { message: "Something went wrong with that", detail: sentence([raw, cause].filter(Boolean).join(". ")) };
}
