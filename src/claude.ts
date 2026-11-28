import { homedir } from "node:os";
import { basename } from "node:path";
import { z } from "zod";
import { proxy, settings } from "./config";

/** Goes through cliproxy when it's configured and answering; otherwise Claude Code's own login. */
async function claudeEnv(): Promise<Record<string, string | undefined>> {
  const env: Record<string, string | undefined> = { ...process.env };
  if (proxy) {
    const up = await fetch(`${proxy.url}/v1/models`, {
      headers: { Authorization: `Bearer ${proxy.token}` },
      signal: AbortSignal.timeout(1500),
    }).then(
      (res) => res.ok,
      () => false,
    );
    if (up) return { ...env, ANTHROPIC_BASE_URL: proxy.url, ANTHROPIC_AUTH_TOKEN: proxy.token };
  }
  // Falling back means the keychain login, so drop any proxy settings inherited from the shell.
  for (const key of ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"]) delete env[key];
  return env;
}

/** Apps opened from Finder get a bare PATH, so look where Claude Code installs itself too. */
export function findClaude(): string | null {
  const PATH = [process.env.PATH, `${homedir()}/.local/bin`, "/opt/homebrew/bin", "/usr/local/bin"].filter(Boolean).join(":");
  return Bun.which("claude", { PATH });
}

function claudePath(): string {
  const found = findClaude();
  if (!found) {
    throw new Error("Claude Code isn't installed", { cause: "Install it from claude.com/claude-code, then run claude in Terminal to sign in." });
  }
  return found;
}

type Options = {
  args: string[];
  cwd?: string;
  env?: Record<string, string>;
  timeoutMs?: number;
  /** Called with a short phrase each time Claude uses a tool, e.g. "Reading Team". */
  onStep?: (step: string) => void;
  /** Aborting stops Claude (SIGTERM), and the run ends in an error. */
  signal?: AbortSignal;
};

const clip = (text: string, max: number) => {
  const flat = text.replace(/\s+/g, " ").trim();
  return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat;
};
// Every step fits the box beside the timer: about 24 characters. The Dock says daily notes'
// dates as days ("today's note"), so a date here costs no more room than its name.
const noteName = (path: unknown) => clip(basename(String(path ?? ""), ".md"), 16);
/** A Grep or Glob pattern as the words in it: "shed.*roof|felt" reads as "shed roof felt". */
const words = (pattern: unknown, max: number) => clip(String(pattern ?? "").replace(/\.md\b/gi, " ").replace(/[^\p{L}\p{N}]+/gu, " "), max);

export function describeStep(tool: string, input: Record<string, unknown>): string {
  switch (tool) {
    case "Read": return `Reading ${noteName(input.file_path)}`;
    case "Grep": return `Searching “${words(input.pattern, 12) || "notes"}”`;
    case "Glob": return words(input.pattern, 12) ? `Looking for ${words(input.pattern, 12)}` : "Looking through notes";
    case "Edit":
    case "MultiEdit": return `Updating ${noteName(input.file_path)}`;
    case "Write": return `Writing ${noteName(input.file_path)}`;
    case "Skill": return `Using ${clip(String(input.skill ?? input.command ?? input.name ?? "a skill"), 18)}`;
    case "StructuredOutput": return "Writing the answer";
    default: return clip(tool, 24);
  }
}

/** The parts of Claude Code's JSON output Jarvis reads: tool calls as they happen, then the result. */
type Event = {
  type?: string;
  message?: { content?: { type: string; name: string; input?: Record<string, unknown> }[] };
  is_error?: boolean;
  result?: string;
  structured_output?: unknown;
};

/**
 * A `claude -p` failure as an actionable headline, with the next step on `cause` (the `detail:` line).
 * Claude Code's own wording goes on `cause` only for unrecognised failures. Headlines have no full
 * stop, as Claude's own have none; the next steps are sentences, so they end with one.
 */
export function failure(stderr: string, killed = false): Error {
  const text = stderr.trim();
  if (killed) return new Error("Claude took too long, so Jarvis stopped it", { cause: "Try again, or ask for less at once." });
  if (/\b529\b|overloaded/i.test(text)) return new Error("Claude is busy right now", { cause: "Try again in a minute." });
  if (/\b429\b|rate.?limit|usage limit/i.test(text)) {
    return new Error("Claude's usage limit is reached", { cause: "Try again later, or edit it (⌘E) and press ⌘⏎ to put it in your Inbox." });
  }
  if (/\b401\b|not logged in|please run \/login|invalid api key/i.test(text)) {
    return new Error("Claude Code isn't signed in", { cause: "Run claude in Terminal to sign in." });
  }
  // After the specific API errors, which can mention a network in passing.
  if (/ENOTFOUND|ECONNREFUSED|ECONNRESET|ETIMEDOUT|EAI_AGAIN|Unable to connect|fetch failed|network|offline/i.test(text)) {
    return new Error("Can't reach Claude", { cause: "Check your connection, then try again, or edit it (⌘E) and press ⌘⏎ to put it in your Inbox." });
  }
  return new Error("Claude stopped before it finished", { cause: text || undefined });
}

/** Runs `claude -p` and returns its structured output, validated against `schema`. */
export async function runClaude<T extends z.ZodType>(
  schema: T,
  prompt: string,
  { args, cwd, env = {}, timeoutMs = 2 * 60_000, onStep, signal }: Options,
): Promise<z.output<T>> {
  // Claude Code's validator doesn't know zod's draft 2020-12 `$schema` URI; the body is fine without it.
  const { $schema: _, ...jsonSchema } = z.toJSONSchema(schema);
  // Streaming reports each tool call as it happens; the last line is the same result object.
  const format = onStep ? ["--output-format", "stream-json", "--verbose"] : ["--output-format", "json"];
  const path = claudePath();
  const baseEnv = await claudeEnv();
  // Stopped while the environment was being prepared: never start Claude.
  signal?.throwIfAborted();
  const proc = Bun.spawn(
    [
      path, "-p",
      "--model", settings.model,
      ...format,
      "--no-session-persistence",
      "--json-schema", JSON.stringify(jsonSchema),
      ...args,
    ],
    {
      cwd,
      env: { ...baseEnv, ...env },
      timeout: timeoutMs,
      signal,
      stdin: new Response(prompt),
      stdout: "pipe",
      stderr: "pipe",
    },
  );

  let result: Event | undefined;
  const readEvents = async () => {
    let buffer = "";
    const decoder = new TextDecoder();
    for await (const chunk of proc.stdout) {
      buffer += decoder.decode(chunk, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";
      for (const line of lines) handle(line);
    }
    handle(buffer);
  };
  // Claude Code can print a warning line (e.g. about connectors) before any JSON, and a run
  // killed by the timeout can end mid-line. Skip both, so the error says how it ended.
  const handle = (line: string) => {
    if (!line.trim().startsWith("{")) return;
    let event: Event;
    try {
      event = JSON.parse(line);
    } catch {
      return;
    }
    if (event.type === "result" || !onStep) result = event;
    if (event.type === "assistant") {
      for (const item of event.message?.content ?? []) {
        if (item.type === "tool_use") onStep?.(describeStep(item.name, item.input ?? {}));
      }
    }
  };

  const [, stderr, code] = await Promise.all([readEvents(), new Response(proc.stderr).text(), proc.exited]);
  if (code !== 0) throw failure(stderr, proc.signalCode !== null);
  if (!result) throw failure(stderr);
  if (result.is_error) throw failure(String(result.result ?? ""));
  return schema.parse(result.structured_output);
}
