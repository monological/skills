# Subagent Prompt Skeleton

This file shows what an assembled subagent prompt looks like during a plan-fanout. Two parts:

1. **Placeholder template** — the structural skeleton with `{{...}}` placeholders. Use this when assembling a new prompt.
2. **Example assembled prompt (illustrative)** — a fully-filled version using a fictional "task tags" feature, matching the worked example in `SKILL.md` Phase 2. The feature and identifiers are illustrative; substitute your own.

Both parts assume the preamble in `assets/preamble.md` is prepended before the task body. The preamble carries the universal rules (cwd, git rules, no-dev-server, no-test-suite, owned-files-only, sibling-file-reading, stuck handling, report format). The task body adds feature-specific context, type contracts, edits, and verification.

---

## Part 1 — Placeholder template

```
{{paste full contents of assets/preamble.md, with these substitutions:
   - {{ABSOLUTE_REPO_PATH}}  → the project's absolute path
   - {{OWNED_FILES}}         → bulleted list of paths this agent may write to}}

## Context

{{3-5 sentences. What feature is being implemented and why. Wave-level
context, not just this agent's slice — the agent should understand the
overall goal so it can make sensible judgment calls when the brief
underspecifies a detail.}}

## Type contracts (inlined verbatim)

{{Any type interfaces, endpoint shapes, JSON structures, or prompt
blocks the agent must conform to. NEVER write "see the spec" — paste
the actual shape here. If two agents in this wave share a type, both
prompts MUST have identical inline copies. Drift across copies causes
integration-time type errors.}}

## Edit instructions (numbered)

1. {{File: ABSOLUTE_PATH
    Around line N (or "the X function near the top of the file")
    Current state: ...
    Change to: ...
    Why: ...}}
2. {{...}}

## Verification

From {{cwd path, e.g. "the project's web/ subdir"}}, run `{{typecheck command}}`.
Expect errors in files outside your ownership list — those are NOT
yours to fix. Goal: zero type errors in your owned files.

(Report format is already specified in the preamble — the agent
follows it without further instruction.)
```

---

## Part 2 — Example assembled prompt (illustrative)

Below is what a fully-assembled W1-A-style brief looks like in practice for the fictional task-tags feature from `SKILL.md` Phase 2. The feature and identifiers are fictional; substitute your own when generating prompts.

Note especially:

- The verbatim type-shape inlining (`TaskTag` interface pasted in full).
- The line-numbered edit instructions.
- The explicit verification step.
- The report-format reference back to the preamble.

The preamble at the top is shown abbreviated for readability — in a real prompt you would paste the entire `assets/preamble.md` contents with substitutions made.

```
{{...preamble from assets/preamble.md, with substitutions:
   ABSOLUTE_REPO_PATH = /Users/example/projects/taskapp
   OWNED_FILES        = - api/routes/tasks.ts
}}

## Context

We're adding a tag system to a task-management web app. Each task can have
multiple tags; one tag may be marked "primary" so AI features can use it as
the canonical label for that task. A new database table `task_tags` was
added by an earlier wave, and the corresponding `TaskTag` type is now
exported from `lib/db/types.ts`. Your job is the CRUD layer: add HTTP
endpoints under the existing tasks route so the frontend can read, create,
update, select, and delete tag rows for a task.

## Type contracts (inlined verbatim)

The new type already exists in `lib/db/types.ts`:

    export interface TaskTagsTable {
      id: Generated<number>;
      task_id: number;
      name: string;
      notes: string | null;
      is_primary: ColumnType<boolean, boolean | undefined, boolean>;
      created_at: Generated<Date>;
      updated_at: Generated<Date>;
    }
    export type TaskTag = Selectable<TaskTagsTable>;

A partial unique index enforces "at most one primary tag per task":

    CREATE UNIQUE INDEX task_tags_one_primary_per_task
      ON task_tags (task_id) WHERE is_primary = TRUE

You do NOT need to recreate this index — it ships with the migration. Your
endpoint logic must respect it: when marking one tag as primary, first
clear `is_primary` on any sibling row that already had it, then set the
target row in the same transaction.

## Edit instructions (numbered)

Add the following endpoints to `api/routes/tasks.ts`. Place them as a
group after the existing `DELETE /:orgId/tasks/:taskId` handler near the
end of the file (around line 200 — confirm by reading the file first;
match the file's existing route order and style exactly).

| Method | Path | Behavior |
|---|---|---|
| GET    | `/:orgId/tasks/:taskId/tags`                  | List tags for a task, ordered `is_primary DESC, created_at DESC`. Return `{ tags: TaskTag[] }`. 404 if the task doesn't belong to the org. |
| POST   | `/:orgId/tasks/:taskId/tags`                  | Create a new tag. Body: `{ name: string (trimmed, 1..255), notes?: string \| null (max 2000) }`. Never auto-marks as primary. Return the created row. |
| PATCH  | `/:orgId/tasks/:taskId/tags/:tagId`           | Update `name` and/or `notes`. Does NOT touch `is_primary`. 404 if the tag doesn't belong to the given task. Bump `updated_at`. Return the updated row. |
| POST   | `/:orgId/tasks/:taskId/tags/:tagId/select`    | Mark this tag primary. Run inside `db.transaction().execute(async trx => { ... })`: first UPDATE all sibling rows SET `is_primary = false`, then UPDATE the target SET `is_primary = true`. Return the updated row. |
| POST   | `/:orgId/tasks/:taskId/tags/unselect`         | Clear `is_primary` from whichever tag for this task is currently primary. Idempotent. Return `{ ok: true }`. |
| DELETE | `/:orgId/tasks/:taskId/tags/:tagId`           | Delete the tag. No auto-promote — if the deleted tag was primary, the task simply ends up with no primary tag. Return `{ deleted: true }`. |

**Before you write code, read the existing endpoints in `api/routes/tasks.ts`**
(per the preamble's "read sibling files" rule). Match: auth middleware,
validation library, error response shape, rate-limiter usage, 404 handling,
and the file's existing imports. Do not invent new patterns.

Add any new validation schemas inline at the top of the new route group.
If the project keeps schemas in a sibling file (e.g. `lib/schemas.ts`),
mention it in your report but don't edit that file — schemas can be moved
in a follow-up.

## Verification

From the project's `web/` subdirectory (or wherever `npm run typecheck`
lives — check the project's package.json), run:

    npm run typecheck

Expect errors in files outside your ownership list (other agents in this
wave are editing the AI integration files in parallel). Those errors are
NOT yours to fix. Goal: zero type errors in `api/routes/tasks.ts` itself.

Do NOT run `npm test` or `npm run dev` — see the preamble.

(Report format already specified in the preamble. Follow it.)
```

---

## How to use this file

When generating a prompt for a new fanout:

1. Start by copy-pasting the **placeholder template** above.
2. Fill in the preamble at the top by pasting `assets/preamble.md` and making the two substitutions.
3. Fill in the four task-body sections (Context, Type contracts, Edit instructions, Verification).
4. Compare against the **example** to make sure the level of concreteness matches — especially the verbatim type-shape inlining and the line-numbered edits.
5. Spawn the agent with the assembled prompt as its only input. Set `run_in_background: true`.

Do not be tempted to abbreviate the type contracts section to save tokens. Drifted contracts across parallel agents are the single most expensive failure mode of fanout — verbatim inlining is the cheap fix.
