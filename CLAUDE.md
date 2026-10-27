# git-sync

One bash script, `git-sync`, that copies a repo's full history to another repo and re-syncs incrementally. Goal: migrations between accounts or services, and backups. Tests: `./test.sh`.

## Guiding a migration
When I say "migrate <old url> to <new url>", or hand over a pairs file:
1. Confirm the destination repo exists and is empty. If it doesn't, offer `--create` (private; `--public` only if I say so; on Azure DevOps the project sets the visibility, and the project must already exist). It works for GitHub (through `gh`), Azure DevOps (through `az`, which needs the `azure-devops` extension), gitlab.com and bitbucket.org (through their APIs, which need a token via `--dst-token-env`, `api` scope on GitLab; Bitbucket's credential setup is under Traps); for other hosts, ask me to create the repo.
2. Ask which credentials each side needs: SSH key path or token env var name, per side (a Bitbucket API token needs more than a token; see Traps). Never ask me to paste a secret, and never put one in the pairs file or on a command line.
3. Run with `--dry-run` first, then for real. Report each line it prints. On a real run `ok` means every source ref was verified at the destination; a dry-run `ok` only says what was simulated (with `--create` and a missing destination, nothing is fetched or pushed).
4. A `FAIL` line says why. `--force` only after I agree: it allows a non-empty destination and overwriting rewritten history.
5. For a recurring sync, propose a cron line on the host that has both credentials; don't install it without asking.

## Traps
- Only git data moves, not issues, PRs, wikis or permissions. Say so before a migration.
- `--create` runs as the account the provider CLI is logged into (`gh`, `az`), or as the `--dst-token-env` token when one is given. That can differ from the SSH key used to push, and an exported `AZURE_DEVOPS_EXT_PAT` for another org is used too. Check `gh auth status` or `az account show` first.
- On GitLab a dry run with `--create` checks that the token can read and that the group exists, not that it may create a repo there; a read-only token fails only on the real run.
- Bitbucket credentials: an access token works as is. An API token needs `dst_api_user=<account email>` and `dst_user=x-bitbucket-api-token-auth` (for a Bitbucket source, `src_user=` with the same name); that git user name is unconfirmed (third-party docs only), so say so if it fails. App passwords no longer work.
- A repo created on Bitbucket lands in the workspace's oldest project; move it afterwards if that matters.
- On Bitbucket a dry run with `--create` only checks that the token can read: it can't tell a missing workspace from a missing repo, and it doesn't check that the token may create one.
- GitLab protects the default branch of a new project, so `--force` on it is rejected until force push is allowed in the project settings.
- A destination that looks missing may be an existing repo the credentials can't see (GitHub, GitLab, Bitbucket and Azure answer "not found" for both). `--create` then fails on the real run with an already-exists error, and a dry run can't predict it.
- The default branch of a new destination isn't set by the script.
- `--prune` deletes at the destination; without it, branches deleted at the source stay there.
- `pairs*.txt` and `*.pairs` are git-ignored because they list private URLs. The repo is public: keep real URLs and secrets out of it.
