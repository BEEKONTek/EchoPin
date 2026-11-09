#!/usr/bin/env bash
# Install EchoPin on phones by scanning a QR code.
#
#   scripts/share_apk.sh [path/to/app.apk] [port]
#
# Serves the APK from this computer over your Wi-Fi and prints a QR code.
# Phones on the same network scan it, download the APK and install it.
#
# Nothing leaves your network: only the APK and a one-page download link
# are served, only to devices on the same Wi-Fi, and only while this runs.
# If firewalld is on, the port is opened until you press Ctrl+C (runtime
# rule only, so a reboot closes it too).
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${2:-8765}"
APK="${1:-}"
if [[ -z "$APK" ]]; then
  # Newest build wins: the universal APK, or the arm64 one from
  # `flutter build apk --split-per-abi` (fits nearly every current phone).
  APK="$(ls -t build/app/outputs/flutter-apk/app-release.apk \
                build/app/outputs/flutter-apk/app-arm64-v8a-release.apk 2>/dev/null | head -1 || true)"
fi
if [[ -z "$APK" || ! -f "$APK" ]]; then
  echo "No APK found. Build one first:" >&2
  echo "  flutter build apk --release --dart-define=ECHOPIN_SERVER_URL=..." >&2
  exit 1
fi
command -v qrencode >/dev/null || { echo "Install qrencode first (pacman -S qrencode / apt install qrencode)" >&2; exit 1; }

# The address phones will use: this computer's IP on the default route.
IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
[[ -n "$IP" ]] || { echo "Not connected to a network." >&2; exit 1; }

VERSION="$(awk '/^version:/ { split($2, v, "+"); print v[1] }' pubspec.yaml)"
NAME="EchoPin-${VERSION}.apk"
SHA="$(sha256sum "$APK" | cut -c1-16)"
SIZE="$(du -h "$APK" | cut -f1)"
BUILT="$(date -r "$APK" '+%d %b %H:%M')"

# Serve a copy from a private temp folder, so nothing else in the repo is
# reachable over the network.
DIR="$(mktemp -d)"
cp "$APK" "$DIR/$NAME"
cat > "$DIR/index.html" <<HTML
<!doctype html><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Install EchoPin</title>
<style>
  body { font: 17px/1.5 system-ui, sans-serif; margin: 0; padding: 32px 20px;
         background: #0e1016; color: #f3f5f9; text-align: center; }
  a.b { display: block; margin: 28px auto; max-width: 320px; padding: 18px;
        border-radius: 14px; background: #2563EB; color: #fff;
        font-weight: 700; font-size: 20px; text-decoration: none; }
  ol { text-align: left; max-width: 340px; margin: 0 auto; color: #c5cad6; }
  small { color: #8a90a0; }
</style>
<h1>EchoPin ${VERSION}</h1>
<a class="b" href="${NAME}" download>Download (${SIZE})</a>
<ol>
  <li>Tap <b>Download</b>. If Chrome warns about the file, tap <b>Download anyway</b>.</li>
  <li>Open the downloaded file.</li>
  <li>If asked, allow your browser to <b>install unknown apps</b>, then go back.</li>
  <li>Tap <b>Install</b>.</li>
</ol>
<p><small>Built ${BUILT} · SHA-256 ${SHA}…</small></p>
HTML

OPENED_PORT=""
cleanup() {
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
  if [[ -n "$OPENED_PORT" ]]; then
    # -n: never prompt on the way out; the rule's timeout is the fallback.
    if sudo -n firewall-cmd --quiet --remove-port="$PORT/tcp" 2>/dev/null; then
      echo "Closed port $PORT again."
    else
      echo "Port $PORT closes by itself within 2 hours (or run: sudo firewall-cmd --remove-port=$PORT/tcp)."
    fi
  fi
  rm -rf "$DIR"
}
trap cleanup EXIT          # runs once, however the script ends
trap 'exit 130' INT TERM   # Ctrl+C: exit, which runs cleanup

# firewalld blocks incoming connections by default; open the port for now.
# The timeout closes it even if this terminal is closed without Ctrl+C.
if systemctl is-active --quiet firewalld 2>/dev/null &&
   [[ "$(firewall-cmd --query-port="$PORT/tcp" 2>/dev/null || true)" != "yes" ]]; then
  echo "The firewall blocks phones from connecting. Opening port $PORT until you stop this"
  echo "(asks for your password):"
  sudo firewall-cmd --quiet --add-port="$PORT/tcp" --timeout=2h
  OPENED_PORT=1
fi

# A tiny server bound to the Wi-Fi address only, with the MIME type Android
# expects for APKs. Each download is logged below the QR code.
python3 -I - "$DIR" "$IP" "$PORT" <<'PY' &
import functools, http.server, sys
root, ip, port = sys.argv[1], sys.argv[2], int(sys.argv[3])

class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                      '.apk': 'application/vnd.android.package-archive'}

    def log_message(self, fmt, *args):
        sys.stderr.write('  %s  %s\n' % (self.client_address[0], fmt % args))

http.server.ThreadingHTTPServer((ip, port), functools.partial(Handler, directory=root)).serve_forever()
PY
SERVER_PID=$!
sleep 0.5
kill -0 "$SERVER_PID" 2>/dev/null || { echo "Could not start the server on port $PORT (in use?). Try: $0 \"$APK\" 8766" >&2; exit 1; }

URL="http://$IP:$PORT/"
echo
qrencode -t ANSIUTF8 -m 2 "$URL"
echo "  Scan with the phone's camera, or open: $URL"
echo "  $NAME · $SIZE · built $BUILT · sha256 $SHA…"
echo "  The phone must be on the same Wi-Fi as this computer. Ctrl+C to stop."
echo
wait "$SERVER_PID"
