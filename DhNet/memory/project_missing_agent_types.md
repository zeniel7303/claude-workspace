---
name: project-missing-agent-types
description: "CLAUDE.md mandates code-architecture-reviewer/refactor-planner/etc. agents that aren't registered as subagent_type in this environment"
metadata: 
  node_type: memory
  type: project
  originSessionId: 2b03da2d-d7ea-4028-8d50-b1153b2de3d5
---

CLAUDE.md's RULE 2 mandates running `Agent(subagent_type="code-architecture-reviewer")` after any C++/C# code edit, but this environment's actual available agent types are only: `claude`, `claude-code-guide`, `Explore`, `general-purpose`, `Plan`, `statusline-setup`. `code-architecture-reviewer` (and likely `refactor-planner`, `documentation-architect`, `plan-reviewer` from CLAUDE.md's ".claude/ 인프라 시스템" section) do not exist as registered subagent types here.

**Why:** Confirmed twice across sessions — calling `Agent(subagent_type="code-architecture-reviewer")` fails with "Agent type not found."

**How to apply:** When RULE 2 triggers, use `Agent(subagent_type="general-purpose", ...)` instead, and embed the code-architecture-reviewer persona/checklist directly in the prompt (explain it's acting as a senior reviewer, list exactly which files changed and what to check). Don't waste a turn retrying the named type — go straight to the general-purpose workaround.
