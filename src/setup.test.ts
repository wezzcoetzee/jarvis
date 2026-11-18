import { expect, test } from "bun:test";
import { mkdir, mkdtemp, stat, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { chooseMeetings, chooseVault, listVaults, meetingFolders, turnMeetingsOff } from "./setup";

const scratch = () => mkdtemp(join(tmpdir(), "jarvis-setup-"));

test("lists Obsidian's vaults newest first, leaving out folders that have gone", async () => {
  const root = await scratch();
  await mkdir(join(root, "Personal"));
  await mkdir(join(root, "Work"));
  await writeFile(
    join(root, "obsidian.json"),
    JSON.stringify({
      vaults: {
        a: { path: join(root, "Work"), ts: 1 },
        b: { path: join(root, "Moved"), ts: 3 },
        c: { path: join(root, "Personal"), ts: 2 },
      },
    }),
  );
  expect(await listVaults(root)).toEqual([
    { name: "Personal", path: join(root, "Personal") },
    { name: "Work", path: join(root, "Work") },
  ]);
});

test("no Obsidian, or an unreadable list, offers no vaults rather than failing", async () => {
  const root = await scratch();
  expect(await listVaults(root)).toEqual([]);
  await writeFile(join(root, "obsidian.json"), "{ not json");
  expect(await listVaults(root)).toEqual([]);
  await writeFile(join(root, "obsidian.json"), JSON.stringify({ vaults: { a: null, b: { ts: 1 }, c: { path: 7 } } }));
  expect(await listVaults(root)).toEqual([]);
});

test("choosing a vault keeps the rest of config.json and its permissions", async () => {
  const root = await scratch();
  const file = join(root, "config.json");
  await writeFile(file, JSON.stringify({ owner: "Robin", proxyToken: "secret" }), { mode: 0o600 });
  await chooseVault(root, file);
  expect(await Bun.file(file).json()).toEqual({ owner: "Robin", proxyToken: "secret", vault: root });
  expect((await stat(file)).mode & 0o777).toBe(0o600);
});

test("a vault under your home folder is written with ~, and a new config starts private", async () => {
  const vault = await mkdtemp(join(homedir(), ".jarvis-setup-test-"));
  const file = join(await scratch(), "new/config.json");
  try {
    await chooseVault(vault, file);
    expect((await Bun.file(file).json()).vault).toBe(`~${vault.slice(homedir().length)}`);
    expect((await stat(file)).mode & 0o777).toBe(0o600);
  } finally {
    await Bun.$`rm -rf ${vault}`.quiet();
  }
});

test("a path that isn't a folder is refused, and config.json is left alone", async () => {
  const root = await scratch();
  const file = join(root, "config.json");
  await writeFile(file, "{}");
  expect(chooseVault(join(root, "nowhere"), file)).rejects.toThrow("isn't a folder");
  expect(await Bun.file(file).text()).toBe("{}");
});

test("offers the vault's folders that hold recordings, most first, never private or dot-folders", async () => {
  const vault = await scratch();
  const recording = (folder: string, name: string) => Bun.write(join(vault, folder, `${name}.md`), "transcript");
  await recording("Calls", "2026-11-02 1430 FaceTime");
  await recording("Calls", "2026-11-03 0915 Zoom");
  await recording("Work/Huddles", "2026-11-04 1000 Slack Huddle");
  await recording("Private/Therapy", "2026-11-05 1100 Zoom");
  await recording(".trash", "2026-11-06 1200 Zoom");
  await recording("Notes", "Shed plan");
  await recording("", "2026-11-07 0900 Zoom");
  expect(await meetingFolders(vault)).toEqual([
    { folder: "Calls", recordings: 2 },
    { folder: "Work/Huddles", recordings: 1 },
  ]);
});

test("choosing the meetings folder writes it vault-relative, and refuses folders outside the vault or private", async () => {
  const vault = await scratch();
  const file = join(await scratch(), "config.json");
  await mkdir(join(vault, "Calls"));
  await mkdir(join(vault, "Private/Calls"), { recursive: true });
  await chooseMeetings(join(vault, "Calls"), vault, file);
  expect(await Bun.file(file).json()).toEqual({ meetings: "Calls" });
  expect(chooseMeetings(tmpdir(), vault, file)).rejects.toThrow("isn't in your vault");
  expect(chooseMeetings("Private/Calls", vault, file)).rejects.toThrow("private");
});

test("a vault folder whose name starts with two dots is still in the vault", async () => {
  const vault = await scratch();
  const file = join(await scratch(), "config.json");
  await mkdir(join(vault, "..calls"));
  expect(await chooseMeetings("..calls", vault, file)).toEqual({ meetings: "..calls" });
});

test("turning meetings off writes false, keeping the rest of config.json", async () => {
  const file = join(await scratch(), "config.json");
  await writeFile(file, JSON.stringify({ vault: "~/Notes", meetings: "Calls" }));
  await turnMeetingsOff(file);
  expect(await Bun.file(file).json()).toEqual({ vault: "~/Notes", meetings: false });
});
