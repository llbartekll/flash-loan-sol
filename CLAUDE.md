# CLAUDE.md

Guidance for Claude when working in this repository.

## Project Context
- This is a Solidity project using Foundry.
- Source contracts live in `src/`.
- Tests live in `test/`.
- Scripts live in `script/`.
- Dependencies are managed in `lib/`.

## Preferred Workflow
1. Read relevant files before editing.
2. Keep changes minimal and focused on the user request.
3. Preserve existing style and naming conventions.
4. Avoid modifying unrelated files.

## Commands
- Build: `forge build`
- Test: `forge test`
- Format: `forge fmt`
- Gas snapshot: `forge snapshot`

## Solidity/Foundry Notes
- Keep compiler and project settings aligned with `foundry.toml`.
- Prefer deterministic, isolated tests.
- Add/adjust tests when behavior changes.
- Avoid introducing breaking interface changes unless requested.

## Safety
- Do not commit secrets from `.env`.
- Do not run destructive git commands unless explicitly requested.
