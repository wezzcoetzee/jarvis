import { readdir, stat } from "node:fs/promises";
import { join } from "node:path";
import { paths, settings } from "./config";

// What Did I Say names its notes `YYYY-MM-DD HHMM <Source>.md`. Curated meeting
// notes and their transcripts use `YYYY-MM-DD - Type - Topic.md`, so they never match.
const RECORDING = /^\d{4}-\d{2}-\d{2} \d{4} .+\.md$/;

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
