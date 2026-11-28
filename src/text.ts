/** One leading bullet or checkbox (`- [ ] x`, `- x`, `* x`, `+ x`, `[x] x`) dropped, so a pasted todo isn't doubled. Numbers stay. */
export const stripListMarker = (text: string) => text.replace(/^(?:[-*+](?:\s+|$))?(?:\[[ xX]\](?:\s+|$))?/, "");

/**
 * Untrusted text (a page title, an app name, a meeting title Claude read off a transcript) as one
 * short plain line. No control characters or newlines, and none of `<>[]|`, so it can't close a
 * prompt's `<context>` block, add lines to a note or break out of a `[[link|title]]`.
 */
export const oneLine = (text: string, max: number) =>
  text
    .replace(/[\p{Cc}<>[\]|]/gu, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, max);
