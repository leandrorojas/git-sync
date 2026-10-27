#!/usr/bin/env bash
# Runs git-sync against local repos. No network, no credentials.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
gs=$here/git-sync
t=$(mktemp -d); trap '/bin/rm -rf "${t:?}"' EXIT
export GIT_SYNC_DIR=$t/cache GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
cd "$t" || exit 1
pass=0; fail=0
check() { # description, command...
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $d"; fi
}
refs() { git -C "$1" for-each-ref --format='%(refname)' | tr '\n' ' '; }
same_main() { [[ $(git -C "$1" rev-parse main) == $(git -C "$2" rev-parse main) ]]; }

git init -q -b main src; (cd src && echo one > f && git add f && git commit -qm c1 && git tag -a v1 -m v1 && git branch feat)
git init -q --bare dst.git; git init -q -b main empty; git init -q --bare other.git

check "dry run leaves destination empty" bash -c "'$gs' --dry-run '$t/src' '$t/dst.git' && [[ -z \$(git -C '$t/dst.git' for-each-ref) ]]"
check "first sync copies branches and tags" bash -c "'$gs' '$t/src' '$t/dst.git' && [[ '$(echo refs/heads/feat refs/heads/main refs/tags/v1) ' == \"\$(git -C '$t/dst.git' for-each-ref --format='%(refname)' | tr '\n' ' ')\" ]]"

(cd src && echo two >> f && git commit -qam c2)
check "incremental sync picks up new commit" bash -c "'$gs' '$t/src' '$t/dst.git'" && check "dest main equals source main" same_main src dst.git

(cd src && git commit -q --amend -m rewritten)
check "rewritten history is rejected without --force" bash -c "! '$gs' '$t/src' '$t/dst.git'"
check "rewritten history passes with --force" "$gs" --force "$t/src" "$t/dst.git"
check "dest main equals rewritten source main" same_main src dst.git

(cd src && git branch -D feat -q)
"$gs" "$t/src" "$t/dst.git" >/dev/null 2>&1
check "deleted branch stays without --prune" bash -c "git -C '$t/dst.git' show-ref --verify -q refs/heads/feat"
"$gs" --prune "$t/src" "$t/dst.git" >/dev/null 2>&1
check "deleted branch is removed with --prune" bash -c "! git -C '$t/dst.git' show-ref --verify -q refs/heads/feat"

/bin/rm -rf "${GIT_SYNC_DIR:?}"
check "non-empty destination refused on a first sync" bash -c "! '$gs' '$t/src' '$t/dst.git'"
check "non-empty destination adopted with --force" "$gs" --force "$t/src" "$t/dst.git"

check "empty source fails" bash -c "! '$gs' '$t/empty' '$t/other.git'"
check "unreadable source fails" bash -c "! '$gs' '$t/missing' '$t/other.git'"

printf '# comment\n\n%s %s\n%s\n%s %s bogus=1\n' "$t/src" "$t/other.git" "$t/src" "$t/src" "$t/other.git" > pairs.txt
check "pairs file: bad lines fail the run" bash -c "! '$gs' -f '$t/pairs.txt'"
check "pairs file: good line still synced" bash -c "git -C '$t/other.git' show-ref --verify -q refs/heads/main"

# --create, with a stub gh and github.com/bitbucket.org URLs rewritten to local folders
mkdir -p bin remotes; export GH_LOG=$t/gh.log GH_REMOTES=$t/remotes
cat > bin/gh <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$GH_LOG"
case "$1 $2" in
  "repo view") [[ -d $GH_REMOTES/$3.git ]];;
  "repo create") git init -q --bare "$GH_REMOTES/$3.git";;
esac
STUB
chmod +x bin/gh; export PATH=$t/bin:$PATH
export GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0="url.$t/remotes/.insteadOf" GIT_CONFIG_VALUE_0="git@github.com:" \
  GIT_CONFIG_KEY_1="url.$t/nowhere/.insteadOf" GIT_CONFIG_VALUE_1="git@bitbucket.org:" \
  GIT_CONFIG_KEY_2="url.$t/remotes/.insteadOf" GIT_CONFIG_VALUE_2="https://github.com/"
/bin/rm -rf "${GIT_SYNC_DIR:?}"

check "missing destination fails without --create" bash -c "! '$gs' '$t/src' git@github.com:me/new.git"
check "--create --dry-run creates nothing" bash -c "'$gs' --create --dry-run '$t/src' git@github.com:me/new.git && [[ ! -d '$t/remotes/me/new.git' ]]"
check "--create makes a private repo and syncs it" bash -c "'$gs' --create '$t/src' git@github.com:me/new.git && grep -q -- '--private' '$t/gh.log' && git -C '$t/remotes/me/new.git' show-ref --verify -q refs/heads/main"
check "--create --public makes a public repo" bash -c "'$gs' --create --public '$t/src' https://github.com/me/pub.git && grep -q -- '--public' '$t/gh.log'"
mkdir -p remotes/me/broken.git
check "--create does not recreate an existing unreadable repo" bash -c "! '$gs' --create '$t/src' git@github.com:me/broken.git && ! grep -q 'repo create me/broken' '$t/gh.log'"
check "--create on an unsupported host fails" bash -c "! '$gs' --create '$t/src' git@bitbucket.org:me/x.git"

echo "$pass passed, $fail failed"
exit $((fail > 0))
