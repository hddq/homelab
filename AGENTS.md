# Agent Guidelines

## Secrets & SOPS
- Never decrypt, read, inspect, dump, or print secrets.
- Never locate, read, or inspect private keys (`keys.txt`, `SOPS_AGE_KEY`, etc.).
- Forbidden commands include `sops -d` and `sops decrypt`.
- Only encrypt dummy/template values when scaffolding new files.
- Never decrypt files for verification. Ask the human operator to verify secret existence or structure.