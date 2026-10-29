import { basename, join } from "node:path";
import { ask, undo } from "./ask";
import { hook } from "./backup-hook";
import { paths, settings } from "./config";
import { extract } from "./extract";
import { listRecordings, settledRecordings } from "./meetings";
import { type Capture, draft, notify, parseDraft } from "./review";
import { search } from "./search";
import { enqueue, loadSeen, logEvent, readPending, removePending, saveSeen } from "./state";
import { commit, planDecisions, planTodos, readDaily, section } from "./vault";

const localDate = (d = new Date()) => d.toLocaleDateString("en-CA");

type Meeting = { noteName: string; meetingDate: string; title: string };

async function save(capture: Capture, { noteName, meetingDate, title }: Meeting): Promise<string[]> {
  return commit([
    await planTodos(capture.todos, { today: localDate(), link: `[[${noteName}|${title}]]` }),
    await planDecisions(capture.decisions, meetingDate, noteName),
  ]);
}

/** Drafts a proposal for one recording. By default it waits in the Dock's queue. */
async function handle(file: string, mode: "queue" | "dry-run" | "yes"): Promise<void> {
  const noteName = basename(file, ".md");
  const meetingDate = noteName.slice(0, 10);

  const peopleFile = Bun.file(paths.people);
  const [note, people, daily] = await Promise.all([
    Bun.file(file).text(),
    peopleFile.exists().then((exists) => (exists ? peopleFile.text() : "")),
    readDaily(localDate()),
  ]);
  const proposal = await extract({
    note,
    date: meetingDate,
    people,
    openTodos: daily ? section(daily, "## Todo") : "",
  });
  await logEvent({ type: "proposed", note: noteName, proposal });

  if (mode === "dry-run") {
    console.log(`${proposal.title}\n\n${draft(proposal) || "(nothing proposed)"}`);
  } else if (mode === "yes") {
    const written = await save(parseDraft(draft(proposal)), { noteName, meetingDate, title: proposal.title });
    console.log(`${noteName}: saved to ${written.join(", ") || "nothing"}`);
  } else {
    await enqueue({ noteName, meetingDate, proposal });
    await notify(`${proposal.title}: ready to review in the Dock`);
  }
}

/** Saves (draft text on stdin) or skips a queued prompt. Called by the Dock. */
async function resolve(noteName: string, skip: boolean): Promise<void> {
  const pending = await readPending(noteName);
  if (!pending) throw new Error(`Nothing queued for ${noteName}`);

  if (skip) {
    await logEvent({ type: "skipped", note: noteName });
  } else {
    const capture = parseDraft(await Bun.stdin.text());
    const written = await save(capture, { ...pending, title: pending.proposal.title });
    const edited = JSON.stringify(capture) !== JSON.stringify(parseDraft(draft(pending.proposal)));
    await logEvent({ type: "saved", note: noteName, capture, edited });
    console.log(JSON.stringify({ savedTo: written }));
  }
  await removePending(noteName);
}

async function watch(): Promise<void> {
  let seen = await loadSeen();
  if (!seen) {
    // First run: only react to meetings recorded from now on.
    seen = new Set(await listRecordings());
    await saveSeen(seen);
  }
  console.log(`Watching ${paths.meetings}`);

  // Polling one folder is cheap and sidesteps FSEvents quirks in cloud-synced folders.
  // Jarvis.app runs the watcher. If the app dies without stopping it, exit, so the next launch
  // doesn't end up with two. (process.ppid is read once at startup in compiled Bun, so ask
  // whether the parent is still alive instead.)
  const parent = process.ppid;
  const parentAlive = () => {
    try {
      process.kill(parent, 0);
      return true;
    } catch {
      return false;
    }
  };
  while (true) {
    if (parent !== 1 && !parentAlive()) process.exit(0);
    for (const name of await settledRecordings(seen)) {
      try {
        await handle(join(paths.meetings, name), "queue");
      } catch (error) {
        await logEvent({ type: "error", note: name, error: String(error) });
        await notify(`Couldn't read ${name}. See events.jsonl.`);
      }
      seen.add(name);
      await saveSeen(seen);
    }
    await Bun.sleep(settings.pollMs);
  }
}

const USAGE = `usage:
  jarvis watch
  jarvis process <note.md> [--dry-run | --yes]
  jarvis capture [--inbox] [--] <text>
  jarvis search [--] <query>
  jarvis resolve [--skip] [--] <note name>    (draft text on stdin)
  jarvis ask [--app=<frontmost app>] [--] <text>
  jarvis undo [--] <run id>
  jarvis hook                                 (the PreToolUse hook jarvis ask installs)

Everything after \`--\` is text, so captures may start with dashes.`;

const [command = "watch", ...rest] = Bun.argv.slice(2);
const split = rest.indexOf("--");
const flags = split === -1 ? rest.filter((a) => a.startsWith("--")) : rest.slice(0, split);
const positional = (split === -1 ? rest.filter((a) => !a.startsWith("--")) : rest.slice(split + 1)).join(" ");
const flag = (name: string) => flags.includes(`--${name}`);

async function run(): Promise<void> {
  switch (command) {
    case "watch":
      return watch();
    case "process":
      if (!positional) throw new Error(USAGE);
      return handle(positional, flag("dry-run") ? "dry-run" : flag("yes") ? "yes" : "queue");
    case "capture": {
      if (!positional) throw new Error(USAGE);
      const [savedTo = null] = await commit([await planTodos([positional], { today: localDate(), inboxOnly: flag("inbox") })]);
      await logEvent({ type: "captured", text: positional, savedTo });
      console.log(JSON.stringify({ savedTo }));
      return;
    }
    case "search":
      console.log(JSON.stringify(await search(positional)));
      return;
    case "resolve":
      if (!positional) throw new Error(USAGE);
      return resolve(positional, flag("skip"));
    case "ask": {
      if (!positional) throw new Error(USAGE);
      const app = flags.find((f) => f.startsWith("--app="))?.slice("--app=".length);
      // Progress goes to stderr as `step: ...` lines, which the Dock reads as they arrive.
      const result = await ask(positional, app, (step) => console.error(`step: ${step}`));
      await logEvent({ type: "asked", text: positional, app, result });
      console.log(JSON.stringify(result));
      return;
    }
    case "hook":
      return hook();
    case "undo": {
      if (!positional) throw new Error(USAGE);
      const result = await undo(positional);
      await logEvent({ type: "undone", run: positional, ...result });
      console.log(JSON.stringify(result));
      return;
    }
    default:
      throw new Error(USAGE);
  }
}

// One `error:` line on stderr is what the Dock shows when something fails.
try {
  await run();
} catch (error) {
  console.error(`error: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
}
