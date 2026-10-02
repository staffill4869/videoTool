#!/usr/bin/env bash
# Cloudflare Tunnel 을 붙인다. 포트를 열지 않고, 공인 IP 도 인증서도 필요 없다.
#
#   ./setup-tunnel.sh videocrm.내도메인.com
#
# 먼저 한 번은 사람이 로그인해야 한다:
#   cloudflared tunnel login        ← 브라우저가 열리고, 쓸 도메인(영역)을 고른다
#
# **이걸 붙이는 순간 videoCRM 이 인터넷에 열린다. 이 앱에는 인증이 없다** —
# /settings(API 키 화면) · /api/tools/*(publish 포함) · /dev/dashboard 가 전부 무방비다.
# 그래서 스크립트 끝에서 Cloudflare Access 를 걸라고 다시 알린다. 그 전에는 켜지 마라.
set -euo pipefail

HOST="${1:-}"
NAME="${TUNNEL_NAME:-videocrm}"
PORT="${VIDEOCRM_PORT:-4300}"

if [ -z "$HOST" ]; then
  echo "쓰기: $0 <공개할 호스트이름>   예) videocrm.example.com"
  exit 2
fi

if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
  echo "먼저 로그인해야 한다:  cloudflared tunnel login"
  echo "  (브라우저가 열린다. 서버에 화면이 없으면 나오는 URL 을 내 PC 브라우저에 붙여넣는다)"
  exit 1
fi

# 터널은 한 번만 만든다. 이미 있으면 그대로 쓴다 — 다시 만들면 자격증명이 갈려
# 예전 설정이 조용히 죽는다.
if ! cloudflared tunnel list 2>/dev/null | awk '{print $2}' | grep -qx "$NAME"; then
  cloudflared tunnel create "$NAME"
fi
UUID=$(cloudflared tunnel list 2>/dev/null | awk -v n="$NAME" '$2==n {print $1}' | head -1)
[ -n "$UUID" ] || { echo "터널 UUID 를 못 찾았다"; exit 1; }
echo "터널: $NAME ($UUID)"

mkdir -p "$HOME/.cloudflared"
cat > "$HOME/.cloudflared/config.yml" <<EOF
tunnel: $UUID
credentials-file: $HOME/.cloudflared/$UUID.json

ingress:
  - hostname: $HOST
    service: http://127.0.0.1:$PORT
    originRequest:
      # LiveView 웹소켓이 도중에 끊기지 않게 넉넉히 둔다
      noTLSVerify: true
      connectTimeout: 30s
  # 마지막 규칙은 반드시 catch-all 이어야 한다. 없으면 cloudflared 가 기동하지 않는다.
  - service: http_status:404
EOF

# DNS 레코드(CNAME)를 터널로 붙인다. 이미 있으면 덮어쓴다.
cloudflared tunnel route dns --overwrite-dns "$NAME" "$HOST"

sudo cloudflared service install 2>/dev/null || true
sudo mkdir -p /etc/cloudflared
sudo cp "$HOME/.cloudflared/config.yml" /etc/cloudflared/config.yml
sudo cp "$HOME/.cloudflared/$UUID.json" /etc/cloudflared/ 2>/dev/null || true
sudo sed -i "s#$HOME/.cloudflared/#/etc/cloudflared/#" /etc/cloudflared/config.yml
sudo systemctl enable --now cloudflared
sleep 3
sudo systemctl is-active cloudflared

cat <<EOF

터널이 붙었습니다:  https://$HOST

  ⚠️  아직 **누구나 들어올 수 있습니다.** videoCRM 에는 인증이 없습니다.
      지금 바로 Cloudflare Access 를 거세요:

      Cloudflare 대시보드 → Zero Trust → Access → Applications
        → Add an application → Self-hosted
        → Application domain: $HOST
        → Policy: Allow / Emails / ceodblab@gmail.com (쓰실 계정)
        → Save

      건 다음 시크릿 창으로 https://$HOST 를 열어
      **로그인 화면이 먼저 뜨는지** 확인하세요. 바로 들어가지면 안 걸린 겁니다.
EOF
