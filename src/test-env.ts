// Preloaded by `bun test` (see bunfig.toml), before any module reads the config.
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const root = mkdtempSync(join(tmpdir(), "jarvis-test-"));
for (const dir of ["config", "vault", "state"]) mkdirSync(join(root, dir));
writeFileSync(join(root, "config/config.json"), JSON.stringify({ private: ["Private"] }));

process.env.JARVIS_CONFIG = join(root, "config");
process.env.JARVIS_VAULT = join(root, "vault");
process.env.JARVIS_STATE = join(root, "state");
