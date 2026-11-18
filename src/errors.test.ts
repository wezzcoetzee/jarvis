import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { explain } from "./errors";

test("Jarvis's own errors pass through, with their cause as the detail", () => {
  expect(explain(new Error("Claude Code isn't installed", { cause: "Install it" }))).toEqual({
    message: "Claude Code isn't installed",
    detail: "Install it",
  });
});

test("a system error gets plain words, keeping its own as the detail", async () => {
  const error = await readFile("/nowhere/at/all.md").catch((e: unknown) => e);
  const { message, detail } = explain(error);
  expect(message).toBe("Couldn't find a file Jarvis needed");
  expect(detail).toContain("ENOENT");
});

test("anything else gets a plain headline rather than a stack of jargon", () => {
  expect(explain(new TypeError("undefined is not an object"))).toEqual({
    message: "Something went wrong with that",
    detail: "undefined is not an object",
  });
  expect(explain("boom")).toEqual({ message: "Something went wrong with that", detail: "boom" });
});
