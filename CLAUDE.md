# Project Rules

## Commit Rules
- NEVER add "Co-Authored-By" lines to any commit message
- NEVER include Claude's name or attribution in commits
- Keep commit messages clean — just the message, nothing else
- On every commit: bump VERSION file (patch for fixes, minor for features), run `./scripts/build-release.sh`, and create a git tag before pushing

## Content Rules
- NEVER use this text anywhere: "Press 's' three times to toggle. Invisible on Zoom, Meet, Teams, OBS, and all screen recording."
- Do not include marketing taglines in commit messages or descriptions
