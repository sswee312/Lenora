# Contributing

We welcome developers and editors to submit their skills and share with the community. You can submit a skill by creating a PR.

## SKILL.md

Create `<id>/SKILL.md`. The `<id>` (folder name) is the skill's stable id:
lowercase, hyphenated.

```markdown
---
name: color-grading
description: Color grade footage inside Lenora.
---

## Workflow
1. A concrete step using Lenora's tools (inspect_color, apply_color, …).
2. …

## Notes
- Gotchas, defaults, and things that are easy to get wrong.
```


## Writing a good skill

Follows Anthropic's skill best practice: https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices

## Submitting

1. Add your `<id>/SKILL.md`.
2. Run `node scripts/build-catalog.mjs` — it validates the frontmatter and
   regenerates `catalog.json`. Commit `catalog.json` along with your skill.
3. Open a PR. CI runs the same build and fails if the frontmatter is invalid or
   `catalog.json` is out of date.
4. Record a demo video or describe how you used the skills, and what did you create with it.

Contributions are accepted under the repository's [Apache-2.0](LICENSE) license.
