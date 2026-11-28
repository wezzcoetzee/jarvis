import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { explain } from "./errors";

test("Jarvis's own errors pass through, with their cause as a detail that ends in a full stop", () => {
  expect(explain(new Error("Claude Code isn't installed", { cause: "Install it" }))).toEqual({
    message: "Claude Code isn't installed",
    detail: "Install it.",
  });
  expect(explain(new Error("Nothing", { cause: "Already a sentence!" })).detail).toBe("Already a sentence!");
  expect(explain(new Error("Plain")).detail).toBeUndefined();
  // A usage line is copied into a terminal, so it gets no full stop.
  expect(explain(new Error("x needs text", { cause: "Usage: jarvis x <text>" })).detail).toBe("Usage: jarvis x <text>");
});

test("a system error gets plain words and a next step, not its raw errno text", async () => {
  const error = await readFile("/nowhere/at/all.md").catch((e: unknown) => e);
  expect(explain(error)).toEqual({ message: "Couldn't find all.md", detail: "Check the path, then try again." });
  // Without a path there's no file to name.
  expect(explain(Object.assign(new Error("gone"), { code: "ENOENT" })).message).toBe("Couldn't find a file Jarvis needed");
  const denied = explain(Object.assign(new Error("no"), { code: "EACCES", path: "/v/Inbox.md" }));
  expect(denied).toEqual({ message: "macOS didn't let Jarvis open Inbox.md", detail: "Check the file's permissions, then try again." });
  expect(explain(Object.assign(new Error("full"), { code: "ENOSPC" })).detail).toBe("Free some space, then try again.");
  // A cause someone gave it wins over the stock step.
  expect(explain(Object.assign(new Error("no", { cause: "Move it back" }), { code: "ENOENT" })).detail).toBe("Move it back.");
});

test("reading a folder as a note says it isn't a note", () => {
  for (const code of ["EISDIR", "ENOTDIR"]) {
    expect(explain(Object.assign(new Error("x"), { code, path: "/v/Meetings" }))).toEqual({ message: "Meetings isn't a note", detail: "Choose a .md file." });
  }
  expect(explain(Object.assign(new Error("x"), { code: "EISDIR" })).message).toBe("That isn't a note");
});

test("anything else gets a plain headline, with its own words kept as the detail", () => {
  expect(explain(new TypeError("undefined is not an object"))).toEqual({
    message: "Something went wrong with that",
    detail: "undefined is not an object.",
  });
  expect(explain("boom")).toEqual({ message: "Something went wrong with that", detail: "boom." });
});
