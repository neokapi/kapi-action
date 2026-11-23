#!/usr/bin/env bash
# Runs the action's "Run kapi" step in plan mode against the kapi stub in
# test/stub, once for each plan shape a kapi release has printed: snake_case
# (kapi 1.4, captured from 1.4.0-rc5), camelCase with memoryExact (1.3) and
# camelCase with tmExact (1.2), plus a plan whose counts carry names the action
# does not know. It asserts the outputs, the job summary and the sticky PR
# comment each produces. It then runs the step on `kapi up` result records
# (1.4 and 1.3) and asserts outcome, passes and parked-locales. The step
# scripts are read out of action.yml, so the code under test is the code the
# action ships. Needs yq (v4) and jq.
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

# plan_case NAME OUTPUT MISSING MEMORY AI TOKENS SENTENCE ROW...
#
# Runs the plan step with the stub printing test/plan-output/OUTPUT, then the
# sticky PR comment step with what it wrote. MISSING..TOKENS are the outputs
# the step must write (empty for a count it must report as missing). SENTENCE
# and each ROW must appear in the summary and in the comment.
plan_case() {
  local name="$1" output="$2" missing="$3" memory="$4" ai="$5" tokens="$6" sentence="$7"
  shift 7
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
  for pair in mode=plan "plan-missing=$missing" "plan-memory-exact=$memory" "plan-ai-remaining=$ai" "plan-token-estimate=$tokens"; do
    got="$(output_value "${pair%%=*}" "$dir/output")"
    [ "$got" = "${pair#*=}" ] || fail "$name" "${pair%%=*}: got '$got', want '${pair#*=}'"
  done
  got="$(tr '\n' ' ' < "$dir/argv")"
  [ "$got" = "up --plan --json " ] || fail "$name" "kapi argv: got '$got', want 'up --plan --json '"
  if grep -q null "$dir/summary"; then
    fail "$name" "the summary prints null"
  fi

  contains "$name" "$dir/summary" "$sentence"
  contains "$name" "$dir/summary" "| Locale | Collection | Pending | Content memory exact | AI remaining | Token estimate |"
  local row
  for row in "$@"; do
    contains "$name" "$dir/summary" "$row"
  done
  if [ -n "$missing" ] && [ -n "$memory" ] && [ -n "$ai" ] && [ -n "$tokens" ]; then
    contains "$name" "$dir/stdout" "Plan: ${missing} unit(s) pending, ${memory} from content memory, ${ai} for AI (~${tokens} tokens)."
  else
    contains "$name" "$dir/stdout" "::warning::kapi's plan did not report:"
  fi

  rc=0
  env \
    PATH="$here/stub:$PATH" GH_STUB_LOG="$dir/gh" \
    GH_TOKEN=unused REPO=neokapi/kapi-action PR_NUMBER=1 \
    RUN_URL="https://github.com/neokapi/kapi-action/actions/runs/1" \
    MODE="$(output_value mode "$dir/output")" OUTCOME="" PASSES="" PARKED="" \
    GATE="" RESULT="" CAUSE="" DID_NOT_RUN_SUMMARY="" \
    RUNNER_TEMP="$dir/tmp" \
    bash "$work/comment.sh" > "$dir/comment.stdout" 2>&1 || rc=$?
  [ "$rc" = 0 ] || fail "$name comment" "exit code: got '$rc', want '0'"
  if [ ! -f "$dir/gh/body.md" ]; then
    fail "$name comment" "posted no comment"
  else
    contains "$name comment" "$dir/gh/body.md" "$sentence"
    contains "$name comment" "$dir/gh/body.md" "| Locale | Collection | Pending | Content memory exact | AI remaining | Token estimate |"
    for row in "$@"; do
      contains "$name comment" "$dir/gh/body.md" "$row"
    done
    if grep -q null "$dir/gh/body.md"; then
      fail "$name comment" "the comment prints null"
    fi
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

# result_case NAME OUTPUT OUTCOME PASSES PARKED runs the step as `kapi up`
# with the stub printing the NDJSON stream test/up-output/OUTPUT and asserts
# the outputs it reads from the closing result record.
result_case() {
  local name="$1" output="$2" want_outcome="$3" want_passes="$4" want_parked="$5"
  local dir="$work/cases/$name"
  mkdir -p "$dir/tmp"
  : > "$dir/output"
  : > "$dir/summary"
  local before="$failures"

  local rc=0
  env \
    PATH="$here/stub:$PATH" \
    COMMAND=up ARGS="" PROJECT="" PLAN=false FAIL_ON_PARKED=false \
    RUNNER_TEMP="$dir/tmp" GITHUB_OUTPUT="$dir/output" GITHUB_STEP_SUMMARY="$dir/summary" \
    KAPI_STUB_OUTPUT="$here/up-output/$output" KAPI_STUB_EXIT=0 KAPI_STUB_ARGV="$dir/argv" \
    bash "$work/step.sh" > "$dir/stdout" 2>&1 || rc=$?
  [ "$rc" = 0 ] || fail "$name" "exit code: got '$rc', want '0'"

  local got
  for pair in "outcome=$want_outcome" "passes=$want_passes" "parked-locales=$want_parked"; do
    got="$(output_value "${pair%%=*}" "$dir/output")"
    [ "$got" = "${pair#*=}" ] || fail "$name" "${pair%%=*}: got '$got', want '${pair#*=}'"
  done
  contains "$name" "$dir/summary" "| Outcome | **${want_outcome}** |"
  contains "$name" "$dir/summary" "| Parked locales | ${want_parked:-—} |"

  if [ "$failures" = "$before" ]; then
    echo "ok   $name"
  else
    sed 's/^/     | /' "$dir/stdout" "$dir/summary"
  fi
}

SENTENCE_13="This change leaves **6 unit(s)** of pending translation work: 3 recoverable from content memory, 3 for AI (~11 tokens estimated)."

plan_case kapi-1.4 kapi-1.4.json 6 0 6 22 \
  "This change leaves **6 unit(s)** of pending translation work: 0 recoverable from content memory, 6 for AI (~22 tokens estimated)." \
  "| de | app | 3 | 0 | 3 | 11 |" "| fr | app | 3 | 0 | 3 | 11 |"
plan_case kapi-1.3 kapi-1.3.json 6 3 3 11 "$SENTENCE_13" "| de | app | 3 | 1 | 2 | 7 |" "| fr | app | 3 | 2 | 1 | 4 |"
plan_case kapi-1.2 kapi-1.2.json 6 3 3 11 "$SENTENCE_13" "| de | app | 3 | 1 | 2 | 7 |" "| fr | app | 3 | 2 | 1 | 4 |"
plan_case renamed renamed.json "" "" "" "" \
  "kapi's plan did not report: pending units, content-memory matches, AI remaining, token estimate. The table shows what it did report." \
  "| de | app | not reported | not reported | not reported | not reported |"

plan_case escaped escaped.json 3 1 2 7 \
  "This change leaves **3 unit(s)** of pending translation work: 1 recoverable from content memory, 2 for AI (~7 tokens estimated)." \
  "| de\\|ch | app web | 3 | 1 | 2 | 7 |"

result_case up-kapi-1.4-parked kapi-1.4.parked.ndjson parked 1 de,fr
result_case up-kapi-1.4-converged kapi-1.4.converged.ndjson converged 1 ""
result_case up-kapi-1.3-parked kapi-1.3.parked.ndjson parked 2 de,fr
result_case up-escaped escaped.parked.ndjson parked 1 "de,x%0Aplan-missing%3D9,y%7Cz"

if [ "$failures" -gt 0 ]; then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "all plan outputs passed"
