# UX-4: Move ir.json Out of Output Directory

blocked_by: []
unlocks: [UX-9]

## Problem

`generateIR` writes `ir.json` (187KB) into the user-facing output directory alongside generated TypeScript files. It's an intermediate build artifact that doesn't belong there.

## Scope

Write `ir.json` to the cache directory instead:
- `~/.cache/plexus-codegen/synapse/ir/<backend>/ir.json`

Update `generateCode` to read from the new location. Update `writeCache` / `readIRPluginHashes` accordingly.

## Acceptance Criteria

- `./generated/` contains only TypeScript files, `package.json`, config, and `.codegen-metadata.json`
- `ir.json` lives under `~/.cache/plexus-codegen/synapse/ir/<backend>/`
- Pipeline still works end-to-end
