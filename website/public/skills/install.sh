#!/bin/sh
# Installs OpenTraffic's agent skill, which teaches coding agents to share your dev server and act on
# the feedback people leave on it:
#
#   curl -fsSL https://opentraffic.dev/skill | sh                    for you, in every project
#   curl -fsSL https://opentraffic.dev/skill | sh -s -- --project     for this project (commit it)
#   curl -fsSL https://opentraffic.dev/skill | sh -s -- --uninstall   remove it again
#
# For you, it goes in ~/.claude/skills/opentraffic (Claude Code, opencode) and/or
# ~/.agents/skills/opentraffic (Codex, opencode, and other agents that read ~/.agents), for the agents
# found on this Mac; with --project, in .claude/skills and .agents/skills of the current folder.
set -eu

BASE="https://opentraffic.dev/skills/opentraffic"
FILES="SKILL.md reference.md"

say() { printf '%s\n' "$*"; }
fail() { printf 'opentraffic skill: %s\n' "$*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

scope="user"
action="install"
for arg in "$@"; do
  case "${arg}" in
    --project) scope="project" ;;
    --uninstall) action="uninstall" ;;
    *) fail "unknown option ${arg} (use --project or --uninstall)" ;;
  esac
done

if [ "${scope}" = "project" ]; then
  roots="$(pwd)/.claude/skills $(pwd)/.agents/skills"
else
  roots=""
  if [ -d "${HOME}/.claude" ] || has claude; then roots="${HOME}/.claude/skills"; fi
  if [ -d "${HOME}/.agents" ] || [ -d "${HOME}/.codex" ] || [ -d "${HOME}/.config/opencode" ] || has codex || has opencode; then
    roots="${roots} ${HOME}/.agents/skills"
  fi
  # No agent found: both, so whichever you install next finds it.
  [ -n "${roots}" ] || roots="${HOME}/.claude/skills ${HOME}/.agents/skills"
fi

if [ "${action}" = "uninstall" ]; then
  for root in ${roots}; do
    if [ -f "${root}/opentraffic/SKILL.md" ]; then
      rm -rf "${root}/opentraffic"
      say "Removed ${root}/opentraffic"
    fi
  done
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
for file in ${FILES}; do
  curl -fsSL "${BASE}/${file}" -o "${work}/${file}" || fail "couldn't download ${file}."
done
grep -q '^name: opentraffic$' "${work}/SKILL.md" || fail "the download doesn't look like the OpenTraffic skill."

for root in ${roots}; do
  mkdir -p "${root}/opentraffic"
  for file in ${FILES}; do cp "${work}/${file}" "${root}/opentraffic/${file}"; done
  say "Installed the OpenTraffic skill in ${root}/opentraffic"
done
say "Restart your coding agent to load it, then ask it to share your dev server."
if ! has opentraffic; then
  say "The skill uses the opentraffic command, which comes with OpenTraffic: curl -fsSL https://opentraffic.dev/install | sh"
fi
