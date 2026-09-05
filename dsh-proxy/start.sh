#!/usr/bin/env bash

# Start the local dsh Web server, login service, and foreground Nginx instance.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AUTH_ENV="$SCRIPT_DIR/.env"
PROXY_HOME="${DSH_PROXY_HOME:-$SCRIPT_DIR/.dsh-home}"
export DSH_HOME="$PROXY_HOME"
RUNTIME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dsh-proxy.XXXXXX")"

PUBLIC_PORT=3080
DSH_PORT=3081
AUTH_PORT=3082
STOP_GRACE_SECONDS=5

# Space-separated authorities accepted by dsh's browser-trust fence. The
# reverse proxy preserves the browser Host header, so every public authority
# must be declared here explicitly.
TRUSTED_HOSTS_VALUE="${DSH_TRUSTED_HOSTS:-}"
TRUSTED_HOST_ARGS=()
if [[ -n "$TRUSTED_HOSTS_VALUE" ]]; then
  read -r -a trusted_hosts <<< "$TRUSTED_HOSTS_VALUE"
  for authority in "${trusted_hosts[@]}"; do
    [[ -n "$authority" ]] || continue
    TRUSTED_HOST_ARGS+=(--trusted-host "$authority")
  done
fi

declare -a CHILD_PIDS=()
declare -a CHILD_NAMES=()
CLEANING_UP=0

fail() {
  printf 'dsh-proxy: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

port_pids() {
  {
    if command -v lsof >/dev/null 2>&1; then
      lsof -nP -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null || true
    fi
    ss -ltnH "sport = :$1" 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p'
  } | awk 'NF { print $1 }' | sort -u
}

port_is_listening() {
  [[ -n "$(ss -ltnH "sport = :$1" 2>/dev/null)" ]]
}

stop_port_users() {
  local port="$1"
  local pid
  local -a pids=()

  if ! port_is_listening "$port"; then return; fi
  mapfile -t pids < <(port_pids "$port")
  if ((${#pids[@]} == 0)); then
    fail "port $port is occupied, but no listener PID is visible; stop that service manually"
  fi

  printf 'dsh-proxy: port %s is occupied; stopping PID(s): %s\n' "$port" "${pids[*]}"
  for pid in "${pids[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done

  local deadline=$((SECONDS + STOP_GRACE_SECONDS))
  while port_is_listening "$port"; do
    if ((SECONDS >= deadline)); then break; fi
    sleep 0.2
  done

  mapfile -t pids < <(port_pids "$port")
  if port_is_listening "$port" && ((${#pids[@]} == 0)); then
    fail "port $port is still occupied, but no listener PID is visible"
  fi
  for pid in "${pids[@]}"; do
    printf 'dsh-proxy: PID %s did not stop; sending SIGKILL\n' "$pid"
    kill -KILL "$pid" 2>/dev/null || true
  done

  deadline=$((SECONDS + STOP_GRACE_SECONDS))
  while port_is_listening "$port"; do
    if ((SECONDS >= deadline)); then fail "port $port is still occupied after termination"; fi
    sleep 0.2
  done
}

group_alive() { kill -0 -- "-$1" 2>/dev/null; }

stop_child() {
  local pid="$1"
  local name="$2"
  if ! group_alive "$pid"; then wait "$pid" 2>/dev/null || true; return; fi
  printf 'dsh-proxy: stopping %s (process group %s)\n' "$name" "$pid"
  kill -TERM -- "-$pid" 2>/dev/null || true
  local deadline=$((SECONDS + STOP_GRACE_SECONDS))
  while group_alive "$pid"; do
    if ((SECONDS >= deadline)); then
      printf 'dsh-proxy: %s did not stop; sending SIGKILL\n' "$name" >&2
      kill -KILL -- "-$pid" 2>/dev/null || true
      break
    fi
    sleep 0.2
  done
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  if ((CLEANING_UP)); then return; fi
  CLEANING_UP=1
  trap - EXIT INT TERM
  local i
  for ((i = ${#CHILD_PIDS[@]} - 1; i >= 0; i--)); do
    stop_child "${CHILD_PIDS[i]}" "${CHILD_NAMES[i]}"
  done
  rm -f "$RUNTIME_DIR"/*.pid
  rmdir "$RUNTIME_DIR" 2>/dev/null || true
}

on_interrupt() { exit 130; }
trap cleanup EXIT
trap on_interrupt INT TERM

start_child() {
  local name="$1"
  shift
  local pid_file="$RUNTIME_DIR/$name.pid"
  setsid bash -c 'printf "%s\\n" "$$" > "$1"; shift; exec "$@"' bash "$pid_file" "$@" &
  local pid=''
  local deadline=$((SECONDS + STOP_GRACE_SECONDS))
  while [[ ! -s "$pid_file" ]]; do
    if ((SECONDS >= deadline)); then
      fail "$name did not publish its process ID"
    fi
    sleep 0.05
  done
  read -r pid < "$pid_file"
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    fail "$name published an invalid process ID"
  fi
  CHILD_PIDS+=("$pid")
  CHILD_NAMES+=("$name")
  printf 'dsh-proxy: started %s (process group %s)\n' "$name" "$pid"
}

wait_for_port() {
  local port="$1"
  local name="$2"
  local child_pid="${3:-}"
  local deadline=$((SECONDS + 30))
  while ! port_is_listening "$port"; do
    if [[ -n "$child_pid" ]] && ! group_alive "$child_pid"; then
      fail "$name exited before listening on port $port"
    fi
    if ((SECONDS >= deadline)); then fail "$name did not listen on port $port within 30 seconds"; fi
    sleep 0.2
  done
  printf 'dsh-proxy: %s is listening on 127.0.0.1:%s\n' "$name" "$port"
}

require_command node
require_command nginx
require_command setsid
require_command ss

[[ -f "$AUTH_ENV" ]] || fail "missing $AUTH_ENV; copy a configured auth .env before starting"
[[ -f "$SCRIPT_DIR/nginx.conf" ]] || fail "missing $SCRIPT_DIR/nginx.conf"
[[ -f "$SCRIPT_DIR/dsh-web.nginx.conf" ]] || fail "missing $SCRIPT_DIR/dsh-web.nginx.conf"
[[ -x "$SCRIPT_DIR/dsh" ]] || fail "missing executable $SCRIPT_DIR/dsh"
mkdir -p "$DSH_HOME" || fail "cannot create isolated DSH_HOME: $DSH_HOME"

chmod 600 "$AUTH_ENV" || fail "cannot restrict permissions on $AUTH_ENV"
nginx -p "$SCRIPT_DIR/" -c nginx.conf -t

for port in "$PUBLIC_PORT" "$DSH_PORT" "$AUTH_PORT"; do stop_port_users "$port"; done

start_child dsh "$SCRIPT_DIR/dsh" web --no-open --host 127.0.0.1 --port "$DSH_PORT" --trust-proxy-auth "${TRUSTED_HOST_ARGS[@]}"
DSH_PID="${CHILD_PIDS[${#CHILD_PIDS[@]} - 1]}"
wait_for_port "$DSH_PORT" dsh "$DSH_PID"

start_child auth node "$SCRIPT_DIR/auth-server.mjs"
AUTH_PID="${CHILD_PIDS[${#CHILD_PIDS[@]} - 1]}"
wait_for_port "$AUTH_PORT" auth "$AUTH_PID"

start_child nginx nginx -p "$SCRIPT_DIR/" -c nginx.conf -g 'daemon off;'
NGINX_PID="${CHILD_PIDS[${#CHILD_PIDS[@]} - 1]}"
wait_for_port "$PUBLIC_PORT" nginx "$NGINX_PID"

printf 'dsh-proxy: ready at http://127.0.0.1:%s\n' "$PUBLIC_PORT"
printf 'dsh-proxy: press Ctrl-C to stop dsh, auth, and nginx\n'

while :; do
  for i in "${!CHILD_PIDS[@]}"; do
    if ! group_alive "${CHILD_PIDS[i]}"; then
      printf 'dsh-proxy: %s exited unexpectedly\n' "${CHILD_NAMES[i]}" >&2
      exit 1
    fi
  done
  sleep 1
done
