#!/usr/bin/env bash
# Asks before an edit removes a Bond contract.
#
# Why this exists, from the session that prompted it: the rules against deleting
# a contract are correct, present, and were walked past anyway. `contracts.md`,
# the `bond` usage rules, the `writing-bond-contracts` skill and project memory
# all say the right thing, and none of them fires at the moment of decision —
# because the error *produces confidence*. Having constructed a reason why an
# assertion "cannot fail" feels like having checked.
#
# So this is keyed on the **action** rather than the topic. It does not care how
# good the reason is; it interrupts the edit and makes deletion a thing Jason
# says yes to.
#
# Reads a PreToolUse payload on stdin. Answers "ask" when an edit to Elixir
# source lowers the number of contract attributes. False positives are cheap —
# one confirmation — and the failure it guards is not.

set -uo pipefail

payload=$(cat)
tool=$(printf '%s' "$payload" | jq -r '.tool_name // ""')

# `@post` also covers `@post_strengthen`; the trailing class catches both.
ATTRS='@(pre|post|invariant|state_invariant|transition_invariant)[[:space:]_(]'

count() { printf '%s' "${1:-}" | grep -oE "$ATTRS" 2>/dev/null | wc -l | tr -d ' '; }
elixir?() { [[ "${1:-}" == *.ex || "${1:-}" == *.exs ]]; }

ask() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

REASON='This edit removes a Bond contract.

`⚠ never failed` is a question with FOUR answers, and only one is "delete":

  1. It transcribes HOW the body works   -> restate it as WHAT the function promises
  2. The body guards it twice by ACCIDENT -> delete the redundant GUARD, keep the contract
  3. Two guards independently sufficient  -> keep both, mutate them together
  4. A true law, unfalsifiable by data    -> KEEP IT, prove it by mutation

"The implementation makes this true by construction" is the implementation view,
and it is not on that list. A surviving mutation is evidence about the MUTATION
until proven otherwise — aim another one before concluding anything.

Load the `writing-bond-contracts` skill and justify this to Jason before proceeding.'

case "$tool" in
  Edit|MultiEdit)
    path=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // ""')
    elixir? "$path" || exit 0
    before=$(count "$(printf '%s' "$payload" | jq -r '[.tool_input.old_string, (.tool_input.edits // [])[].old_string] | map(select(. != null)) | join("\n")')")
    after=$(count "$(printf '%s' "$payload" | jq -r '[.tool_input.new_string, (.tool_input.edits // [])[].new_string] | map(select(. != null)) | join("\n")')")
    (( after < before )) && ask "$REASON"
    ;;

  Write)
    path=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // ""')
    elixir? "$path" || exit 0
    [[ -f "$path" ]] || exit 0
    before=$(count "$(cat "$path")")
    after=$(count "$(printf '%s' "$payload" | jq -r '.tool_input.content // ""')")
    (( after < before )) && ask "$REASON"
    ;;

  Bash)
    # The gap an Edit-only hook leaves wide open: a contract can be deleted by a
    # heredoc'd python/sed script just as easily, and in this project it usually
    # is. Heuristic, deliberately: a command that both quotes a contract
    # attribute and looks like it writes a file.
    cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')
    printf '%s' "$cmd" | grep -qE "$ATTRS" || exit 0
    printf '%s' "$cmd" | grep -qE "(open\([^)]*['\"]w|\.write\(|>[[:space:]]*[^|&>]*\.exs?|tee[[:space:]]|sed[[:space:]]+-i)" || exit 0
    ask "$REASON

(Matched a shell command that quotes a contract attribute and writes a file. If
this edit does not remove one, say so and re-run.)"
    ;;
esac

exit 0
