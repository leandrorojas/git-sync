# git-sync

Copies a repo's full history (all branches and tags) to another repo, on any git host, and keeps it in sync.
Re-running transfers only what changed. For migrating a repo between accounts or services, and for backups.

```
./git-sync [--dry-run] [--force] [--prune] <source-url> <dest-url>
./git-sync [options] -f pairs.txt
```

Usage, pairs-file format, credentials and exit codes are in the header of `./git-sync`. Tests: `./test.sh` (local repos only).

Only git data moves. Issues, PRs, wikis, CI config and permissions don't.
