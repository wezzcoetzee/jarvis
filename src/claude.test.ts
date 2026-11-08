import { expect, test } from "bun:test";
import { describeStep, failure } from "./claude";

test("tool calls read as short phrases about notes, not paths", () => {
  expect(describeStep("Read", { file_path: "/vault/Daily/2026-10-29.md" })).toBe("Reading 2026-10-29");
  expect(describeStep("Grep", { pattern: "launch\nplan" })).toBe("Searching “launch plan”");
  expect(describeStep("Skill", { skill: "work-log" })).toBe("Using work-log");
  expect(describeStep("StructuredOutput", {})).toBe("Writing the answer");
});

test("patterns read as words, and every step fits the box", () => {
  expect(describeStep("Grep", { pattern: "shed.*roof" })).toBe("Searching “shed roof”");
  expect(describeStep("Glob", { pattern: "**/*Lisbon*.md" })).toBe("Looking for Lisbon");
  expect(describeStep("Glob", { pattern: "**/*" })).toBe("Looking through notes");
  expect(describeStep("Grep", { pattern: "x".repeat(50) })).toHaveLength(24);
  expect(describeStep("Read", { file_path: `/v/${"y".repeat(60)}.md` })).toHaveLength(24);
});

test("failures read as a sentence, not Claude Code's stderr", () => {
  const said = (stderr: string, killed = false) => {
    const error = failure(stderr, killed);
    return [error.message, error.cause];
  };
  // A known failure is its headline alone; the raw text would only repeat it.
  expect(said("API Error: 529 Overloaded. The model is busy.")).toEqual(["Claude is busy right now", undefined]);
  expect(said("Invalid API key · Please run /login")).toEqual(["Claude Code isn't signed in", "Run claude in Terminal to sign in"]);
  expect(said("", true)).toEqual(["Claude took too long, so Jarvis stopped it", undefined]);
  // Anything else keeps Claude Code's words for the detail line.
  expect(said("Something new\nand more")).toEqual(["Claude stopped before it finished", "Something new\nand more"]);
  expect(said("")).toEqual(["Claude stopped before it finished", undefined]);
});
