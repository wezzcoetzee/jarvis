import { rename, rm, stat, writeFile } from "node:fs/promises";

/** Whether `path` is a folder that exists. Never throws. */
export const isFolder = (path: string): Promise<boolean> =>
  stat(path).then(
    (found) => found.isDirectory(),
    () => false,
  );

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
 * Obsidian nor the Dock's prompt queue picks it up. With `mode`, the temp file is created with it,
 * so the content is never readable with the wrong permissions, not even for a moment.
 */
export async function writeAtomic(path: string, content: string, mode?: number): Promise<void> {
  const temp = `${path}.jarvis-tmp`;
  if (mode === undefined) {
    await Bun.write(temp, content);
  } else {
    // A mode only applies when the file is created, so a temp file left by a crash goes first.
    await rm(temp, { force: true });
    await writeFile(temp, content, { mode });
  }
  await rename(temp, path);
}
