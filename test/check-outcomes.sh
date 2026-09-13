#!/usr/bin/env bash
# Runs the action's "Run kapi" step with `command: check` against the kapi stub
# in test/stub, once per check outcome, and asserts the step's exit code, its
# outputs and its error annotation. The step script is read out of action.yml,
# so the code under test is the code the action ships. Needs yq (v4) and jq.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

yq '.runs.steps[] | select(.id == "run-kapi") | .run' "$root/action.yml" > "$work/step.sh"
if ! grep -q 'kapi-check-output.txt' "$work/step.sh"; then
  echo "could not read the run-kapi step out of action.yml" >&2
  exit 1
fi

failures=0

# output_value KEY FILE prints the last value the step wrote for KEY.
output_value() {
  sed -n "s/^$1=//p" "$2" | tail -n 1
}

fail() {
  echo "FAIL $1: $2"
  failures=$((failures + 1))
}

# run_case NAME ARGS OUTPUT EXIT WANT_RC WANT_RESULT WANT_GATE WANT_CAUSE WANT_ERROR
#
# OUTPUT names a file in test/check-output for the stub to print (empty prints
# nothing). WANT_ERROR is a substring the step's ::error:: line must contain;
# empty means the step must print no ::error:: line.
run_case() {
  local name="$1" args="$2" output="$3" code="$4" want_rc="$5"
  local want_result="$6" want_gate="$7" want_cause="$8" want_error="$9"
  local dir="$work/cases/$name"
  mkdir -p "$dir/tmp"
  : > "$dir/output"
  : > "$dir/summary"

  local stub_output=""
  if [ -n "$output" ]; then
    stub_output="$here/check-output/$output"
  fi

  local rc=0
  env \
    PATH="$here/stub:$PATH" \
    COMMAND=check ARGS="$args" PROJECT="" PLAN=false FAIL_ON_PARKED=false \
    RUNNER_TEMP="$dir/tmp" GITHUB_OUTPUT="$dir/output" GITHUB_STEP_SUMMARY="$dir/summary" \
    KAPI_STUB_OUTPUT="$stub_output" KAPI_STUB_EXIT="$code" KAPI_STUB_ARGV="$dir/argv" \
    bash "$work/step.sh" > "$dir/stdout" 2>&1 || rc=$?

  local before="$failures"
  [ "$rc" = "$want_rc" ] || fail "$name" "exit code: got '$rc', want '$want_rc'"

  local got
  got="$(output_value result "$dir/output")"
  [ "$got" = "$want_result" ] || fail "$name" "result: got '$got', want '$want_result'"
  got="$(output_value gate "$dir/output")"
  [ "$got" = "$want_gate" ] || fail "$name" "gate: got '$got', want '$want_gate'"
  got="$(output_value did_not_run_cause "$dir/output")"
  [ "$got" = "$want_cause" ] || fail "$name" "did_not_run_cause: got '$got', want '$want_cause'"

  local error_line
  error_line="$(grep '^::error::' "$dir/stdout" || true)"
  if [ -z "$want_error" ]; then
    [ -z "$error_line" ] || fail "$name" "unexpected annotation: $error_line"
  else
    case "$error_line" in
      *"$want_error"*) ;;
      *) fail "$name" "annotation: got '$error_line', want it to contain '$want_error'" ;;
    esac
  fi

  # The action passes the caller's command line through untouched.
  local want_argv
  # shellcheck disable=SC2086  # split ARGS into words the way the step does
  want_argv="$(printf '%s\n' check $args)"
  got="$(cat "$dir/argv")"
  [ "$got" = "$want_argv" ] || fail "$name" "kapi argv: got '$(tr '\n' ' ' <<< "$got")', want '$(tr '\n' ' ' <<< "$want_argv")'"

  if [ "$failures" = "$before" ]; then
    echo "ok   $name"
  else
    sed 's/^/     | /' "$dir/stdout"
  fi
}

#        name                         args                            output                          exit rc result        gate cause                 annotation
run_case passed                       "content/en.json"               passed.txt                      0    0  passed        pass ""                    ""
run_case failed                       "--ship"                        failed.txt                      3    3  failed        fail ""                    "kapi gate unmet (exit 3)"
run_case checker_invalid-text         "content/en.json"               checker_invalid.txt             4    4  did_not_run   ""   checker_invalid       "kapi check did not run (exit 4, checker_invalid): a checker failed its canary, so this run's result cannot be trusted."
run_case checker_invalid-json         "content/en.json --json"        checker_invalid.json            4    4  did_not_run   ""   checker_invalid       "this run's result cannot be trusted"
run_case nothing_to_check-text        "empty.json"                    nothing_to_check.txt            4    4  did_not_run   ""   nothing_to_check      "kapi check did not run (exit 4, nothing_to_check): there was nothing in scope to check."
run_case nothing_to_check-json        "empty.json --output-format json" nothing_to_check.json         4    4  did_not_run   ""   nothing_to_check      "there was nothing in scope to check"
run_case nothing_to_check-yaml        "empty.json --output-format yaml" nothing_to_check.yaml         4    4  did_not_run   ""   nothing_to_check      "there was nothing in scope to check"
run_case nothing_to_check-color       "empty.json --color always"     nothing_to_check.color.txt      4    4  did_not_run   ""   nothing_to_check      "there was nothing in scope to check"
run_case content_not_checked-ship     "--ship --gate voice"           content_not_checked.ship.txt    4    4  did_not_run   ""   content_not_checked   "kapi check did not run (exit 4, content_not_checked): content in scope was not checked."
run_case content_not_checked-ship-json "--ship --gate voice --json"   content_not_checked.ship.json   4    4  did_not_run   ""   content_not_checked   "content in scope was not checked"
run_case future-cause                 "content/en.json"               future_cause.txt                4    4  did_not_run   ""   some_new_cause        "(exit 4, some_new_cause): kapi gave a cause this version of the action does not describe."
run_case unreadable-cause-json        "content/en.json --json"        unreadable_cause.json           4    4  did_not_run   ""   unknown               "(exit 4, unknown): kapi's output named no cause."
run_case no-cause                     "content/en.json"               ""                              4    4  did_not_run   ""   unknown               "(exit 4, unknown): kapi's output named no cause."
run_case operational-error            "content/en.json"               ""                              1    1  error         ""   ""                    "kapi check failed operationally (exit 1)"
run_case usage-error                  "--no-such-flag"                ""                              2    2  error         ""   ""                    "kapi check failed operationally (exit 2)"

if [ "$failures" -gt 0 ]; then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "all check outcomes passed"
