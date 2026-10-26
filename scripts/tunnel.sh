#!/usr/bin/env bash
# Forward SPACE's ports from the Linux host to this Mac over ssh, and write a
# kubeconfig for the host's KinD cluster. Safe to rerun: a tunnel that's
# already up is left alone.
#
#   scripts/tunnel.sh <ssh-host>          start the tunnel
#   scripts/tunnel.sh <ssh-host> --stop   stop it
#   scripts/tunnel.sh <ssh-host> --status   check every forwarded endpoint
#
# <ssh-host> is anything ssh accepts: a ~/.ssh/config alias or user@host.
# SPACE_KIND_CLUSTER picks the KinD cluster (default space-local, as in
# SPACE's install guide).
set -euo pipefail

log() { printf '[tunnel] %s\n' "$*"; }
die() { printf '[tunnel] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $# -ge 1 ]] || die "usage: $0 <ssh-host> [--stop|--status]"
host="$1"
action="${2:-start}"
cluster="${SPACE_KIND_CLUSTER:-space-local}"

# API, data plane, UI, object storage, Tilt UI.
ports="8080 8090 3000 8333 10350"

state_dir="$HOME/.space-on-kind"
mkdir -p "$state_dir"
sock="$state_dir/tunnel-${host//[^A-Za-z0-9._-]/_}.sock"
kubeconfig="$HOME/.kube/space-on-kind.yaml"

running() { ssh -S "$sock" -O check "$host" >/dev/null 2>&1; }

# Probe each forwarded endpoint through the tunnel. Returns non-zero if any
# fails, so --status can be used in scripts.
check_endpoints() {
  local bad=0 name url code
  while read -r name url; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" || true)"
    if [[ "$code" == 200 ]]; then
      printf '[tunnel]   ok    %-15s %s\n' "$name" "$url"
    else
      printf '[tunnel]   FAIL  %-15s %s (HTTP %s)\n' "$name" "$url" "${code:-none}"
      bad=1
    fi
  done <<'ENDPOINTS'
API             http://127.0.0.1:8080/healthz
Data-plane      http://127.0.0.1:8090/healthz
UI              http://127.0.0.1:3000/login
Object-storage  http://127.0.0.1:8333/healthz
Tilt-UI         http://127.0.0.1:10350/
ENDPOINTS
  if [[ -f "$kubeconfig" ]] && command -v kubectl >/dev/null 2>&1; then
    if kubectl get --raw /readyz --request-timeout=5s --kubeconfig "$kubeconfig" --context "kind-$cluster" >/dev/null 2>&1; then
      printf '[tunnel]   ok    %-15s kubectl --kubeconfig %s\n' "KinD-API" "$kubeconfig"
    else
      printf '[tunnel]   FAIL  %-15s kubectl --kubeconfig %s\n' "KinD-API" "$kubeconfig"
      bad=1
    fi
  fi
  return "$bad"
}

case "$action" in
  --stop)
    if running; then
      ssh -S "$sock" -O exit "$host" >/dev/null 2>&1
      log "tunnel to $host stopped"
    else
      log "no tunnel to $host is running"
    fi
    exit 0
    ;;
  --status)
    if ! running; then
      log "tunnel to $host is down; start it with: $0 $host"
      exit 1
    fi
    log "tunnel to $host is up; checking endpoints:"
    if check_endpoints; then
      log "all endpoints answer"
    else
      log "some endpoints don't answer; the tunnel is up, so check SPACE on $host"
      exit 1
    fi
    exit 0
    ;;
  start) ;;
  *) die "unknown action: $action" ;;
esac

if running; then
  log "tunnel to $host is already up; check it with: $0 $host --status"
  exit 0
fi

# KinD's API server listens on a random loopback port on the host. Read it from
# the cluster's kubeconfig and forward the same port, so the certificate (issued
# for 127.0.0.1) still matches.
remote_kubeconfig="$(ssh "$host" "PATH=\$HOME/.local/bin:\$PATH kind get kubeconfig --name '$cluster'" 2>/dev/null || true)"
api_port=""
if [[ -n "$remote_kubeconfig" ]]; then
  api_port="$(printf '%s\n' "$remote_kubeconfig" | sed -n 's#.*server: https://127\.0\.0\.1:\([0-9]*\).*#\1#p' | head -1)"
fi
if [[ -z "$api_port" ]]; then
  log "KinD cluster '$cluster' not found on $host; forwarding SPACE ports only"
fi

forwards=()
for port in $ports $api_port; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    die "local port $port is already in use: $(lsof -nP -iTCP:"$port" -sTCP:LISTEN | awk 'NR == 2 { print $1 " (pid " $2 ")" }')"
  fi
  forwards+=(-L "127.0.0.1:$port:127.0.0.1:$port")
done

ssh -f -N -M -S "$sock" \
  -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  "${forwards[@]}" "$host"
log "tunnel to $host is up: ports $ports${api_port:+ $api_port}"

if [[ -n "$api_port" ]]; then
  mkdir -p "$(dirname "$kubeconfig")"
  printf '%s\n' "$remote_kubeconfig" > "$kubeconfig"
  chmod 600 "$kubeconfig"
  log "kubeconfig written to $kubeconfig"
  log "  kubectl get pods -n space --kubeconfig $kubeconfig --context kind-$cluster"
fi

log "checking endpoints:"
check_endpoints || log "some endpoints don't answer yet; rerun with --status once SPACE is up"
