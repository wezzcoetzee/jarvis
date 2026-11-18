import { basename, join } from "node:path";
import { ask, undo } from "./ask";
import { hook } from "./backup-hook";
import { explain } from "./errors";
import { meetingsOff, paths, settings } from "./config";
import { extract } from "./extract";
import { isFolder, readText } from "./files";
import { draftSettled, listRecordings } from "./meetings";
import { type Capture, draft, parseDraft } from "./review";
import { search } from "./search";
import { chooseMeetings, chooseVault, meetingFolders, setupStatus, turnMeetingsOff } from "./setup";
import { enqueue, heartbeat, loadFailures, loadSeen, loadSeenFolder, logEvent, readPending, removePending, saveSeen, saveSeenFolder } from "./state";
import { commit, localDate, planDecisions, planTodos, readDaily, section } from "./vault";

async function notify(message: string): Promise<void> {
  await Bun.spawn([
    "osascript", "-e", "on run argv", "-e", 'display notification (item 1 of argv) with title "Jarvis"', "-e", "end run",
    message,
  ]).exited;
}

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

  const [note, people, daily] = await Promise.all([Bun.file(file).text(), readText(paths.people), readDaily(localDate())]);
  const proposal = await extract({
    note,
    date: meetingDate,
    people: people ?? "",
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
  // Which folder `seen` belongs to. State from before this was recorded belongs to the current one.
  let seenFolder = (await loadSeenFolder()) ?? (seen ? paths.meetings : null);
  const failures = await loadFailures();
  let said = "";

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
    await heartbeat();
    // A missing vault, at startup or later, is breakage: exit with one plain `error:` line,
    // which the Dock reads from watch.log and shows as "Meetings paused".
    if (!(await isFolder(paths.vault))) throw new Error(`Can't find your vault at ${paths.vault}`);
    // Meetings turned off, or no meetings folder (not everyone records calls), aren't breakage:
    // wait quietly rather than exit and turn the Dock's pill red.
    const present = !meetingsOff && (await isFolder(paths.meetings));
    const status = meetingsOff ? "Meetings are off" : `${present ? "Watching" : "Waiting for"} ${paths.meetings}`;
    if (status !== said) console.log(status);
    said = status;
    if (meetingsOff && seenFolder !== "off") {
      seenFolder = "off";
      await saveSeenFolder(seenFolder);
    }
    if (present) {
      // A folder seen for the first time (first run, another one picked in Settings, meetings
      // turned back on) starts from its recordings as they are: only meetings recorded from now
      // on prompt, rather than every old one drafting at once.
      if (!seen || seenFolder !== paths.meetings) {
        seen = new Set(await listRecordings());
        await saveSeen(seen);
        seenFolder = paths.meetings;
        await saveSeenFolder(seenFolder);
      }
      await draftSettled(
        seen,
        failures,
        async (name) => {
          // A draft can take a while; it's work, not a stall.
          await heartbeat();
          await handle(join(paths.meetings, name), "queue");
        },
        (name) => notify(`Couldn't draft ${name} after ${settings.draftAttempts} tries. See events.jsonl.`),
      );
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
  jarvis setup [[--] <vault folder>]          (no folder: JSON status and Obsidian's vaults)
  jarvis setup --meetings [--vault=<path>] [--off | [--] <folder>]   (neither: vault folders holding recordings)
  jarvis hook                                (the PreToolUse hook jarvis ask installs)

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
    case "setup": {
      // `--vault=` names the vault just chosen, which config.json may not reach (JARVIS_VAULT wins).
      const vault = flags.find((f) => f.startsWith("--vault="))?.slice("--vault=".length);
      if (flag("meetings")) {
        const result = flag("off") ? await turnMeetingsOff() : positional ? await chooseMeetings(positional, vault) : await meetingFolders(vault);
        console.log(JSON.stringify(result));
      } else {
        console.log(JSON.stringify(positional ? await chooseVault(positional) : await setupStatus()));
      }
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

// One `error:` line on stderr is what the Dock shows when something fails, and one `detail:`
// line under it, so a multi-line cause is joined into one.
try {
  await run();
} catch (error) {
  const { message, detail } = explain(error);
  console.error(`error: ${message}`);
  if (detail) console.error(`detail: ${detail.replace(/\s*\n\s*/g, " ")}`);
  process.exit(1);
}
