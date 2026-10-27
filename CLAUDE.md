# git-sync

One bash script, `git-sync`, that copies a repo's full history to another repo and re-syncs incrementally. Goal: migrations between accounts or services, and backups. Tests: `./test.sh`.

## Guiding a migration
When I say "migrate <old url> to <new url>", or hand over a pairs file:
1. Confirm the destination repo exists and is empty. If it doesn't, offer `--create` (private; `--public` only if I say so). It works for GitHub (through `gh`) and Azure DevOps (through `az`, which needs the `azure-devops` extension); for other hosts, ask me to create the repo.
2. Ask which credentials each side needs: SSH key path or token env var name, per side. Never ask me to paste a secret, and never put one in the pairs file or on a command line.
3. Run with `--dry-run` first, then for real. Report each line it prints. On a real run `ok` means every source ref was verified at the destination; a dry-run `ok` only says what was simulated (with `--create` and a missing destination, nothing is fetched or pushed).
4. A `FAIL` line says why. `--force` only after I agree: it allows a non-empty destination and overwriting rewritten history.
5. For a recurring sync, propose a cron line on the host that has both credentials; don't install it without asking.

## Traps
- Only git data moves, not issues, PRs, wikis or permissions. Say so before a migration.
- `--create` runs as the account `gh` is logged into, which can differ from the SSH key or token used to push. Check `gh auth status` first.
- The default branch of a new destination isn't set by the script.
- `--prune` deletes at the destination; without it, branches deleted at the source stay there.
- `pairs*.txt` and `*.pairs` are git-ignored because they list private URLs. The repo is public: keep real URLs and secrets out of it.
