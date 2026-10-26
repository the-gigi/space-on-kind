#!/usr/bin/env bash
# Install SPACE on a Linux host and bring it up on KinD.
#
# Runs on the host. scripts/install.sh on the Mac copies it there and runs it;
# you can also run it on the host directly with `bash host-install.sh`.
#
# It checks every host prerequisite first and stops before changing anything
# if one fails. Then it follows SPACE's install guide:
# https://github.com/perplexityai/SPACE/blob/main/docs/installation.md
#
# Safe to rerun. Every step skips what's already done: an existing checkout is
# left as is, installed tools are kept, and SPACE's bring-up reuses a live
# stack. While an install is running, rerunning attaches to it.
#
# The first run takes a while (it compiles SPACE's Rust workspace), so the
# script reruns itself inside a tmux session, `space-install`. If ssh drops,
# rerun scripts/install.sh (or this script) to get back to it.
#
# Settings (environment variables):
#   SPACE_DIR               SPACE checkout (default: ~/SPACE)
#   SPACE_REPO              repo to clone when SPACE_DIR is missing
#   SPACE_KIND_CLUSTER      KinD cluster name (default: space-local)
#   SPACE_CONSOLE_PASSWORD  initial root@local password (default: password)
#   SPACE_INSTALL_NO_TMUX   set to 1 to run in the current shell
#   SPACE_CHECK_ONLY        set to 1 to run the prerequisite checks and stop
set -uo pipefail

INSTALL_GUIDE=https://github.com/perplexityai/SPACE/blob/main/docs/installation.md
MIN_FREE_GIB=30
TMUX_SESSION=space-install

SPACE_DIR="${SPACE_DIR:-$HOME/SPACE}"
SPACE_REPO="${SPACE_REPO:-https://github.com/perplexityai/SPACE.git}"
export SPACE_KIND_CLUSTER="${SPACE_KIND_CLUSTER:-space-local}"
export SPACE_VENDOR_ROOT="${SPACE_VENDOR_ROOT:-$HOME/.local/share/space/vendor}"
export INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
export PATH="$INSTALL_DIR:$PATH"
KCTX="kind-$SPACE_KIND_CLUSTER"
API_URL=http://127.0.0.1:8080

step() { printf '\n==> %s\n' "$*"; }
log() { printf '    %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# --- tmux ----------------------------------------------------------------------

# Empty when the script is piped in with `bash -s`.
self=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
fi

if [[ -z "${TMUX:-}" && "${SPACE_INSTALL_NO_TMUX:-}" != 1 && "${SPACE_CHECK_ONLY:-}" != 1 ]]; then
  if [[ -z "$self" ]]; then
    echo "Running without tmux: the script came from stdin, so it can't rerun itself."
    echo "For a long install, copy it to the host and run it from a file instead."
  elif ! command -v tmux >/dev/null 2>&1 && ! { sudo -n true 2>/dev/null && command -v apt-get >/dev/null 2>&1 \
      && sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tmux >/dev/null; }; then
    echo "tmux isn't installed and couldn't be installed; running in this shell."
  elif tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "An install is already running in tmux session '$TMUX_SESSION'; attaching."
    exec tmux attach-session -t "$TMUX_SESSION"
  else
    exec tmux new-session -s "$TMUX_SESSION" \
      "bash '$self'; echo; echo 'Finished. This tmux session stays open; exit the shell to close it.'; exec bash -l"
  fi
fi

# --- 1. prerequisites ----------------------------------------------------------

failures=0
warnings=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; failures=$((failures + 1)); }
warn() { printf '  warn  %s\n' "$*"; warnings=$((warnings + 1)); }
free_gib() { df -Pk "$1" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1048576 }'; }

step "Checking host prerequisites"

echo "Platform"
platform="$(uname -s):$(uname -m)"
if [[ "$platform" == "Linux:x86_64" ]]; then
  pass "Linux x86_64"
else
  fail "need Linux x86_64, this is $platform"
fi

echo "Devices"
if [[ -c /dev/kvm ]]; then
  if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    pass "/dev/kvm is readable and writable"
  else
    fail "/dev/kvm exists but $(id -un) can't read and write it (add the user to the kvm group, then log in again)"
  fi
else
  fail "/dev/kvm is missing (enable virtualization in the BIOS, or nested virtualization on a VM)"
fi
if [[ -c /dev/net/tun ]]; then pass "/dev/net/tun"; else fail "/dev/net/tun is missing"; fi
if [[ -c /dev/loop-control ]]; then pass "loop devices"; else fail "/dev/loop-control is missing (load the loop module)"; fi
if grep -qw btrfs /proc/filesystems 2>/dev/null || modinfo btrfs >/dev/null 2>&1; then
  pass "btrfs support"
else
  fail "no btrfs support in this kernel"
fi

echo "Tools"
for tool in bash git curl tar openssl ssh-keygen docker; do
  if command -v "$tool" >/dev/null 2>&1; then pass "$tool"; else fail "$tool is missing"; fi
done
if command -v python3 >/dev/null 2>&1; then
  py_version="$(python3 -c 'import platform; print(platform.python_version())' 2>/dev/null || echo unknown)"
  if python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))'; then
    pass "python3 $py_version (SPACE needs 3.8+)"
  else
    fail "python3 $py_version is too old (SPACE needs 3.8+)"
  fi
else
  fail "python3 is missing (SPACE needs 3.8+)"
fi
if sudo -n true 2>/dev/null; then
  pass "non-interactive sudo"
else
  warn "no non-interactive sudo; SPACE's prerequisite installer can't install system packages"
fi
if command -v apt-get >/dev/null 2>&1; then
  pass "apt-based"
else
  warn "not apt-based; SPACE's installer skips system packages, so install jq, lsof and unzip yourself"
  for pkg in jq lsof unzip; do
    command -v "$pkg" >/dev/null 2>&1 || fail "$pkg is missing"
  done
fi

echo "Docker"
if docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
  pass "daemon reachable (server $(docker version --format '{{.Server.Version}}'))"
  if docker run --rm --privileged busybox true >/dev/null 2>&1; then
    pass "privileged containers run"
  else
    fail "can't run a privileged container (docker run --privileged busybox)"
  fi
else
  fail "can't reach the Docker daemon as $(id -un) (is it running, and is the user in the docker group?)"
fi

echo "Disk (need ${MIN_FREE_GIB} GiB free)"
docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
# The 30 GiB is headroom for the first build. Once the cluster exists, that
# build has already used some of it, so low space only warns, as SPACE's own
# bring-up does; a hard failure here would block every rerun.
installed=0
if command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null | grep -qx "$SPACE_KIND_CLUSTER"; then
  installed=1
fi
for path in "$HOME" ${docker_root:+"$docker_root"}; do
  gib="$(free_gib "$path")"
  if [[ -z "$gib" ]]; then
    warn "can't read free space for $path"
  elif (( gib >= MIN_FREE_GIB )); then
    pass "$path has ${gib} GiB free"
  elif (( installed )); then
    warn "$path has only ${gib} GiB free; fine for a rerun, but rebuilds may run out"
  else
    fail "$path has only ${gib} GiB free"
  fi
done

echo
if (( failures > 0 )); then
  echo "$failures check(s) failed, $warnings warning(s). Nothing was installed."
  echo "Host requirements: $INSTALL_GUIDE#before-you-begin"
  exit 1
fi
echo "All required checks passed ($warnings warning(s))."
if [[ "${SPACE_CHECK_ONLY:-}" == 1 ]]; then
  exit 0
fi

# From here on, stop at the first failure.
set -e

# --- 2. SPACE checkout ---------------------------------------------------------

step "SPACE checkout"
if [[ -d "$SPACE_DIR/.git" ]]; then
  log "using the existing checkout at $SPACE_DIR ($(git -C "$SPACE_DIR" rev-parse --short HEAD) on $(git -C "$SPACE_DIR" branch --show-current))"
else
  [[ ! -e "$SPACE_DIR" ]] || die "$SPACE_DIR exists but isn't a git checkout; move it or set SPACE_DIR"
  log "cloning $SPACE_REPO into $SPACE_DIR"
  git clone -q "$SPACE_REPO" "$SPACE_DIR"
fi
cd "$SPACE_DIR"
[[ -f infra/space/kind/scripts/up.sh ]] || die "$SPACE_DIR doesn't look like a SPACE checkout"

# --- 3. tools ------------------------------------------------------------------

step "Host tools (KinD, kubectl, Helm, Tilt, Go, ...)"
mkdir -p "$INSTALL_DIR"
# Put INSTALL_DIR on PATH for future Bash logins, once.
path_line='case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'
login_rc="$HOME/.profile"
for rc in "$HOME/.bash_profile" "$HOME/.bash_login"; do
  if [[ -f "$rc" ]]; then login_rc="$rc"; break; fi
done
for rc in "$login_rc" "$HOME/.bashrc"; do
  touch "$rc"
  if ! grep -Fxq "$path_line" "$rc"; then
    printf '\n%s\n' "$path_line" >> "$rc"
    log "added $INSTALL_DIR to PATH in $rc"
  fi
done
bash infra/space/kind/scripts/install-prereqs.sh
missing=()
for tool in kind kubectl helm grpcurl tilt go jq; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
(( ${#missing[@]} == 0 )) || die "still missing after the prerequisite installer: ${missing[*]}"
log "all tools on PATH"

# --- 4. bring-up ---------------------------------------------------------------

step "Firecracker and guest kernel"
# The default storage mode doesn't use AWS credentials; keep any in the shell
# out of the cluster.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
bash infra/space/kind/scripts/install-fc-vendor.sh

step "Bringing up SPACE on KinD cluster '$SPACE_KIND_CLUSTER' (the first run builds everything)"
log "Tilt UI: http://localhost:10350, log: ~/.space-devbox/kind/tilt-$SPACE_KIND_CLUSTER.log"
bash infra/space/kind/scripts/up.sh

# --- 5. verify -----------------------------------------------------------------

step "Verifying the installation"
kubectl wait --for=condition=complete job/space-seed-publish --timeout=300s -n space --context "$KCTX"
for ds in $(bash infra/space/kind/lib/node-services.sh daemonsets); do
  kubectl rollout status "ds/$ds" --timeout=300s -n space --context "$KCTX"
done
curl --noproxy '*' --fail-with-body --silent --show-error --max-time 15 \
  "$API_URL/openapi-m1.json" | jq -e '.openapi and .paths' >/dev/null
log "API is serving its OpenAPI document"

token="$(
  SPACE_CONSOLE_PASSWORD="${SPACE_CONSOLE_PASSWORD:-password}" \
    jq -nc '{email:"root@local",password:env.SPACE_CONSOLE_PASSWORD}' |
  curl --noproxy '*' --fail-with-body --silent --show-error --max-time 15 \
    -H 'Content-Type: application/json' --data-binary @- \
    "$API_URL/auth/v1/sessions" |
  jq -er '.token | select(type == "string" and length > 0)'
)" || die "couldn't log in as root@local; if you changed its password, set SPACE_CONSOLE_PASSWORD"
curl --noproxy '*' --fail-with-body --silent --show-error --max-time 15 \
  -H "Authorization: Bearer $token" "$API_URL/v1/sandboxes?limit=1" >/dev/null
unset token
log "logged in as root@local and listed sandboxes"

cat <<EOF

SPACE is up on KinD cluster '$SPACE_KIND_CLUSTER'.

  API         $API_URL
  Data plane  http://127.0.0.1:8090
  UI          http://127.0.0.1:3000   (root@local)
  Tilt UI     http://127.0.0.1:10350

From the Mac, forward these with:  scripts/tunnel.sh <host>
Then try SPACE's first sandbox:
  https://github.com/perplexityai/SPACE/blob/main/docs/first-sandbox.md
EOF
