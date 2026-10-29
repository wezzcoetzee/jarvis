import { expect, test } from "bun:test";
import { draft, parseDraft } from "./review";

const proposal = {
  title: "Huddle with Sam",
  followUps: [
    { task: "Fri: speak to Alex about the API naming", alreadyTracked: false },
    { task: "Ask Priya about the launch date", alreadyTracked: true },
  ],
  decisions: ["Ship the importer before the redesign"],
};

test("draft lists new todos and decisions, with tracked items as comments", () => {
  expect(draft(proposal)).toBe(
    [
      "[ ] Fri: speak to Alex about the API naming",
      "decision: Ship the importer before the redesign",
      "# already on your list: Ask Priya about the launch date",
    ].join("\n"),
  );
});

test("an untouched draft round-trips without the comments", () => {
  expect(parseDraft(draft(proposal))).toEqual({
    todos: ["Fri: speak to Alex about the API naming"],
    decisions: ["Ship the importer before the redesign"],
  });
});

test("lines typed by hand are todos; AppleScript's \\r separators are handled", () => {
  expect(parseDraft("- [ ] one\rtwo\r\rDecision: three")).toEqual({
    todos: ["one", "two"],
    decisions: ["three"],
  });
});
