import { expect, test } from "bun:test";
import { appendFile, chmod } from "node:fs/promises";
import { basename, join } from "node:path";
import pkg from "../package.json";
import { paths } from "./config";
import { enqueue } from "./state";
import { localDate } from "./vault";

/** Starts the real CLI against the test vault, as the Dock does. `input` is what the Dock pipes to stdin. */
function start(args: string[], env: Record<string, string> = {}, input?: string) {
  return Bun.spawn([process.execPath, join(import.meta.dir, "main.ts"), ...args], {
    // bun test runs in UTC without putting TZ in process.env; pass it on so "today" matches.
    env: { TZ: Intl.DateTimeFormat().resolvedOptions().timeZone, ...process.env, ...env },
    stdin: input === undefined ? undefined : new Response(input),
    stdout: "pipe",
    stderr: "pipe",
  });
}

async function jarvis(args: string[], env: Record<string, string> = {}, input?: string) {
  const proc = start(args, env, input);
  const [code, stdout, stderr] = await Promise.all([proc.exited, new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
  return { code, stdout: stdout.trim(), stderr: stderr.trim() };
}

/**
 * A vault with an Inbox, state and HOME of its own, and a stand-in `claude` first on PATH that
 * only records that it started and then waits. The real one is never reachable from here.
 */
async function sandbox(name: string) {
  const root = join(paths.state, name);
  const inbox = join(root, "vault/Inbox.md");
  const claude = join(root, "bin/claude");
  const started = join(root, "claude-started");
  await Bun.write(inbox, "# Inbox\n\n## Items\n");
  await Bun.write(claude, `#!/bin/sh\ntouch "${started}"\nexec sleep 30\n`);
  await chmod(claude, 0o755);
  const env = { JARVIS_VAULT: join(root, "vault"), JARVIS_STATE: join(root, "state"), HOME: root, PATH: `${join(root, "bin")}:/usr/bin:/bin` };
  return { root, inbox, started, env };
}

const INBOX = join(paths.vault, "Inbox.md");

test("help goes to stdout and succeeds, bare or asked for; a typo is one error with a pointer", async () => {
  const bare = await jarvis([]);
  expect(bare).toMatchObject({ code: 0, stderr: "" });
  expect(bare.stdout).toContain("jarvis capture [--inbox] [--] <text>");
  for (const word of ["help", "--help", "-h"]) expect((await jarvis([word])).stdout).toBe(bare.stdout);

  expect(await jarvis(["bogus"])).toEqual({ code: 1, stdout: "", stderr: 'error: Unknown command "bogus"\ndetail: Run jarvis help for the list.' });
  // Help fits a normal terminal.
  expect(Math.max(...bare.stdout.split("\n").map((line) => line.length))).toBeLessThanOrEqual(100);
});

test("help <command> prints that command's usage; an unknown word is the unknown-command error", async () => {
  const asked = await jarvis(["capture", "--help"]);
  expect(await jarvis(["help", "capture"])).toEqual({ code: 0, stdout: asked.stdout, stderr: "" });
  expect((await jarvis(["help", "undo"])).stdout).toContain("--last");
  expect(await jarvis(["help", "capture", "extra"])).toEqual({ code: 1, stdout: "", stderr: "error: help takes one command\ndetail: Usage: jarvis help <command>" });
  expect(await jarvis(["version", "extra"])).toEqual({ code: 1, stdout: "", stderr: "error: version takes no arguments\ndetail: Usage: jarvis --version" });
  expect((await jarvis([""])).stdout).toStartWith("Usage: jarvis");
  expect(await jarvis(["help", "bogus"])).toEqual({ code: 1, stdout: "", stderr: 'error: Unknown command "bogus"\ndetail: Run jarvis help for the list.' });
});

test("--help or -h after a command prints that command's usage and runs nothing; a flag-like word is never text", async () => {
  const usage = "Usage: jarvis capture [--inbox] [--] <text>";
  for (const word of ["--help", "-h"]) {
    const help = await jarvis(["capture", word]);
    expect(help).toMatchObject({ code: 0, stderr: "" });
    expect(help.stdout.startsWith(usage)).toBe(true);
  }
  await Bun.write(INBOX, "# Inbox\n\n## Items\n");
  expect(await jarvis(["capture", "-h"])).toMatchObject({ code: 0 });
  expect(await jarvis(["capture", "-x"])).toMatchObject({ code: 1, stderr: `error: Unknown option -x for capture\ndetail: ${usage}` });
  expect(await Bun.file(INBOX).text()).toBe("# Inbox\n\n## Items\n");

  // After `--` it is text, and so is a bare negative number.
  expect(await jarvis(["capture", "--inbox", "--", "-h"])).toMatchObject({ code: 0 });
  expect(await jarvis(["capture", "--inbox", "-5"])).toMatchObject({ code: 0 });
  const saved = await Bun.file(INBOX).text();
  expect(saved).toContain("— -h.");
  expect(saved).toContain("— -5.");
});

test("flags that don't go together, or only work beside another, are an error", async () => {
  expect(await jarvis(["process", "--dry-run", "--yes", "x.md"])).toMatchObject({ code: 1, stderr: expect.stringContaining("error: --dry-run and --yes can't be used together\ndetail: Usage: ") });
  expect(await jarvis(["setup", "--vault=/tmp/x"])).toMatchObject({ code: 1, stderr: expect.stringContaining("error: --vault needs --meetings\ndetail: Usage: ") });
});

test("a flag the command doesn't take, or missing text, says so with that command's usage line", async () => {
  const usage = "detail: Usage: jarvis capture [--inbox] [--] <text>";
  expect(await jarvis(["capture", "--inbxo", "--", "x"])).toMatchObject({ code: 1, stderr: `error: Unknown option --inbxo for capture\n${usage}` });
  expect(await jarvis(["capture", "--", "  \n "])).toMatchObject({ code: 1, stderr: `error: capture needs some text\n${usage}` });
  // The Dock searches as you type, so an empty query is an empty list, not an error.
  expect(await jarvis(["search"])).toMatchObject({ code: 0, stdout: "[]" });
});

test("capture folds a pasted block into one line, and undo puts the note back", async () => {
  const before = "# Inbox\n\n## Items\n\n- old\n";
  await Bun.write(INBOX, before);
  const { code, stdout } = await jarvis(["capture", "--inbox", "--", "first\n\n## Injected heading\n   - second"]);
  const { savedTo, run } = JSON.parse(stdout);
  expect({ code, savedTo }).toEqual({ code: 0, savedTo: "Inbox.md" });

  const saved = await Bun.file(INBOX).text();
  expect(saved).toContain("first ## Injected heading - second");
  expect(saved.split("\n").some((line) => line.startsWith("##") && line.includes("Injected"))).toBe(false);

  expect(JSON.parse((await jarvis(["undo", "--", run])).stdout)).toEqual({ restored: ["Inbox.md"], skipped: [] });
  expect(await Bun.file(INBOX).text()).toBe(before);
  expect((await jarvis(["undo", "--", run])).stderr).toBe("error: Already undone\ndetail: jarvis runs lists what's left to undo.");
});

test("capture drops one pasted bullet or checkbox, and leaves numbers and dashes in text", async () => {
  await Bun.write(INBOX, "# Inbox\n\n## Items\n");
  for (const text of ["- [ ] one", "- [x] two", "* three", "[ ] four", "1. five", "-6"]) await jarvis(["capture", "--inbox", "--", text]);
  const items = (await Bun.file(INBOX).text()).split("\n").filter((line) => line.startsWith("- "));
  expect(items.map((line) => line.replace(/^- \S+ — /, ""))).toEqual(["one.", "two.", "three.", "four.", "1. five.", "-6."]);
  for (const bare of ["-", "[ ]", "- [ ]"]) {
    expect((await jarvis(["capture", "--inbox", "--", bare])).stderr).toStartWith("error: capture needs some text");
  }
});

test("undoing a capture leaves a note you edited since", async () => {
  await Bun.write(INBOX, "# Inbox\n\n## Items\n\n- old\n");
  const { run } = JSON.parse((await jarvis(["capture", "--inbox", "--", "kept"])).stdout);
  await appendFile(INBOX, "typed by hand\n");

  expect(JSON.parse((await jarvis(["undo", "--", run])).stdout)).toEqual({ restored: [], skipped: ["Inbox.md"] });
  expect(await Bun.file(INBOX).text()).toContain("typed by hand");
});

test("a config key of the wrong type is named in plain words", async () => {
  const dir = join(paths.state, "bad-config");
  const file = join(dir, "config.json");
  await Bun.write(file, JSON.stringify({ vault: 3, meetings: 4, private: ["ok", 2], inbox: true }));
  const { code, stderr } = await jarvis(["search"], { JARVIS_CONFIG: dir });
  expect({ code, stderr }).toEqual({
    code: 2,
    stderr: `error: ${file} isn't valid: "vault" should be text; "meetings" should be text or false; "inbox" should be text; "private" item 2 should be text\ndetail: Fix that key in config.json, or delete it to use the default.`,
  });

  // Invalid JSON gets its own next step, and a path under the home folder is shown with `~`.
  await Bun.write(file, "{ nope");
  expect(await jarvis(["search"], { JARVIS_CONFIG: dir })).toMatchObject({
    code: 2,
    stderr: `error: ${file} isn't valid JSON\ndetail: Fix it in a text editor, then try again.`,
  });
  const home = join(paths.state, "home");
  await Bun.write(join(home, ".config/jarvis/config.json"), "{ nope");
  expect((await jarvis(["search"], { HOME: home, JARVIS_CONFIG: "~/.config/jarvis" })).stderr).toStartWith("error: ~/.config/jarvis/config.json isn't valid JSON");
});

test("saving a meeting is an undoable run, and undo puts both notes back", async () => {
  // The CLI runs in UTC so its idea of today matches this one wherever the test runs.
  const env = { TZ: "UTC" };
  const today = new Date().toISOString().slice(0, 10);
  const daily = join(paths.daily, `${today}.md`);
  const dailyBefore = "# Today\n\n## Todo\n\n- [ ] old\n";
  const logBefore = "# Work Log\n\n## Entries\n\n- 2026-01-01 · #decision · old · [[x]]\n";
  await Bun.write(daily, dailyBefore);
  await Bun.write(paths.workLog, logBefore);
  const proposal = { title: "Huddle", followUps: [], decisions: [] };
  await enqueue({ noteName: "2026-11-02 1430 Huddle", meetingDate: "2026-11-02", proposal });

  const { savedTo, run } = JSON.parse((await jarvis(["resolve", "--", "2026-11-02 1430 Huddle"], env, "[ ] Ring Sam\ndecision: Ship it")).stdout);
  expect(savedTo).toEqual([`Daily/${today}.md`, "Work Log.md"]);
  expect(await Bun.file(daily).text()).toContain("Ring Sam");

  expect(JSON.parse((await jarvis(["undo", "--", run])).stdout)).toEqual({ restored: [`Daily/${today}.md`, "Work Log.md"], skipped: [] });
  expect(await Bun.file(daily).text()).toBe(dailyBefore);
  expect(await Bun.file(paths.workLog).text()).toBe(logBefore);
});

test("a prompt whose draft failed can be skipped, or saved with lines typed by hand", async () => {
  const box = await sandbox("draft-failed");
  const queue = async (noteName: string) => {
    const proposal = { title: "Zoom", followUps: [], decisions: [] };
    await Bun.write(join(box.env.JARVIS_STATE, "pending", `${noteName}.json`), JSON.stringify({ noteName, meetingDate: noteName.slice(0, 10), proposal, draftFailed: true }));
    return join(box.env.JARVIS_STATE, "pending", `${noteName}.json`);
  };
  const skipped = await queue("2026-11-02 1430 Zoom");
  // Piped, a skip prints nothing: the Dock only reads the exit code.
  expect(await jarvis(["resolve", "--skip", "--", "2026-11-02 1430 Zoom"], box.env)).toEqual({ code: 0, stdout: "", stderr: "" });
  expect(await Bun.file(skipped).exists()).toBe(false);

  const saved = await queue("2026-11-03 0915 Zoom");
  const { savedTo } = JSON.parse((await jarvis(["resolve", "--", "2026-11-03 0915 Zoom"], box.env, "[ ] Book flights")).stdout);
  expect(savedTo).toHaveLength(1);
  expect(await Bun.file(saved).exists()).toBe(false);
});

test("capture, resolve, search and ask refuse a missing vault, and ask never starts Claude", async () => {
  const box = await sandbox("missing-vault");
  const gone = join(box.root, "no-such-vault");
  const env = { ...box.env, JARVIS_VAULT: gone };
  // HOME is the sandbox, so the path is shown the way a person sees it, under `~`.
  const said = { code: 1, stderr: "error: Can't find your vault at ~/no-such-vault\ndetail: Move it back, or choose it again in Settings." };
  for (const args of [["capture", "--", "x"], ["resolve", "--", "x"], ["search", "--", "x"], ["ask", "--", "x"], ["undo", "--last"], ["undo", "--", "x"], ["runs"]]) {
    expect(await jarvis(args, env)).toMatchObject(said);
  }
  expect(await Bun.file(join(gone, "Inbox.md")).exists()).toBe(false);
  expect(await Bun.file(box.started).exists()).toBe(false);
});

test("stopping an ask (SIGTERM) stops Claude and ends with `error: Stopped`", async () => {
  const box = await sandbox("stop");
  const proc = start(["ask", "--", "note something"], box.env);
  const stderr = new Response(proc.stderr).text();
  for (let tries = 0; tries < 100 && !(await Bun.file(box.started).exists()); tries++) await Bun.sleep(50);
  expect(await Bun.file(box.started).exists()).toBe(true);

  proc.kill("SIGTERM");
  expect(await proc.exited).toBe(1);
  expect((await stderr).trim()).toBe("error: Stopped");
});

test("runs lists what can be undone, newest first, and undo --last puts the newest back", async () => {
  const box = await sandbox("runs");
  const { env, inbox } = box;
  expect(await jarvis(["runs"], env)).toEqual({ code: 0, stdout: "No runs to undo.", stderr: "" });
  expect(await jarvis(["undo", "--last"], env)).toEqual({
    code: 1,
    stdout: "",
    stderr: "error: Nothing to undo\ndetail: Runs are kept for a week; jarvis runs lists them.",
  });

  const first = JSON.parse((await jarvis(["capture", "--inbox", "--", "one"], env)).stdout).run;
  const afterFirst = await Bun.file(inbox).text();
  const second = JSON.parse((await jarvis(["capture", "--inbox", "--", "two"], env)).stdout).run;

  const lines = (await jarvis(["runs"], env)).stdout.split("\n");
  expect(lines).toHaveLength(3);
  expect(lines[0]).toStartWith("Run id");
  expect(lines[0]).toMatch(/^Run id +When +Changed$/);
  expect(lines[1]).toMatch(new RegExp(`^${second}  (today|yesterday) \\d\\d:\\d\\d  Inbox\\.md$`));
  expect(lines[2]).toStartWith(`${first}  `);

  expect(JSON.parse((await jarvis(["undo", "--last"], env)).stdout)).toEqual({ restored: ["Inbox.md"], skipped: [] });
  expect(await Bun.file(inbox).text()).toBe(afterFirst);
  expect((await jarvis(["runs"], env)).stdout).toContain(`\n${first}  `);

  // --last is the run, so a run id beside it is a mistake, not something to guess at.
  expect(await jarvis(["undo", "--last", "--", first], env)).toMatchObject({ code: 1, stderr: expect.stringContaining("error: --last doesn't take a run id") });
  // Only runs made by --before= count, so an ask that saves after ⌥⌘Z isn't the one undone.
  expect(await jarvis(["undo", "--last", "--before=2000-01-01T00:00:00Z"], env)).toMatchObject({ code: 1, stderr: expect.stringContaining("error: Nothing to undo") });
  expect(await jarvis(["undo", "--last", "--before=soon"], env)).toMatchObject({ code: 1, stderr: expect.stringContaining("error: Not a time: soon") });
});

test("undo --last moves past a run it already kept as is, so older runs stay in reach", async () => {
  const { env } = await sandbox("kept");
  const daily = join(env.JARVIS_VAULT, "Daily", `${localDate()}.md`);
  await Bun.write(daily, "# Today\n\n## Todo\n");
  const first = JSON.parse((await jarvis(["capture", "--inbox", "--", "one"], env)).stdout).run;
  await jarvis(["capture", "--", "two"], env);
  await appendFile(daily, "typed by hand\n");

  expect(JSON.parse((await jarvis(["undo", "--last"], env)).stdout).restored).toEqual([]);
  expect((await jarvis(["runs"], env)).stdout).toContain("(edited since)");
  expect(JSON.parse((await jarvis(["undo", "--last"], env)).stdout)).toEqual({ restored: ["Inbox.md"], skipped: [] });
  expect((await jarvis(["runs"], env)).stdout).not.toContain(first);
});

test("failures that name no system error still say what to do, in a sentence", async () => {
  const box = await sandbox("details");
  expect((await jarvis(["undo", "--", "nope"], box.env)).stderr).toBe("error: Not a run id: nope\ndetail: Copy an id from jarvis runs.");
  expect((await jarvis(["undo", "--", "2026-01-01T00-00-00-000Z"], box.env)).stderr).toBe("error: Nothing to undo for 2026-01-01T00-00-00-000Z\ndetail: Runs are kept for a week; jarvis runs lists them.");
  expect((await jarvis(["undo", "--", "../nope"], box.env)).stderr).toBe("error: Not a run id: ../nope\ndetail: Copy an id from jarvis runs.");
  expect((await jarvis(["resolve", "--", "nothing"], box.env)).stderr).toBe("error: Nothing queued for nothing\ndetail: Run jarvis process -- \"nothing\" to queue it.");
  const outside = await jarvis(["setup", "--meetings", `--vault=${box.env.JARVIS_VAULT}`, "--", "/nowhere"], box.env);
  expect(outside.stderr).toBe("error: /nowhere isn't in your vault\ndetail: Choose a folder inside your vault.");
  // A missing file is named, with a next step rather than the raw errno line.
  expect((await jarvis(["process", "--", "/nowhere/missing.md"], box.env)).stderr).toBe("error: Couldn't find missing.md\ndetail: Check the path, then try again.");
});

test("an empty JARVIS_VAULT means unset, so the config's vault is used", async () => {
  const box = await sandbox("empty-vault");
  const config = join(box.root, "config");
  await Bun.write(join(config, "config.json"), JSON.stringify({ vault: join(box.root, "vault") }));
  const saved = await jarvis(["capture", "--inbox", "--", "from config"], { ...box.env, JARVIS_VAULT: "", JARVIS_CONFIG: config });
  expect(saved.code).toBe(0);
  expect(await Bun.file(box.inbox).text()).toContain("from config");
});

test("--version, version and -v print the version; help says so", async () => {
  for (const word of ["--version", "version", "-v"]) expect(await jarvis([word])).toEqual({ code: 0, stdout: pkg.version, stderr: "" });
  expect((await jarvis([])).stdout).toContain("jarvis --version");
});

test("commands that take no text reject some, with their usage line", async () => {
  for (const name of ["watch", "runs", "hook"]) {
    expect(await jarvis([name, "extra"])).toEqual({ code: 1, stdout: "", stderr: `error: ${name} takes no arguments\ndetail: Usage: jarvis ${name}` });
  }
});

test("setup says a vault is configured even when its folder is missing", async () => {
  const box = await sandbox("configured");
  const status = async (env: Record<string, string>) => JSON.parse((await jarvis(["setup"], { ...box.env, ...env })).stdout);
  expect(await status({})).toMatchObject({ configured: true, ready: true });
  expect(await status({ JARVIS_VAULT: join(box.root, "gone") })).toMatchObject({ configured: true, ready: false });
  // No vault in the environment or in config.json: first run.
  expect(await status({ JARVIS_VAULT: "" })).toMatchObject({ configured: false, ready: false });
});

test("a folder where a note or a folder is wanted is a sentence with a next step", async () => {
  const box = await sandbox("not-a-note");
  expect((await jarvis(["process", "--", box.root], box.env)).stderr).toBe(`error: ${basename(box.root)} isn't a note\ndetail: Choose a .md file.`);
  expect((await jarvis(["setup", "--", join(box.root, "nowhere")], box.env)).stderr).toBe(`error: ${join(box.root, "nowhere")} isn't a folder\ndetail: Choose a folder that exists.`);
});

test("process finds a note by name in the meetings folder, and names one that isn't there", async () => {
  const box = await sandbox("by-name");
  expect((await jarvis(["process", "--", "2026-11-03 0915 Zoom"], box.env)).stderr).toBe(
    "error: No recording called “2026-11-03 0915 Zoom” in Meetings\ndetail: Use the name the Dock shows, or the note's path.",
  );
  // Claude never starts for a name that isn't there.
  expect(await Bun.file(box.started).exists()).toBe(false);
});
