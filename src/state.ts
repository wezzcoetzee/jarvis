import { appendFile, mkdir, rename, rm } from "node:fs/promises";
import { join } from "node:path";
import { paths } from "./config";
import type { Proposal } from "./extract";

const seenPath = join(paths.state, "seen.json");
const eventsPath = join(paths.state, "events.jsonl");
// The Dock watches this folder and shows one prompt per file.
const pendingDir = join(paths.state, "pending");

/** Notes already handled, or null on first run. */
export async function loadSeen(): Promise<Set<string> | null> {
  const file = Bun.file(seenPath);
  return (await file.exists()) ? new Set<string>(await file.json()) : null;
}

export async function saveSeen(seen: Set<string>): Promise<void> {
  await Bun.write(seenPath, JSON.stringify([...seen].sort(), null, 2));
}

/** Append-only raw log. The source for tuning which prompts get skipped. */
export async function logEvent(event: { type: string } & Record<string, unknown>): Promise<void> {
  await mkdir(paths.state, { recursive: true });
  await appendFile(eventsPath, `${JSON.stringify({ at: new Date().toISOString(), ...event })}\n`);
}

export type Pending = { noteName: string; meetingDate: string; proposal: Proposal };

const pendingPath = (noteName: string) => join(pendingDir, `${noteName}.json`);

/** Written to a temp file and renamed, so the Dock never reads a half-written prompt. */
export async function enqueue(pending: Pending): Promise<void> {
  await mkdir(pendingDir, { recursive: true });
  const path = pendingPath(pending.noteName);
  await Bun.write(`${path}.tmp`, JSON.stringify(pending, null, 2));
  await rename(`${path}.tmp`, path);
}

export async function readPending(noteName: string): Promise<Pending | null> {
  const file = Bun.file(pendingPath(noteName));
  return (await file.exists()) ? file.json() : null;
}

export async function removePending(noteName: string): Promise<void> {
  await rm(pendingPath(noteName), { force: true });
}
