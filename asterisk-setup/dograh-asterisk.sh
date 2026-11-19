#!/bin/bash
# Dograh <-> Asterisk 22 <-> Voicelink (IP-auth SIP trunk) setup helper.
#
#   sudo ./dograh-asterisk.sh clean              purana Asterisk band + config backup
#   sudo ./dograh-asterisk.sh build              Asterisk 22 install (skip agar pehle se OK)
#   sudo ARI_PASS=xxxx ./dograh-asterisk.sh config      saari config files likho + restart
#   sudo ./dograh-asterisk.sh firewall           iptables rules (duplicate hata kar)
#   sudo ./dograh-asterisk.sh stasis dograh_xxx  Dograh ka Stasis App Name dialplan me daalo
#   sudo ./dograh-asterisk.sh check              sab kuch verify (ARI password ari.conf se khud padhta hai)
#   sudo ./dograh-asterisk.sh ari-pass           ari.conf wala asli ARI password dikhao (Dograh me yahi daalo)
#
# Optional env (defaults aapke setup ke hisaab se):
#   PUBLIC_IP=140.245.7.25  DID=919429491500  TECH=45454
#   VL_HOST=sip.voicelink.co.in  VL_PORT=3300  VL_MATCH=160.30.71.0/24
#   SIP_ALLOW=any (default, sabko khula). Call chalne ke BAAD lock: SIP_ALLOW=160.30.71.0/24,<IP> ./dograh-asterisk.sh firewall
#   VL_USER / VL_PASS  (optional: sirf tab kaam aate hain jab Voicelink digest-auth maange)

set -euo pipefail

ETC="${ETC:-/etc/asterisk}"
PUBLIC_IP="${PUBLIC_IP:-140.245.7.25}"
DID="${DID:-919429491500}"
TECH="${TECH:-45454}"
VL_HOST="${VL_HOST:-sip.voicelink.co.in}"
VL_PORT="${VL_PORT:-3300}"
VL_MATCH="${VL_MATCH:-160.30.71.0/24}"
WS_URI="${WS_URI:-ws://127.0.0.1:8000/api/v1/telephony/ws/ari}"
VL_USER="${VL_USER:-}"
VL_PASS="${VL_PASS:-}"
ARI_USER="dograh"
WS_NAME="dograh"
AST="${AST:-asterisk}"
ASTCONF=()
[ -n "${ASTCONF_FILE:-}" ] && ASTCONF=(-C "$ASTCONF_FILE")

ari_pass_from_conf() {
  awk -F'=' -v u="$ARI_USER" '
    /^\[/ { f = ($0 == "[" u "]"); next }
    f && $1 ~ /^[ \t]*password[ \t]*$/ { gsub(/[ \t\r]/, "", $2); print $2; exit }
  ' "$ETC/ari.conf" 2>/dev/null || true
}

need_root() { [ "$(id -u)" -eq 0 ] || { echo "sudo ke saath chalao"; exit 1; }; }
rx() { "$AST" "${ASTCONF[@]}" -rx "$1"; }
restart_ast() {
  if [ "${NO_RESTART:-0}" = "1" ]; then return; fi
  systemctl restart asterisk
  sleep 6
}

cmd_clean() {
  need_root
  systemctl stop asterisk 2>/dev/null || true
  systemctl disable asterisk 2>/dev/null || true
  pkill -x asterisk 2>/dev/null || true
  if [ -d "$ETC" ]; then
    b="/root/asterisk-etc-backup-$(date +%F-%H%M%S)"
    cp -a "$ETC" "$b" && echo "Purani config backup: $b"
  fi
  echo "clean done. Ab: build -> config -> firewall"
}

cmd_build() {
  need_root
  if command -v asterisk >/dev/null 2>&1 && asterisk -V | grep -qE 'Asterisk (2[2-9]|[3-9][0-9])'; then
    echo "Asterisk pehle se installed: $(asterisk -V)"
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y build-essential wget curl git dnsutils iptables-persistent
    cd /usr/src
    rm -rf asterisk-22.* asterisk-22-current.tar.gz
    wget -q https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-22-current.tar.gz
    tar xzf asterisk-22-current.tar.gz
    cd /usr/src/asterisk-22.*/
    contrib/scripts/install_prereq install
    ./configure --with-jansson-bundled
    make menuselect.makeopts
    menuselect/menuselect --enable chan_websocket --enable res_websocket_client menuselect.makeopts || true
    make -j"$(nproc)"
    make install
    make samples
    ldconfig
  fi
  cat > /etc/systemd/system/asterisk.service <<'EOF'
[Unit]
Description=Asterisk PBX
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/asterisk -f -C /etc/asterisk/asterisk.conf
ExecReload=/usr/sbin/asterisk -rx "core reload"
ExecStop=/usr/sbin/asterisk -rx "core stop now"
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable asterisk
  echo "build done. Ab: config"
}

cmd_config() {
  : "${ARI_PASS:?ARI_PASS set karo (sirf letters+numbers, min 8)}"
  [[ "$ARI_PASS" =~ ^[A-Za-z0-9]{8,}$ ]] || { echo "ARI_PASS me sirf letters/numbers, min 8 char"; exit 1; }
  mkdir -p "$ETC"
  b="$ETC/backup-$(date +%F-%H%M%S)"; mkdir -p "$b"
  for f in ari.conf http.conf websocket_client.conf pjsip.conf extensions.conf; do
    [ -f "$ETC/$f" ] && cp "$ETC/$f" "$b/" || true
  done

  cat > "$ETC/ari.conf" <<EOF
[general]
enabled = yes
pretty = yes

[$ARI_USER]
type = user
read_only = no
password = $ARI_PASS
EOF

  cat > "$ETC/http.conf" <<'EOF'
[general]
enabled = yes
bindaddr = 0.0.0.0
bindport = 8088
EOF

  cat > "$ETC/websocket_client.conf" <<EOF
[$WS_NAME]
type = websocket_client
uri = $WS_URI
protocols = media
EOF

  AUTHBLOCK=""; OUTAUTH=""
  if [ -n "$VL_USER" ] && [ -n "$VL_PASS" ]; then
    AUTHBLOCK="[voicelink-auth]
type=auth
auth_type=userpass
username=$VL_USER
password=$VL_PASS
"
    OUTAUTH="outbound_auth=voicelink-auth"
  fi

  cat > "$ETC/pjsip.conf" <<EOF
; Voicelink = IP-based trunk. REGISTER nahi hota (Voicelink 405 deta hai).
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060
external_media_address=$PUBLIC_IP
external_signaling_address=$PUBLIC_IP
local_net=10.0.0.0/8
local_net=172.16.0.0/12

$AUTHBLOCK
[voicelink]
type=aor
contact=sip:$VL_HOST:$VL_PORT

[voicelink]
type=endpoint
transport=transport-udp
context=from-voicelink
disallow=all
allow=ulaw
allow=alaw
aors=voicelink
from_domain=$PUBLIC_IP
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
dtmf_mode=rfc4733
$OUTAUTH

[voicelink]
type=identify
endpoint=voicelink
match=$VL_MATCH
EOF

  STASIS="dograh_PENDING"
  if [ -f "$ETC/extensions.conf" ]; then
    old=$(grep -oE 'Stasis\([^)]*\)' "$ETC/extensions.conf" | head -1 | sed -E 's/Stasis\((.*)\)/\1/' || true)
    [[ "${old:-}" =~ ^dograh_[a-f0-9]{6,}$ ]] && STASIS="$old"
  fi
  write_dialplan "$STASIS"
  restart_ast
  echo "config done. Stasis abhi: $STASIS"
  if [ "${NO_RESTART:-0}" != "1" ]; then
    code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -u "$ARI_USER:$ARI_PASS" http://127.0.0.1:8088/ari/asterisk/info || true)
    if [ "$code" = "200" ]; then
      echo "ARI login test: OK (HTTP 200)"
      echo "Dograh me ARI Password yahi daalo: $ARI_PASS"
    else
      echo "ARI login test: FAIL (HTTP $code). 'sudo ./dograh-asterisk.sh check' chalao"
    fi
  fi
}

write_dialplan() {
  cat > "$ETC/extensions.conf" <<EOF
; ---- Voicelink se aayi call -> Dograh ----
[from-voicelink]
exten => _X.,1,NoOp(VOICELINK IN dialed=\${EXTEN} caller=\${CALLERID(num)})
 same => n,Goto(dograh-in,91\${EXTEN:-10},1)
exten => _+X.,1,Goto(from-voicelink,\${EXTEN:1},1)

[dograh-in]
exten => _X.,1,NoOp(TO DOGRAH exten=\${EXTEN})
 same => n,Stasis($1)
 same => n,Hangup()

; ---- Dograh se outbound -> Voicelink ($TECH + 91 + last 10 digit) ----
[dograh-out]
exten => _.,1,NoOp(DOGRAH OUT \${EXTEN})
 same => n,Set(NUM=\${FILTER(0-9,\${EXTEN})})
 same => n,Set(CALLERID(num)=$DID)
 same => n,Set(CALLERID(name)=$DID)
 same => n,Dial(PJSIP/${TECH}91\${NUM:-10}@voicelink,60)
 same => n,Hangup()
EOF
}

cmd_stasis() {
  name="${1:-}"
  [[ "$name" =~ ^dograh_[a-f0-9]{6,}$ ]] || { echo "Stasis name aisa hona chahiye: dograh_a1b2c3d4e5f6"; exit 1; }
  write_dialplan "$name"
  rx "dialplan reload" >/dev/null
  rx "dialplan show from-voicelink"
  rx "dialplan show dograh-in"
}

cmd_firewall() {
  need_root
  del() { while iptables -D INPUT "$@" 2>/dev/null; do :; done; }
  # purane/duplicate rules hatao
  del -p udp --dport 5060 -j ACCEPT
  del -p udp --dport 10000:10100 -j ACCEPT
  del -p udp --dport 10000:20000 -j ACCEPT
  del -p tcp --dport 8088 -j ACCEPT
  del -p tcp --dport 8088 -j DROP
  while :; do
    r=$(iptables -S INPUT | grep -E -- '--dport (5060|8088)' | head -1 || true)
    [ -n "$r" ] || break
    # shellcheck disable=SC2086
    iptables -D INPUT ${r#-A INPUT } || break
  done
  # 8088 (ARI): sirf docker + localhost. (reverse order: last insert = sabse upar)
  iptables -I INPUT 1 -p tcp --dport 8088 ! -s 172.16.0.0/12 -j DROP
  iptables -I INPUT 1 -p tcp --dport 8088 -s 172.16.0.0/12 -j ACCEPT
  iptables -I INPUT 1 -p tcp --dport 8088 -s 127.0.0.1 -j ACCEPT
  # RTP (awaaz) sabko open (Voicelink ke media IP alag ho sakte hain).
  iptables -I INPUT 1 -p udp --dport 10000:20000 -j ACCEPT
  # SIP 5060: default sabko khula. Scanner spam rokne ke liye call chalne ke baad SIP_ALLOW se lock karo.
  SIP_ALLOW="${SIP_ALLOW:-any}"
  if [ "$SIP_ALLOW" = "any" ]; then
    iptables -I INPUT 1 -p udp --dport 5060 -j ACCEPT
  else
    vlip=$(getent ahostsv4 "$VL_HOST" 2>/dev/null | awk 'NR==1{print $1}' || true)
    iptables -I INPUT 1 -p udp --dport 5060 -j DROP
    for n in ${SIP_ALLOW//,/ } $vlip; do
      [ -n "$n" ] && iptables -I INPUT 1 -p udp --dport 5060 -s "$n" -j ACCEPT
    done
    echo "SIP 5060 allowed sirf: ${SIP_ALLOW} ${vlip}"
  fi
  if [ "${NO_PERSIST:-0}" != "1" ]; then
    command -v netfilter-persistent >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
    netfilter-persistent save
  fi
  iptables -L INPUT -n --line-numbers | grep -E '5060|10000|8088' || true
}

cmd_check() {
  ok() { echo "  [OK]   $1"; }; bad() { echo "  [FAIL] $1"; }
  echo "== 1. Asterisk modules"
  for m in chan_websocket res_websocket_client res_ari chan_pjsip codec_ulaw; do
    out=$(rx "module show like $m" 2>/dev/null || true)
    case "$out" in *Running*) ok "$m" ;; *) bad "$m" ;; esac
  done
  echo "== 2. PJSIP"
  rx "pjsip show endpoint voicelink" | grep -E "Endpoint:|Match|Contact:|allow" | head -6 || true
  echo "== 3. ARI (localhost)"
  CONF_PASS=$(ari_pass_from_conf)
  ARI_PASS="${ARI_PASS:-$CONF_PASS}"
  if [ -n "$CONF_PASS" ] && [ "$ARI_PASS" != "$CONF_PASS" ]; then
    bad "ARI_PASS jo tumne diya woh ari.conf se alag hai. ari.conf ka password: $CONF_PASS"
    ARI_PASS="$CONF_PASS"
  fi
  if [ -n "$ARI_PASS" ]; then
    tmp=$(mktemp)
    code=$(curl -s -m 5 -o "$tmp" -w '%{http_code}' -u "$ARI_USER:$ARI_PASS" http://127.0.0.1:8088/ari/asterisk/info || true)
    case "$code" in
      200) ok "ARI login (HTTP 200)" ;;
      401) bad "ARI login HTTP 401 = user/password galat. ari.conf me [$ARI_USER] ka password dekho" ;;
      000) bad "ARI se connect nahi hua. http.conf / Asterisk chal raha hai? (asterisk -rx 'http show status')" ;;
      *)   bad "ARI HTTP $code: $(head -c 200 "$tmp")" ;;
    esac
    rm -f "$tmp"
    rx "ari show users" 2>/dev/null | head -5 || true
    echo "  Registered Stasis apps: $(curl -s -m 5 -u "$ARI_USER:$ARI_PASS" http://127.0.0.1:8088/ari/applications | grep -oE '"name": *"[^"]*"' | tr '\n' ' ')"
  else echo "  ari.conf nahi mila ya password khali. Pehle: config"; fi
  echo "== 4. Dograh backend port 8000 (Asterisk ye use karta hai)"
  out=$(curl -s -m 5 http://127.0.0.1:8000/api/v1/health || true)
  case "$out" in *'"status":"ok"'*) ok "Dograh API 127.0.0.1:8000" ;; *) bad "Dograh API 8000 nahi mila" ;; esac
  echo "== 5. Docker -> ARI"
  PRIV=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}')
  [ -n "$PRIV" ] || PRIV=$(hostname -I | awk '{print $1}')
  if command -v docker >/dev/null && [ -n "${ARI_PASS:-}" ]; then
    code=$(docker run --rm curlimages/curl -s -m 5 -o /dev/null -w '%{http_code}' -u "$ARI_USER:$ARI_PASS" "http://$PRIV:8088/ari/asterisk/info" 2>/dev/null || true)
    case "$code" in
      200) ok "Dograh container -> http://$PRIV:8088 (HTTP 200)" ;;
      401) bad "container pahunch gaya par password galat (HTTP 401)" ;;
      *)   bad "container se ARI nahi pahunch raha (HTTP '${code:-none}'): firewall ya docker image pull" ;;
    esac
  fi
  echo "== 6. Dialplan"
  st=$(rx "dialplan show dograh-in" | grep -oE 'Stasis\([^)]*\)' | head -1 || true)
  case "$st" in
    *dograh_*) ok "dialplan: $st" ;;
    *) bad "dialplan me ${st:-Stasis nahi} hai. Chalao: sudo ./dograh-asterisk.sh stasis dograh_<tumhara_naam>" ;;
  esac
  echo "== 7. Voicelink IP"
  vlip=$(getent ahostsv4 "$VL_HOST" 2>/dev/null | awk 'NR==1{print $1}' || true)
  echo "  $VL_HOST -> ${vlip:-?}   (match range: $VL_MATCH)"
  if [ -n "$vlip" ] && command -v python3 >/dev/null; then
    python3 -c "import ipaddress,sys; sys.exit(0 if ipaddress.ip_address('$vlip') in ipaddress.ip_network('$VL_MATCH') else 1)" \
      && ok "Voicelink IP match range me hai" || bad "Voicelink IP range ke bahar. VL_MATCH='$VL_MATCH,$vlip/32' ke saath config chalao"
  fi
  echo
  echo "Dograh me paste karne ki values:"
  echo "  ARI Endpoint    : http://$PRIV:8088"
  echo "  ARI Username    : $ARI_USER"
  echo "  ARI Password    : ${ARI_PASS:-(ari.conf nahi mila)}"
  echo "  websocket_client.conf Name : $WS_NAME"
  echo "  Dial String Template       : Local/{number}@dograh-out/n"
}

case "${1:-}" in
  clean) cmd_clean ;;
  build) cmd_build ;;
  config) need_root; cmd_config ;;
  firewall) cmd_firewall ;;
  stasis) shift; cmd_stasis "${1:-}" ;;
  check) need_root; cmd_check ;;
  ari-pass) need_root; ari_pass_from_conf ;;
  *) sed -n '2,16p' "$0"; exit 1 ;;
esac
