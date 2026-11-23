#!/usr/bin/env bash
# Runs the action's "Check for changes" step, read out of action.yml, in a
# scratch git repository, and reads what it wrote to GITHUB_OUTPUT the way the
# runner does (name=value lines, and name<<DELIMITER blocks). It asserts that a
# changed file named KAPI_EOF stays inside changed-files, and that a kapi data
# directory inside the repository is left out with a warning. Needs yq (v4).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
work="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work"' EXIT

yq '.runs.steps[] | select(.id == "check-changes") | .run' "$root/action.yml" > "$work/step.sh"
if ! grep -q 'porcelain' "$work/step.sh"; then
  echo "could not read the check-changes step out of action.yml" >&2
  exit 1
fi

failures=0
fail() {
  echo "FAIL $1: $2"
  failures=$((failures + 1))
}

# parse_outputs FILE writes one "name<TAB>value" line per output, with a
# multi-line value's lines joined by "|", as the runner reads GITHUB_OUTPUT.
parse_outputs() {
  awk '
    delim != "" { if ($0 == delim) { print name "\t" value; delim = ""; next }
                  value = (value == "" ? $0 : value "|" $0); next }
    /^[A-Za-z_][A-Za-z0-9_-]*<</ { i = index($0, "<<"); name = substr($0, 1, i - 1)
                                   delim = substr($0, i + 2); value = ""; next }
    /=/ { i = index($0, "="); print substr($0, 1, i - 1) "\t" substr($0, i + 1) }
  ' "$1"
}

output() {
  parse_outputs "$2" | awk -F'\t' -v n="$1" '$1 == n { v = $2 } END { print v }'
}

# new_repo NAME makes a repository with one committed file.
new_repo() {
  local repo="$work/$1/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  echo source > "$repo/en.json"
  git -C "$repo" add en.json
  git -C "$repo" -c user.name=t -c user.email=t@example.com commit -qm init
  echo "$repo"
}

# run_step NAME REPO [VAR=VALUE...] runs the step in REPO.
run_step() {
  local name="$1" repo="$2"
  shift 2
  : > "$work/$name/output"
  (cd "$repo" && env -u KAPI_DATA_DIR -u XDG_DATA_HOME PATHS="" GITHUB_OUTPUT="$work/$name/output" "$@" \
    bash -e "$work/step.sh") > "$work/$name/stdout" 2>&1 || fail "$name" "exit code $?"
}

# A changed file named KAPI_EOF, and one after it, stay inside changed-files.
repo="$(new_repo delimiter)"
echo x > "$repo/KAPI_EOF"
echo y > "$repo/zz.json"
run_step delimiter "$repo"
got="$(output changed_files "$work/delimiter/output")"
[ "$got" = "KAPI_EOF|zz.json" ] || fail delimiter "changed_files: got '$got'"
[ "$(output has_changes "$work/delimiter/output")" = true ] || fail delimiter "has_changes"
[ "$(parse_outputs "$work/delimiter/output" | cut -f1 | sort | tr '\n' ' ')" = "changed_files has_changes " ] \
  || fail delimiter "outputs: $(parse_outputs "$work/delimiter/output" | cut -f1 | tr '\n' ' ')"

# A data directory inside the repository is not reported, with a warning.
repo="$(new_repo data-inside)"
mkdir -p "$repo/.kapi-data/workspaces"
echo state > "$repo/.kapi-data/workspaces/db"
echo fr > "$repo/fr.json"
run_step data-inside "$repo" KAPI_DATA_DIR="$repo/.kapi-data"
[ "$(output changed_files "$work/data-inside/output")" = "fr.json" ] || fail data-inside "changed_files: $(output changed_files "$work/data-inside/output")"
grep -q '^::warning::kapi.s data directory' "$work/data-inside/stdout" || fail data-inside "printed no warning"

# The same through a relative KAPI_DATA_DIR, and through XDG_DATA_HOME.
repo="$(new_repo data-relative)"
mkdir -p "$repo/.kapi-data"
echo state > "$repo/.kapi-data/db"
run_step data-relative "$repo" KAPI_DATA_DIR=.kapi-data
[ "$(output has_changes "$work/data-relative/output")" = false ] || fail data-relative "has_changes: $(cat "$work/data-relative/output")"
repo="$(new_repo data-xdg)"
mkdir -p "$repo/.xdg/kapi"
echo state > "$repo/.xdg/kapi/db"
run_step data-xdg "$repo" XDG_DATA_HOME="$repo/.xdg"
[ "$(output has_changes "$work/data-xdg/output")" = false ] || fail data-xdg "has_changes: $(cat "$work/data-xdg/output")"

# Only the data directory changed: no changes.
repo="$(new_repo data-only)"
mkdir -p "$repo/.kapi-data"
echo state > "$repo/.kapi-data/db"
run_step data-only "$repo" KAPI_DATA_DIR="$repo/.kapi-data"
[ "$(output has_changes "$work/data-only/output")" = false ] || fail data-only "has_changes"

# A data directory outside the repository changes nothing and warns not.
repo="$(new_repo data-outside)"
echo fr > "$repo/fr.json"
run_step data-outside "$repo" KAPI_DATA_DIR="$work/data-outside/data"
[ "$(output changed_files "$work/data-outside/output")" = "fr.json" ] || fail data-outside "changed_files"
! grep -q '::warning' "$work/data-outside/stdout" || fail data-outside "warned"

if [ "$failures" -gt 0 ]; then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "all change reports passed"
