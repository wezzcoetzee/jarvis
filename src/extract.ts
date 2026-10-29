import { z } from "zod";
import { runClaude } from "./claude";
import { owner } from "./config";

export const Proposal = z.object({
  title: z.string().describe('Short label for the meeting, e.g. "Huddle with Sam"'),
  followUps: z.array(
    z.object({
      task: z.string(),
      alreadyTracked: z.boolean().describe("True when an open todo already covers this action"),
    }),
  ),
  decisions: z.array(z.string()),
});
export type Proposal = z.infer<typeof Proposal>;

const SYSTEM = `You read a meeting transcript recorded by ${owner} (labelled "Me") and propose what they should capture in their notes.

- followUps: actions ${owner} committed to or needs to take. One imperative line each that names the person and the topic. Prefix the weekday when a day was said, resolving "tomorrow" from the meeting date (e.g. "Fri: speak to Sam about ..."). Skip actions owned by other people.
- alreadyTracked: true when one of their open todos already covers the same action.
- decisions: decisions actually agreed in the meeting, one line each, with the reason when it was stated. Skip opinions and open questions.
- Spell names the way the people list or the note's participants do, even when the transcript misspells them.
- Transcripts are noisy speech-to-text. Ignore filler, [BLANK_AUDIO] markers and lines repeated across speakers.
- Return empty lists when nothing is worth capturing.`;

type Context = { note: string; date: string; people: string; openTodos: string };

export async function extract({ note, date, people, openTodos }: Context): Promise<Proposal> {
  const weekday = new Date(`${date}T12:00:00`).toLocaleDateString("en-GB", { weekday: "long" });
  const prompt = [
    `Meeting date: ${weekday} ${date}`,
    `<people>\n${people || "(none)"}\n</people>`,
    `<open_todos>\n${openTodos || "(none)"}\n</open_todos>`,
    `<meeting_note>\n${note}\n</meeting_note>`,
  ].join("\n\n");

  // Strips settings, plugins, MCP and the default prompt (~60k tokens down to ~1k) but,
  // unlike --bare, still reads the keychain login, so it works under launchd.
  return runClaude(Proposal, prompt, {
    args: ["--tools", "", "--strict-mcp-config", "--setting-sources", "", "--disable-slash-commands", "--system-prompt", SYSTEM],
  });
}
