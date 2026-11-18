/** What a few system failures mean, said the way the Dock's failure bubble says things. */
const PLAIN: Record<string, string> = {
  ENOENT: "Couldn't find a file Jarvis needed",
  EACCES: "macOS didn't let Jarvis open a file",
  EPERM: "macOS didn't let Jarvis open a file",
  ENOSPC: "Your disk is full",
};

/**
 * The `error:` and `detail:` lines the Dock shows for a failure. Errors Jarvis throws itself
 * are already plain sentences and pass through. Anything else (a system error with a code, a
 * TypeError, a thrown string) gets a plain headline, with its own words kept as the detail.
 */
export function explain(error: unknown): { message: string; detail?: string } {
  const raw = error instanceof Error ? error.message : String(error);
  const cause = error instanceof Error && error.cause !== undefined ? String(error.cause) : undefined;
  const code = error instanceof Error && "code" in error && typeof error.code === "string" ? error.code : undefined;
  if (error instanceof Error && error.constructor === Error && code === undefined) return { message: raw, detail: cause };
  const message = (code && PLAIN[code]) ?? "Something went wrong with that";
  return { message, detail: [raw, cause].filter(Boolean).join(". ") };
}
