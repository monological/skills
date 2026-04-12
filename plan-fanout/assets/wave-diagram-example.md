# Wave diagram — Phase 4 presentation format

When you present the wave plan for user approval in Phase 4, render it as a vertical stack of ASCII boxes connected by arrows between waves. This file shows the canonical format, using the same fictional task-tags feature from `SKILL.md` Phase 2's dep-graph example so the vocabulary is consistent across the skill.

## Format rules

1. **One box per task.** Stacked vertically, full-width. **Never put multiple tasks as columns inside a single big box** — fixed-width columns force file paths to wrap on arbitrary boundaries (`generate-names-dialog.tsx` becomes `generate-/names-/dialog`) and the whole diagram becomes unreadable.

2. **Coupling rationale on the header line** after `──`. Don't bury it below the file list in a "Notes" or "Coupled:" section. Typical labels:
   - `── signature-coupled (route ↔ agent ↔ tests)` — merged because a type cascade spans files
   - `── parallel-safe, contract-scoped` — codes against a documented contract (hook, endpoint)
   - `── parallel-safe, file-disjoint` — no coupling, purely independent files
   - `── parallel-safe, separate helpers` — same *concept* as another agent but independent function signatures
   - `── parallel-safe, consumes hook from W1-C` — downstream of an earlier wave's output

3. **File list as bullets, full-width.** One file per line with a `• ` prefix. Optional right-side annotation in parentheses like `(new)` or `(add wand button)` or `(register the new route — trivial)`.

4. **Waves connected with `│` + `▼` arrows**, centered under the preceding box. A label like `W1 — 3 parallel background agents` sits between the arrow and the first box of the wave so the reader can see the boxes below belong to a single wave.

5. **W0 and the final gate are boxes too**, not special prose — keep the visual rhythm consistent from top to bottom so the reader's eye tracks the whole plan the same way.

6. **No arrows between tasks within the same wave.** W1-A, W1-B, W1-C all run in parallel; they don't feed each other. Only draw `│`/`▼` arrows BETWEEN waves, never within one.

## Worked example — task-tags multi-wave plan from Phase 2

This is the full Phase 4 presentation you would show the user for the task-tags plan (a task-management app gaining a tag system where each task can have multiple tags and one may be marked primary; two separate AI features consume the new concept through their own independent helpers).

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ W0 — main conversation (sequential)                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│ • lib/db/migrations/042_task_tags.ts                                  (new) │
│ • lib/db/types.ts                                          (register types) │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
                        W1 — 4 parallel background agents

┌─────────────────────────────────────────────────────────────────────────────┐
│ W1-A  CRUD endpoints        ── parallel-safe, file-disjoint                 │
├─────────────────────────────────────────────────────────────────────────────┤
│ • api/routes/tasks.ts                                                       │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│ W1-B  Copilot AI integration  ── signature-coupled (route ↔ agent ↔ tests)  │
├─────────────────────────────────────────────────────────────────────────────┤
│ • api/routes/copilot.ts                                                     │
│ • lib/copilot/agent.ts                                                      │
│ • tests/copilot-agent.test.ts                                               │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│ W1-C  SWR hook              ── parallel-safe, contract-scoped               │
├─────────────────────────────────────────────────────────────────────────────┤
│ • lib/hooks/use-task-tags.ts                                          (new) │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│ W1-D  Digest + email-composer agents  ── parallel-safe, separate helpers    │
├─────────────────────────────────────────────────────────────────────────────┤
│ • api/routes/digest.ts                                                      │
│ • lib/digest/agent.ts                                                       │
│ • api/routes/email-composer.ts                                              │
│ • lib/email-composer/agent.ts                                               │
│ • lib/email-composer/prompts.ts                                             │
│ • tests/email-composer.test.ts                                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
                        W2 — 2 parallel background agents

┌─────────────────────────────────────────────────────────────────────────────┐
│ W2-A  Task view section     ── parallel-safe, consumes hook from W1-C       │
├─────────────────────────────────────────────────────────────────────────────┤
│ • components/tasks/task-view.tsx                                            │
│ • components/tasks/tags-section.tsx                                   (new) │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│ W2-B  Copilot panel banner  ── parallel-safe, consumes hook from W1-C       │
├─────────────────────────────────────────────────────────────────────────────┤
│ • components/copilot/chat-panel.tsx                                         │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ Final gate — main conversation                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│ • tsc --noEmit          (filtered to touched files via grep recipe)         │
│ • prettier --check      (touched files only)                                │
│ • eslint                (touched files only)                                │
│ • git diff --stat HEAD  (handoff — no commit, user reviews and commits)     │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Common mistakes to avoid

- **Columns inside a single box.** The original anti-pattern. Three tasks side-by-side in one box force content to wrap on narrow columns and produce garbage like `lib/product/-name-ai/agent/.ts`. Always use one full-width box per task.
- **Coupling rationale in a "Notes:" or "Coupled:" section below the file list.** Makes the reader scroll into every box just to see if it's parallel-safe or merged. Put it on the header line so the user can scan grouping at a glance.
- **Arrows between tasks within a wave.** W1-A/B/C all run in parallel — they don't feed each other. Drawing arrows between them implies sequencing that isn't there. Arrows only between waves.
- **No wave label between the arrow and the first task box.** Without `W1 — 3 parallel background agents`, the reader can't tell if the three boxes below belong to one wave or three. Always include the label.
- **Mixing box-drawing styles.** Pick `─│┌┐└┘├┤` (light box-drawing) and stick with it. Don't mix in `═║╔╗╚╝` (double), rounded `╭╮╰╯`, or ASCII `-|+`. The widths don't line up and the result looks broken.
- **Including coupling detail like "Files: /  Coupled: /  Because:" inside the box body.** Keep box body to file list only. Everything else goes on the header line.
