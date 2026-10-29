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
function claudePath(): string {
  const PATH = [process.env.PATH, `${homedir()}/.local/bin`, "/opt/homebrew/bin", "/usr/local/bin"].filter(Boolean).join(":");
  const found = Bun.which("claude", { PATH });
  if (!found) throw new Error("Couldn't find Claude Code (claude) on this Mac");
  return found;
}

type Options = {
  args: string[];
  cwd?: string;
  env?: Record<string, string>;
  timeoutMs?: number;
  /** Called with a short phrase each time Claude uses a tool, e.g. "Reading Team". */
  onStep?: (step: string) => void;
};

const clip = (text: string, max: number) => {
  const flat = text.replace(/\s+/g, " ").trim();
  return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat;
};
const noteName = (path: unknown) => clip(basename(String(path ?? ""), ".md"), 40);

/** Turns a tool call into the few words the Dock shows while Claude works. */
export function describeStep(tool: string, input: Record<string, unknown>): string {
  switch (tool) {
    case "Read": return `Reading ${noteName(input.file_path)}`;
    case "Grep": return `Searching for “${clip(String(input.pattern ?? ""), 30)}”`;
    case "Glob": return `Looking through ${clip(String(input.pattern ?? "notes"), 30)}`;
    case "Edit":
    case "MultiEdit": return `Updating ${noteName(input.file_path)}`;
    case "Write": return `Writing ${noteName(input.file_path)}`;
    case "Skill": return `Using ${clip(String(input.skill ?? input.command ?? input.name ?? "a skill"), 30)}`;
    case "StructuredOutput": return "Writing the answer";
    default: return clip(tool, 30);
  }
}

/** Runs `claude -p` and returns its structured output, validated against `schema`. */
export async function runClaude<T extends z.ZodType>(
  schema: T,
  prompt: string,
  { args, cwd, env = {}, timeoutMs = 2 * 60_000, onStep }: Options,
): Promise<z.output<T>> {
  // Claude Code's validator doesn't know zod's draft 2020-12 `$schema` URI; the body is fine without it.
  const { $schema: _, ...jsonSchema } = z.toJSONSchema(schema);
  // Streaming reports each tool call as it happens; the last line is the same result object.
  const format = onStep ? ["--output-format", "stream-json", "--verbose"] : ["--output-format", "json"];
  const proc = Bun.spawn(
    [
      claudePath(), "-p",
      "--model", settings.model,
      ...format,
      "--no-session-persistence",
      "--json-schema", JSON.stringify(jsonSchema),
      ...args,
    ],
    {
      cwd,
      env: { ...(await claudeEnv()), ...env },
      timeout: timeoutMs,
      stdin: new Response(prompt),
      stdout: "pipe",
      stderr: "pipe",
    },
  );

  let result: { is_error?: boolean; result?: string; structured_output?: unknown } | undefined;
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
  // Claude Code can print a warning line (e.g. about connectors) before any JSON.
  const handle = (line: string) => {
    if (!line.trim().startsWith("{")) return;
    const event = JSON.parse(line);
    if (event.type === "result" || !onStep) result = event;
    if (event.type === "assistant") {
      for (const item of event.message?.content ?? []) {
        if (item.type === "tool_use") onStep?.(describeStep(item.name, item.input ?? {}));
      }
    }
  };

  const [, stderr, code] = await Promise.all([readEvents(), new Response(proc.stderr).text(), proc.exited]);
  if (code !== 0) throw new Error(`claude exited ${code}: ${stderr.trim()}`);
  if (!result) throw new Error("claude returned no result");
  if (result.is_error) throw new Error(`claude failed: ${result.result}`);
  return schema.parse(result.structured_output);
}
