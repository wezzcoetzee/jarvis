import { expect, test } from "bun:test";
import { describeStep, failure } from "./claude";

test("steps name notes and pattern words, not paths or regex, and fit the box", () => {
  expect(describeStep("Read", { file_path: "/vault/Daily/2026-10-29.md" })).toBe("Reading 2026-10-29");
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
  // Each known failure is its headline and what to do next, never Claude Code's own words.
  // Headlines have no full stop; the next step under each is a sentence and has one.
  expect(said("API Error: 529 Overloaded. The model is busy.")).toEqual(["Claude is busy right now", "Try again in a minute."]);
  expect(said("429 usage limit reached")).toEqual(["Claude's usage limit is reached", "Try again later, or edit it (⌘E) and press ⌘⏎ to put it in your Inbox."]);
  expect(said("Invalid API key · Please run /login")).toEqual(["Claude Code isn't signed in", "Run claude in Terminal to sign in."]);
  expect(said("", true)).toEqual(["Claude took too long, so Jarvis stopped it", "Try again, or ask for less at once."]);
  const offline = ["Can't reach Claude", "Check your connection, then try again, or edit it (⌘E) and press ⌘⏎ to put it in your Inbox."];
  for (const stderr of ["getaddrinfo ENOTFOUND api.anthropic.com", "connect ECONNREFUSED 127.0.0.1:8317", "TypeError: fetch failed", "Unable to connect to API", "Network error", "You appear to be OFFLINE"]) {
    expect(said(stderr)).toEqual(offline);
  }
  // The specific failures win over a network word in the same message.
  expect(said("529 overloaded (network)")[0]).toBe("Claude is busy right now");
  expect(said("429 rate limit, network busy")[0]).toBe("Claude's usage limit is reached");
  expect(said("401 not logged in, offline")[0]).toBe("Claude Code isn't signed in");
  expect(said("ETIMEDOUT", true)[0]).toBe("Claude took too long, so Jarvis stopped it");
  // Anything else keeps Claude Code's words for the detail line.
  expect(said("Something new\nand more")).toEqual(["Claude stopped before it finished", "Something new\nand more"]);
  expect(said("")).toEqual(["Claude stopped before it finished", undefined]);
});
