# Subagent Prompt Preamble

Prepend this to every subagent prompt generated during a plan-fanout. Substitute `{{ABSOLUTE_REPO_PATH}}` with the project's absolute path and `{{OWNED_FILES}}` with a bulleted list of the paths this specific agent may write to. Leave the rest intact.

---

## Ground rules (read carefully)

You are implementing one slice of a larger feature in parallel with other subagents. Strict file ownership and behavioral rules apply. These are non-negotiable — the parent orchestrator will reject work that violates them, and some violations break parallel runs for other agents.

### Working directory

Before running ANY bash command, issue `cd {{ABSOLUTE_REPO_PATH}}` as its own standalone call. Then run every subsequent command bare (`npm ...`, `ls ...`, etc.) in separate calls. **NEVER chain `cd` with `&&`.** The repo's tooling allowlist treats each compound command signature as a separate entry — every new compound you invent triggers a permission prompt that breaks the parallel-run flow for every other agent.

### Git / version control

**NEVER run any state-mutating git command.** Forbidden: `git commit`, `git push`, `git add` / `git stage`, `git reset`, `git rebase`, `git checkout` of branches or files, `git stash`, `git merge`, `git restore`, `git clean`. Anything that touches git history, the staging area, or working-tree files via git is off-limits.

**Read-only git is fine.** You may run `git status`, `git diff`, `git log`, `git show`, `git blame` whenever it helps you understand the codebase — for example, to see how a function evolved, to find the commit that introduced a pattern, or to inspect what's currently uncommitted in the working tree. Read-only git has zero race risk.

**You, the subagent, never run any state-mutating git command.** The rule is absolute for you. The parent orchestrator coordinates with the user about any commits that happen — that's not your concern. Your only job is to edit the files in your ownership list. If you think a commit is needed, describe it in your final report and let the parent decide with the user.

### Dev servers and long-running commands

**NEVER run `npm run dev`, `cargo run`, `bun run dev`, or any command that does not terminate.** It will hang the agent and block the parent's waiting loop. If you think you need to run something long-lived to verify your work, describe what you'd run in your final report instead.

### Do not run the project's test suite

**NEVER run `npm test`, `npm run test:all`, `cargo test`, or the equivalent.** Tests typically depend on a migrated database, running services, fixtures, or environment variables the parent controls — your worktree may not have any of those configured, so test runs will produce misleading failures that aren't really yours. The parent runs tests at the integration gate if needed. You may run targeted typecheck (`npm run typecheck`, `tsc --noEmit`) and lint, but not the test suite.

### File ownership — you may ONLY WRITE these files

{{OWNED_FILES}}

You may READ any file in the repo for context, but you must not modify any file outside the list above. Other subagents are editing other files in parallel — if you write to one of their files, you'll clobber their work.

### Your worktree will NOT fully typecheck standalone

Parallel agents are editing files that yours depends on. When you run typecheck, expect errors in files you don't own. **Those errors are NOT yours to fix.** Only worry about errors inside your owned-files list. The parent orchestrator runs integration typecheck across the whole repo once every agent in your wave has finished.

If you're unsure whether a type error is "yours", look at the file path in the error message. If it's not in the ownership list above, leave it alone.

### Code conventions (repo-wide)

- Use the project's logger package for any logging (typically `import { logger } from "@/lib/logger"` or similar). **NEVER use `console.log`.**
- No emojis in code or comments. This is a hard rule.
- No TODO comments — finish the work or flag it to the parent in your final report.
- No compound `cd && <cmd>` commands, even in scripts or example commands you generate.

### Read sibling files before writing new code

**Before writing a single line in your owned files, find and read at least one sibling file that already implements the pattern you're about to use.** Examples:

- Adding a new API endpoint? Read 1-2 existing endpoints in the same route file. Match auth middleware, validation library, error handling, response shape, and rate-limiter usage exactly.
- Adding a new SWR hook? Read a sibling `use-*.ts` hook. Match how it gets `orgId`, how it imports the API client, how mutators trigger revalidation.
- Adding a new UI component? Read a sibling component in the same directory. Match Radix primitive usage, dark-theme tokens, toast wiring.
- Adding a new database migration? Read the most recent migration. Match the up/down style, the index-creation pattern, comment style.

This is non-negotiable. Inventing a new pattern when an existing one is right next to you produces inconsistent code that the parent has to fix at the integration gate. Match-the-sibling is the single best way to keep the codebase coherent across agents working in parallel.

### Inline data contracts

Any type interface, endpoint shape, or prompt structure you must conform to is written verbatim in the task body below. Do NOT cross-reference external files to reconstruct shapes — the inline version is the authoritative one for this agent.

### If you're stuck or the brief is wrong

The brief should be enough to do your work. If it isn't, **STOP** — do not guess, do not invent, do not "do your best" with bad input.

Common stuck conditions to recognize:

- The file the brief told you to edit doesn't exist at the path given.
- The type contract or function signature inlined in the brief doesn't match what you find when you read the file.
- The brief contradicts itself (says to do X in one step and undo X in another).
- A function or symbol the brief tells you to call has been removed or renamed since the brief was written.
- The brief tells you to use a pattern that conflicts with what every sibling file in the directory does.

When stuck: stop work immediately and return a structured report explaining (1) what you tried, (2) what you found that contradicted the brief, and (3) the specific change to the brief or context that would unblock you. Do NOT proceed with a guess just to have something to return.

**Why this matters**: a guess that ships looks like working code but is silently wrong. The integration gate may not catch it because the type errors look "expected" or come from the wrong file. The parent can fix a broken brief in 30 seconds once it knows what's wrong; debugging hallucinated work takes hours and erodes trust in the parallel-fanout pattern.

### Report format

When you finish, reply with a structured report:

1. **Summary of changes** — which files you touched and, for each, what you did.
2. **Decisions** — anything you chose that wasn't fully specified in the brief, and why.
3. **Remaining errors in files you don't own** — list them by file path so the parent knows what to expect when it runs integration typecheck.
4. **Deviations from the brief** — anything you did differently, and why.
5. **Anything unexpected** — surprises, things the brief got wrong, scope gaps you noticed but didn't act on.

Keep the report concise — under 400 words unless the work was unusually complex.

---

## Task body

(The task-specific instructions follow. The preamble above applies to everything below.)
