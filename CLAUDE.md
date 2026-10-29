# Jarvis

Read README.md first. Its "Safety" section lists hard constraints:

- Never make Jarvis watch a path it writes to.
- Raw activity goes in `~/.local/share/jarvis/`, never the vault.
- Vault writes are append-only and follow the target note's existing format.
- Nothing about a particular vault goes in the code. Paths, names and private folders come from `~/.config/jarvis/config.json` (`src/config.ts`).
- `jarvis ask` gets no Bash, and every file access goes through `jarvis hook`. Changes there need a test against the hook (pipe a PreToolUse payload into `bun src/main.ts hook`).
- Test vault writes against a copy (`JARVIS_VAULT=/tmp/...`), never a real vault.
- Keep vault logic in the CLI. The Dock (`dock/`) only renders and shells out to it.
- Animations play once on change. Nothing may redraw at the display's refresh rate.

Checks: `bun run typecheck && bun test`, and `swift build --package-path dock`.
