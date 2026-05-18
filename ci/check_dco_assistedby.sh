#!/usr/bin/env bash
# Enforce the kernel AI coding-assistant + DCO policy on commit messages
# (plan §9.2; faithful to references/linux-mainline/Documentation/process/
# coding-assistants.rst). Checks the range of commits given (default: commits
# not on origin/main, else HEAD).
#
#  R1: an AI agent must NOT add Signed-off-by  -> reject agent-looking SoB
#  R2: Assisted-by: must not stand alone       -> require >=1 human Signed-off-by
#  R3: Assisted-by: must match the documented format
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
RANGE="${1:-}"
if [[ -z "$RANGE" ]]; then
  if git rev-parse --verify -q origin/main >/dev/null; then RANGE="origin/main..HEAD"; else RANGE="HEAD~0..HEAD"; fi
fi
fail=0
# format from coding-assistants.rst: Assisted-by: AGENT_NAME:MODEL_VERSION [TOOL1] [TOOL2]
AB_RE='^Assisted-by:[[:space:]]+[^:[:space:]]+:[^[:space:]]+([[:space:]]+[^[:space:]]+)*[[:space:]]*$'
AGENT_RE='(claude|gpt|copilot|gemini|llama|aider|openhands|devin|bot|\[bot\])'

commits=$(git rev-list "$RANGE" 2>/dev/null) || { echo "PASS (no commit range / no repo history yet)"; exit 0; }
[[ -z "$commits" ]] && { echo "PASS (no commits in range $RANGE)"; exit 0; }

for c in $commits; do
  msg=$(git log -1 --format=%B "$c")
  sob=$(grep -iE '^Signed-off-by:' <<<"$msg" || true)
  ab=$(grep -iE '^Assisted-by:'  <<<"$msg" || true)

  # R1
  if grep -qiE "^Signed-off-by:.*$AGENT_RE" <<<"$sob"; then
    echo "FAIL $c: agent-looking Signed-off-by (R1, §9.2: only humans certify the DCO)"; fail=1
  fi
  # R2
  if [[ -n "$ab" && -z "$sob" ]]; then
    echo "FAIL $c: Assisted-by without any human Signed-off-by (R2, §9.2)"; fail=1
  fi
  # R3
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    grep -qE "$AB_RE" <<<"$line" || { echo "FAIL $c: malformed '$line' (R3 — expected 'Assisted-by: NAME:MODEL [TOOL...]')"; fail=1; }
  done <<<"$ab"
done
[[ $fail -eq 0 ]] && echo "PASS DCO/Assisted-by policy clean over $RANGE"
exit $fail
