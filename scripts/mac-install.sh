#!/usr/bin/env bash
# Install the Mac-side tools for space-on-kind. Safe to rerun: anything already
# installed is left alone.
#
# The Mac is only the client. SPACE, Docker and KinD run on the Linux host, so
# this installs just what talks to it: kubectl and jq. ssh and curl ship with
# macOS.
set -euo pipefail

log() { printf '[mac-prereqs] %s\n' "$*"; }
die() { printf '[mac-prereqs] ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "this script is for macOS; on the Linux host use scripts/host-install.sh"

# command name -> Homebrew formula. A tool counts as installed if it's on PATH,
# however it got there; Homebrew is only used for the missing ones.
tools="kubectl:kubernetes-cli jq:jq"

for entry in $tools; do
  cmd="${entry%%:*}"
  formula="${entry#*:}"
  if command -v "$cmd" >/dev/null 2>&1; then
    log "$cmd already installed ($(command -v "$cmd")), skipping"
    continue
  fi
  if ! command -v brew >/dev/null 2>&1; then
    die "$cmd is missing and Homebrew isn't installed. Install $cmd your own way, or install Homebrew from https://brew.sh and rerun."
  fi
  log "installing $cmd (brew formula $formula)"
  brew install "$formula"
done

for cmd in ssh curl; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is missing; it normally ships with macOS"
done

log "Mac tools ready"
