# Agent Guidelines

## Secrets & SOPS
- Never decrypt, read, inspect, dump, or print secrets.
- Never locate, read, or inspect private keys (`keys.txt`, `SOPS_AGE_KEY`, etc.).
- Forbidden commands include `sops -d` and `sops decrypt`.
- Only encrypt dummy/template values when scaffolding new files.
- Never decrypt files for verification. Ask the human operator to verify secret existence or structure.

## Commit Messages

Use Conventional Commits: `<type>(<scope>): <description>`. Use the most specific affected component as the lowercase scope; concise, unambiguous shortcuts are allowed (`pve`, `qbit`, `abs`, `tf`).

### Allowed Types
- `feat`: New feature, service, or capability.
- `fix`: Bug or configuration fix.
- `chore`: Routine maintenance, dependency updates, or housekeeping.
- `ci`: CI/CD workflows and automation.
- `docs`: Documentation changes.
- `refactor`: Refactoring code or configuration without behavioral changes.
- `revert`: Reverting a previous commit.

### Scopes
- K8s: use the application or infrastructure service name.
- Talos, Ansible, and Terraform: use `talos`, `ansible`, or `tf`, respectively.
- Nix: use `flake` for the root `flake.nix`; otherwise use the host name (for example, `vps0`).
- Scripts: use the script target (for example, `talos` or `backup`); use `scripts` only for general script-related changes.
- Documentation: use the specific doc or topic name (e.g., `agents`, `readme`).
- CI & Tooling: use the specific workflow target or tool (e.g., `k8s`, `lint`, `renovate`, `pre-commit`).
