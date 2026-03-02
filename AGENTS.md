# AGENTS.md

Instructions for coding agents (including Codex) in this repository.

## Project Context
- Foundry-based Solidity project.
- Contracts: `src/`
- Tests: `test/`
- Scripts: `script/`
- Dependencies: `lib/`

## Working Rules
1. Read impacted files before changing anything.
2. Keep edits scoped to the request.
3. Follow existing code style and layout.
4. Do not touch unrelated files.
5. Prefer small, reviewable diffs.

## Validation Commands
- `forge build`
- `forge test`
- `forge fmt`
- `forge snapshot`

## Engineering Expectations
- Update or add tests for logic changes.
- Keep contract interfaces stable unless the task requires changes.
- Prefer explicit revert messages/custom errors over silent failures.
- Avoid unnecessary gas regressions in hot paths.

## Safety
- Never commit private keys or secrets.
- Treat `.env` as local-only.
- Avoid destructive commands (`git reset --hard`, force deletes) unless asked.
