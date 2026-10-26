#!/usr/bin/env bash
# One command, run on the Mac: install the Mac tools, then install SPACE on the
# Linux host and bring it up on KinD.
#
#   scripts/install.sh --space-host <host>
#   SPACE_HOST=<host> scripts/install.sh
#
# <host> is anything ssh accepts: a ~/.ssh/config alias or user@host.
#
# Steps:
#   1. scripts/mac-install.sh installs the Mac-side tools.
#   2. Checks that ssh reaches the host without a password prompt.
#   3. Copies scripts/host-install.sh to ~/.space-on-kind/ on the host.
#   4. Runs it there over `ssh -t`. It checks the host's prerequisites, stops
#      if any fail, and otherwise installs SPACE. It runs inside a tmux session
#      on the host, so if ssh drops, rerun this command to reattach.
#
# Safe to rerun: every step skips what's already done.
#
# Options:
#   --space-host <host>  the Linux host (overrides SPACE_HOST)
#   --check-only         run the host's prerequisite checks and stop
#   -h, --help           show this help
#
# These settings are passed through to host-install.sh when set:
#   SPACE_DIR, SPACE_REPO, SPACE_KIND_CLUSTER, SPACE_CONSOLE_PASSWORD,
#   SPACE_INSTALL_NO_TMUX, SPACE_CHECK_ONLY
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Quoted so ~ expands on the host, not here.
remote_dir='~/.space-on-kind'
remote_script="$remote_dir/host-install.sh"
passthrough="SPACE_DIR SPACE_REPO SPACE_KIND_CLUSTER SPACE_CONSOLE_PASSWORD SPACE_INSTALL_NO_TMUX SPACE_CHECK_ONLY"

log() { printf '[install] %s\n' "$*"; }
die() { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; }

host="${SPACE_HOST:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --space-host) [[ $# -ge 2 ]] || die "--space-host needs a value"; host="$2"; shift 2 ;;
    --space-host=*) host="${1#*=}"; shift ;;
    --check-only) export SPACE_CHECK_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[[ -n "$host" ]] || die "no host given: pass --space-host <host> or set SPACE_HOST"

log "1/4 Mac tools"
bash "$here/mac-install.sh"

log "2/4 ssh to $host"
if ! ssh -o BatchMode=yes -o ConnectTimeout=15 "$host" true; then
  die "can't ssh to $host without a password prompt; see 'Set up ssh' in SETUP.md"
fi

log "3/4 copying host-install.sh to $host:$remote_script"
ssh -o BatchMode=yes "$host" "mkdir -p $remote_dir && cat > $remote_script" < "$here/host-install.sh"

log "4/4 running host-install.sh on $host"
env_args=""
for name in $passthrough; do
  if [[ -n "${!name:-}" ]]; then
    env_args+=" $name=$(printf '%q' "${!name}")"
  fi
done
exec ssh -t "$host" "env$env_args bash $remote_script"
