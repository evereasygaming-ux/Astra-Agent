String buildSetupScript({
  required String token,
  required int bridgePort,
  required int hubPort,
  required int assetPort,
}) {
  if (!RegExp(r'^[0-9a-z]{12}$').hasMatch(token)) {
    throw ArgumentError('Invalid bridge token');
  }
  if (bridgePort < 1 ||
      bridgePort > 65535 ||
      hubPort < 1 ||
      hubPort > 65535 ||
      bridgePort == hubPort ||
      assetPort < 1 ||
      assetPort > 65535) {
    throw ArgumentError('Invalid bridge, hub, or asset port');
  }

  const template = r'''
set -e
export HOME=/root
export PATH="$HOME/.local/bin:$PATH"
mkdir -p "$HOME/.astra" "$HOME/.local/bin"
LOG="$HOME/.astra/setup.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== AstraAgent Debian proot setup ==="

if [ ! -x /system/bin/linker64 ]; then
  echo "Android linker is not visible inside Debian proot"
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required inside Debian. Install it with apt, then retry."
  exit 1
fi
AGY_BIN=$(command -v agy || true)
if [ -z "$AGY_BIN" ] || [ ! -x "$AGY_BIN" ]; then
  echo "AGY was not found in Debian. Expected an executable named agy on PATH."
  exit 1
fi

echo "-> installing the AstraAgent bridge in Debian"
curl -fsSL "http://127.0.0.1:__ASSET_PORT__/agy_ide_bridge" \
  -o "$HOME/.local/bin/agy_ide_bridge.tmp"
chmod 755 "$HOME/.local/bin/agy_ide_bridge.tmp"
mv "$HOME/.local/bin/agy_ide_bridge.tmp" "$HOME/.local/bin/agy_ide_bridge"

cat > "$HOME/.local/bin/claude" <<'CLAUDE_EOF'
#!/bin/sh
VERSIONS="$HOME/.local/share/claude/versions"
LATEST=$(ls -1 "$VERSIONS" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
if [ -z "$LATEST" ]; then
  echo "Claude Code is not installed. Open AstraAgent -> Claude Code and tap Install." >&2
  exit 127
fi
exec "$VERSIONS/$LATEST" "$@"
CLAUDE_EOF
chmod 755 "$HOME/.local/bin/claude"

cat > "$HOME/.astra/bridge.env" <<ENV_EOF
TOKEN=__TOKEN__
BRIDGE_PORT=__BRIDGE_PORT__
HUB_PORT=__HUB_PORT__
AGY_BIN=$AGY_BIN
ENV_EOF
chmod 600 "$HOME/.astra/bridge.env"

cat > "$HOME/.astra/start-bridge.sh" <<'ASTRA_EOF'
#!/bin/bash
export HOME=/root
export PATH="$HOME/.local/bin:$PATH"
. "$HOME/.astra/bridge.env"
PIDFILE="$HOME/.astra/bridge.pid"
if [ -f "$PIDFILE" ]; then
  PID=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    if [ "$1" != "--restart" ]; then
      exit 0
    fi
    kill "$PID" 2>/dev/null || true
    sleep 1
  fi
fi
nohup "$HOME/.local/bin/agy_ide_bridge" -f \
  --token "$TOKEN" -p "$BRIDGE_PORT" --hub-port "$HUB_PORT" \
  --bin "$AGY_BIN" --claude-bin "$HOME/.local/bin/claude" --dir "$HOME" \
  >> "$HOME/.astra/bridge.log" 2>&1 &
echo $! > "$PIDFILE"
ASTRA_EOF
chmod 755 "$HOME/.astra/start-bridge.sh"
"$HOME/.astra/start-bridge.sh" --restart

sleep 3
if curl -fsS "http://127.0.0.1:__BRIDGE_PORT__/api/health" >/dev/null; then
  echo "AstraAgent bridge is running in Debian on port __BRIDGE_PORT__"
else
  echo "Bridge did not become healthy. Check ~/.astra/bridge.log"
  exit 1
fi
echo "=== AstraAgent Debian proot setup finished ==="
''';
  return template
      .replaceAll('__TOKEN__', token)
      .replaceAll('__BRIDGE_PORT__', '$bridgePort')
      .replaceAll('__HUB_PORT__', '$hubPort')
      .replaceAll('__ASSET_PORT__', '$assetPort');
}

String buildLaunchScript() => r'''
if [ -x "$HOME/.astra/start-bridge.sh" ]; then
  "$HOME/.astra/start-bridge.sh"
else
  echo "AstraAgent Debian setup has not run yet."
  exit 3
fi
''';

String buildBridgeConfigUpdateScript({
  required String token,
  required int bridgePort,
  required int hubPort,
}) {
  if (!RegExp(r'^[0-9a-z]{12}$').hasMatch(token)) {
    throw ArgumentError('Invalid bridge token');
  }
  if (bridgePort < 1 ||
      bridgePort > 65535 ||
      hubPort < 1 ||
      hubPort > 65535 ||
      bridgePort == hubPort) {
    throw ArgumentError('Invalid bridge or hub port');
  }
  return r'''
set -e
export HOME=/root
export PATH="$HOME/.local/bin:$PATH"
if [ ! -x "$HOME/.astra/start-bridge.sh" ]; then
  echo "AstraAgent Debian setup has not run yet. Run Set up & launch first."
  exit 3
fi
if ! grep -q 'bridge.env' "$HOME/.astra/start-bridge.sh"; then
  echo "Debian setup is outdated. Run Set up & launch before changing the token."
  exit 4
fi
AGY_BIN=$(command -v agy)
if [ -z "$AGY_BIN" ]; then
  echo "AGY is not available in the Debian environment."
  exit 1
fi
cat > "$HOME/.astra/bridge.env" <<ENV_EOF
TOKEN=__TOKEN__
BRIDGE_PORT=__BRIDGE_PORT__
HUB_PORT=__HUB_PORT__
AGY_BIN=$AGY_BIN
ENV_EOF
chmod 600 "$HOME/.astra/bridge.env"
"$HOME/.astra/start-bridge.sh" --restart
'''
      .replaceAll('__TOKEN__', token)
      .replaceAll('__BRIDGE_PORT__', '$bridgePort')
      .replaceAll('__HUB_PORT__', '$hubPort');
}
