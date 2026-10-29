import { expect, test } from "bun:test";
import { insertInSection, section } from "./vault";

const daily = `# Thu 29 Oct 2026

## Todo

- [ ] first
- [x] second

## Done (closed PM)

- [x] shipped`;

test("appends after the last item of a section, before the next heading", () => {
  expect(insertInSection(daily, "## Todo", ["- [ ] new"], "end")).toBe(`# Thu 29 Oct 2026

## Todo

- [ ] first
- [x] second
- [ ] new

## Done (closed PM)

- [x] shipped`);
});

test("prepends straight under the heading for newest-on-top logs", () => {
  const log = "## Entries\n- 2026-10-28 · #pr · old";
  expect(insertInSection(log, "## Entries", ["- 2026-10-29 · #decision · new"], "start")).toBe(
    "## Entries\n- 2026-10-29 · #decision · new\n- 2026-10-28 · #pr · old",
  );
});

test("replaces the empty-section placeholder", () => {
  const inbox = "# Inbox\n\n## Items\n\n_(nothing yet)_\n";
  expect(insertInSection(inbox, "## Items", ["- item"], "end")).toBe("# Inbox\n\n## Items\n\n- item\n");
});

test("returns null when the heading is missing", () => {
  expect(insertInSection(daily, "## Nope", ["x"], "end")).toBeNull();
});

test("section reads one section's body", () => {
  expect(section(daily, "## Todo")).toBe("- [ ] first\n- [x] second");
});
