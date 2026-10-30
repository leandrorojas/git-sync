# git-sync

Copies a repo's full history (all branches and tags) to another repo, on any git host, and keeps it in sync.
Re-running transfers only what changed. For migrating a repo between accounts or services, and for backups.

```
./git-sync [--dry-run] [--force] [--prune] [--create [--public]] [--dst-prefix P] <source-url> <dest-url>
./git-sync [options] -f pairs.txt
```

Usage, pairs-file format, credentials and exit codes are in the header of `./git-sync`. Tests: `./test.sh` (local repos only).

Several sources can share one destination repo with `--dst-prefix P` (or `dst_prefix=P` per pair in a pairs file): source branch `main` lands as `P/main` and tag `v1` as `P/v1`, with the full history and the same commits. Each source is a set of branches, not a folder of the checkout.

Only git data moves. Issues, PRs, wikis, CI config and permissions don't.
