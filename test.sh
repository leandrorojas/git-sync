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
echo "gh-host:${GH_HOST:-}" >> "$GH_LOG.env"
[[ -n ${GH_TOKEN:-} ]] && echo "gh-token-from:${GH_TOKEN}" >> "$GH_LOG.env"
case "$1 $2" in
  "repo view") [[ -z ${GH_FAIL:-} ]] || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
               [[ -d $GH_REMOTES/$3.git ]] || { echo "GraphQL: Could not resolve to a Repository with the name '$3'." >&2; exit 1; };;
  "repo create") git init -q --bare "$GH_REMOTES/$3.git";;
esac
STUB
cat > bin/ssh <<'STUB'
#!/usr/bin/env bash
[[ $1 == -G ]] || exit 1
[[ $2 == gh-alias ]] && echo "hostname github.com" || echo "hostname $2"
STUB
cat > bin/az <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$AZ_LOG"
[[ -n ${AZURE_DEVOPS_EXT_PAT:-} ]] && echo "az-pat-from:${AZURE_DEVOPS_EXT_PAT}" >> "$AZ_LOG.env"
[[ -z ${AZ_FAIL:-} ]] || { echo "Please run 'az login' to setup account." >&2; exit 1; }
[[ $* != *"--project noproj"* ]] || { echo "TF200016: The following project does not exist: noproj." >&2; exit 1; }
shift; cmd=$1; shift
while [[ $# -gt 0 ]]; do
  case $1 in
    --repository|--name) repo=$2;; --project) proj=$2;; --organization) org=${2##*/};;
  esac; shift
done
case $cmd in
  show) [[ -d $AZ_REMOTES/$org/$proj/_git/$repo ]] ||
          { echo "TF401019: The Git repository with name or identifier $repo does not exist or you do not have permissions for the operation you are attempting." >&2; exit 1; };;
  create) git init -q --bare "$AZ_REMOTES/$org/$proj/_git/$repo"
          mkdir -p "$AZ_REMOTES_SSH/$org/$proj"; ln -s "$AZ_REMOTES/$org/$proj/_git/$repo" "$AZ_REMOTES_SSH/$org/$proj/$repo"
          [[ $proj != "$repo" ]] || ln -sfn "$AZ_REMOTES/$org/$proj/_git" "$AZ_REMOTES/$org/_git"
          [[ $proj == "${proj// /%20}" ]] || ln -sfn "$AZ_REMOTES/$org/$proj" "$AZ_REMOTES/$org/${proj// /%20}"
          [[ $proj == "${proj//&/%26}" ]] || ln -sfn "$AZ_REMOTES/$org/$proj" "$AZ_REMOTES/$org/${proj//&/%26}";;
esac
STUB
chmod +x bin/gh bin/ssh bin/az; export AZ_LOG=$t/az.log AZ_REMOTES=$t/azure AZ_REMOTES_SSH=$t/azure-ssh; export PATH=$t/bin:$PATH
export GIT_CONFIG_COUNT=7 GIT_CONFIG_KEY_0="url.$t/remotes/.insteadOf" GIT_CONFIG_VALUE_0="git@github.com:" \
  GIT_CONFIG_KEY_1="url.$t/nowhere/.insteadOf" GIT_CONFIG_VALUE_1="git@bitbucket.org:" \
  GIT_CONFIG_KEY_2="url.$t/remotes/.insteadOf" GIT_CONFIG_VALUE_2="https://github.com/" \
  GIT_CONFIG_KEY_3="url.$t/remotes/.insteadOf" GIT_CONFIG_VALUE_3="ssh://git@github.com:22/" \
  GIT_CONFIG_KEY_4="url.$t/remotes/.insteadOf" GIT_CONFIG_VALUE_4="git@gh-alias:" \
  GIT_CONFIG_KEY_5="url.$t/azure/.insteadOf" GIT_CONFIG_VALUE_5="https://dev.azure.com/" \
  GIT_CONFIG_KEY_6="url.$t/azure-ssh/.insteadOf" GIT_CONFIG_VALUE_6="git@ssh.dev.azure.com:v3/"
/bin/rm -rf "${GIT_SYNC_DIR:?}"

check "missing destination fails without --create" bash -c "! '$gs' '$t/src' git@github.com:me/new.git"
check "--create --dry-run creates nothing" bash -c "'$gs' --create --dry-run '$t/src' git@github.com:me/new.git && [[ ! -d '$t/remotes/me/new.git' ]] && ! grep -q 'repo create' '$t/gh.log'"
check "--create makes a private repo and syncs it" bash -c "'$gs' --create '$t/src' git@github.com:me/new.git && grep -q -- '--private' '$t/gh.log' && git -C '$t/remotes/me/new.git' show-ref --verify -q refs/heads/main"
check "--create --public makes a public repo" bash -c "'$gs' --create --public '$t/src' https://github.com/me/pub.git && grep -q -- '--public' '$t/gh.log'"
mkdir -p remotes/me/broken.git
check "--create does not recreate an existing unreadable repo" bash -c "! '$gs' --create '$t/src' git@github.com:me/broken.git && ! grep -q 'repo create me/broken' '$t/gh.log'"
check "--create --dry-run on an existing unreadable repo fails" bash -c "! '$gs' --create --dry-run '$t/src' git@github.com:me/broken.git"
check "--create accepts ssh:// URLs with a port" bash -c "'$gs' --create '$t/src' ssh://git@github.com:22/me/porturl.git && git -C '$t/remotes/me/porturl.git' show-ref --verify -q refs/heads/main"
check "--create resolves an SSH alias to github.com" bash -c "'$gs' --create '$t/src' git@gh-alias:me/aliased.git && git -C '$t/remotes/me/aliased.git' show-ref --verify -q refs/heads/main"
DEST_TOK=tok123 check "--create gives gh the destination token, not on argv" bash -c "'$gs' --create --dst-token-env DEST_TOK '$t/src' git@github.com:me/withtoken.git && grep -q 'gh-token-from:tok123' '$t/gh.log.env' && ! grep -q tok123 '$t/gh.log'"
check "--create --dry-run fails when gh cannot check the repo" bash -c "! GH_FAIL=1 '$gs' --create --dry-run '$t/src' git@github.com:me/gh-down.git"
check "--create does not create when gh cannot check the repo" bash -c "! GH_FAIL=1 '$gs' --create '$t/src' git@github.com:me/gh-down.git && [[ ! -d '$t/remotes/me/gh-down.git' ]]"
check "--create names the repo right for a .git/ URL" bash -c "'$gs' --create '$t/src' https://github.com/me/trailing.git/ && grep -q -- 'repo create me/trailing --private' '$t/gh.log'"
check "--create names the repo right for a scp URL with a leading slash" bash -c "'$gs' --create '$t/src' git@github.com:/me/slashed.git && grep -q -- 'repo create me/slashed --private' '$t/gh.log'"
check "--create refuses an empty --dst-token-env" bash -c "! env -u NO_SUCH_TOK '$gs' --create --dst-token-env NO_SUCH_TOK '$t/src' git@github.com:me/notok.git && ! grep -q 'repo create me/notok' '$t/gh.log'"
check "--create pins gh to github.com even when GH_HOST points elsewhere" bash -c "GH_HOST=ghe.corp.example '$gs' --create '$t/src' git@github.com:me/pinned.git && grep -q 'gh-host:github.com' '$t/gh.log.env' && ! grep -q 'ghe.corp.example' '$t/gh.log.env'"
printf '%s git@github.com:me/pair1.git\n%s git@github.com:me/pair2.git dst_token_env=PAIR_TOK\n' "$t/src" "$t/src" > create-pairs.txt
check "--create works from a pairs file, per-line token, and keeps reading the file" bash -c "PAIR_TOK=pairtok '$gs' --create -f '$t/create-pairs.txt' && git -C '$t/remotes/me/pair1.git' show-ref --verify -q refs/heads/main && git -C '$t/remotes/me/pair2.git' show-ref --verify -q refs/heads/main && grep -q 'gh-token-from:pairtok' '$t/gh.log.env'"
check "azure: --create makes the repo from an https URL" bash -c "'$gs' --create '$t/src' https://dev.azure.com/org1/proj1/_git/repo1 && git -C '$t/azure/org1/proj1/_git/repo1' show-ref --verify -q refs/heads/main && grep -q -- '--organization https://dev.azure.com/org1' '$t/az.log'"
check "azure: --create makes the repo from an ssh v3 URL" bash -c "'$gs' --create '$t/src' git@ssh.dev.azure.com:v3/org1/proj1/repo2 && git -C '$t/azure/org1/proj1/_git/repo2' show-ref --verify -q refs/heads/main"
check "azure: org/_git/repo URL uses the repo name as the project" bash -c "'$gs' --create '$t/src' https://dev.azure.com/org1/_git/solo && [[ -d '$t/azure/org1/solo/_git/solo' ]]"
check "azure: project name with %20 is decoded" bash -c "'$gs' --create '$t/src' 'https://dev.azure.com/org1/my%20proj/_git/spaced' && grep -q -- '--project my proj' '$t/az.log'"
check "azure: --dry-run creates nothing" bash -c "'$gs' --create --dry-run '$t/src' https://dev.azure.com/org1/proj1/_git/dry && [[ ! -d '$t/azure/org1/proj1/_git/dry' ]] && ! grep -q 'repos create --name dry' '$t/az.log'"
check "azure: --public is refused before any az call" bash -c "! '$gs' --create --public '$t/src' https://dev.azure.com/org1/proj1/_git/pub && [[ ! -d '$t/azure/org1/proj1/_git/pub' ]] && ! grep -q -- '--repository pub\\|--name pub' '$t/az.log'"
check "azure: a failing az is a FAIL, not a create" bash -c "! AZ_FAIL=1 '$gs' --create '$t/src' https://dev.azure.com/org1/proj1/_git/azdown && [[ ! -d '$t/azure/org1/proj1/_git/azdown' ]] && ! grep -q 'repos create --name azdown' '$t/az.log'"
check "azure: dry run does not claim a visibility" bash -c "'$gs' --create --dry-run '$t/src' https://dev.azure.com/org1/proj1/_git/dry2 | grep -q 'visibility: set by the project'"
check "azure: percent-encoded characters other than %20 are decoded" bash -c "'$gs' --create '$t/src' 'https://dev.azure.com/org1/R%26D/_git/enc' && grep -q -- '--project R&D' '$t/az.log' && git -C '$t/azure/org1/R&D/_git/enc' show-ref --verify -q refs/heads/main"
check "azure: a literal % in a name is passed to az unchanged" bash -c "'$gs' --create '$t/src' 'https://dev.azure.com/org1/proj1/_git/100%' && grep -q -- '--name 100% ' '$t/az.log'"
mkdir -p azure/org1/proj1/_git/azbroken
check "azure: an existing unreadable repo is not recreated" bash -c "! '$gs' --create '$t/src' https://dev.azure.com/org1/proj1/_git/azbroken && ! grep -q 'repos create --name azbroken' '$t/az.log'"
check "azure: an empty --dst-token-env is refused" bash -c "! env -u NO_SUCH_TOK '$gs' --create --dst-token-env NO_SUCH_TOK '$t/src' https://dev.azure.com/org1/proj1/_git/emptytok && ! grep -q 'repos create --name emptytok' '$t/az.log'"
check "azure: a legacy visualstudio.com URL is reported as unsupported" bash -c "! '$gs' --create '$t/src' https://org1.visualstudio.com/proj1/_git/legacy"
check "azure: a missing project says to create the project first" bash -c "'$gs' --create '$t/src' https://dev.azure.com/org1/noproj/_git/r 2>&1 | grep -q 'project must exist already'"
AZ_TOK=aztok check "azure: PAT reaches az through the environment, not argv" bash -c "'$gs' --create --dst-token-env AZ_TOK '$t/src' https://dev.azure.com/org1/proj1/_git/withpat && grep -q 'az-pat-from:aztok' '$t/az.log.env' && ! grep -q aztok '$t/az.log'"
check "--create on an unsupported host fails" bash -c "! '$gs' --create '$t/src' git@bitbucket.org:me/x.git"

echo "$pass passed, $fail failed"
exit $((fail > 0))
