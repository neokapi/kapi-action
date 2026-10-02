#!/usr/bin/env bash
# Runs the action's "Run kapi" step in plan mode against the kapi stub in
# test/stub, once with the plan kapi 1.3 prints (memoryExact) and once with the
# plan kapi 1.2 printed (tmExact), and asserts the outputs, the job summary and
# the sticky PR comment each produces. The step scripts are read out of
# action.yml, so the code under test is the code the action ships. Needs yq
# (v4) and jq.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

yq '.runs.steps[] | select(.id == "run-kapi") | .run' "$root/action.yml" > "$work/step.sh"
if ! grep -q 'kapi-plan.json' "$work/step.sh"; then
  echo "could not read the run-kapi step out of action.yml" >&2
  exit 1
fi
yq '.runs.steps[] | select(.id == "pr-comment") | .run' "$root/action.yml" > "$work/comment.sh"
if ! grep -q 'kapi-report' "$work/comment.sh"; then
  echo "could not read the pr-comment step out of action.yml" >&2
  exit 1
fi

failures=0

output_value() {
  sed -n "s/^$1=//p" "$2" | tail -n 1
}

fail() {
  echo "FAIL $1: $2"
  failures=$((failures + 1))
}

# contains NAME FILE TEXT asserts that FILE contains TEXT.
contains() {
  grep -qF -- "$3" "$2" || fail "$1" "$(basename "$2") lacks '$3'"
}

# plan_case NAME OUTPUT runs the plan step with the stub printing
# test/plan-output/OUTPUT, then the sticky PR comment step with what it wrote.
plan_case() {
  local name="$1" output="$2"
  local dir="$work/cases/$name"
  mkdir -p "$dir/tmp"
  : > "$dir/output"
  : > "$dir/summary"
  local before="$failures"

  local rc=0
  env \
    PATH="$here/stub:$PATH" \
    COMMAND=up ARGS="" PROJECT="" PLAN=true FAIL_ON_PARKED=false \
    RUNNER_TEMP="$dir/tmp" GITHUB_OUTPUT="$dir/output" GITHUB_STEP_SUMMARY="$dir/summary" \
    KAPI_STUB_OUTPUT="$here/plan-output/$output" KAPI_STUB_EXIT=0 KAPI_STUB_ARGV="$dir/argv" \
    bash "$work/step.sh" > "$dir/stdout" 2>&1 || rc=$?
  [ "$rc" = 0 ] || fail "$name" "exit code: got '$rc', want '0'"

  local got
  for pair in mode=plan plan-missing=6 plan-memory-exact=3 plan-ai-remaining=3 plan-token-estimate=11; do
    got="$(output_value "${pair%%=*}" "$dir/output")"
    [ "$got" = "${pair#*=}" ] || fail "$name" "${pair%%=*}: got '$got', want '${pair#*=}'"
  done
  got="$(tr '\n' ' ' < "$dir/argv")"
  [ "$got" = "up --plan --json " ] || fail "$name" "kapi argv: got '$got', want 'up --plan --json '"

  contains "$name" "$dir/summary" "3 recoverable from content memory, 3 for AI (~11 tokens estimated)."
  contains "$name" "$dir/summary" "| Locale | Pending | Content memory exact | AI remaining | Token estimate |"
  contains "$name" "$dir/summary" "| de | 3 | 1 | 2 | 7 |"
  contains "$name" "$dir/summary" "| fr | 3 | 2 | 1 | 4 |"
  contains "$name" "$dir/stdout" "Plan: 6 unit(s) pending, 3 from content memory, 3 for AI (~11 tokens)."

  rc=0
  env \
    PATH="$here/stub:$PATH" GH_STUB_LOG="$dir/gh" \
    GH_TOKEN=unused REPO=neokapi/kapi-action PR_NUMBER=1 \
    RUN_URL="https://github.com/neokapi/kapi-action/actions/runs/1" \
    MODE="$(output_value mode "$dir/output")" OUTCOME="" PASSES="" PARKED="" \
    GATE="" RESULT="" CAUSE="" DID_NOT_RUN_SUMMARY="" \
    PLAN_MISSING="$(output_value plan-missing "$dir/output")" \
    PLAN_MEMORY="$(output_value plan-memory-exact "$dir/output")" \
    PLAN_AI="$(output_value plan-ai-remaining "$dir/output")" \
    PLAN_TOKENS="$(output_value plan-token-estimate "$dir/output")" \
    RUNNER_TEMP="$dir/tmp" \
    bash "$work/comment.sh" > "$dir/comment.stdout" 2>&1 || rc=$?
  [ "$rc" = 0 ] || fail "$name comment" "exit code: got '$rc', want '0'"
  if [ ! -f "$dir/gh/body.md" ]; then
    fail "$name comment" "posted no comment"
  else
    contains "$name comment" "$dir/gh/body.md" "This change leaves **6 unit(s)** of pending translation work: 3 recoverable from content memory, 3 for AI (~11 tokens estimated)."
    contains "$name comment" "$dir/gh/body.md" "| Locale | Pending | Content memory exact | AI remaining | Token estimate |"
    contains "$name comment" "$dir/gh/body.md" "| de | 3 | 1 | 2 | 7 |"
    contains "$name comment" "$dir/gh/body.md" "| fr | 3 | 2 | 1 | 4 |"
  fi

  if [ "$failures" = "$before" ]; then
    echo "ok   $name"
  else
    sed 's/^/     | /' "$dir/stdout" "$dir/summary"
    if [ -f "$dir/gh/body.md" ]; then
      sed 's/^/     > /' "$dir/gh/body.md"
    fi
  fi
}

plan_case kapi-1.3 kapi-1.3.json
plan_case kapi-1.2 kapi-1.2.json

if [ "$failures" -gt 0 ]; then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "all plan outputs passed"
