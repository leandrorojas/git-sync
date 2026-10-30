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
case $2 in gh-alias) echo "hostname github.com";; gl-alt) echo "hostname altssh.gitlab.com";; bb-alt) echo "hostname altssh.bitbucket.org";; *) echo "hostname $2";; esac
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
cat > bin/curl <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$GL_LOG"
[[ -z ${GL_NET_DOWN:-} ]] || exit 7
url=; method=GET; tok=; data=; bearer=; basic=
while IFS= read -r line; do
  case $line in
    'url = "'*) url=${line#url = \"}; url=${url%\"};;
    'request = "'*) method=${line#request = \"}; method=${method%\"};;
    'header = "PRIVATE-TOKEN: '*) tok=${line#header = \"PRIVATE-TOKEN: }; tok=${tok%\"};;
    'data = "'*) data=${line#data = \"}; data=${data%\"};;
    'header = "Authorization: Bearer '*) bearer=${line#header = \"Authorization: Bearer }; bearer=${bearer%\"};;
    'user = "'*) basic=${line#user = \"}; basic=${basic%\"};;
  esac
done
data=${data//\\\"/\"}
echo "$method $url data:$data" >> "$GL_LOG.req"; echo "gl-token-from:$tok" >> "$GL_LOG.env"
reply() { printf '%s\n%s' "$2" "$1"; exit 0; }
if [[ $url == https://api.bitbucket.org/* ]]; then
  echo "bb-cred-from:${bearer:-$basic} repo:${url#https://api.bitbucket.org/2.0/repositories/}" >> "$GL_LOG.env"
  [[ $bearer == bbtok || $bearer == bbreadonly || $basic == me:apppw ]] || reply 401 '{}'
  slug=${url#https://api.bitbucket.org/2.0/repositories/}
  case $method in
    GET) [[ -d $BB_REMOTES/$slug.git ]] && reply 200 '{"slug":"x"}' || reply 404 '{"type":"error"}';;
    POST) [[ ${slug%%/*} != nows ]] || reply 404 '{}'
          [[ $bearer != bbreadonly ]] || reply 403 '{"error":{"message":"Your credentials lack one or more required privilege scopes."}}'
          git init -q --bare "$BB_REMOTES/$slug.git"; reply 200 '{"slug":"x"}';;
  esac
fi
[[ $tok == gltok || $tok == readonly || $tok == flaky ]] || reply 401 '{"message":"401 Unauthorized"}'
path=${url#https://gitlab.com/api/v4}
case "$method $path" in
  "GET /projects/"*) [[ $tok != flaky ]] || reply 500 '{"message":"500 Internal Server Error"}'
                     enc=${path#/projects/}; [[ -d $GL_REMOTES/${enc//%2F//}.git ]] && reply 200 '{"id":7}' || reply 404 '{"message":"404 Project Not Found"}';;
  "GET /namespaces/"*) case ${path#/namespaces/} in me) reply 200 '{"id":42,"name":"me"}';; group%2Fsub) reply 200 '{"id":44,"name":"sub"}';; *) reply 404 '{}';; esac;;
  "POST /projects")
    [[ $tok != readonly ]] || reply 403 '{"message":"403 Forbidden - Your token has not enough scopes"}'
    name=$(sed -n 's/.*"path":"\([^"]*\)".*/\1/p' <<<"$data"); nsid=$(sed -n 's/.*"namespace_id":\([0-9]*\).*/\1/p' <<<"$data")
    [[ $name != hidden ]] || reply 400 '{"message":{"name":["has already been taken"],"path":["has already been taken"]}}'
    case $nsid in 42) ns=me;; 44) ns=group/sub;; *) reply 400 '{}';; esac
    git init -q --bare "$GL_REMOTES/$ns/$name.git"; reply 201 '{"id":8}';;
esac
reply 404 '{}'
STUB
chmod +x bin/gh bin/ssh bin/az bin/curl; export GL_LOG=$t/gl.log GL_REMOTES=$t/gitlab BB_REMOTES=$t/bitbucket; export AZ_LOG=$t/az.log AZ_REMOTES=$t/azure AZ_REMOTES_SSH=$t/azure-ssh; export PATH=$t/bin:$PATH
export GIT_CONFIG_COUNT=13 GIT_CONFIG_KEY_0="url.$t/remotes/.insteadOf" GIT_CONFIG_VALUE_0="git@github.com:" \
  GIT_CONFIG_KEY_1="url.$t/nowhere/.insteadOf" GIT_CONFIG_VALUE_1="git@example.org:" \
  GIT_CONFIG_KEY_2="url.$t/remotes/.insteadOf" GIT_CONFIG_VALUE_2="https://github.com/" \
  GIT_CONFIG_KEY_3="url.$t/remotes/.insteadOf" GIT_CONFIG_VALUE_3="ssh://git@github.com:22/" \
  GIT_CONFIG_KEY_4="url.$t/remotes/.insteadOf" GIT_CONFIG_VALUE_4="git@gh-alias:" \
  GIT_CONFIG_KEY_5="url.$t/azure/.insteadOf" GIT_CONFIG_VALUE_5="https://dev.azure.com/" \
  GIT_CONFIG_KEY_6="url.$t/azure-ssh/.insteadOf" GIT_CONFIG_VALUE_6="git@ssh.dev.azure.com:v3/" \
  GIT_CONFIG_KEY_7="url.$t/gitlab/.insteadOf" GIT_CONFIG_VALUE_7="https://gitlab.com/" \
  GIT_CONFIG_KEY_8="url.$t/gitlab/.insteadOf" GIT_CONFIG_VALUE_8="git@gitlab.com:" \
  GIT_CONFIG_KEY_9="url.$t/bitbucket/.insteadOf" GIT_CONFIG_VALUE_9="https://bitbucket.org/" \
  GIT_CONFIG_KEY_10="url.$t/bitbucket/.insteadOf" GIT_CONFIG_VALUE_10="git@bitbucket.org:" \
  GIT_CONFIG_KEY_11="url.$t/gitlab/.insteadOf" GIT_CONFIG_VALUE_11="git@gl-alt:" \
  GIT_CONFIG_KEY_12="url.$t/bitbucket/.insteadOf" GIT_CONFIG_VALUE_12="git@bb-alt:"
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
GL_TOK=gltok check "gitlab: --create makes a private project in a user namespace" bash -c "'$gs' --create --dst-token-env GL_TOK '$t/src' https://gitlab.com/me/proj1.git && git -C '$t/gitlab/me/proj1.git' show-ref --verify -q refs/heads/main && grep -q '\"visibility\":\"private\"' '$t/gl.log.req'"
GL_TOK=gltok check "gitlab: nested group path from an scp URL" bash -c "'$gs' --create --dst-token-env GL_TOK '$t/src' git@gitlab.com:group/sub/proj2.git && git -C '$t/gitlab/group/sub/proj2.git' show-ref --verify -q refs/heads/main"
GL_TOK=gltok check "gitlab: --public sets visibility public" bash -c "'$gs' --create --public --dst-token-env GL_TOK '$t/src' https://gitlab.com/me/proj3 && grep -q '\"visibility\":\"public\"' '$t/gl.log.req'"
GL_TOK=gltok check "gitlab: --dry-run creates nothing" bash -c "'$gs' --create --dry-run --dst-token-env GL_TOK '$t/src' https://gitlab.com/me/dry && [[ ! -d '$t/gitlab/me/dry.git' ]] && ! grep -q '\"path\":\"dry\"' '$t/gl.log.req'"
check "gitlab: no token configured is refused" bash -c "! '$gs' --create '$t/src' https://gitlab.com/me/notoken && [[ ! -d '$t/gitlab/me/notoken.git' ]]"
GL_TOK=wrong check "gitlab: a rejected token fails, also in a dry run" bash -c "! '$gs' --create --dst-token-env GL_TOK '$t/src' https://gitlab.com/me/badtok && ! '$gs' --create --dry-run --dst-token-env GL_TOK '$t/src' https://gitlab.com/me/badtok && [[ ! -d '$t/gitlab/me/badtok.git' ]]"
GL_TOK=gltok check "gitlab: unknown group fails without creating" bash -c "! '$gs' --create --dst-token-env GL_TOK '$t/src' https://gitlab.com/nogroup/proj4 && [[ ! -d '$t/gitlab/nogroup' ]]"
mkdir -p gitlab/me/broken.git
GL_TOK=gltok check "gitlab: an existing unreadable project is not recreated" bash -c "! '$gs' --create --dst-token-env GL_TOK '$t/src' https://gitlab.com/me/broken && ! grep -q '\"path\":\"broken\"' '$t/gl.log.req'"
GL_TOK=gltok check "gitlab: the token is read from stdin, never argv" bash -c "'$gs' --create --dst-token-env GL_TOK '$t/src' https://gitlab.com/me/proj5 && grep -q 'gl-token-from:gltok' '$t/gl.log.env' && ! grep -q gltok '$t/gl.log'"
GL_TOK=gltok check "gitlab: a dry run also checks the group exists" bash -c "! '$gs' --create --dry-run --dst-token-env GL_TOK '$t/src' https://gitlab.com/nogroup/dry3"
GL_TOK=gltok check "gitlab: an invisible existing project gets a clear message" bash -c "'$gs' --create --dst-token-env GL_TOK '$t/src' https://gitlab.com/me/hidden 2>&1 | grep -q 'already taken'"
GL_TOK=gltok check "gitlab: altssh.gitlab.com resolves to gitlab" bash -c "'$gs' --create --dst-token-env GL_TOK '$t/src' git@gl-alt:me/viaalt.git && [[ -d '$t/gitlab/me/viaalt.git' ]]"
GL_TOK=readonly check "gitlab: a refused create shows GitLab's own message" bash -c "'$gs' --create --dst-token-env GL_TOK '$t/src' https://gitlab.com/me/ro 2>&1 | grep -q 'not enough scopes'"
GL_TOK=gltok check "gitlab: no network is reported as unreachable, not as an HTTP status" bash -c "GL_NET_DOWN=1 '$gs' --create --dst-token-env GL_TOK '$t/src' https://gitlab.com/me/down 2>&1 | grep -q 'could not reach GitLab'"
printf '%s https://gitlab.com/me/frompairs dst_token_env=GL_PAIR_TOK\n' "$t/src" > gl-pairs.txt
check "gitlab: the token comes from dst_token_env= in a pairs file" bash -c "GL_PAIR_TOK=gltok '$gs' --create -f '$t/gl-pairs.txt' && [[ -d '$t/gitlab/me/frompairs.git' ]]"
GL_TOK=flaky check "gitlab: a failing project check fails the pair, also in a dry run" bash -c "! '$gs' --create --dry-run --dst-token-env GL_TOK '$t/src' https://gitlab.com/me/flaky1 && ! '$gs' --create --dst-token-env GL_TOK '$t/src' https://gitlab.com/me/flaky1 && [[ ! -d '$t/gitlab/me/flaky1.git' ]]"
GL_TOK=gltok check "gitlab: a path that could break the JSON body is refused before any call" bash -c "! '$gs' --create --dst-token-env GL_TOK '$t/src' 'https://gitlab.com/me/x\",\"visibility\":\"public' && ! grep -q '\"name\":\"x' '$t/gl.log.req'"
BB_TOK=bbtok check "bitbucket: --create makes a private repo with an access token" bash -c "'$gs' --create --dst-token-env BB_TOK '$t/src' https://bitbucket.org/ws/repo1.git && git -C '$t/bitbucket/ws/repo1.git' show-ref --verify -q refs/heads/main && grep -q '\"is_private\":true' '$t/gl.log.req' && grep -q '\"scm\":\"git\"' '$t/gl.log.req'"
BB_TOK=bbtok check "bitbucket: --public sets is_private false" bash -c "'$gs' --create --public --dst-token-env BB_TOK '$t/src' git@bitbucket.org:ws/repo2.git && grep -q '\"is_private\":false' '$t/gl.log.req'"
BB_PW=apppw GIT_SYNC_DST_API_USER=me GIT_SYNC_DST_USER=x-bitbucket-api-token-auth check "bitbucket: dst_api_user sends the token as basic auth for that user" bash -c "'$gs' --create --dst-token-env BB_PW '$t/src' https://bitbucket.org/ws/repo3 && grep -q 'bb-cred-from:me:apppw repo:ws/repo3' '$t/gl.log.env'"
BB_TOK=bbtok check "bitbucket: --dry-run creates nothing" bash -c "'$gs' --create --dry-run --dst-token-env BB_TOK '$t/src' https://bitbucket.org/ws/dry && [[ ! -d '$t/bitbucket/ws/dry.git' ]]"
check "bitbucket: no token configured is refused" bash -c "! '$gs' --create '$t/src' https://bitbucket.org/ws/notoken && [[ ! -d '$t/bitbucket/ws/notoken.git' ]]"
BB_TOK=wrong check "bitbucket: a rejected token fails, also in a dry run" bash -c "! '$gs' --create --dst-token-env BB_TOK '$t/src' https://bitbucket.org/ws/badtok && ! '$gs' --create --dry-run --dst-token-env BB_TOK '$t/src' https://bitbucket.org/ws/badtok && [[ ! -d '$t/bitbucket/ws/badtok.git' ]]"
mkdir -p bitbucket/ws/broken.git
BB_TOK=bbtok check "bitbucket: an existing unreadable repo is not recreated" bash -c "! '$gs' --create --dst-token-env BB_TOK '$t/src' https://bitbucket.org/ws/broken && ! grep -q 'POST.*ws/broken' '$t/gl.log.req'"
BB_TOK=bbtok check "bitbucket: the token is read from stdin, never argv" bash -c "'$gs' --create --dst-token-env BB_TOK '$t/src' https://bitbucket.org/ws/repo4 && grep -q 'bb-cred-from:bbtok repo:ws/repo4' '$t/gl.log.env' && ! grep -q bbtok '$t/gl.log'"
BB_TOK=bbreadonly check "bitbucket: a refused create shows Bitbucket's own message" bash -c "'$gs' --create --dst-token-env BB_TOK '$t/src' https://bitbucket.org/ws/ro 2>&1 | grep -q 'privilege scopes'"
BB_TOK=bbtok check "bitbucket: altssh.bitbucket.org resolves to bitbucket" bash -c "'$gs' --create --dst-token-env BB_TOK '$t/src' git@bb-alt:ws/viaalt.git && [[ -d '$t/bitbucket/ws/viaalt.git' ]]"
BB_TOK=bbtok check "bitbucket: a path that could break the curl config is refused before any call" bash -c "! '$gs' --create --dst-token-env BB_TOK '$t/src' 'https://bitbucket.org/ws/x\"' && ! grep -q 'repo:ws/x' '$t/gl.log.env'"
check "default_user: x-token-auth only for Bitbucket over HTTPS" bash -c "eval \"\$(sed -n '/^parse_url()/,/^}/p;/^default_user()/,/^}/p' '$gs')\"; [[ \$(default_user https://bitbucket.org/ws/r) == x-token-auth && \$(default_user git@bitbucket.org:ws/r.git) == x-access-token && \$(default_user ssh://git@bitbucket.org/ws/r.git) == x-access-token && \$(default_user https://github.com/o/r) == x-access-token ]]"
BB_TOK=bbtok GIT_SYNC_DST_USER=x-bitbucket-api-token-auth check "bitbucket: dst_user alone changes the git user, not the API auth" bash -c "'$gs' --create --dst-token-env BB_TOK '$t/src' https://bitbucket.org/ws/gituser && grep -q 'bb-cred-from:bbtok repo:ws/gituser' '$t/gl.log.env'"
BB_TOK=bbtok check "bitbucket: a create refused with 404 names the workspace" bash -c "'$gs' --create --dst-token-env BB_TOK '$t/src' https://bitbucket.org/nows/r 2>&1 | grep -q \"workspace 'nows'\""
mkdir -p gitlog; printf '#!/usr/bin/env bash\necho "$*" >> "$GIT_ARGS_LOG"\nexec "%s" "$@"\n' "$(command -v git)" > gitlog/git; chmod +x gitlog/git
BB_TOK=bbtok GIT_ARGS_LOG=$t/ga1.log check "git gets x-token-auth for a Bitbucket access token" bash -c "PATH='$t/gitlog':\$PATH '$gs' --create --dst-token-env BB_TOK '$t/src' https://bitbucket.org/ws/ulog1 && grep -q 'username=x-token-auth' '$t/ga1.log'"
GH_T=ghtok GIT_ARGS_LOG=$t/ga2.log check "git gets x-access-token for a GitHub destination" bash -c "PATH='$t/gitlog':\$PATH '$gs' --create --dst-token-env GH_T '$t/src' https://github.com/me/ulog2 && grep -q 'username=x-access-token' '$t/ga2.log' && ! grep -q 'username=x-token-auth' '$t/ga2.log'"
printf '%s https://bitbucket.org/ws/ulog3 dst_token_env=BB_TOK dst_user=custom\n' "$t/src" > ulog-pairs.txt
BB_TOK=bbtok GIT_ARGS_LOG=$t/ga3.log check "an explicit dst_user in a pairs file wins over the Bitbucket default" bash -c "PATH='$t/gitlog':\$PATH '$gs' --create -f '$t/ulog-pairs.txt' && grep -q 'username=custom' '$t/ga3.log' && ! grep -q 'username=x-token-auth' '$t/ga3.log'"
BB_PW=apppw GIT_SYNC_DST_API_USER=me check "bitbucket: an API user with the default git user is refused before anything is created" bash -c "! '$gs' --create --dst-token-env BB_PW '$t/src' https://bitbucket.org/ws/apirefused && [[ ! -d '$t/bitbucket/ws/apirefused.git' ]] && ! grep -q 'repo:ws/apirefused' '$t/gl.log.env'"
printf '%s https://bitbucket.org/ws/apipairs dst_token_env=BB_PW dst_api_user=me dst_user=x-bitbucket-api-token-auth\n' "$t/src" > api-pairs.txt
BB_PW=apppw check "bitbucket: dst_api_user and dst_user work from a pairs file" bash -c "'$gs' --create -f '$t/api-pairs.txt' && grep -q 'bb-cred-from:me:apppw repo:ws/apipairs' '$t/gl.log.env'"
BB_PW=apppw GIT_SYNC_DST_API_USER=me check "bitbucket: an API token with an SSH destination needs no git user name" bash -c "'$gs' --create --dst-token-env BB_PW '$t/src' git@bitbucket.org:ws/sshapi.git && [[ -d '$t/bitbucket/ws/sshapi.git' ]]"
BB_PW=apppw GIT_SYNC_DST_API_USER=me check "bitbucket: the API-token guard also stops a plain sync" bash -c "'$gs' '$t/src' https://bitbucket.org/ws/plainsync 2>&1 | grep -q 'also needs dst_user'"
printf '%s https://bitbucket.org/ws/explicit dst_token_env=BB_TOK dst_user=x-access-token\n' "$t/src" > explicit-pairs.txt
BB_TOK=bbtok GIT_ARGS_LOG=$t/ga4.log check "an explicit dst_user=x-access-token on Bitbucket is kept" bash -c "PATH='$t/gitlog':\$PATH '$gs' --create -f '$t/explicit-pairs.txt' && grep -q 'username=x-access-token' '$t/ga4.log' && ! grep -q 'username=x-token-auth' '$t/ga4.log'"
BB_TOK=bbtok check "bitbucket: a dot-segment path is refused before any call" bash -c "! '$gs' --create --dst-token-env BB_TOK '$t/src' https://bitbucket.org/ws/.. && ! grep -q 'repo:ws/\.\.' '$t/gl.log.env'"
GL_TOK=gltok check "gitlab: a dot-segment path is refused before any call" bash -c "! '$gs' --create --dst-token-env GL_TOK '$t/src' https://gitlab.com/me/.. && ! grep -q 'projects/me%2F\.\.' '$t/gl.log.req'"
check "--create on an unsupported host fails" bash -c "! '$gs' --create '$t/src' git@example.org:me/x.git"

# --dst-prefix: several sources, one destination
for n in pa pb; do git init -q -b main $n; (cd $n && echo $n > f && git add f && git commit -qm $n && git tag -a v1 -m v1 && git branch feat); done
git init -q --bare multi.git
pfx_refs() { git -C multi.git for-each-ref --format='%(refname)' | tr '\n' ' '; }; export -f pfx_refs
check "prefix: a dry run leaves the destination empty" bash -c "'$gs' --dry-run --dst-prefix pa '$t/pa' '$t/multi.git' && [[ -z \$(git -C '$t/multi.git' for-each-ref) ]]"
check "prefix: first source lands under its prefix" bash -c "'$gs' --dst-prefix pa '$t/pa' '$t/multi.git' && [[ \"\$(pfx_refs)\" == 'refs/heads/pa/feat refs/heads/pa/main refs/tags/pa/v1 ' ]]"
check "prefix: a second source with the same branch and tag names needs no --force" bash -c "'$gs' --dst-prefix pb '$t/pb' '$t/multi.git'"
check "prefix: both sources sit side by side" bash -c "[[ \"\$(pfx_refs)\" == *'refs/heads/pb/main'* && \"\$(pfx_refs)\" == *'refs/tags/pa/v1'* && \"\$(pfx_refs)\" == *'refs/tags/pb/v1'* ]]"
check "prefix: each branch keeps its source commit" bash -c "[[ \$(git -C multi.git rev-parse pa/main) == \$(git -C pa rev-parse main) && \$(git -C multi.git rev-parse pb/main) == \$(git -C pb rev-parse main) ]]"
check "prefix: nothing lands without the prefix" bash -c "! git -C multi.git show-ref --verify -q refs/heads/main"
(cd pa && echo more >> f && git commit -qam c2)
check "prefix: an incremental sync picks up the new commit" bash -c "'$gs' --dst-prefix pa '$t/pa' '$t/multi.git' && [[ \$(git -C multi.git rev-parse pa/main) == \$(git -C pa rev-parse main) ]]"
check "prefix: the prefixed pair has its own cache" bash -c "[[ \$(ls '$t/cache' | wc -l) -gt 1 ]]"
(cd pa && git branch -D feat -q && git tag -d v1 >/dev/null)
"$gs" --dst-prefix pa "$t/pa" "$t/multi.git" >/dev/null 2>&1
check "prefix: a deleted source branch and tag stay without --prune" bash -c "git -C multi.git show-ref --verify -q refs/heads/pa/feat && git -C multi.git show-ref --verify -q refs/tags/pa/v1"
git -C multi.git update-ref refs/heads/legacy "$(git -C multi.git rev-parse pb/main)"
check "prefix: --prune removes the deleted branch and tag" bash -c "'$gs' --prune --dst-prefix pa '$t/pa' '$t/multi.git' && ! git -C multi.git show-ref --verify -q refs/heads/pa/feat && ! git -C multi.git show-ref --verify -q refs/tags/pa/v1"
check "prefix: --prune leaves the other prefix and unprefixed refs alone" bash -c "[[ \"\$(pfx_refs)\" == *'refs/heads/pb/feat'* && \"\$(pfx_refs)\" == *'refs/tags/pb/v1'* && \"\$(pfx_refs)\" == *'refs/heads/legacy'* ]]"
check "prefix: an existing prefix at the destination needs --force on a fresh cache" bash -c "/bin/rm -rf '$t/cache' && ! '$gs' --dst-prefix pb '$t/pb' '$t/multi.git' && '$gs' --force --dst-prefix pb '$t/pb' '$t/multi.git'"
check "prefix: GIT_SYNC_DST_PREFIX is the default" bash -c "git init -q --bare '$t/envdst.git' && GIT_SYNC_DST_PREFIX=envp '$gs' '$t/pa' '$t/envdst.git' && git -C '$t/envdst.git' show-ref --verify -q refs/heads/envp/main"

for bad in /x x/ a..b "a b" a//b .a a.lock '-a' 'a~1'; do
  check "prefix: invalid prefix '$bad' exits 2" bash -c "'$gs' --dst-prefix '$bad' '$t/pa' '$t/multi.git'; [[ \$? -eq 2 ]]"
done
check "prefix: nothing is pushed for an invalid prefix" bash -c "[[ \"\$(pfx_refs)\" != *'a b'* ]]"
printf '%s %s dst_prefix=a..b\n' "$t/pa" "$t/multi.git" > badpfx.txt
check "prefix: an invalid prefix in a pairs file exits 2" bash -c "'$gs' -f '$t/badpfx.txt'; [[ \$? -eq 2 ]]"

git init -q --bare clash.git
(cd pa && git push -q "$t/clash.git" main:refs/heads/x)
check "prefix: a branch named like the prefix fails with a clear message" bash -c "'$gs' --force --dst-prefix x '$t/pa' '$t/clash.git' 2>&1 | grep -q \"clashes with the prefix 'x'\""
check "prefix: a branch named like the start of the prefix fails too" bash -c "'$gs' --force --dst-prefix x/y '$t/pa' '$t/clash.git' 2>&1 | grep -q \"clashes with the prefix 'x/y'\""
(cd pa && git tag -a t1 -m t1 && git push -q "$t/clash.git" t1:refs/tags/t)
check "prefix: a tag named like the prefix fails too" bash -c "'$gs' --force --dst-prefix t '$t/pa' '$t/clash.git' 2>&1 | grep -q \"clashes with the prefix 't'\""
check "prefix: an unrelated prefix works beside those refs" bash -c "'$gs' --dst-prefix xx '$t/pa' '$t/clash.git' && git -C '$t/clash.git' show-ref --verify -q refs/heads/xx/main"

git init -q --bare dup.git
printf '%s %s dst_prefix=one\n%s %s dst_prefix=one\n' "$t/pa" "$t/dup.git" "$t/pb" "$t/dup.git" > dup1.txt
printf '%s %s dst_prefix=one\n%s %s\n' "$t/pa" "$t/dup.git" "$t/pb" "$t/dup.git" > dup2.txt
printf '%s %s dst_prefix=one\n%s %s dst_prefix=one/two\n' "$t/pa" "$t/dup.git" "$t/pb" "$t/dup.git" > dup3.txt
printf '%s %s dst_prefix=one\n%s %s/ dst_prefix=one\n' "$t/pa" "file://$t/dup.git" "$t/pb" "file://$t/dup.git" > dup4.txt
printf '%s %s dst_prefix=one\n%s %s dst_prefix=two\n' "$t/pa" "$t/dup.git" "$t/pb" "$t/dup.git" > ok1.txt
for f in dup1 dup2 dup3 dup4; do
  check "prefix: $f.txt is rejected before any pair runs" bash -c "'$gs' -f '$t/$f.txt'; [[ \$? -eq 2 && -z \$(git -C '$t/dup.git' for-each-ref) ]]"
done
check "prefix: different prefixes on one destination are accepted" bash -c "'$gs' -f '$t/ok1.txt' && git -C '$t/dup.git' show-ref --verify -q refs/heads/two/main"
check "prefix: dst_prefix= in a pairs file overrides the default" bash -c "git init -q --bare '$t/ovr.git' && printf '%s %s dst_prefix=\n' '$t/pa' '$t/ovr.git' > '$t/ovr.txt' && '$gs' --dst-prefix zz -f '$t/ovr.txt' && git -C '$t/ovr.git' show-ref --verify -q refs/heads/main"

git init -q -b main many; (cd many && for i in 1 2 3 4 5 6; do echo $i > f && git add f && git commit -qm $i; done
  hi=$(git rev-list main | sort | tail -1); lo=$(git rev-list main | sort | head -1); git branch a "$lo"; git branch b "$hi")
check "verification holds with many branches whatever their hash order" bash -c "git init -q --bare '$t/many.git' && git -C many push -q '$t/many.git' b:refs/heads/0z && '$gs' --force '$t/many' '$t/many.git'"
check "prefix: many branches verify under a prefix too" bash -c "git init -q --bare '$t/many2.git' && '$gs' --dst-prefix p '$t/many' '$t/many2.git'"

check "prefix: unprefixed sync still lands under the original names" bash -c "git init -q --bare '$t/plain.git' && '$gs' '$t/pb' '$t/plain.git' && [[ \"\$(git -C '$t/plain.git' for-each-ref --format='%(refname)' | tr '\n' ' ')\" == 'refs/heads/feat refs/heads/main refs/tags/v1 ' ]]"

echo "$pass passed, $fail failed"
exit $((fail > 0))
