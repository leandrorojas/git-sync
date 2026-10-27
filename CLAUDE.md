# git-sync

One bash script, `git-sync`, that copies a repo's full history to another repo and re-syncs incrementally. Goal: migrations between accounts or services, and backups. Tests: `./test.sh`.

## Guiding a migration
When I say "migrate <old url> to <new url>", or hand over a pairs file:
1. Confirm the destination repo exists and is empty. If it doesn't, offer `--create` (private; `--public` only if I say so; on Azure DevOps the project sets the visibility, and the project must already exist). It works for GitHub (through `gh`), Azure DevOps (through `az`, which needs the `azure-devops` extension), gitlab.com and bitbucket.org (through their APIs, which need a token via `--dst-token-env`: `api` scope on GitLab; on Bitbucket an access token, or an app password with `dst_user=`); for other hosts, ask me to create the repo.
2. Ask which credentials each side needs: SSH key path or token env var name, per side. Never ask me to paste a secret, and never put one in the pairs file or on a command line.
3. Run with `--dry-run` first, then for real. Report each line it prints. On a real run `ok` means every source ref was verified at the destination; a dry-run `ok` only says what was simulated (with `--create` and a missing destination, nothing is fetched or pushed).
4. A `FAIL` line says why. `--force` only after I agree: it allows a non-empty destination and overwriting rewritten history.
5. For a recurring sync, propose a cron line on the host that has both credentials; don't install it without asking.

## Traps
- Only git data moves, not issues, PRs, wikis or permissions. Say so before a migration.
- `--create` runs as the account the provider CLI is logged into (`gh`, `az`), or as the `--dst-token-env` token when one is given. That can differ from the SSH key used to push, and an exported `AZURE_DEVOPS_EXT_PAT` for another org is used too. Check `gh auth status` or `az account show` first.
- A repo created on Bitbucket lands in the workspace's oldest project; move it afterwards if that matters.
- The default branch of a new destination isn't set by the script.
- `--prune` deletes at the destination; without it, branches deleted at the source stay there.
- `pairs*.txt` and `*.pairs` are git-ignored because they list private URLs. The repo is public: keep real URLs and secrets out of it.
