# Agent Instructions

**Read [CLAUDE.md](CLAUDE.md) first** — it contains the shared project rules. Everything in CLAUDE.md applies to all agents.

Below are additional instructions for non-Claude Code agents only.

# Writing Long Files

NEVER use `write_project_file` for long documents. ALWAYS use
`edit_project_file` to update chunk by chunk instead. The write tool WILL
truncate/corrupt long content. No exceptions.

# Skills

At the start of every conversation, discover available skills by running:
```
for f in $(find .claude/skills -name "SKILL.md"); do echo "==> $f <=="; awk '/^---$/{c++} c==1||c==2{print} c==2{exit}' "$f"; echo; done
```
This prints the YAML frontmatter (`name` and `description`) of each skill.

When a user's request matches a skill's description, read the full `SKILL.md`
before proceeding. Do not load skills that aren't relevant to the current task.
