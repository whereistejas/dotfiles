---
name: doc-writing
description: Write or rewrite a document meant for humans to read — a design doc, plan, explainer, story or proposal — so it reads as one story, in plain prose, short, and checked for facts and logical consistency. Use when asked to write, rewrite, explain or document something in a Markdown file for people (not for an agent or a machine), or when told the prose "has degraded", is "dry" or "abrupt".
---

# Writing documents for humans

A document is for a person who is new to the subject. It has to tell them one story, in
plain words, and everything in it has to be true. Those three things matter most, and they
are repeated below on purpose.

## The three rules

1. **Tell one story.** Every section, paragraph and table builds towards one complete,
   cohesive understanding. The reader should feel each part leading to the next. Nothing
   sits on its own.
2. **Introduce things when they are needed.** Each concept, assumption, fact, requirement
   and prerequisite appears at the point the reader first needs it — never before, never
   after it is used.
3. **Write simple, direct, human prose.** Plain words, short sentences, active voice. No
   flourishes, no clever phrasing. Not dry either: a list of facts with no connecting
   sentences reads as abrupt. Connect the facts so they flow.

And: **keep it short.** Say each thing once. Cut what the story does not need.

## Before writing

- Collect all the facts first, from the code and the sources. Read the code paths in full,
  not samples.
- Never present a guess, a document's intent or a plan's aspiration as fact.
- Decide the story: where the reader starts, what they must understand at the end, and the
  order of steps between.
- If the document explains code, cover every type and code path it claims to describe. A
  story that skips paths is incomplete.

## While writing

- **Tell one story.** Open with what the document is about and why it matters. Then build:
  facts, then assumptions, then concepts, each resting on what came before.
- **Introduce things when they are needed.** Define every term the first time it appears.
  If a reader would ask "what is X?" — a field, a mode, a tag, a "level 1", "the two
  engines" — the document has failed to define X.
- **Write simple, direct, human prose.** One point per sentence and per list item.
- Describe the subject, not the document. No "this document first…", no account of how it
  was researched or written.
- Code in the document must be as easy to read as the prose. Explain what each snippet
  shows; rewrite comments that only make sense to the author.
- Use diagrams where a flow, a structure or a timeline is easier to see than to read
  (Mermaid, rendered to SVG when asked).
- Link sources inline where the text relies on them, and list them at the end.
- When updating a document, fold new material into the existing story. Merge or replace
  sections instead of appending new ones at the end.

## Check in separate passes

Do these as separate passes, in this order. Do not merge them.

1. **Facts.** Check every statement against the code and the cited sources. Fix anything
   wrong or overstated.
2. **Facts again.** Check the facts you collected and the fixes you made in pass 1.
3. **Logical consistency.** Read the whole document for statements that contradict each
   other, or several statements that claim different untruths. Compare sections,
   paragraphs and tables with each other, not only with the code.
4. **The story.** Re-read it as a newcomer. Does it build towards one picture? Is each
   thing introduced when needed? Is the prose simple, direct and human, and short?

After a prose rewrite, confirm nothing factual changed: every identifier, number,
reference and link is still there.

Report what you corrected, as a short list with the evidence for each fix. If writing the
document exposed gaps or mistakes in the design or code it describes, say so separately.

## Workflow

- Put the document in a new jj commit. Don't push unless asked.
- Keep the report to the user short.

## Final checklist

- [ ] It tells one story that builds towards a cohesive understanding.
- [ ] Every concept, assumption, fact, requirement and prerequisite is introduced when
      first needed, and every term is defined.
- [ ] The prose is simple, direct and human — not dry, not abrupt, no flourishes.
- [ ] It is short.
- [ ] Facts checked, twice.
- [ ] Logical consistency checked across the whole document.
- [ ] It describes the subject, not itself.
