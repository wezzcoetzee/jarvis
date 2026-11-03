import { readdir, stat } from "node:fs/promises";
import { join } from "node:path";
import { paths, settings } from "./config";
import { type Failures, logEvent, saveFailures, saveSeen } from "./state";

// What Did I Say names its notes `YYYY-MM-DD HHMM <Source>.md`. Curated meeting
// notes and their transcripts use `YYYY-MM-DD - Type - Topic.md`, so they never match.
export const RECORDING = /^\d{4}-\d{2}-\d{2} \d{4} .+\.md$/;

export async function listRecordings(): Promise<string[]> {
  const names = await readdir(paths.meetings);
  return names.filter((name) => RECORDING.test(name)).sort();
}

/** Recordings not yet handled whose file has stopped changing. */
export async function settledRecordings(seen: Set<string>): Promise<string[]> {
  const now = Date.now();
  const fresh = (await listRecordings()).filter((name) => !seen.has(name));
  const settled = await Promise.all(
    fresh.map(async (name) => {
      const { mtimeMs } = await stat(join(paths.meetings, name));
      return now - mtimeMs >= settings.settleMs ? name : null;
    }),
  );
  return settled.filter((name) => name !== null);
}

/**
 * Drafts each new recording once it has settled, and marks it seen. One that fails is left
 * unseen and tried again `retryMs` later, until `draftAttempts` tries have failed; then
 * `gaveUp` hears about it and it's marked seen, so a note that can never be drafted doesn't
 * call Claude forever.
 */
export async function draftSettled(
  seen: Set<string>,
  failures: Failures,
  draft: (name: string) => Promise<void>,
  gaveUp: (name: string) => Promise<void>,
  now = Date.now(),
): Promise<void> {
  for (const name of await settledRecordings(seen)) {
    const failed = failures[name];
    if (failed && now - failed.at < settings.retryMs) continue;
    try {
      await draft(name);
    } catch (error) {
      const attempts = (failed?.attempts ?? 0) + 1;
      await logEvent({ type: "error", note: name, attempts, error: String(error) });
      if (attempts < settings.draftAttempts) {
        failures[name] = { attempts, at: now };
        await saveFailures(failures);
        continue;
      }
      await gaveUp(name);
    }
    if (failures[name]) {
      delete failures[name];
      await saveFailures(failures);
    }
    seen.add(name);
    await saveSeen(seen);
  }
}
