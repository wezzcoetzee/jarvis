import { rename } from "node:fs/promises";

/** A file's text, or null when there's no such file. */
export async function readText(path: string): Promise<string | null> {
  const file = Bun.file(path);
  return (await file.exists()) ? file.text() : null;
}

/** A JSON file's contents, or null when there's no such file. */
export async function readJson<T>(path: string): Promise<T | null> {
  const file = Bun.file(path);
  return (await file.exists()) ? ((await file.json()) as T) : null;
}

/**
 * Writes via a temp file and rename, so nothing (Obsidian, a skill, the Dock, the next watch)
 * ever reads a half-written file. The temp name ends in neither `.md` nor `.json`, so neither
 * Obsidian nor the Dock's prompt queue picks it up.
 */
export async function writeAtomic(path: string, content: string): Promise<void> {
  await Bun.write(`${path}.jarvis-tmp`, content);
  await rename(`${path}.jarvis-tmp`, path);
}
