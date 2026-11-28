import { basename, join } from "node:path";
import pkg from "../package.json";
import { ask } from "./ask";
import { hook } from "./backup-hook";
import { explain } from "./errors";
import { meetingsOff, paths, settings } from "./config";
import { extract } from "./extract";
import { isFolder, readText } from "./files";
import { draftSettled, findRecording, listRecordings, queueUndrafted } from "./meetings";
import { type Capture, draft, parseDraft } from "./review";
import { NO_RUN, commitRun, describeUndo, formatRuns, lastRun, recentRuns, undo } from "./runs";
import { search } from "./search";
import { NOT_A_FOLDER, chooseMeetings, chooseVault, meetingFolders, setupStatus, turnMeetingsOff } from "./setup";
import { enqueue, heartbeat, loadFailures, loadSeen, loadSeenFolder, logEvent, readPending, removePending, saveSeen, saveSeenFolder } from "./state";
import { describeAsk, describeCapture, describeQueued, describeSave, describeSkip, print } from "./terminal";
import { stripListMarker } from "./text";
import { localDate, planDecisions, planTodos, readDaily, requireVault, section } from "./vault";

async function notify(message: string): Promise<void> {
  await Bun.spawn([
    "osascript", "-e", "on run argv", "-e", 'display notification (item 1 of argv) with title "Jarvis"', "-e", "end run",
    message,
  ]).exited;
}

type Meeting = { noteName: string; meetingDate: string; title: string };

/** Writes a meeting's todos and decisions as one undoable run (`run` is there only if something was written). */
async function save(capture: Capture, { noteName, meetingDate, title }: Meeting) {
  return commitRun([
    await planTodos(capture.todos, { today: localDate(), link: `[[${noteName}|${title}]]` }),
    await planDecisions(capture.decisions, meetingDate, noteName),
  ]);
}

/**
 * Drafts a proposal for one recording, given as a path or as the note's name in the meetings
 * folder. By default it waits in the Dock's queue (replacing a prompt already there for it).
 */
async function handle(recording: string, mode: "queue" | "dry-run" | "yes"): Promise<void> {
  const file = await findRecording(recording);
  const noteName = basename(file, ".md");
  const meetingDate = noteName.slice(0, 10);
  // Drafting takes a while, so a person at a terminal hears it started. stderr keeps stdout for the result.
  if (process.stdout.isTTY) console.error(`Drafting ${noteName}…`);

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
    const { written } = await save(parseDraft(draft(proposal)), { noteName, meetingDate, title: proposal.title });
    console.log(`${noteName}: saved to ${written.join(", ") || "nothing"}`);
  } else {
    await enqueue({ noteName, meetingDate, proposal });
    await notify(`${proposal.title}: ready to review in the Dock`);
    // The Dock only reads the exit code, so piped output stays empty.
    if (process.stdout.isTTY) console.log(describeQueued(proposal.title));
  }
}

/** Saves (draft text on stdin) or skips a queued prompt. Called by the Dock. */
async function resolve(noteName: string, skip: boolean): Promise<void> {
  // Saving reads the draft from stdin, which would just wait at a terminal.
  if (!skip && process.stdin.isTTY) throw new Error("resolve reads the draft on stdin", { cause: "Pipe it in, or use --skip." });
  // Skipping writes nothing to the vault, so it works while the vault is away.
  if (!skip) await requireVault();
  const pending = await readPending(noteName);
  if (!pending) throw new Error(`Nothing queued for ${noteName}`, { cause: `Run jarvis process -- "${noteName}" to queue it.` });

  if (skip) {
    await logEvent({ type: "skipped", note: noteName });
    if (process.stdout.isTTY) console.log(describeSkip(noteName));
  } else {
    const capture = parseDraft(await Bun.stdin.text());
    const { written, run } = await save(capture, { ...pending, title: pending.proposal.title });
    const edited = JSON.stringify(capture) !== JSON.stringify(parseDraft(draft(pending.proposal)));
    await logEvent({ type: "saved", note: noteName, capture, edited, run });
    print({ savedTo: written, run }, describeSave(written));
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
    await requireVault();
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
        async (name) => {
          // Still queued, with nothing proposed, so the Dock can offer to add it by hand.
          const noteName = await queueUndrafted(join(paths.meetings, name));
          await notify(`Couldn't draft ${noteName}. Open the Dock to draft it again or add todos.`);
        },
      );
    }
    await Bun.sleep(settings.pollMs);
  }
}

/** Saves a todo to today's note (or the Inbox) as an undoable run. */
async function capture(text: string, inboxOnly: boolean): Promise<void> {
  await requireVault();
  // One line, so pasted text can't start a heading or list item of its own in the note. A pasted
  // list item loses its own marker, since the note adds one.
  const line = stripListMarker(text.replace(/\s+/g, " ").trim());
  // A bare "-" or "[ ]" is no todo once its marker is gone.
  if (!line) throw new Error("capture needs some text", { cause: `Usage: ${lookup("capture").usage}` });
  const { written, run } = await commitRun([await planTodos([line], { today: localDate(), inboxOnly })]);
  const savedTo = written[0] ?? null;
  await logEvent({ type: "captured", text: line, savedTo, run });
  print({ savedTo, run }, describeCapture(savedTo));
}

/** For people at a terminal, not the Dock: a header, then one run per line, newest first. */
async function printRuns(): Promise<void> {
  await requireVault();
  const runs = await recentRuns();
  console.log(runs.length === 0 ? "No runs to undo." : formatRuns(runs));
}

type CommandSpec = {
  /** The usage line, shown in help and under an error about this command. */
  usage: string;
  about: string;
  /** The flags it takes. One ending in `=` takes a value. */
  flags: string[];
  /** What the text after the flags is, when the command can't run without it. */
  needs?: string;
  /** The command takes no text at all, so any is a mistake. */
  noText?: true;
  /** A flag that stands in for `needs`: `undo --last` takes no run id. */
  unlessFlag?: string;
  /** Two flags that can't be given together. */
  exclusive?: [string, string];
  /** Flags that mean nothing without another one: `--vault=` only works beside `--meetings`. */
  alongside?: Record<string, string>;
};

const COMMANDS: Record<string, CommandSpec> = {
  watch: { usage: "jarvis watch", about: "Watch the meetings folder and queue a prompt for each new recording", flags: [], noText: true },
  process: {
    usage: "jarvis process [--dry-run | --yes] [--] <note.md or note name>",
    about: "Draft one recording: queue it (default), print it, or write it;\na note name is looked up in the meetings folder",
    flags: ["--dry-run", "--yes"],
    needs: "a note path or name",
    exclusive: ["--dry-run", "--yes"],
  },
  capture: {
    usage: "jarvis capture [--inbox] [--] <text>",
    about: "Add a todo to today's note, or to the Inbox; prints the run id for undo",
    flags: ["--inbox"],
    needs: "some text",
  },
  search: { usage: "jarvis search [--] <query>", about: "Print the notes that match, as JSON", flags: [] },
  resolve: {
    usage: "jarvis resolve [--skip] [--] <note name>",
    about: "Save a queued meeting prompt (draft text on stdin; prints the run id for undo), or skip it",
    flags: ["--skip"],
    needs: "a note name",
  },
  ask: {
    usage: "jarvis ask [--app=<frontmost app>] [--] <text>",
    about: "Let Claude save, find or answer; progress comes as step: lines",
    flags: ["--app="],
    needs: "some text",
  },
  undo: {
    usage: "jarvis undo [--last [--before=<time>] | [--] <run id>]",
    about: "Put back what a capture, meeting save or ask changed; --last: the newest (by --before=)",
    flags: ["--last", "--before="],
    alongside: { "--before=": "--last" },
    needs: "a run id",
    unlessFlag: "--last",
  },
  runs: { usage: "jarvis runs", about: "List recent runs you can undo, newest first: run id, when, notes changed", flags: [], noText: true },
  setup: {
    usage: "jarvis setup [--meetings [--vault=<path>] [--off]] [[--] <folder>]",
    // Help lines stay under 100 characters, so a long description is written as two.
    about: "JSON: vault status and Obsidian's vaults (or with --meetings, folders holding recordings);\nwith a folder, choose it",
    flags: ["--meetings", "--vault=", "--off"],
    alongside: { "--vault=": "--meetings", "--off": "--meetings" },
  },
  hook: { usage: "jarvis hook", about: "The PreToolUse check jarvis ask installs; reads one payload on stdin", flags: [], noText: true },
};

const USAGE = `Usage: jarvis <command> [options]

${Object.values(COMMANDS)
  .map(({ usage, about }) => `  ${usage}\n      ${about.replaceAll("\n", "\n      ")}`)
  .join("\n")}

Everything after \`--\` is text, so captures may start with dashes.
\`jarvis help <command>\` (or \`jarvis <command> --help\`) shows one command's usage.
\`jarvis --version\` prints the version.`;

const [command, ...rest] = Bun.argv.slice(2);
const split = rest.indexOf("--");
/** Words that look like a flag (`-h`, `-x`, `--inbox`). A bare negative number (`-5`) or a lone `-` is text. */
const isOption = (arg: string) => /^--?[^\d\s]/.test(arg);
// Before `--`, a word that looks like a flag is one, so `capture -h` can't save "-h" by accident.
// After `--` everything is text.
const flags = split === -1 ? rest.filter(isOption) : rest.slice(0, split);
const positional = (split === -1 ? rest.filter((a) => !isOption(a)) : rest.slice(split + 1)).join(" ");
/** `known` is a flag as `COMMANDS` lists it: one ending in `=` takes a value. */
const matches = (given: string, known: string) => (known.endsWith("=") ? given.startsWith(known) : given === known);
const flag = (known: string) => flags.some((f) => matches(f, known));
const flagValue = (known: string) => flags.find((f) => matches(f, known))?.slice(known.length);

/** Help goes to stdout and succeeds; the Dock never runs a bare `jarvis`, it always passes `watch`. */
const HELP = new Set(["help", "--help", "-h"]);
const VERSION = new Set(["version", "--version", "-v"]);

function lookup(name: string): CommandSpec {
  const spec = Object.hasOwn(COMMANDS, name) ? COMMANDS[name] : undefined;
  if (!spec) throw new Error(`Unknown command "${name}"`, { cause: "Run jarvis help for the list." });
  return spec;
}

/** Turns a flag it doesn't take, flags that don't go together or missing text into one `error:` line. */
function check(name: string, spec: CommandSpec): void {
  // The detail is the usage line, not a sentence, so it has no full stop.
  const cause = `Usage: ${spec.usage}`;
  const unknown = flags.find((f) => !spec.flags.some((known) => matches(f, known)));
  if (unknown) throw new Error(`Unknown option ${unknown} for ${name}`, { cause });
  const [a, b] = spec.exclusive ?? [];
  if (a && b && flag(a) && flag(b)) throw new Error(`${a} and ${b} can't be used together`, { cause });
  for (const [needy, partner] of Object.entries(spec.alongside ?? {})) {
    if (flag(needy) && !flag(partner)) throw new Error(`${needy.replace(/=$/, "")} needs ${partner}`, { cause });
  }
  if (spec.unlessFlag && flag(spec.unlessFlag) && positional.trim()) {
    throw new Error(`${spec.unlessFlag} doesn't take ${spec.needs}`, { cause });
  }
  if (spec.noText && positional.trim()) throw new Error(`${name} takes no arguments`, { cause });
  if (spec.needs && !positional.trim() && !(spec.unlessFlag && flag(spec.unlessFlag))) {
    throw new Error(`${name} needs ${spec.needs}`, { cause });
  }
}

const commandHelp = (spec: CommandSpec) => `Usage: ${spec.usage}\n\n${spec.about}`;

async function run(): Promise<void> {
  if (command === "help" && positional.trim()) {
    const [topic = "", ...extra] = positional.trim().split(/\s+/);
    if (extra.length > 0) throw new Error("help takes one command", { cause: "Usage: jarvis help <command>" });
    console.log(commandHelp(lookup(topic)));
    return;
  }
  // `jarvis ""` (an empty argument from a script) is a bare `jarvis`, not an unknown command.
  if (!command || HELP.has(command)) {
    console.log(USAGE);
    return;
  }
  if (VERSION.has(command)) {
    if (positional.trim()) throw new Error(`${command} takes no arguments`, { cause: "Usage: jarvis --version" });
    // Release builds pin the tag here (scripts/package.sh --define); a checkout reads package.json.
    console.log(process.env.JARVIS_VERSION ?? pkg.version);
    return;
  }
  const spec = lookup(command);
  // Asking for help never runs the command, whatever else was typed.
  if (flag("--help") || flag("-h")) {
    console.log(commandHelp(spec));
    return;
  }
  check(command, spec);
  switch (command) {
    case "watch":
      return watch();
    case "process":
      return handle(positional, flag("--dry-run") ? "dry-run" : flag("--yes") ? "yes" : "queue");
    case "capture":
      return capture(positional, flag("--inbox"));
    case "search":
      await requireVault();
      console.log(JSON.stringify(await search(positional)));
      return;
    case "resolve":
      return resolve(positional, flag("--skip"));
    case "ask": {
      const app = flagValue("--app=");
      // Progress goes to stderr as `step: ...` lines, which the Dock reads as they arrive.
      const result = await ask(positional, app, (step) => console.error(`step: ${step}`));
      await logEvent({ type: "asked", text: positional, app, result });
      print(result, describeAsk(result));
      return;
    }
    case "setup": {
      // `--vault=` names the vault just chosen, which config.json may not reach (JARVIS_VAULT wins).
      const vault = flagValue("--vault=");
      if (vault !== undefined && !(await isFolder(vault))) throw new Error(`${vault} isn't a folder`, { cause: NOT_A_FOLDER });
      if (flag("--meetings")) {
        const result = flag("--off") ? await turnMeetingsOff() : positional ? await chooseMeetings(positional, vault) : await meetingFolders(vault);
        console.log(JSON.stringify(result));
      } else {
        console.log(JSON.stringify(positional ? await chooseVault(positional) : await setupStatus()));
      }
      return;
    }
    case "hook":
      return hook();
    case "undo": {
      await requireVault();
      const before = flagValue("--before=");
      const by = before === undefined ? undefined : Date.parse(before);
      if (by !== undefined && Number.isNaN(by)) throw new Error(`Not a time: ${before}`, { cause: "Give an ISO time, like 2026-11-28T09:30:00Z." });
      const id = flag("--last") ? await lastRun(by) : positional;
      if (!id) throw new Error("Nothing to undo", { cause: NO_RUN });
      const result = await undo(id);
      await logEvent({ type: "undone", run: id, ...result });
      print(result, describeUndo(result));
      return;
    }
    case "runs":
      return printRuns();
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
