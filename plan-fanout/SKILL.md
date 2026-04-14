---
name: plan-fanout
description: Execute an approved plan or spec file by fanning out its tasks to parallel background subagents, orchestrated by a dependency graph. Use this whenever the user has a plan/spec markdown file and wants it implemented via parallel agents — triggers on "fan this out", "parallelize this plan", "run this plan with subagents", "execute this plan in parallel", "subagent fanout", "/plan-fanout", or when the user points at a `.md` plan/spec and asks to implement it in parallel. Also trigger when the user says things like "can you run this plan" or "implement this spec" if the plan is non-trivial enough to benefit from wave-based parallelization. Builds a dependency graph, groups tasks into parallel-safe waves, generates self-contained briefs for each agent, presents the wave plan for approval, then orchestrates wave-by-wave with integration gates between waves.
---

# plan-fanout

Execute an approved plan file by fanning its tasks out to parallel background subagents, with dependency-graph orchestration and integration gates between waves.

## When this skill applies

The user has a plan or spec markdown file — typically in `~/.claude/plans/`, `specs/`, or a path they give you — and wants the implementation work done in parallel by background agents rather than serially in the main conversation.

If the plan is trivial (one file, under ~30 lines of changes), don't fan out at all — just do it in the main conversation. The overhead of agent briefing + integration exceeds the savings.

## The core idea

Subagents have no shared context with the parent conversation, no shared CLAUDE.md awareness, and no shared bash cwd. Every agent prompt must be **self-contained** and every agent must have **strict, disjoint file ownership** so parallel runs can't stomp each other. The parent (you) runs integration typecheck between waves, decides when the next wave is safe to launch, and dispatches per-agent code reviews. **The parent does not *autonomously* run state-mutating git as part of the fanout workflow** — no auto-commits, no auto-stash between waves, no reset-on-failure — so the user can review the entire fanout as one coherent working-tree diff at the end. But if the user directly tells the parent to commit, stash, checkout, or do anything else with git, **just do it without hedging**: the user's explicit request IS the authorization.

The pattern is:

```
[Wave 0] Foundation (schema, types, shared contracts) — run in MAIN conversation, not a subagent.
   │
[Wave 1] Parallel tasks with disjoint file ownership — background agents, one per task.
   │
[Integration gate] Parent runs typecheck across the whole repo.
   │
[Wave 2] Parallel tasks that depend on Wave 1 outputs — background agents.
   │
[Final gate] Parent runs format + typecheck + lint. Fixes any cross-file drift.
```

## Phase 1 — Read and parse the plan

If no plan path was given, ask for one — do NOT auto-detect. Auto-detection is brittle and leads to running the wrong plan.

**Step 1: Read the plan yourself, quickly.** Just enough to understand the shape of what's being asked — how many tasks, what rough areas of the repo are involved, whether it's a 1-wave or multi-wave job. Don't try to extract every detail here.

**Step 2: Delegate the deep parse + scope-gap scan to an Explore subagent.** Explore is purpose-built for repo search and returns a curated brief instead of dumping raw grep output into main context. This matters because the orchestration work ahead needs a clean context window — you're going to fan out N parallel subagents and each one needs careful briefing. Every kilobyte of raw grep output you consume now is a kilobyte unavailable later.

Spawn ONE Explore agent with thoroughness `"medium"` and this brief (substitute the bracketed parts):

```
You are the reconnaissance phase of a plan-fanout. I need a curated brief, not raw output.

Plan file to analyze: [ABSOLUTE_PATH_TO_PLAN]
Repo root: [ABSOLUTE_PATH_TO_REPO]

Before running any bash command, issue `cd [ABSOLUTE_PATH_TO_REPO]` as its own standalone call, then run every subsequent command bare in separate calls. Never chain `cd && <cmd>`.

Your job:

1. Read the plan file fully.

2. For each implementation task the plan describes, produce a task record with:
   - **What changes**: a one-sentence description.
   - **Files touched**: exact absolute paths. If the plan names files vaguely ("the chat agent"), grep the repo to resolve them and report the exact paths.
   - **Type/contract changes**: any function signature, interface, exported type, or data shape that will change. Read the actual files — don't guess from the plan. Quote the current signature verbatim.
   - **Read-dependencies**: files this task must read for context (shared types, helper functions) even if it doesn't modify them.
   - **Depends on**: other tasks in this plan that must land first (e.g., "needs the new TaskTagsTable interface to exist").

3. **Scope-gap scan (this is the most valuable part).** For each key identifier the plan changes — type names, function names, interface fields, route paths, config keys — grep the repo for ALL occurrences. Report any usage that is NOT in the file set the plan mentions. Examples of what counts as a scope gap:
   - The plan updates `buildCopilotContext` but another file `buildDigestContext` has the same shape and reads the same fields.
   - The plan renames a type in types.ts but a test file or a sibling route still imports the old name.
   - The plan changes an API response shape but a hook in another directory still types against the old shape.
   For each scope gap, report: the identifier, the file(s) where usage was found, a one-line code snippet showing the usage, and whether it looks like a "must update" (same pattern, will break) or "might update" (related but could stay).

4. Also flag anything in the plan that's underspecified or inconsistent — e.g., "the plan mentions updating foo but doesn't name which file foo lives in", or "the plan says X is already in place but I couldn't find X in the repo".

Return a structured markdown brief:

## Tasks
1. [task name] — files: [...] — type changes: [...] — depends on: [...]
2. ...

## Scope gaps
- [identifier]: found in [file:line] — [snippet] — [must / might] update
- ...

## Plan issues
- [issue]

Keep the brief under 800 words. Do not include raw grep output or file contents beyond the short snippets in scope-gap rows.
```

**Step 3: Review the brief.** Read the Explore agent's report. If there are scope gaps marked "must update", surface them to the user during Phase 4 (approval). If there are "plan issues", resolve them with the user before proceeding.

Catching scope gaps here is free. Catching them mid-fanout (after agents have spawned) costs a whole integration pass and may force you to abort and re-brief in-flight agents.

## Phase 2 — Build the dependency graph

For each task, record:

- **File ownership set** (exact paths it will write to).
- **Read dependencies** (files it must read for context — shared types, helper functions — even if it doesn't modify them).
- **Blocks** (other tasks that can't start until this one lands).
- **Blocked by** (the inverse).

Then derive the blocking relationships. A task is blocked by another if:

- It imports a type that the other task creates.
- It calls a function whose signature the other task changes.
- It consumes a new route, endpoint, or hook that the other task defines.

**Read-deps don't block.** Read dependencies are tracked so that the agent's task body can include "you may need to read these for context" — but they do not contribute to wave grouping. Only writes do. Two tasks that both read the same shared type file can run in the same wave; only the task that *writes* to the shared file creates a blocking relationship.

### Worked example

The feature below is hypothetical — a task-management app gaining a tag system where each task can have multiple tags and one may be marked "primary". AI features read the primary tag as the canonical label. Two separate AI surfaces (a "copilot" assistant and a "digest" generator) consume the new tag concept through their own independent context-builder helpers; an "email composer" surface needs the same update.

Substitute your own stack mentally — the structure of the dep graph is what matters, not the specific files.

| Task | Writes to | Type changes | Blocked by |
|---|---|---|---|
| W0: Migration + Types | `migrations/042_task_tags.ts` (new), `lib/db/types.ts` | adds `TaskTagsTable`, `TaskTag` | — |
| W1-A: CRUD endpoints | `api/routes/tasks.ts` | — | W0 |
| W1-B: Copilot AI integration | `api/routes/copilot.ts`, `lib/copilot/agent.ts`, `tests/copilot-agent.test.ts` | `CopilotContext.taskTitle` → `primaryTag` + `tagsJson` (cascades through all 3 files) | W0 |
| W1-C: SWR hook | `lib/hooks/use-task-tags.ts` (new) | — (codes against documented endpoint contract) | — (parallel-safe with W1-A even though logically depends on its endpoints) |
| W1-D: Digest + email-composer agents | `api/routes/digest.ts`, `lib/digest/agent.ts`, `api/routes/email-composer.ts`, `lib/email-composer/agent.ts`, `lib/email-composer/prompts.ts`, `tests/email-composer.test.ts` | independent `TagsJson` shape duplicated inline (no cross-file signature) | W0 |
| W2-A: Task view section | `components/tasks/task-view.tsx`, `components/tasks/tags-section.tsx` (new) | — | W1-C |
| W2-B: Copilot panel banner | `components/copilot/chat-panel.tsx` | — | W1-C |

**Why W1-B is one agent and not three.** The `buildCopilotContext` return-type change cascades through all three files: `copilot.ts` defines the helper, `agent.ts` consumes it via `buildCopilotSystemPrompt`, and the test file calls both. Splitting these across three agents would produce a partial type cascade across agent boundaries — exactly what the signature-coupling rule prevents. *This is the canonical illustration of when "disjoint files" is not enough to justify splitting.*

**Why W1-D is a separate agent from W1-B even though both touch AI prompts.** `digest.ts` and `email-composer.ts` have their own context-builder helpers (`buildDigestContext`, `buildEmailComposerPrompt`) that share the *concept* of `TagsJson` but no actual function signature with the copilot helper. The type is duplicated inline in each file. No signature crosses the W1-B / W1-D boundary, so they parallelize cleanly.

**Why W1-C (the hook) doesn't wait for W1-A (the CRUD endpoints).** The hook codes against the *documented endpoint contract* (URL paths + request/response shapes), not the source code of the endpoints. As long as the contract is inlined verbatim in both prompts, the implementations can land in parallel and meet at runtime. This is a powerful pattern: any consumer that talks to a producer through a stable contract — REST, RPC, CLI, file format — can parallelize with its producer.

This worked example also demonstrates the read-dep concept: `lib/db/types.ts` is a read-dep for W1-A, W1-B, and W1-D, but W0 owns the writes. Once W0 finishes, none of W1-A/B/D need to wait on each other for type access — they just read the same file in parallel.

## Phase 3 — Group into parallel-safe waves

The rule is:

> **Two tasks can run in the same wave if and only if (1) their file ownership sets are disjoint AND (2) no changing type signature or shared function contract spans a boundary between them.**

This is the **signature-coupling rule**. When in doubt, merge.

Wave selection:

- **Wave 0**: schema migrations, foundational types, shared contracts. Usually small. Run this in the main conversation, not a subagent — the parent needs the concrete type shapes to brief wave 1 anyway, and spawning an agent for a 2-file change is pure overhead.
- **Wave 1, 2, …**: parallel groups, each wave respecting the rule above. A task in wave N may depend on tasks in waves < N but never on tasks in wave ≥ N.
- **Final gate**: parent runs `typecheck`, `lint`, `format` across the whole repo. Fixes any cross-file drift. This is a main-conversation step, never a subagent.

Also: check whether the task list includes anything that obviously belongs out-of-scope (e.g., test writing that depends on a not-yet-migrated DB). Flag these to the user and exclude them from fanout. The parent or the user runs them later.

## Phase 4 — Present the wave plan for approval

Before spawning any subagent, show the user:

1. **An ASCII dependency graph of the waves in the stacked-boxes format** — see `assets/wave-diagram-example.md` for the canonical template and a full worked example. Key rules, in short: one box per task stacked vertically (never columns inside a single big box — fixed-width columns force file paths to wrap on arbitrary boundaries and the diagram becomes unreadable); coupling rationale on the header line after `──`, not buried below the file list; file list as full-width bullets one-per-line; `│`/`▼` arrows between waves with a wave label like `W1 — 3 parallel background agents` sitting between the arrow and the first task box; no arrows between tasks within the same wave. The asset file has the full worked example you can copy the structure from.
2. Per-wave: the tasks, the files each one owns, and why they're grouped that way (especially merges enforced by the signature-coupling rule). This information is already in the diagram — step 2 just calls it out so the reader knows to look.
3. Any scope gaps you caught during Phase 1 parsing that the plan missed, so the user can decide whether to expand scope before you lock the graph.
4. Whether you recommend worktrees (almost always no — see "Worktrees" below).

Then use `AskUserQuestion` to get approval or corrections. Phrase the question as a choice between concrete options, not an open "does this look right?". Example: "Approve this wave plan as-is / Merge tasks X and Y into one agent / Skip task Z / Other changes (describe)".

**Do not skip this step** even if the plan looks obvious. The user's interactive correction at this step is the cheapest moment to catch missed scope — mid-fanout corrections are 10x more expensive because in-flight agents must be aborted or retroactively re-briefed.

### Handling user corrections

If the user approves the wave plan, proceed to Phase 5. If they correct it, the type of correction determines the response:

- **Merge waves or merge tasks.** Accept and re-derive the graph in your head. No re-spawn of any agent needed.
- **Split a task into multiple agents.** Re-derive the graph. **Apply the signature-coupling rule before splitting** — only split if the resulting agents have disjoint file ownership AND no shared changing type signature crosses the new boundary. If splitting would violate signature-coupling, push back on the user with the reason ("these two files are joined by a type cascade — splitting them will produce typecheck errors at integration") instead of silently accepting a split that will fail.
- **Skip a task entirely.** Remove it from the graph. Note the skipped scope in your final wave plan so the user remembers what was deferred and you don't accidentally include it later.
- **Expand scope (add files / agents not in the original plan).** This is the highest-risk correction. **Re-spawn the Phase 1 Explore agent with the expanded identifier list before locking the graph.** The new identifiers may reveal new scope gaps or new signature coupling that the original Explore pass missed. Do not shortcut this — scope expansion mid-Phase-4 is exactly the kind of thing that produces broken integration runs because the orchestrator skipped re-discovery.

**After ANY correction, re-present the new wave plan** (ASCII graph + per-wave breakdown + scope-gap status if anything was rediscovered) and ask for approval again via `AskUserQuestion`. Don't act on the first correction without confirming the resulting shape — the user may want to refine further once they see the new graph. This is cheap (one more `AskUserQuestion`) and prevents cascading miscommunication where you act on a half-formed change.

## Phase 5 — Generate subagent prompts

Use `assets/prompt-skeleton.md` as the structural template — it includes both a placeholder skeleton and a worked example using the same fictional task-tags feature from Phase 2's dep graph. The two-part structure of every assembled prompt is:

1. **Preamble** — paste `assets/preamble.md` verbatim, substituting `{{ABSOLUTE_REPO_PATH}}` and `{{OWNED_FILES}}`. Same preamble for every agent in every fanout.
2. **Task body** — feature context, type contracts inlined verbatim, line-numbered edit instructions, verification step. The skeleton file shows the section structure and a fully-filled illustrative example.

**Inline type contracts verbatim in every prompt that needs them** — don't reference the plan or spec file. If two agents share a type, both prompts must have identical inline copies. See Phase 2's worked example for why this matters.

**Be explicit about required vs optional in briefs.** If you label something "optional, skip if complex", expect variance — the model may or may not implement it depending on the run. If you actually want it, say "required" or "implement this." Reserve "optional" for things you genuinely don't care about.

**Tests often share helper/base objects.** When writing the task body for an agent that touches tests, tell it to grep for shared `base`/`baseParams`/`helperParams` patterns — updating the shared object once cascades to every call site. This is a huge time-saver. Don't assume the agent will find this pattern on its own; tell it explicitly to look.

## Phase 6 — Execute wave-by-wave

### Set up the task list BEFORE the first wave

The task list is the user's primary progress signal during a long-running fanout. They see it update live as waves progress. Set it up once, upfront, so the full dep graph is visible from the start.

**CRITICAL: Every task MUST be explicitly marked `completed` via `TaskUpdate` the moment its work is finished.** Do not forget this. Do not batch it. Do not assume the user will infer completion from context. If an agent finishes and its review passes, call `TaskUpdate(task, completed)` before moving on. If you skip this, the task list misrepresents state — the user sees stale `in_progress` entries, can't tell what's actually done, and loses the ability to interrupt intelligently. A forgotten `completed` marker is a correctness bug in the orchestration loop, not a cosmetic oversight.

1. **Before fanning out the first wave**, create a `TaskCreate` entry for EVERY task in the full wave plan across all waves. Use descriptive labels like `"W1-A: CRUD endpoints in tasks.ts"` not just `"Task 1"`. (If your environment doesn't have a structured task-tracking tool, skip this — the wave plan in your own context is sufficient. The task list is purely a user-visibility feature.)
2. **Wire dependencies with `addBlockedBy`** so the task list mirrors the graph. A Wave 2 task should be `blockedBy` its Wave 1 dependencies. The user can then see what's unblocked at a glance.
3. **Add a final task** for the integration gate (`"Final: format + typecheck + lint"`) and set `addBlockedBy` to every wave task. This visualizes the completion fence.
4. **Mark W0 `in_progress`** and execute it in the main conversation (not a subagent). Mark it `completed` when done.

### For each parallel wave

1. **Dispatch the entire wave in a SINGLE assistant response** using parallel tool_use blocks. This is the critical move of the whole skill — get it wrong and the wave serializes. In ONE response, emit:
   - One `TaskUpdate(..., in_progress)` call per wave task (so the task list reflects live dispatch state).
   - One `Agent(...)` call per wave task with `run_in_background: true` and `isolation` unset (no worktree), passing the assembled prompt.

   All of these are tool_use blocks inside the same assistant message. Order within the message doesn't matter — they execute in parallel. The response ends after the last tool_use block and you wait for the first agent's completion notification.

   **Correct pattern** — one response containing all the wave's dispatches:
   ```
   TaskUpdate(W1-A, in_progress)
   TaskUpdate(W1-B, in_progress)
   TaskUpdate(W1-C, in_progress)
   Agent(subagent_type: "general-purpose", prompt: <W1-A brief>, run_in_background: true)
   Agent(subagent_type: "general-purpose", prompt: <W1-B brief>, run_in_background: true)
   Agent(subagent_type: "general-purpose", prompt: <W1-C brief>, run_in_background: true)
   ```

   Symptom that this went wrong: the task list shows multiple tasks as `in_progress` but the runtime's "N local agents" counter shows fewer. That means you marked them in_progress but never dispatched them — emit all Agent calls in one response.

2. **Do not poll**. You will receive a completion notification automatically for each agent as it finishes. Go do something useful in the interim (draft the next wave's prompts, work on an unrelated concern the user has, write a quick checklist). If you find yourself tempted to "check on" the agents, don't — you'll get notified.
3. **As each agent completes**, do NOT immediately mark its task completed. Instead run the per-agent code review (next subsection) first. Then **explicitly call `TaskUpdate(task, completed)`** — do not skip this step, do not defer it to "later", do not assume it's implicit. The marker must be set the moment the review passes and any fixes are applied.
4. **After ALL agents in the wave finish AND all per-agent reviews are done**, run the integration gate script from the main conversation. From the directory containing `package.json` (project root, or `web/` in a monorepo):

   ```bash
   bash ~/.claude/skills/plan-fanout/assets/fanout-gate.sh
   ```

   The script builds the touched-files list (modified vs HEAD, excluding deletions, plus untracked new files, cwd-relative so monorepo subdirs work), detects which of prettier / tsc / eslint are installed in `node_modules`, and runs whichever are present. Prettier and eslint run against the touched-files list only. Tsc runs against the whole project **unfiltered** — filtering to touched files would hide regressions in untouched consumers (e.g. a wave changes an exported type and the error surfaces in a file the wave didn't touch). Pre-existing tsc errors will show up; the orchestrator triages. See `assets/fanout-gate.sh` for the source.

   Optionally also run `git diff --stat HEAD` at this point to eyeball the cumulative scope and confirm nothing unexpected landed — a cheap sanity check that often catches scope creep you'd otherwise only notice at the final gate.
5. If typecheck finds errors, **fix them yourself in the main conversation** — don't spawn another agent for small drift. The parent is always the right place for cross-file integration fixes.
6. Only then move to the next wave.

### Per-agent code review (after each agent completes, before marking the task done)

Every successful subagent gets a code review scoped strictly to its owned files. The review catches issues the integration typecheck won't see (architectural problems, contract drift, missed sibling patterns, scope creep) and stops them from compounding into the next wave.

Use the bundled reviewer template at `assets/code-reviewer.md`. It is a file-list-scoped variant of the standard code-reviewer template — give it the agent's `OWNED_FILES` list and it will only look at those files, even though other agents in the same wave have uncommitted changes elsewhere in the working tree.

**Per-agent review flow:**

1. Read the agent's report carefully. If it failed (per the error-recovery rules below), handle the failure first — do NOT review a failed agent.
2. **Run the per-agent precheck script** on the agent's owned files. Run from the directory containing `package.json`:

   ```bash
   bash ~/.claude/skills/plan-fanout/assets/agent-precheck.sh <owned-file-1> <owned-file-2> ...
   ```

   Pass file paths as literal positional args from the brief. The script auto-formats with prettier (`--write`) and lint-checks with eslint (report-only, no `--fix`). Fix anything it flags in main before dispatching the reviewer. See `assets/agent-precheck.sh` for details.

3. Open `assets/code-reviewer.md`. Substitute the placeholders:
   - `{{FILES_TO_REVIEW}}` — space-separated list of the agent's owned files (verbatim from the brief you sent it).
   - `{{ABSOLUTE_REPO_PATH}}` — the project root.
   - `{{WHAT_WAS_IMPLEMENTED}}` — one sentence describing what this agent built (pull from its report or your brief).
   - `{{DESCRIPTION}}` — 2-3 sentences with more detail.
   - `{{PLAN_REFERENCE}}` — short pointer back to the plan file or wave-level intent (e.g. "Wave 1 of the task-tags feature in plans/task-tags.md").
4. Dispatch the filled template via the `Agent` tool (or `Task` — whichever your environment uses for spawning subagents) with `subagent_type: "general-purpose"`. Pass the entire filled template as the agent's prompt. Set `run_in_background: false` — you want this review's verdict before moving on. **Do not specify a specialized reviewer subagent type.** The bundled `assets/code-reviewer.md` template is the specialization: it contains the full review checklist, output format, scoping rules, and plan-fanout-specific checks. A general-purpose subagent following this template produces a valid review without any external dependency. This is why the template lives in the skill — to keep the skill self-contained.
5. **Read the verdict** when the review returns and **fix everything that makes sense to fix**, regardless of severity:
   - **Critical or Important issues**: fix them yourself in the main conversation, then call `TaskUpdate(task, completed)`. Do not spawn another agent — the original agent has already returned and re-spawning to fix small issues is wasteful. The parent has full context.
   - **Minor issues**: fix them too if it's a quick change (most are). A type inconsistency, a missing null check, a stale comment — these take 30 seconds to fix now and accumulate into real debt if deferred. The default should be "fix it" not "skip it". Only defer a minor issue if fixing it would require disproportionate effort relative to its impact (e.g., a large-scale naming consistency sweep that's better done as its own task). Then call `TaskUpdate(task, completed)`.
   - **No issues / Ready to integrate**: call `TaskUpdate(task, completed)` and move on.

   **In all three branches above, the `TaskUpdate(task, completed)` call is mandatory.** It is the single most-forgotten step in the loop. Make it the last thing you do for an agent before moving to the next one.
6. If you fixed Critical or Important issues yourself, optionally re-run the review on the same file list to confirm. Use judgment — for a 2-line fix this is overkill, for a substantive rework it's worth the round-trip.

**Why scope to file list**: other agents in the same wave have uncommitted changes elsewhere in the working tree, so a naive `git diff` review would pollute THIS agent's verdict with findings about other agents' files. `assets/code-reviewer.md` enforces the scope inside the reviewer prompt itself — see that file for the exact guardrail language.

**When to skip the per-agent review entirely**:
- The agent failed and is being respawned — review the respawn, not the failed attempt.
- The agent's task was a single mechanical edit (e.g., bumping a version number, adding a single import). Use judgment.
- The user has explicitly said they want to skip code reviews for this fanout (rare; only honor if explicit).

**Note**: per-agent reviews are sequential and add wall-clock time. This is intentional — correctness over speed. Skip only if the user explicitly asks.

### Error recovery — when an agent fails or the gate finds problems

The happy path assumes every wave agent succeeds and integration typecheck is clean. In practice, things go wrong. Here's how to handle each failure mode without aborting the whole fanout.

#### Partial wave failure: one agent fails, others succeed

A wave agent can fail in several ways: it errors out, it returns a "couldn't complete" report, it produces obviously broken output, or its summary reveals it misunderstood the brief. Meanwhile, the other agents in the wave finished cleanly.

**Do NOT roll back the successful agents.** Their work is locked in. Wave parallelism is asymmetric on purpose — some agents finish faster than others, and accepting partial progress is the whole reason fanout is faster than serial execution.

Instead:

1. Read the failing agent's report carefully. Distinguish two root causes:
   - **Brief problem**: the brief was missing context, named the wrong file, gave the wrong type contract, or omitted a step. The agent did its best with bad input.
   - **Work problem**: the brief was correct, but the task itself turned out harder than expected — maybe the file had a structure the brief didn't anticipate.
2. **Brief problem → respawn one agent with a corrected brief.** Re-use the preamble and the working parts of the original task body; fix the part that was wrong. Inline any context the original brief was missing. Do not re-spawn the agents that already succeeded.
3. **Work problem → do the failed task yourself in the main conversation.** Spawning a fresh agent with the same brief usually produces the same failure. The parent has the full context and can investigate the underlying difficulty in a way a fresh agent cannot.
4. Update the failing agent's task entry to `in_progress` if respawning, or `completed` once you've done the work in main.
5. Only run the integration typecheck once the failed task is actually resolved (by either path).

#### Integration-gate failure after a wave

`npm run typecheck` (or the equivalent) finds N errors after a wave completes. Triage by error count and pattern:

- **Small drift (1–5 errors, scattered across files)**: the most common failure. Usually one agent's signature change wasn't perfectly propagated to a caller in another agent's file, or someone used `let` where TS now wants `const`. **Fix in main.** Don't spawn an agent for trivial drift — the round-trip cost outweighs any benefit, and you have full context already.
- **Concentrated failure (10+ errors all in one file owned by one agent)**: that agent botched its task. Read the agent's summary and the file to understand what they did. If the fix is small, do it in main. If the file is largely wrong, re-spawn a fresh agent with a sharper brief and explicit "the previous attempt had these problems: …".
- **Systematic failure (every agent's files have the same kind of error)**: you missed something in the preamble or in the task bodies — every agent followed the same broken instructions. Fix in main, then update the preamble or your prompt template so the next fanout doesn't repeat the mistake. This is the most valuable kind of failure to learn from.

Lint errors and format errors are almost always "small drift" — fix in main.

#### When to escalate to the user instead of recovering

Most failures are recoverable by the parent. Escalate when:

- The plan itself was wrong (the file paths don't exist, the type the plan describes isn't what's in the repo, the feature doesn't make sense once you actually look at the code). At that point you're not implementing the plan anymore, you're rewriting it — that needs the user's input.
- A respawn fails the same way the original did, and you don't have a clear theory why. Don't burn three agents on the same failing brief.
- The user's intent has shifted under your feet — for example, the integration-gate failure reveals that the spec misunderstood an existing system in a way that needs a design discussion.

When escalating, keep the successful agents' work in place. Tell the user exactly what broke, what you tried, and what decision you need from them. Don't undo work that succeeded just because something else failed.

### End-of-fanout final gate

Run the same gate script one more time against the full cumulative working-tree state:

```bash
bash ~/.claude/skills/plan-fanout/assets/fanout-gate.sh
```

This catches cross-wave drift and anything the per-agent prechecks or reviewers missed. If the script exits non-zero, fix errors in main. If it reports "no touched files", the fanout produced no changes — investigate before proceeding (every agent may have no-oped due to a bad brief). **Do not commit** — the user commits manually after reviewing the full diff at handoff.

### Handoff to the user

When the final gate passes, you're done. **Do not commit.** Present a summary to the user:

1. **Total waves run** and a one-line description of each wave's work.
2. **Agents dispatched** — a count and their task titles.
3. **Files touched** — run `git diff --stat HEAD` and paste the output verbatim so the user sees the scope at a glance.
4. **Outstanding issues** — any Minor-severity review findings you deliberately left for later, any scope the user deferred, any parts of the plan you could not complete.
5. **Next action** — tell the user: "All work is in your working tree, uncommitted. Review the diff with `git diff HEAD` and commit when you're satisfied. If you want me to make further changes first, tell me now."

6. **Brief learnings** — if the same error appeared across multiple agents or across re-runs (e.g., a recurring lint error, an import the brief forgot to exclude), note it here so the user can bake it into the brief for future fanouts. Recurring errors are brief gaps, not bad luck.

This handoff is the end of the orchestrator's turn. The user takes over from here.

## Critical rules (baked in from hard-won experience)

Put these in the preamble and repeat them in the task body if the agent is likely to trip on them.

1. **Never chain `cd` with `&&` in bash commands.** Every agent prompt must include: "Before running any bash command, issue `cd /absolute/path` as its own standalone call, then run every subsequent command bare in separate calls." Subagents do NOT have access to the CLAUDE.md rule that forbids compound commands — you must state it per prompt. Violating this causes repeated permission prompts that break the flow.

2. **Two-tier git rule — absolute for agents, "no autonomous decisions" for the parent.**

   **Agents (hard rule)**: NEVER run any state-mutating git command. Forbidden for agents: `git commit`, `git push`, `git add` / `stage`, `git reset`, `git rebase`, `git checkout` (branches or files), `git stash`, `git merge`, `git restore`, `git clean`. This is absolute because agents operate without direct human oversight and can race on the git index when multiple wave agents run concurrently. Read-only git (`status`, `diff`, `log`, `show`, `blame`) is freely available to agents — zero race risk, useful for self-orientation.

   **Parent orchestrator (softer rule)**: Do not *autonomously* run state-mutating git as part of the fanout workflow. That means: don't add commits between waves, don't stash files automatically, don't reset on failure, don't do git gymnastics as part of the normal orchestration loop. The default end-state of a fanout is "working tree has all the fanout's changes uncommitted, user reviews the full diff, user commits manually." This keeps the entire fanout reviewable as one coherent diff.

   **But the parent IS still the user's assistant.** If the user directly asks you to do a git thing — stash, commit, amend, checkout, whatever — **just do it**. No hedging, no citing this rule, no second confirmation. **Autonomous = no; user-directed = yes.**

3. **Never tell a subagent to run a dev server** (`npm run dev`, `cargo run`, etc.) or any command that doesn't terminate. It will hang the agent.

4. **Explicitly tell the agent its worktree will not fully typecheck standalone.** Without this reassurance, agents waste effort chasing errors in files outside their ownership. The correct framing: "Errors in files you don't own are NOT yours to fix. Focus only on your owned files."

5. **Inline type contracts, don't reference them.** If two agents need to produce/consume the same `TagsJson` shape, both prompts must spell out the type verbatim. Do not write "see the plan". The plan may not even be readable from the agent's context.

6. **Repeat repo conventions verbatim in every prompt**: logger not console.log, no emojis in code, Radix primitives not native HTML form elements, etc. The preamble handles the universal ones; the task body handles anything specific to the file the agent is editing (e.g., "use the existing `useToast` from `@/components/ui/toast`").

7. **Signature-coupling rule (see Phase 3)**: if a type signature change cascades across files, those files belong to ONE agent, not several — even if the file paths are "disjoint".

## Worktrees

Default: **do not use worktrees.** Parallel same-repo agents can coexist safely as long as:

- Their file ownership sets are strictly disjoint.
- None of them runs a command that mutates global repo state (`npm install`, migrations, codegen, lockfile updates, `git add`/`commit`/etc. — see rule 2 in Critical rules for the full list).

Given those constraints, file writes to different paths are isolated at the OS level. Worktree isolation adds overhead for no benefit.

Use worktrees only when:

- The agent will run a command that mutates `node_modules`, lockfiles, or generated code (e.g., codegen).
- The agent needs to run the project's test suite (which may write artifacts).
- The user explicitly asks for isolation.

When worktrees ARE used, pass `isolation: "worktree"` on the `Agent` tool call. Note that the completion notification will include the worktree path, and the parent is responsible for either merging the branch back or deleting the worktree — neither of which is done automatically.

## Anti-patterns

Do NOT:

- **Emit one `Agent` call per assistant response.** All `Agent` calls for a single wave MUST be in the same response as parallel tool_use blocks alongside the `TaskUpdate(in_progress)` calls. One-per-response serializes the wave (each response ends and waits for that agent's notification before you can dispatch the next) and defeats the entire point of plan-fanout. See Phase 6 "For each parallel wave" step 1 for the correct vs wrong patterns. Symptom that this went wrong: the task list shows multiple `in_progress` but the runtime's "N local agents" counter shows fewer.
- Give multiple agents write access to the same file (race condition).
- Tell agents to "follow the spec" without inlining the relevant shapes.
- Autonomously run state-mutating git in the parent orchestrator (auto-commit between waves, auto-stash, auto-reset) — the fanout's default end-state is "working tree dirty, user commits manually". BUT: if the user directly asks you to run git, comply without hedging. See Critical rule 2 for the two-tier split.
- Skip the approval step in Phase 4.
- Run typecheck DURING a wave — it's meaningless while agents are mid-flight and wastes cache.
- Assume the plan is complete without scanning for scope gaps in Phase 1.
- Use worktrees by default — only when mutation of global repo state requires isolation.
