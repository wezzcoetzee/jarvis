import { expect, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { paths } from "./config";
import { search } from "./search";

test("private folders stay out of results whatever their case or Unicode form on disk", async () => {
  await mkdir(join(paths.vault, "private"), { recursive: true });
  await Bun.write(join(paths.vault, "private/Salary.md"), "garden budget");
  await Bun.write(join(paths.vault, "Garden.md"), "garden budget");
  expect((await search("garden")).map((hit) => hit.path)).toEqual(["Garden.md"]);
});

test("a filename match ranks above a body match", async () => {
  await Bun.write(join(paths.vault, "Shed plan.md"), "wood and screws");
  await Bun.write(join(paths.vault, "Notes.md"), "the shed needs wood");
  expect((await search("shed")).map((hit) => hit.title)).toEqual(["Shed plan", "Notes"]);
});
