import { rename, rm, stat, writeFile } from "node:fs/promises";

export const isFolder = (path: string): Promise<boolean> =>
  stat(path).then(
    (found) => found.isDirectory(),
    () => false,
  );

export const exists = (path: string): Promise<boolean> =>
  stat(path).then(
    () => true,
    () => false,
  );

export async function readText(path: string): Promise<string | null> {
  const file = Bun.file(path);
  return (await file.exists()) ? file.text() : null;
}

export async function readJson<T>(path: string): Promise<T | null> {
  const file = Bun.file(path);
  return (await file.exists()) ? ((await file.json()) as T) : null;
}

/**
 * Temp file and rename, so nothing ever reads a half-written file. The temp name ends in neither
 * `.md` nor `.json`, so neither Obsidian nor the Dock's prompt queue picks it up. `mode` is set at
 * creation, so the content is never briefly readable with the wrong permissions.
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
