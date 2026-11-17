#!/usr/bin/env bash
set -euo pipefail

hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.hooks/pre_tool_use_common.sh
source "$hook_dir/pre_tool_use_common.sh"

normalized_command="$(hook_normalized_command)"
command_prefix='((command|env)[[:space:]]+)*'
git_command='(git|/[[:alnum:]_./-]*/git)'
git_option='([[:space:]]+(-c|-C)[[:space:]]+[^[:space:];&|]+|[[:space:]]+--[^[:space:];&|]+)*'
push_option='([[:space:]]+-[^[:space:];&|]+)*'
upstream_remote="(upstream|\"upstream\"|'upstream')"

if hook_grep_command "$normalized_command" "${HOOK_COMMAND_BOUNDARY}${command_prefix}${git_command}${git_option}[[:space:]]+push${push_option}[[:space:]]+${upstream_remote}${HOOK_COMMAND_END}" \
  || hook_grep_command "$normalized_command" "${HOOK_COMMAND_BOUNDARY}${command_prefix}${git_command}${git_option}[[:space:]]+push${push_option}[[:space:]]+--repo=${upstream_remote}${HOOK_COMMAND_END}"; then
  hook_deny "Blocked git push upstream by repository policy."
fi
