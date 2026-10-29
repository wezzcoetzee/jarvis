import { expect, test } from "bun:test";
import { describeStep } from "./claude";

test("tool calls read as short phrases about notes, not paths", () => {
  expect(describeStep("Read", { file_path: "/vault/Daily/2026-10-29.md" })).toBe("Reading 2026-10-29");
  expect(describeStep("Grep", { pattern: "launch\nplan" })).toBe("Searching for “launch plan”");
  expect(describeStep("Skill", { skill: "work-log" })).toBe("Using work-log");
  expect(describeStep("StructuredOutput", {})).toBe("Writing the answer");
});

test("long phrases are clipped so they fit the box", () => {
  expect(describeStep("Grep", { pattern: "x".repeat(50) })).toHaveLength(37);
});
