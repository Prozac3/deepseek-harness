#!/usr/bin/env bash

# Build a self-contained production app directory that starts without pnpm.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SKIP_BUILD=0
if [[ "${1:-}" == "--skip-build" ]]; then
  SKIP_BUILD=1
  shift
fi
if (($# > 1)); then
  printf 'Usage: %s [--skip-build] [absolute-target-directory]\n' "$0" >&2
  exit 2
fi
TARGET_DIR="$(realpath -m -- "${1:-${HOME:?HOME is not set}/app}")"
TARGET_PARENT="$(dirname -- "$TARGET_DIR")"
TARGET_NAME="$(basename -- "$TARGET_DIR")"
MARKER_FILE=".dsh-proxy-app"
SMOKE_PID=''
SOURCE_DEPENDENCIES_PRUNED=0

fail() {
  printf 'dsh-proxy deploy: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

[[ "$TARGET_DIR" = /* ]] || fail "target must be an absolute path: $TARGET_DIR"
[[ "$TARGET_DIR" != "/" ]] || fail "refusing to deploy over /"
[[ "$TARGET_DIR" != "${HOME:?HOME is not set}" ]] || fail "refusing to deploy over the home directory"
[[ "$TARGET_DIR" != "$REPO_DIR" ]] || fail "refusing to deploy over the source checkout"

if [[ -e "$TARGET_DIR" && ! -d "$TARGET_DIR" ]]; then
  fail "target exists and is not a directory: $TARGET_DIR"
fi
if [[ -d "$TARGET_DIR" && -n "$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -print -quit)" && ! -f "$TARGET_DIR/$MARKER_FILE" ]]; then
  fail "target is not an app directory managed by this script: $TARGET_DIR"
fi

require_command node
require_command pnpm
require_command realpath
require_command rsync
require_command ss

mkdir -p "$TARGET_PARENT"
STAGING_ROOT="$(mktemp -d "$TARGET_PARENT/.${TARGET_NAME}.deploy.XXXXXX")"
STAGING_APP="$STAGING_ROOT/app"

cleanup() {
  if [[ -n "$SMOKE_PID" ]]; then
    kill -TERM "$SMOKE_PID" 2>/dev/null || true
    wait "$SMOKE_PID" 2>/dev/null || true
  fi
  if ((SOURCE_DEPENDENCIES_PRUNED)); then
    CI=true pnpm --dir "$REPO_DIR" install --offline --ignore-scripts --no-frozen-lockfile >/dev/null \
      || printf 'dsh-proxy deploy: warning: could not restore source development dependencies\n' >&2
  fi
  rm -rf -- "$STAGING_ROOT"
}
trap cleanup EXIT

if ((SKIP_BUILD)); then
  printf 'dsh-proxy deploy: using existing source artifacts\n'
else
  printf 'dsh-proxy deploy: building source artifacts\n'
  pnpm --dir "$REPO_DIR" run build
fi

printf 'dsh-proxy deploy: collecting production dependencies\n'
SOURCE_DEPENDENCIES_PRUNED=1
pnpm --dir "$REPO_DIR" --filter dsh-python-runtime-closure deploy --legacy --prod \
  --ignore-scripts \
  --config.node-linker=hoisted \
  --config.auto-install-peers=false \
  --config.link-workspace-packages=true \
  "$STAGING_APP"
CI=true pnpm --dir "$REPO_DIR" install --offline --ignore-scripts --no-frozen-lockfile >/dev/null
SOURCE_DEPENDENCIES_PRUNED=0

while IFS= read -r dependency; do
  destination="$STAGING_APP/node_modules/$dependency"
  source_package="$REPO_DIR/python/sdk-runtime/node_modules/$dependency"
  [[ -e "$source_package" ]] || fail "production dependency is unavailable: $dependency"
  if [[ -e "$destination" || -L "$destination" ]]; then rm -rf -- "$destination"; fi
  mkdir -p "$(dirname -- "$destination")"
  rsync -aL --exclude 'node_modules/' "$source_package/" "$destination/"
done < <(node -e "const p=require(process.argv[1]); for (const name of Object.keys(p.dependencies ?? {}).sort()) console.log(name)" "$STAGING_APP/package.json")

cp "$SCRIPT_DIR/$MARKER_FILE" "$STAGING_APP/$MARKER_FILE"
cp "$SCRIPT_DIR/auth-server.mjs" "$STAGING_APP/auth-server.mjs"
cp "$SCRIPT_DIR/dsh-web.nginx.conf" "$STAGING_APP/dsh-web.nginx.conf"
cp "$SCRIPT_DIR/nginx.conf" "$STAGING_APP/nginx.conf"
cp "$SCRIPT_DIR/dsh" "$STAGING_APP/dsh"
cp "$SCRIPT_DIR/start.sh" "$STAGING_APP/start.sh"
chmod 755 "$STAGING_APP/dsh" "$STAGING_APP/start.sh"

if [[ -f "$TARGET_DIR/.env" ]]; then
  cp "$TARGET_DIR/.env" "$STAGING_APP/.env"
elif [[ -f "$SCRIPT_DIR/.env" ]]; then
  cp "$SCRIPT_DIR/.env" "$STAGING_APP/.env"
else
  cp "$SCRIPT_DIR/.env.example" "$STAGING_APP/.env.example"
fi

printf 'dsh-proxy deploy: starting the standalone dsh Web smoke check\n'
SMOKE_LOG="$STAGING_ROOT/dsh-web-smoke.log"
SMOKE_PORT="$(node -e "const s=require('node:net').createServer(); s.listen(0, '127.0.0.1', () => { console.log(s.address().port); s.close() })")"
DSH_HOME="$STAGING_ROOT/smoke-home" "$STAGING_APP/dsh" web \
  --no-open --host 127.0.0.1 --port "$SMOKE_PORT" --trust-proxy-auth >"$SMOKE_LOG" 2>&1 &
SMOKE_PID=$!
smoke_deadline=$((SECONDS + 30))
while [[ -z "$(ss -ltnH "sport = :$SMOKE_PORT" 2>/dev/null)" ]]; do
  if ! kill -0 "$SMOKE_PID" 2>/dev/null; then
    tail -n 40 "$SMOKE_LOG" >&2
    fail "standalone dsh Web exited before becoming ready"
  fi
  if ((SECONDS >= smoke_deadline)); then
    tail -n 40 "$SMOKE_LOG" >&2
    fail "standalone dsh Web did not become ready within 30 seconds"
  fi
  sleep 0.2
done
kill -TERM "$SMOKE_PID" 2>/dev/null || true
wait "$SMOKE_PID" 2>/dev/null || true
SMOKE_PID=''

rm -rf -- \
  "$STAGING_APP/README.md" \
  "$STAGING_APP/README.zh.md" \
  "$STAGING_APP/README.i18n.yaml" \
  "$STAGING_APP/hatch_build.py" \
  "$STAGING_APP/package.json" \
  "$STAGING_APP/platforms.json" \
  "$STAGING_APP/pnpm-lock.yaml" \
  "$STAGING_APP/pnpm-workspace.yaml" \
  "$STAGING_APP/pyproject.toml" \
  "$STAGING_APP/src"

mkdir -p "$TARGET_DIR"
rsync -a --delete \
  --exclude '.dsh-home/' \
  --exclude '.env' \
  "$STAGING_APP/" "$TARGET_DIR/"
if [[ ! -f "$TARGET_DIR/.env" && -f "$STAGING_APP/.env" ]]; then
  cp "$STAGING_APP/.env" "$TARGET_DIR/.env"
fi
if [[ -f "$TARGET_DIR/.env" ]]; then chmod 600 "$TARGET_DIR/.env"; fi

printf 'dsh-proxy deploy: ready at %s\n' "$TARGET_DIR"
printf '  cd %q && ./start.sh\n' "$TARGET_DIR"
