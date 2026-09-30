#!/usr/bin/env bash
# setup-tunnel.sh
# Alur: masuk root -> cd ~ -> apt update -> install cloudflared ->
#       buat folder public + index.html -> jalankan web server + tunnel (trycloudflare.com).
#
# Pakai (satu baris, dari user biasa maupun root):
#   curl -fsSL https://raw.githubusercontent.com/ZexDev4/cftunnel_tes/refs/heads/main/setup-tunnel.sh | USE_PM2=1 bash
#
# Opsi lewat environment variable:
#   PORT=8080            port server lokal
#   WEB_DIR=~/public     folder yang dilayani (default: /root/public)
#   USE_PM2=1            jalankan lewat pm2 (install nodejs/npm/pm2 bila belum ada)

say() { printf '\033[36m[setup]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# Semua logika ada di dalam fungsi main supaya seluruh skrip sudah terbaca
# sebelum dijalankan (penting untuk mode `curl ... | bash`).
main() {
  set -euo pipefail

  # --- 1. jadi root (pengganti "sudo su") ---
  # "sudo su" di dalam skrip akan membuka shell baru dan menghentikan alur,
  # jadi skrip menjalankan dirinya ulang sebagai root dengan HOME=/root.
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "Bukan root dan sudo tidak ada."
    say "Bukan root, masuk sebagai root lewat sudo ..."
    SELF_TMP="$(mktemp)"
    chmod 644 "$SELF_TMP"
    { echo 'set -euo pipefail'; declare -f say die main; echo 'main "$@"'; } > "$SELF_TMP"
    SELF_TMP="$SELF_TMP" exec sudo -H -E bash "$SELF_TMP" "$@"
  fi
  rm -f "${SELF_TMP:-}"

  # --- 2. pindah ke home root ---
  cd ~
  say "Berjalan sebagai root di $(pwd)"

  PORT="${PORT:-8080}"
  WEB_DIR="${WEB_DIR:-$HOME/public}"
  LOG_DIR="${LOG_DIR:-$HOME/.tunnel-logs}"
  USE_PM2="${USE_PM2:-0}"

  mkdir -p "$LOG_DIR" "$WEB_DIR"

  # --- 3. apt update ---
  say "Menjalankan apt update ..."
  apt-get update -y >/dev/null

  apt_install() { apt-get install -y "$@" >/dev/null; }

  for bin in curl wget python3; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      say "Memasang $bin ..."
      case "$bin" in
        python3) apt_install python3 ;;
        *) apt_install "$bin" ca-certificates ;;
      esac
    fi
  done

  # --- 4. cloudflared ---
  if ! command -v cloudflared >/dev/null 2>&1; then
    ARCH="$(dpkg --print-architecture)"
    case "$ARCH" in
      amd64|arm64) ;;
      *) die "Arsitektur $ARCH belum didukung skrip ini." ;;
    esac
    say "Mengunduh cloudflared ($ARCH) ..."
    TMP_DEB="$(mktemp --suffix=.deb)"
    chmod 644 "$TMP_DEB"
    wget -q -O "$TMP_DEB" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb" \
      || die "Gagal mengunduh cloudflared (cek akses internet ke github.com)."
    say "Memasang cloudflared ..."
    apt-get install -y "$TMP_DEB" >/dev/null
    rm -f "$TMP_DEB"
  else
    say "cloudflared sudah terpasang: $(cloudflared --version | head -n1)"
  fi

  # --- 5. pm2 (opsional) ---
  if [ "$USE_PM2" = "1" ] && ! command -v pm2 >/dev/null 2>&1; then
    say "Memasang nodejs, npm, dan pm2 ..."
    apt_install nodejs npm
    npm install -g pm2 >/dev/null 2>&1
  fi

  # --- 6. folder public + index.html (tidak menimpa kalau sudah ada) ---
  if [ ! -f "$WEB_DIR/index.html" ]; then
    say "Membuat $WEB_DIR/index.html ..."
    cat > "$WEB_DIR/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="id">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Halaman Publik</title>
  <style>
    body { font-family: system-ui, sans-serif; background: #0f1115; color: #e5e7eb;
           display: flex; min-height: 100vh; align-items: center; justify-content: center; margin: 0; }
    .box { text-align: center; }
    h1 { margin: 0 0 .5rem; }
    p { color: #9ca3af; }
  </style>
</head>
<body>
  <div class="box">
    <h1>Hello dari tunnel</h1>
    <p>Server berjalan dan bisa diakses lewat Cloudflare Tunnel.</p>
  </div>
</body>
</html>
HTML
  else
    say "index.html sudah ada, tidak ditimpa."
  fi

  # --- 7. hentikan proses lama supaya tidak bentrok ---
  say "Menghentikan proses lama (kalau ada) ..."
  if command -v pm2 >/dev/null 2>&1; then
    pm2 delete web tunnel >/dev/null 2>&1 || true
  fi
  pkill -f "http.server $PORT" >/dev/null 2>&1 || true
  pkill -f "cloudflared tunnel" >/dev/null 2>&1 || true
  sleep 1

  TUNNEL_LOG="$LOG_DIR/tunnel.log"
  WEB_LOG="$LOG_DIR/web.log"
  : > "$TUNNEL_LOG"
  : > "$WEB_LOG"

  WEB_CMD="python3 -m http.server $PORT --bind 127.0.0.1 --directory $WEB_DIR"
  TUNNEL_CMD="cloudflared tunnel --no-autoupdate --protocol http2 --url http://127.0.0.1:$PORT"

  # --- 8. jalankan web server + tunnel ---
  if [ "$USE_PM2" = "1" ] && command -v pm2 >/dev/null 2>&1; then
    say "Menjalankan lewat pm2 ..."
    pm2 start "$WEB_CMD > $WEB_LOG 2>&1" --name web >/dev/null
    pm2 start "$TUNNEL_CMD > $TUNNEL_LOG 2>&1" --name tunnel >/dev/null
  else
    say "Menjalankan di background (nohup) ..."
    setsid nohup bash -c "$WEB_CMD" > "$WEB_LOG" 2>&1 < /dev/null &
    setsid nohup bash -c "$TUNNEL_CMD" > "$TUNNEL_LOG" 2>&1 < /dev/null &
  fi

  # --- 9. cek server lokal ---
  sleep 2
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT" || true)"
  [ "$CODE" = "200" ] || say "Peringatan: server lokal membalas '$CODE' (bukan 200). Cek $WEB_LOG"

  # --- 10. tunggu URL tunnel ---
  say "Menunggu URL tunnel (maks ~60 detik) ..."
  URL=""
  for _ in $(seq 1 30); do
    URL="$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$TUNNEL_LOG" | head -n1 || true)"
    [ -n "$URL" ] && break
    sleep 2
  done

  echo
  if [ -n "$URL" ]; then
    printf '\033[32mSelesai.\033[0m URL publik: \033[1m%s\033[0m\n' "$URL"
  else
    printf '\033[33mURL belum muncul.\033[0m Cek log: tail -n 30 %s\n' "$TUNNEL_LOG"
  fi
  echo
  echo "Folder yang dilayani : $WEB_DIR"
  echo "Log web / tunnel     : $WEB_LOG , $TUNNEL_LOG"
  echo "Lihat URL lagi       : grep -o 'https://[a-z0-9-]*\\.trycloudflare\\.com' $TUNNEL_LOG | head -n1"
  echo "Hentikan             : pkill -f 'http.server $PORT'; pkill -f 'cloudflared tunnel'"
  echo "Catatan              : URL berganti tiap tunnel dijalankan ulang."
}

main "$@"
