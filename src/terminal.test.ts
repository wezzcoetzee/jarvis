import { expect, test } from "bun:test";
import { describeAsk, describeCapture, describeQueued, describeSave, describeSkip } from "./terminal";

test("what a person at a terminal reads names where it went and how to undo it", () => {
  expect(describeCapture("Inbox.md")).toBe("Added to Inbox.md. Undo: jarvis undo --last");
  expect(describeSave(["Daily/2026-11-02.md", "Work Log.md"])).toBe("Saved to Daily/2026-11-02.md, Work Log.md. Undo: jarvis undo --last");
  // Nothing written means no run, so no undo to offer.
  expect(describeSave([])).toBe("Nothing to save");
  expect(describeSkip("2026-11-02 1430 Zoom")).toBe("Skipped 2026-11-02 1430 Zoom");
  expect(describeQueued("Zoom")).toBe("Queued “Zoom”: review it in the Dock");
});

test("an ask reads as its headline and detail; only a save offers undo, only a find lists notes", () => {
  const notes = [{ path: "Projects/Apollo.md", title: "Apollo" }];
  expect(describeAsk({ kind: "saved", message: "Logged the release", detail: "", notes })).toBe("Logged the release\nUndo: jarvis undo --last");
  expect(describeAsk({ kind: "found", message: "Found 1 note", detail: "", notes })).toBe("Found 1 note\nApollo (Projects/Apollo.md)");
  expect(describeAsk({ kind: "answer", message: "Two meetings today", detail: "- 10:00 Standup\n- 14:00 Review", notes })).toBe(
    "Two meetings today\n- 10:00 Standup\n- 14:00 Review",
  );
  expect(describeAsk({ kind: "question", message: "Which Apollo?", detail: "", notes: [] })).toBe("Which Apollo?");
});
