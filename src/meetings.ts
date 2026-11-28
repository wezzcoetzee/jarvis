import { readdir, stat } from "node:fs/promises";
import { basename, join } from "node:path";
import { layout, paths, settings } from "./config";
import { exists } from "./files";
import { type Failures, enqueue, logEvent, saveFailures, saveSeen } from "./state";

// What Did I Say names its notes `YYYY-MM-DD HHMM <Source>.md`. Curated meeting
// notes and their transcripts use `YYYY-MM-DD - Type - Topic.md`, so they never match.
export const RECORDING = /^\d{4}-\d{2}-\d{2} \d{4} .+\.md$/;

export async function listRecordings(): Promise<string[]> {
  const names = await readdir(paths.meetings);
  return names.filter((name) => RECORDING.test(name)).sort();
}

/**
 * What `jarvis process` was given, as a path. A path that exists is used as is; otherwise the
 * argument is a note's name (what the Dock shows), looked up in the meetings folder with or
 * without its `.md`. A path that isn't found comes back unchanged, so the error names it; a bare
 * name that isn't found says where it looked.
 */
export async function findRecording(arg: string, meetings = paths.meetings): Promise<string> {
  if (await exists(arg)) return arg;
  const inMeetings = join(meetings, arg.endsWith(".md") ? arg : `${arg}.md`);
  if (await exists(inMeetings)) return inMeetings;
  if (arg.includes("/")) return arg;
  throw new Error(`No recording called “${arg}” in ${layout.meetings}`, { cause: "Use the name the Dock shows, or the note's path." });
}

/**
 * Queues a recording Claude couldn't draft as a prompt with nothing proposed, so it still shows
 * in the Dock and the person can add todos by hand or skip it. Returns the name it's queued under.
 */
export async function queueUndrafted(file: string): Promise<string> {
  const noteName = basename(file, ".md");
  // `2026-11-03 0915 Zoom` is titled "Zoom"; a name in another shape is its own title.
  const title = noteName.replace(/^\d{4}-\d{2}-\d{2} \d{4} /, "") || noteName;
  await enqueue({ noteName, meetingDate: noteName.slice(0, 10), proposal: { title, followUps: [], decisions: [] }, draftFailed: true });
  return noteName;
}

/** Recordings not yet handled whose file has stopped changing. */
async function settledRecordings(seen: Set<string>): Promise<string[]> {
  const now = Date.now();
  const fresh = (await listRecordings()).filter((name) => !seen.has(name));
  const settled = await Promise.all(
    fresh.map(async (name) => {
      // Gone since the listing (a recorder's temp file, a sync rename): not a reason to stop watching.
      const found = await stat(join(paths.meetings, name)).catch(() => null);
      return found && now - found.mtimeMs >= settings.settleMs ? name : null;
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
