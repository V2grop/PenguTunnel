#!/usr/bin/env bash
# PenguTunnel upstream menu adapted for a local, hash-pinned v4.2.1 core.
BUNDLE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
OFFLINE_SHA256="793e594170065186df4979e6fffa360b6b9796f7cb4595493c8f48c2ed4cc9fd"
[[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]] || { echo "Linux amd64 is required." >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum is required." >&2; exit 1; }
set -o pipefail

SCRIPT_VERSION="4.1.0"
INSTALL_DIR="/root/pengutunnel"          # core + configs + logs all live here
BIN_PATH="/root/pengutunnel/pengutunnel" # the core binary
SERVICE_DIR="/etc/systemd/system"
DOMAIN="${DOMAIN:-pg.pengucloud.net}"
DOMAIN_MIRROR="${DOMAIN_MIRROR:-pg-ir.pengucloud.net}"
DOMAIN_OLD="validate.pengucloud.net"
DOMAIN_MIRROR_OLD="validate-ir.pengucloud.net"
DL_PORT="${DL_PORT:-2096}"
SELF_URL="https://${DOMAIN}:${DL_PORT}/install.sh"
SELF_URL_MIR="https://${DOMAIN_MIRROR}:${DL_PORT}/install.sh"
CORE_URL="${CORE_URL:-https://${DOMAIN}:${DL_PORT}/pengutunnel}"
CORE_URL_MIR="https://${DOMAIN_MIRROR}:${DL_PORT}/pengutunnel"

if [[ -t 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[36m'; M=$'\e[35m'; W=$'\e[1;37m'; D=$'\e[2m'; N=$'\e[0m'
else R=""; G=""; Y=""; B=""; M=""; W=""; D=""; N=""; fi
ok(){ echo "${G}[ok]${N} $*"; }
warn(){ echo "${Y}[!]${N} $*"; }
err(){ echo "${R}[x]${N} $*" >&2; }
hr(){ echo "${D}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"; }
pause(){ read -rp "$(echo "${D}press enter...${N}")" _; }
ask(){ local p="$1" d="${2:-}" a; if [[ -n "$d" ]]; then read -rp "${B}${p}${N} [${d}]: " a; echo "${a:-$d}"; else read -rp "${B}${p}${N}: " a; echo "$a"; fi; }

ask_req(){ local p="$1" a; while :; do read -rp "${B}${p}${N}: " a; if [[ -n "${a// }" ]]; then echo "$a"; return; fi; echo "${R}[x]${N} this field is required — please enter a value" >&2; done; }
strip_block(){ local f="$1" tmp; tmp="$(mktemp)"; awk -v sec="[$2]" 'BEGIN{skip=0} $0==sec{skip=1;next} skip==1&&/^\[/{skip=0} skip==0{print}' "$f" > "$tmp" && mv "$tmp" "$f"; }
_ipl_block(){ awk '/^\[xui_iplimit\]/{f=1;next} f&&/^\[/{f=0} f{print}' "$1" 2>/dev/null; }
_ipl_enabled(){ _ipl_block "$1" | grep -q 'enabled *= *true'; }
_ipl_field(){ _ipl_block "$1" | sed -n "s/^ *$2 *= *\"\{0,1\}\([^\"]*\)\"\{0,1\} *\$/\1/p" | head -1; }

ask_yn(){
  local p="$1" d="${2:-}" a
  while true; do
    a="$(ask "$p" "$d")"
    case "${a,,}" in
      y|yes) echo "y"; return 0;;
      n|no)  echo "n"; return 0;;
      *) err "invalid answer '${a}' — please enter y or n";;
    esac
  done
}

WIZ_VAL=""; WIZ_BACK=0
wask(){   # $1 prompt  $2 default
  local p="$1" d="${2:-}" a
  if [[ -n "$d" ]]; then read -rp "${B}${p}${N} ${D}(b=back)${N} [${d}]: " a; a="${a:-$d}"
  else read -rp "${B}${p}${N} ${D}(b=back)${N}: " a; fi
  case "$a" in b|B|back|BACK) WIZ_BACK=1; WIZ_VAL=""; return 0;; esac
  WIZ_BACK=0; WIZ_VAL="$a"
}
wask_req(){   # $1 prompt (required; blank re-asks)
  local p="$1" a
  while :; do
    read -rp "${B}${p}${N} ${D}(b=back)${N}: " a
    case "$a" in b|B|back|BACK) WIZ_BACK=1; WIZ_VAL=""; return 0;; esac
    if [[ -n "${a// }" ]]; then WIZ_BACK=0; WIZ_VAL="$a"; return 0; fi
    echo "${R}[x]${N} this field is required — please enter a value (or b = back)" >&2
  done
}
wyn(){   # $1 prompt  $2 default  -> WIZ_VAL = y|n
  local p="$1" d="${2:-}" a
  while :; do
    if [[ -n "$d" ]]; then read -rp "${B}${p}${N} ${D}(b=back)${N} [${d}]: " a; a="${a:-$d}"
    else read -rp "${B}${p}${N} ${D}(b=back)${N}: " a; fi
    case "$a" in y|Y|yes) WIZ_BACK=0; WIZ_VAL="y"; return 0;; n|N|no) WIZ_BACK=0; WIZ_VAL="n"; return 0;; b|B|back|BACK) WIZ_BACK=1; WIZ_VAL=""; return 0;; *) err "please enter y / n / b";; esac
  done
}

detect_cpu_mem(){
  local cpus mem_kb
  cpus="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  mem_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
  [[ -n "$mem_kb" ]] || mem_kb=$((512*1024))
  echo "$cpus $((mem_kb/1024))"
}

need_root(){ [[ $EUID -eq 0 ]] || { err "run as root"; exit 1; }; }

olddom(){ local u="${1//$DOMAIN_MIRROR/$DOMAIN_MIRROR_OLD}"; echo "${u//$DOMAIN/$DOMAIN_OLD}"; }
fetch2(){
  curl -fsSL --connect-timeout 2 "$1" -o "$3" 2>/dev/null && return 0
  curl -fsSL --connect-timeout 6 "$2" -o "$3" 2>/dev/null && return 0
  curl -fsSL --connect-timeout 6 "$(olddom "$2")" -o "$3" 2>/dev/null && return 0
  curl -fsSL --connect-timeout 6 "$(olddom "$1")" -o "$3"
}

VERSION_URL="https://${DOMAIN}:${DL_PORT}/version"
VERSION_URL_MIR="https://${DOMAIN_MIRROR}:${DL_PORT}/version"
WHOAMI_URL="https://${DOMAIN}:${DL_PORT}/whoami"
WHOAMI_URL_MIR="https://${DOMAIN_MIRROR}:${DL_PORT}/whoami"
SYS_IP=""; SYS_IP6=""; SYS_LOC=""; SYS_DC=""; CORE_LATEST=""
core_version(){ [[ -x "$BIN_PATH" ]] && "$BIN_PATH" -version 2>/dev/null | awk '{print $2}' || echo ""; }
CORE_VER=""; CORE_VER_KEY="-"
refresh_core_version(){ local k; k="$(stat -c '%Y-%s' "$BIN_PATH" 2>/dev/null)"; [[ "$k" == "$CORE_VER_KEY" ]] && return 0; CORE_VER_KEY="$k"; CORE_VER="$(core_version)"; }
core_at_least(){ refresh_core_version; [[ -n "$CORE_VER" && "$(printf '%s\n%s\n' "$1" "$CORE_VER" | sort -V | head -1)" == "$1" ]]; }

load_sysinfo(){
  local tmp; tmp="$(mktemp -d 2>/dev/null)" || { tmp="/tmp/.pengu.$$"; mkdir -p "$tmp"; }
  ( curl -fsS -4 --max-time 4 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' > "$tmp/v4" ) &
  ( curl -fsS -6 --max-time 2 https://api6.ipify.org 2>/dev/null | grep -oE '^[0-9a-fA-F:]+$' | head -1 > "$tmp/v6" ) &
  ( curl -fsS --connect-timeout 2 --max-time 4 "$VERSION_URL_MIR" 2>/dev/null | tr -d '\r\n ' > "$tmp/verm" ) &
  ( curl -fsS --connect-timeout 2 --max-time 4 "$VERSION_URL" 2>/dev/null | tr -d '\r\n ' > "$tmp/verf" ) &
  ( curl -fsS -4 --max-time 4 "$WHOAMI_URL_MIR" 2>/dev/null > "$tmp/mir" ) &
  ( curl -fsS -4 --max-time 5 "$WHOAMI_URL" 2>/dev/null > "$tmp/geo" ) &
  ( curl -fsS --connect-timeout 2 --max-time 4 "$(olddom "$VERSION_URL_MIR")" 2>/dev/null | tr -d '\r\n ' > "$tmp/vero" ) &
  ( curl -fsS -4 --max-time 5 "$(olddom "$WHOAMI_URL")" 2>/dev/null > "$tmp/geoo" ) &
  ( ipx="$(curl -fsS -4 --max-time 3 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p')"; [ -n "$ipx" ] && curl -fsS --max-time 3 "http://ipwhois.app/json/${ipx}?fields=ip,country_code,isp" 2>/dev/null > "$tmp/ext" ) &
  local i=0
  while [ $i -lt 30 ]; do
    if [ -s "$tmp/v4" ] && { [ -s "$tmp/ext" ] || [ -s "$tmp/geo" ] || [ -s "$tmp/geoo" ]; } && { [ -s "$tmp/verm" ] || [ -s "$tmp/verf" ] || [ -s "$tmp/vero" ]; }; then break; fi
    sleep 0.1; i=$((i+1))
  done
  kill $(jobs -p) 2>/dev/null; wait 2>/dev/null
  SYS_IP="$(cat "$tmp/v4" 2>/dev/null)"
  SYS_IP6="$(cat "$tmp/v6" 2>/dev/null)"
  CORE_LATEST="$(cat "$tmp/verm" 2>/dev/null)"; [ -n "$CORE_LATEST" ] || CORE_LATEST="$(cat "$tmp/verf" 2>/dev/null)"
  [ -n "$CORE_LATEST" ] || CORE_LATEST="$(cat "$tmp/vero" 2>/dev/null)"
  local ext geo mir; ext="$(cat "$tmp/ext" 2>/dev/null)"; geo="$(cat "$tmp/geo" 2>/dev/null)"; mir="$(cat "$tmp/mir" 2>/dev/null)"
  [ -n "$geo" ] || geo="$(cat "$tmp/geoo" 2>/dev/null)"
  if [ -n "$ext" ]; then
    [ -n "$SYS_IP" ] || SYS_IP="$(sed -n 's/.*"ip":"\([^"]*\)".*/\1/p' <<<"$ext")"
    SYS_LOC="$(sed -n 's/.*"country_code":"\([^"]*\)".*/\1/p' <<<"$ext")"
    SYS_DC="$(sed -n 's/.*"isp":"\([^"]*\)".*/\1/p' <<<"$ext")"
  fi
  if [ -z "$SYS_LOC" ] || [ -z "$SYS_DC" ]; then
    [ -n "$SYS_LOC" ] || SYS_LOC="$(sed -n 's/.*"country":"\([^"]*\)".*/\1/p' <<<"$geo")"
    [ -n "$SYS_DC" ] || SYS_DC="$(sed -n 's/.*"asn":"\([^"]*\)".*/\1/p' <<<"$geo")"
  fi
  [ -n "$SYS_IP" ] || SYS_IP="$(sed -n 's/.*"ip":"\([^"]*\)".*/\1/p' <<<"$mir")"
  [ -n "$SYS_IP" ] || SYS_IP="$(sed -n 's/.*"ip":"\([^"]*\)".*/\1/p' <<<"$geo")"
  rm -rf "$tmp"
}

banner(){
  clear 2>/dev/null || true
  echo "${B}${W}"
  cat <<'ART'
    ____  ____________                       __
   / __ \/ ____/_  __/_  ______  ____  ___  / /
  / /_/ / / __  / / / / / / __ \/ __ \/ _ \/ /
 / ____/ /_/ / / / / /_/ / / / / / / /  __/ /
/_/    \____/ /_/  \__,_/_/ /_/_/ /_/\___/_/
ART
  echo "${N}"
  local sep="${Y}═══════════════════════════════════════════${N}"

  refresh_core_version; local ci="$CORE_VER"
  local cver="not installed"
  if [[ -n "$ci" ]]; then
    cver="$ci"
    [[ -n "$CORE_LATEST" && "$ci" != "$CORE_LATEST" ]] && cver="${ci} ${Y}(update: ${CORE_LATEST})${N}"
  fi

  echo "  ${G}Script Version:${N} ${B}v${SCRIPT_VERSION}${N}"
  echo "  ${G}Core Version:${N}   ${B}${cver}${N}"
  echo "$sep"
  echo "  ${B}IPv4:${N}       ${M}${SYS_IP:-null}${N}"
  echo "  ${B}IPv6:${N}       ${M}${SYS_IP6:-null}${N}"
  echo "  ${B}Location:${N}   ${M}${SYS_LOC:-null}${N}"
  echo "  ${B}Datacenter:${N} ${M}${SYS_DC:-null}${N}"
  echo "  ${B}pengutunnel Core:${N} $([[ -x "$BIN_PATH" ]] && echo "${G}Installed${N}" || echo "${R}Not installed${N}")"
  echo "  ${B}Auto core update:${N} $(au_enabled && echo "${G}ON${N}" || echo "${R}OFF${N}")"
  echo "  ${B}Tunnels:${N} ${W}$(count_tunnels)${N}"
  echo "$sep"
}

count_tunnels(){ ls "${SERVICE_DIR}"/pengutunnel-*.service 2>/dev/null | wc -l; }
list_ids(){ for f in "${SERVICE_DIR}"/pengutunnel-*.service; do [[ -e "$f" ]] || continue; basename "$f" | sed 's/^pengutunnel-\(.*\)\.service$/\1/'; done; }
conf_of(){ [[ -f "${INSTALL_DIR}/$1.toml" ]] && echo "${INSTALL_DIR}/$1.toml" || echo "${INSTALL_DIR}/$1.yaml"; }
log_of(){ echo "${INSTALL_DIR}/$1.log"; }
svc_of(){ echo "pengutunnel-$1"; }
rm_icmp_rule(){ command -v iptables >/dev/null 2>&1 || return 0; local r; iptables -w 5 -S OUTPUT 2>/dev/null | grep -E "pengutunnel-icmp:$1(\"| |$)" | sed 's/^-A /-D /' | while read -r r; do eval "iptables -w 5 $r" 2>/dev/null; done; }

view_logs(){
  local id="$1" svc="$2" lf; lf="$(log_of "$id")"
  banner
  echo "${B}live log — ${W}${id}${N}${B}   (press ${W}Ctrl-C${N}${B} to return)${N}"; hr
  if [[ -f "$lf" ]]; then
    trap : INT
    tail -n 100 -F "$lf" 2>/dev/null
    trap - INT
  else
    journalctl -u "$svc" -n 80 --no-pager 2>/dev/null || warn "no log yet"
    pause
  fi
}

install_prereqs(){
  if command -v apt-get >/dev/null 2>&1; then
    local miss=()
    command -v curl >/dev/null 2>&1 || miss+=(curl)
    command -v tar  >/dev/null 2>&1 || miss+=(tar)
    command -v ip   >/dev/null 2>&1 || miss+=(iproute2)
    { dpkg -s ca-certificates >/dev/null 2>&1 || [ -f /etc/ssl/certs/ca-certificates.crt ]; } || miss+=(ca-certificates)
    if [ ${#miss[@]} -eq 0 ]; then echo "prerequisites already present"; return; fi
    echo "installing prerequisites: ${miss[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${miss[@]}" >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    local miss=()
    command -v curl >/dev/null 2>&1 || miss+=(curl)
    command -v tar  >/dev/null 2>&1 || miss+=(tar)
    command -v ip   >/dev/null 2>&1 || miss+=(iproute)
    if [ ${#miss[@]} -eq 0 ]; then echo "prerequisites already present"; return; fi
    yum install -y -q "${miss[@]}" >/dev/null
  fi
}

replace_bin(){
  mkdir -p "$INSTALL_DIR"
  cp -f "$1" "${BIN_PATH}.new" && chmod +x "${BIN_PATH}.new" && mv -f "${BIN_PATH}.new" "$BIN_PATH"
}

install_core(){
  local source="$BUNDLE_DIR/pengutunnel" actual
  [[ -f "$source" ]] || { err "Keep install.sh beside the bundled pengutunnel binary."; return 1; }
  actual="$(sha256sum "$source" | awk '{print $1}')"
  [[ "$actual" == "$OFFLINE_SHA256" ]] || { err "Bundled binary checksum mismatch; nothing installed."; return 1; }
  mkdir -p "$INSTALL_DIR" || return 1
  if [[ -f "$BIN_PATH" && "$(sha256sum "$BIN_PATH" | awk '{print $1}')" != "$OFFLINE_SHA256" ]]; then
    cp -p "$BIN_PATH" "${BIN_PATH}.backup-$(date -u +%Y%m%dT%H%M%SZ)" || return 1
  fi
  replace_bin "$source" || return 1
  ok "offline core installed: $(core_version)"
}

ensure_core(){
  if [[ -x "$BIN_PATH" && "$(sha256sum "$BIN_PATH" | awk '{print $1}')" == "$OFFLINE_SHA256" ]]; then return 0; fi
  install_prereqs || return 1
  install_core || return 1
  local id
  for id in $(list_ids); do
    systemctl try-restart "$(svc_of "$id").service" || warn "Could not restart $(svc_of "$id"); inspect its service log."
  done
  return 0
}

gen_psk(){ head -c 32 /dev/urandom | base64; }


wiz_run(){
  local -a _st=("$@") _stk=(); local _i=0 _n=$# _rc
  while (( _i < _n )); do
    WIZ_BACK=0
    "${_st[$_i]}"; _rc=$?
    if (( _rc == 3 )); then _i=$((_i+1)); continue; fi
    if (( _rc == 4 )); then return 0; fi
    if (( WIZ_BACK == 1 )); then
      if (( ${#_stk[@]} > 0 )); then _i=${_stk[$((${#_stk[@]}-1))]}; unset '_stk[$((${#_stk[@]}-1))]'; else return 1; fi
      continue
    fi
    _stk+=("$_i"); _i=$((_i+1))
  done
  return 0
}

_cn_role(){
  if   [[ "$dir" == "3" ]]; then role="dualway"
  elif [[ "$side" == "1" && "$dir" == "1" ]]; then role="server"
  elif [[ "$side" == "1" && "$dir" == "2" ]]; then role="client"
  elif [[ "$side" == "2" && "$dir" == "1" ]]; then role="client"
  else role="server"; fi
}

cn_side(){
  banner
  echo "Which server is THIS host?"
  echo "   ${W}1${N}) Iran   (origin — users connect here)"
  echo "   ${W}2${N}) Kharej (exit/foreign — runs xray etc.)"
  echo "  ${D}(tip: type ${W}b${N}${D} at any question to go back one step)${N}"
  while :; do wask 'select' "${_r_side:-1}"; (( WIZ_BACK )) || break; warn "this is the first step"; done
  _r_side="$WIZ_VAL"; side="$WIZ_VAL"
}
cn_cat(){
  echo; echo "Transport:"
  echo "   ${W}1${N}) tcp       ${D}— tcp forward        (no tun)${N}"
  echo "   ${W}2${N}) tun       ${D}— L3 tunnel (tcp / ipx)${N}"
  echo "   ${W}3${N}) dns       ${D}— DNS mimicry        (UDP/53)${N}"
  echo "   ${W}4${N}) ssh       ${D}— SSH mimicry        (TCP/22)${N}"
  echo "   ${W}5${N}) tls       ${D}— real TLS, whitelisted on the Iran path (tun or no-tun)${N}"
  wask 'select' "${_r_cat:-2}"; (( WIZ_BACK )) && return 0
  _r_cat="$WIZ_VAL"; cat="$WIZ_VAL"
  if [[ "$cat" == "5" ]]; then
    echo; echo "TLS mode:"
    echo "   ${W}1${N}) no-tun ${G}(recommended)${N} — tcpfwd port-forward over TLS (what panels use)"
    echo "   ${W}2${N}) tun             — full L3 IP tunnel over TLS"
    wask 'select' "${_r_tlsmode:-1}"; (( WIZ_BACK )) && return 0; _r_tlsmode="$WIZ_VAL"
    if [[ "$_r_tlsmode" == "2" ]]; then
      cat=3; is_ipx=0; no_mux=0; no_pool=0; transport=tls; cat_tls=1; return 0
    fi
    GO_L4=1; l4_tls=1; return 4
  fi
  case "$cat" in 2) cat=3;; 3) cat=4;; 4) cat=5;; esac
  if [[ "$cat" == "1" ]]; then GO_L4=1; return 4; fi
  is_ipx=0; no_mux=0; no_pool=0; transport=tcp
  if [[ "$cat" == "4" ]]; then transport=dns; no_mux=1; no_pool=1
  elif [[ "$cat" == "5" ]]; then transport=ssh; no_mux=1; no_pool=1; fi
}
cn_ensure(){
  [[ "$cat" != "1" ]] && { [[ -x "$BIN_PATH" ]] || { install_prereqs; install_core || { CN_ABORT=1; return 4; }; }; }
  return 3
}
cn_tuntype(){
  [[ "$cat" == "3" ]] || return 3
  [[ "$cat_tls" == "1" ]] && return 3   # TLS tun carrier already chosen in the Transport menu
  echo; echo "tun type:"
  echo "   ${W}1${N}) tcp    ${D}— plain TCP over the tun (scaled by pool)${N}"
  echo "   ${W}2${N}) udp    ${D}— plain UDP over the tun (scaled by pool)${N}"
  echo "   ${W}3${N}) ipx    ${D}— raw IP mimicry (icmp / ipip / ospf / gre / ah / esp)${N}"
  echo "   ${W}4${N}) PGprotocol-NUM1 ${D}— custom header (scaled by pool)${N}"
  echo "   ${W}5${N}) PGprotocol-NUM2 ${D}— custom header 2 (scaled by pool)${N}"
  echo "   ${W}6${N}) PGprotocol-NUM3 ${D}— custom header 3 (scaled by pool)${N}"
  wask 'select' "${_r_tt:-1}"; (( WIZ_BACK )) && return 0
  _r_tt="$WIZ_VAL"
  is_ipx=0; no_mux=1; no_pool=0
  case "$_r_tt" in
    3) is_ipx=1; no_mux=1; no_pool=1; transport=icmp ;;
    2) transport=udp ;;
    4) transport=PGprotocol-NUM1 ;;
    5) transport=PGprotocol-NUM2 ;;
    6) transport=PGprotocol-NUM3 ;;
    *) transport=tcp ;;
  esac
}
cn_ipxproto(){
  [[ "$is_ipx" == "1" ]] || return 3
  echo; echo "ipx protocol:"
  echo "   ${W}1${N}) icmp    ${W}2${N}) ipip    ${W}3${N}) ospf    ${W}4${N}) gre    ${W}5${N}) ah    ${W}6${N}) esp"
  wask 'select' "${_r_ipx:-1}"; (( WIZ_BACK )) && return 0
  _r_ipx="$WIZ_VAL"
  case "$_r_ipx" in 2) transport=ipip;; 3) transport=ospf;; 4) transport=gre;; 5) transport=ah;; 6) transport=esp;; *) transport=icmp;; esac
}
cn_icmp(){
  [[ "$is_ipx" == "1" && "$transport" == "icmp" ]] || return 3
  echo "  ${D}ICMP type: 0=Echo Reply · 8=Echo Request · 3=Dest Unreachable · 11=Time Exceeded${N}"
  echo "  ${D}each server may use a different type (both on core 3.21.5+). If 0 does not connect"
  echo "  (a firewall drops unasked replies): ${W}8${D} on Kharej + ${W}0${D} on Iran = a real ping + its answer${N}"
  wask 'ICMP type' "${icmp_type:-0}"; (( WIZ_BACK )) && return 0; icmp_type="$WIZ_VAL"
  wask 'ICMP code' "${icmp_code:-0}"; (( WIZ_BACK )) && return 0; icmp_code="$WIZ_VAL"
}
cn_tls(){
  [[ "$transport" == "tls" ]] || return 3
  echo; echo "  ${D}TLS carrier: a real TLS session (the client speaks a browser fingerprint via uTLS)."
  echo "  ${D}The Iran policer whitelists any real TLS handshake, so SNI only matters for looks.${N}"
  wask 'SNI (ClientHello server name)' "${tls_sni:-www.cloudflare.com}"; (( WIZ_BACK )) && return 0; tls_sni="$WIZ_VAL"
  echo; echo "uTLS fingerprint:"
  echo "   ${W}1${N}) chrome ${G}(recommended)${N}   ${W}2${N}) firefox   ${W}3${N}) safari   ${W}4${N}) edge   ${W}5${N}) ios"
  wask 'select' "${_r_fp:-1}"; (( WIZ_BACK )) && return 0; _r_fp="$WIZ_VAL"
  case "$_r_fp" in 2) tls_fp=firefox;; 3) tls_fp=safari;; 4) tls_fp=edge;; 5) tls_fp=ios;; *) tls_fp=chrome;; esac
}
cn_dir(){
  if [[ "$is_ipx" == "1" ]]; then dir=1; _cn_role; return 3; fi
  echo; echo "Direction:"
  echo "   ${W}1${N}) reverse ${G}(recommended)${N} — Kharej dials Iran; Iran listens"
  echo "   ${W}2${N}) direct            — Iran dials Kharej"
  if [[ "$transport" == "tcp" || "$transport" == "udp" ]]; then
    echo "   ${W}3${N}) dualway           — both ends dial+listen; upload & download each ride their own fast carrier"
  fi
  wask 'select' "${_r_dir:-1}"; (( WIZ_BACK )) && return 0
  _r_dir="$WIZ_VAL"; dir="$WIZ_VAL"; _cn_role
}
cn_tunname(){ wask 'tun interface name' "${tun_name:-pengutun}"; (( WIZ_BACK )) && return 0; tun_name="$WIZ_VAL"; }
cn_mtu(){ wask 'tun MTU' "${mtu:-1380}"; (( WIZ_BACK )) && return 0; mtu="$WIZ_VAL"; [[ "$mtu" =~ ^[0-9]+$ ]] || mtu=1380; }
cn_profile(){ wask 'tuning profile (fast | balance | resource | gaming)' "${tune_profile:-fast}"; (( WIZ_BACK )) && return 0; tune_profile="$WIZ_VAL"; }
cn_workers(){
  local _cm cpus mem_mb; _cm="$(detect_cpu_mem)"; cpus="${_cm% *}"; mem_mb="${_cm#* }"
  echo "  ${D}workers = max CPU cores the tunnel may use (GOMAXPROCS). 0 = auto —${N}"
  echo "  ${D}scales to this box (cores=${cpus}, ram=${mem_mb}MB) and respects cgroup CPU limits;${N}"
  echo "  ${D}RAM is handled separately via an auto memory limit. Set >0 only to cap CPU.${N}"
  wask 'workers (0 = auto)' "${workers:-0}"; (( WIZ_BACK )) && return 0; workers="$WIZ_VAL"; [[ "$workers" =~ ^[0-9]+$ ]] || workers=0
}
cn_tunaddr(){
  if [[ "$side" == "1" ]]; then wask 'local tun IP (Iran)' "${tun_addr:-10.20.0.1/24}"
  else wask 'local tun IP (Kharej)' "${tun_addr:-10.20.0.2/24}"; fi
  (( WIZ_BACK )) && return 0; tun_addr="$WIZ_VAL"
}
cn_peer(){
  [[ "$is_ipx" == "1" || "$role" == "client" || "$role" == "dualway" ]] || return 3
  wask_req 'peer public IP (the OTHER server)'; (( WIZ_BACK )) && return 0; peer="$WIZ_VAL"
}
cn_ipxextra(){
  [[ "$is_ipx" == "1" ]] || return 3
  local def_ip def_if
  def_if="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' | head -1)"
  def_ip="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1)"
  [[ -n "$def_ip" ]] || def_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  wask 'source IP (this server — packets leave FROM it)' "${src_ip:-$def_ip}"; (( WIZ_BACK )) && return 0; src_ip="$WIZ_VAL"
  wask 'bind interface' "${bind_if:-$def_if}"; (( WIZ_BACK )) && return 0; bind_if="$WIZ_VAL"
  echo
  echo "  ${D}Source-IP spoof: forge the source address of carrier packets (helps evade${N}"
  echo "  ${D}a per-source egress policer). Set matching values on BOTH servers:${N}"
  echo "  ${D}this box's SRC = the other box's DST, and vice-versa.${N}"
  wyn 'use source-IP spoof? (y/N)' 'n'; (( WIZ_BACK )) && return 0; use_spoof="$WIZ_VAL"
  if [[ "$use_spoof" == "y" ]]; then
    wask_req 'spoof SRC (the fake source THIS server stamps on its packets)'; (( WIZ_BACK )) && return 0; spoof_src="$WIZ_VAL"
    wask_req 'spoof DST (the fake source you EXPECT from the peer)'; (( WIZ_BACK )) && return 0; spoof_dst="$WIZ_VAL"
  else spoof_src=""; spoof_dst=""; fi
}
cn_portblock(){
  [[ "$is_ipx" == "1" ]] && return 3
  if [[ "$transport" == "dns" ]]; then
    wask 'DNS UDP port' "${port:-53}"; (( WIZ_BACK )) && return 0; port="$WIZ_VAL"
  elif [[ "$transport" == "ssh" ]]; then
    wask 'SSH port (any port — the SSH banner does the mimicry)' "${port:-2020}"; (( WIZ_BACK )) && return 0; port="$WIZ_VAL"
  elif [[ "$role" == "dualway" ]]; then
    echo "  ${D}dualway uses TWO ports: THIS side's LISTEN port (the peer dials in) and the${N}"
    echo "  ${D}PEER's port (we dial out). Same or different is fine — just make sure each${N}"
    echo "  ${D}side's peer-port equals the OTHER side's listen port. Open both on the firewall.${N}"
    wask 'this side LISTEN port (peer dials in here)' "${dw_lport:-443}"; (( WIZ_BACK )) && return 0; dw_lport="$WIZ_VAL"
    wask 'peer port (we dial out to — the peer LISTEN port)' "${dw_rport:-$dw_lport}"; (( WIZ_BACK )) && return 0; dw_rport="$WIZ_VAL"
  elif [[ "$role" == "server" ]]; then
    wask 'listener port (all connections use this one port)' "${port:-443}"; (( WIZ_BACK )) && return 0; port="$WIZ_VAL"
  else
    wask 'peer port (all connections use this one port)' "${port:-443}"; (( WIZ_BACK )) && return 0; port="$WIZ_VAL"
  fi
}
cn_pool(){
  [[ "$no_pool" == "1" ]] && { pool_conn=1; return 3; }
  echo "  ${D}pool connections = independent parallel carriers, each on its own CPU core.${N}"
  echo "  ${D}For dualway this is carriers PER DIRECTION. Set the SAME value on both servers.${N}"
  echo "  ${D}More carriers = smoother through a per-flow rate policer (decorrelated buckets).${N}"
  wask 'pool connections' "${pool_conn:-8}"; (( WIZ_BACK )) && return 0; pool_conn="$WIZ_VAL"
  [[ "$pool_conn" =~ ^[0-9]+$ && "$pool_conn" -ge 1 ]] || pool_conn=8
}
cn_algo(){
  wask 'encryption (aes-256-gcm | chacha20-poly1305)' "${algo:-aes-256-gcm}"; (( WIZ_BACK )) && return 0; algo="$WIZ_VAL"
  case "$algo" in aes-256-gcm|chacha20-poly1305) ;; *) algo="aes-256-gcm";; esac
}
cn_health(){
  local sidename; [[ "$side" == "1" ]] && sidename="iran" || sidename="kharej"
  wask 'health port (also names the service)' "${health:-1234}"; (( WIZ_BACK )) && return 0; health="$WIZ_VAL"; [[ -n "$health" ]] || health=1234
  id="${sidename}${health}"
}
cn_psk(){
  wask 'pre-shared key (blank = auto)' ""; (( WIZ_BACK )) && return 0; psk="$WIZ_VAL"
  [[ -n "$psk" ]] || { psk="$(gen_psk)"; warn "generated PSK — use the SAME on the other side:"; echo "   ${W}${psk}${N}"; }
}
cn_license(){ lic_enabled="false"; lic_key=""; return 3; }

cn_forward(){
  [[ "$side" == "1" ]] || return 3
  local _lip _base _last peer_tun
  _lip="${tun_addr%%/*}"; _base="${_lip%.*}"; _last="${_lip##*.}"
  if [[ "$_last" == "2" ]]; then peer_tun="${_base}.1"; else peer_tun="${_base}.2"; fi
  local pp_gate="n"; fwd_block=""
  local _fspecs=""
  echo "  ${D}Port-forward (optional): expose local TCP and/or UDP ports over the tunnel${N}"
  echo "  ${D}to the far side (${peer_tun}). TCP can keep the real client IP via PROXY v2.${N}"
  echo "  ${D}Enter ports comma-separated — a single port, a range, or PORT=FARPORT:${N}"
  echo "  ${D}  e.g.  2096,2097    or    200-300    or    8000=9000${N}"
  if [[ "$(ask_yn 'add TCP port-forward(s)? (y/n)' 'y')" == "y" ]]; then
    pp_gate="$(ask_yn '  proxy_protocol — send real client IP? (y/n)' 'n')"
    echo "  ${D}Enter port specs (commas ok, e.g. 2096,2097 or 200-300); blank line = done.${N}"
    [[ "$pp_gate" == "y" ]] && echo "  ${D}proxy_protocol is asked for EACH entry (default no); it is set per-port, not globally.${N}"
    while true; do
      local line; line="$(ask '  TCP ports e.g. 2096,2097 or 200-300 (blank = done)' '')"
      [[ -z "$line" ]] && break
      local lpp="false"
      [[ "$pp_gate" == "y" && "$(ask_yn '    proxy_protocol for these? (y/n)' 'n')" == "y" ]] && lpp="true"
      local parts; IFS=',' read -ra parts <<< "$line"
      local s
      for s in "${parts[@]}"; do
        s="$(printf '%s' "$s" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -z "$s" ]] && continue
        if [[ "$lpp" == "true" && "$s" != *proxy_protocol=* && "$s" != *pp=* ]]; then s="$s proxy_protocol=true"; fi
        _fspecs="${_fspecs}  \"${s}\",
"
        ok "  + ${s}"
      done
    done
  fi
  if [[ "$transport" != "dns" && "$transport" != "ssh" ]] && [[ "$(ask_yn 'add UDP port-forward(s)? (y/n)' 'n')" == "y" ]]; then
    echo "  ${D}UDP relays datagrams over the tunnel (e.g. WireGuard 51820, game, DNS).${N}"
    echo "  ${D}proxy_protocol does not apply to UDP. blank line = done.${N}"
    while true; do
      local uline; uline="$(ask '  UDP ports e.g. 51820 or 7000-7100 (blank = done)' '')"
      [[ -z "$uline" ]] && break
      local uparts; IFS=',' read -ra uparts <<< "$uline"
      local us
      for us in "${uparts[@]}"; do
        us="$(printf '%s' "$us" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -z "$us" ]] && continue
        us="${us#udp/}"
        _fspecs="${_fspecs}  \"udp/${us}\",
"
        ok "  + udp/${us}"
      done
    done
  fi
  if [[ -n "$_fspecs" ]]; then
    fwd_block="[forward]
proxy_protocol = false
ports = [
${_fspecs}]
"
  fi
}

configure_new(){
  local side cat transport="tcp" icmp_type=0 icmp_code=0 is_ipx=0 no_mux=1 no_pool=0 dir role
  local tun_addr tun_name mtu mux=1 pool_conn=1 algo port peer id health psk tune_profile workers src_ip bind_if spoof_src="" spoof_dst="" use_spoof
  local dw_lport="" dw_rport="" lic_enabled="false" lic_key="" fwd_block="" GO_L4=0 CN_ABORT=0
  local tls_sni="" tls_fp="chrome" l4_tls=0 cat_tls=0
  local _r_side _r_cat _r_tt _r_ipx _r_dir _r_fp _r_tlsmode
  wiz_run cn_side cn_cat cn_ensure cn_tuntype cn_ipxproto cn_icmp cn_tls cn_dir cn_tunname cn_mtu cn_profile cn_workers cn_tunaddr cn_peer cn_ipxextra cn_portblock cn_pool cn_algo cn_health cn_psk cn_license cn_forward || return
  [[ "$CN_ABORT" == "1" ]] && { pause; return; }
  [[ "$GO_L4" == "1" ]] && { configure_l4 "$side" tcpfwd "$l4_tls"; return; }
  mkdir -p "$INSTALL_DIR"
  local conf; conf="${INSTALL_DIR}/${id}.toml"
  {
    echo "[transport]"
    if [[ "$is_ipx" == "1" ]]; then echo "type = \"ipx\""; else echo "type = \"${transport}\""; fi
    echo "mode = \"${role}\""
    if [[ "$is_ipx" == "1" ]]; then echo "rekey_interval = 200"; fi
    if [[ "$is_ipx" != "1" ]]; then
      if [[ "$role" == "dualway" ]]; then
        echo "listen = \"0.0.0.0:${dw_lport}\""
        echo "remote = \"${peer}:${dw_rport}\""
      elif [[ "$role" == "server" ]]; then echo "listen = \"0.0.0.0:${port}\""
      else echo "remote = \"${peer}:${port}\""; fi
      echo "pool_connection = ${pool_conn}"
      if [[ "$transport" == "tls" ]]; then
        echo "sni = \"${tls_sni:-www.cloudflare.com}\""
        echo "tls_fingerprint = \"${tls_fp:-chrome}\""
      fi
    fi
    echo ""
    if [[ "$is_ipx" == "1" ]]; then
      echo "[ipx]"
      echo "mode = \"${role}\""
      echo "profile = \"${transport}\""
      echo "listen_ip = \"${src_ip}\""
      echo "dst_ip = \"${peer}\""
      [[ -n "$bind_if" ]] && echo "interface = \"${bind_if}\""
      [[ -n "$spoof_src" ]] && echo "spoof_source = \"${spoof_src}\""
      [[ -n "$spoof_dst" ]] && echo "spoof_peer = \"${spoof_dst}\""
      if [[ "$transport" == "icmp" ]]; then echo "icmp_type = ${icmp_type}"; echo "icmp_code = ${icmp_code}"; fi
      echo ""
    fi
    echo "[tun]"
    echo "name = \"${tun_name}\""
    echo "address = \"${tun_addr}\""
    echo "mtu = ${mtu}"
    echo "health_port = ${health}"
    echo ""
    echo "[security]"
    echo "enable_encryption = true"
    echo "algorithm = \"${algo}\""
    echo "psk = \"${psk}\""
    if [[ "$lic_enabled" == "true" ]]; then
      echo ""
      echo "[license]"
      echo "key = \"${lic_key}\""
    fi
    echo ""
    echo "[health]"
    echo "# heartbeat_interval: how often (seconds) to check the tunnel is alive"
    echo "# heartbeat_timeout: restart the tunnel if it stays down this long (seconds)"
    echo "heartbeat_interval = 10"
    echo "heartbeat_timeout = 25"
    echo ""
    echo "[tuning]"
    echo "auto_tuning = true"
    echo "profile = \"${tune_profile}\""
    echo "workers = ${workers}"
    echo "channel_size = 0"
    echo "so_sndbuf = 0"
    echo "batch_size = 0"
    echo ""
    echo "[logging]"
    echo "level = \"info\""
    if [[ -n "$fwd_block" ]]; then
      printf '%s\n' "$fwd_block"
    fi
  } > "$conf"
  ok "config: ${conf}"

  cat > "${SERVICE_DIR}/$(svc_of "$id").service" <<EOF
[Unit]
Description=pengutunnel ${id} (${role})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStartPre=-/bin/sh -c 'truncate -s 0 $(log_of "$id")'
ExecStart=${BIN_PATH} -config ${conf}
Restart=on-failure
RestartSec=2
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
LimitNOFILE=1048576
StandardOutput=append:$(log_of "$id")
StandardError=append:$(log_of "$id")
[Install]
WantedBy=multi-user.target
EOF
  if [[ "$transport" == "dns" && "$role" == "server" && "$port" == "53" ]]; then
    if ss -ulnp 2>/dev/null | grep -q ':53 '; then
      if systemctl is-active --quiet systemd-resolved; then
        mkdir -p /etc/systemd/resolved.conf.d
        printf '[Resolve]\nDNSStubListener=no\n' > /etc/systemd/resolved.conf.d/pengu-nostub.conf
        [[ -e /run/systemd/resolve/resolv.conf ]] && ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
        systemctl restart systemd-resolved; sleep 1
      fi
      if ss -ulnp 2>/dev/null | grep -q ':53 '; then
        warn "UDP/53 still in use — free it manually before the DNS tunnel can bind it"
      else
        ok "freed UDP/53 (disabled systemd-resolved stub listener)"
      fi
    fi
  fi
  systemctl daemon-reload
  systemctl enable --now "$(svc_of "$id")" >/dev/null 2>&1
  sleep 2
  ok "tunnel ${W}${id}${N} (${role}/${transport}) — $(systemctl is-active "$(svc_of "$id")")"
  echo "  ${D}config: ${conf}   log: $(log_of "$id")${N}"
  pause
}

configure_l4(){
  local side="$1" transport="$2" l4_tls="${3:-0}"   # transport = tcpfwd; l4_tls=1 wraps carriers in real TLS
  local tls_sni="" tls_fp="chrome" _r_fp=""
  local role; [[ "$side" == "1" ]] && role="server" || role="client"
  [[ -x "$BIN_PATH" ]] || { install_prereqs; install_core || { pause; return; }; }
  echo "  ${D}(tip: type ${W}b${N}${D} at any question to go back one step)${N}"
  local ldir listens=0 port peer pool algo health psk tune_profile workers swin l4hdr="" id sidename pp_gate fspecs="" lic_key lic_block="" fwd_block=""
  local _r_dir="" _r_hdr=""
  local step=dir
  while :; do
    case "$step" in
    dir)
      echo; echo "Direction:"
      echo "   ${W}1${N}) reverse ${G}(recommended)${N} — Kharej dials Iran; Iran listens"
      echo "   ${W}2${N}) direct            — Iran dials Kharej; Kharej listens"
      echo "  ${D}Set the SAME direction on both servers.${N}"
      wask 'select' "${_r_dir:-1}"; (( WIZ_BACK )) && { warn "this is the first step"; continue; }
      _r_dir="$WIZ_VAL"; [[ "$WIZ_VAL" == "2" ]] && ldir="direct" || ldir="reverse"
      listens=0
      if [[ "$role" == "server" && "$ldir" == "reverse" ]] || [[ "$role" == "client" && "$ldir" == "direct" ]]; then listens=1; fi
      hr; step=peerport ;;
    peerport)
      if [[ "$listens" == "1" ]]; then
        if [[ "$role" == "server" ]]; then wask 'carrier listen port (Kharej dials this)' "${port:-443}"; else wask 'carrier listen port (the Iran edge dials this)' "${port:-443}"; fi
        (( WIZ_BACK )) && { step=dir; continue; }; port="$WIZ_VAL"
      elif [[ "$role" == "server" ]]; then
        wask_req 'peer public IP (the Kharej exit)'; (( WIZ_BACK )) && { step=dir; continue; }; peer="$WIZ_VAL"
        wask 'carrier port (the Kharej exit listens on)' "${port:-443}"; (( WIZ_BACK )) && { continue; }; port="$WIZ_VAL"
      else
        wask_req 'peer public IP (the Iran edge)'; (( WIZ_BACK )) && { step=dir; continue; }; peer="$WIZ_VAL"
        wask 'carrier port (the Iran edge listens on)' "${port:-443}"; (( WIZ_BACK )) && { continue; }; port="$WIZ_VAL"
      fi
      step=profile ;;
    profile)
      wask 'tuning profile (fast | balance | resource | gaming)' "${tune_profile:-fast}"; (( WIZ_BACK )) && { step=peerport; continue; }; tune_profile="$WIZ_VAL"
      step=workers ;;
    workers)
      wask 'workers (0 = auto)' "${workers:-0}"; (( WIZ_BACK )) && { step=profile; continue; }; workers="$WIZ_VAL"; [[ "$workers" =~ ^[0-9]+$ ]] || workers=0
      step=swin ;;
    swin)
      core_at_least v4.1.0 || { step=pool; continue; }   # older cores have no stream window
      local _cm _mem; _cm="$(detect_cpu_mem)"; _mem="${_cm#* }"
      echo "  ${D}stream window = how fast ONE user connection may go (MB): speed = window / ping.${N}"
      echo "  ${D}0 = auto from this box's RAM (${_mem}MB): 1GB=8, 2GB=16, 4GB=32, 8GB+=64.${N}"
      echo "  ${D}This server's value sets the speed TOWARD it (Iran = download, Kharej = upload).${N}"
      wask 'stream window MB (0 = auto)' "${swin:-0}"; (( WIZ_BACK )) && { step=workers; continue; }; swin="$WIZ_VAL"
      [[ "$swin" =~ ^[0-9]+$ && "$swin" -le 256 ]] || swin=0
      step=pool ;;
    pool)
      echo "  ${D}pool = the fixed number of carrier connections; every user is multiplexed${N}"
      echo "  ${D}over them. Set the SAME value on both servers.${N}"
      wask 'pool (carrier connections)' "${pool:-2}"; (( WIZ_BACK )) && { core_at_least v4.1.0 && step=swin || step=workers; continue; }; pool="$WIZ_VAL"; [[ "$pool" =~ ^[0-9]+$ && "$pool" -ge 1 ]] || pool=2
      step=header ;;
    header)
      if [[ "$l4_tls" == "1" ]]; then
        echo "  ${D}TLS carrier: the client speaks a real browser TLS handshake (uTLS). The${N}"
        echo "  ${D}Iran policer whitelists any real TLS, so SNI only matters for looks.${N}"
        wask 'SNI (ClientHello server name)' "${tls_sni:-www.cloudflare.com}"; (( WIZ_BACK )) && { step=pool; continue; }; tls_sni="$WIZ_VAL"
        echo "  uTLS fingerprint:"
        echo "   ${W}1${N}) chrome ${G}(recommended)${N}   ${W}2${N}) firefox   ${W}3${N}) safari   ${W}4${N}) edge   ${W}5${N}) ios"
        wask 'select' "${_r_fp:-1}"; (( WIZ_BACK )) && { continue; }; _r_fp="$WIZ_VAL"
        case "$_r_fp" in 2) tls_fp=firefox;; 3) tls_fp=safari;; 4) tls_fp=edge;; 5) tls_fp=ios;; *) tls_fp=chrome;; esac
        l4hdr=""; step=algo; continue
      fi
      echo "  ${D}header = how each carrier opens on the wire. Set the SAME on both servers.${N}"
      echo "   ${W}0${N}) none            ${D}— plain tcp${N}"
      echo "   ${W}1${N}) PGprotocol-NUM1 ${D}— custom header${N}"
      echo "   ${W}2${N}) PGprotocol-NUM2 ${D}— custom header 2${N}"
      echo "   ${W}3${N}) PGprotocol-NUM3 ${D}— custom header 3${N}"
      wask 'header' "${_r_hdr:-3}"; (( WIZ_BACK )) && { step=pool; continue; }; _r_hdr="$WIZ_VAL"
      case "$_r_hdr" in 1) l4hdr="PGprotocol-NUM1";; 2) l4hdr="PGprotocol-NUM2";; 3) l4hdr="PGprotocol-NUM3";; *) l4hdr="";; esac
      step=algo ;;
    algo)
      wask 'encryption (aes-256-gcm | chacha20-poly1305)' "${algo:-aes-256-gcm}"; (( WIZ_BACK )) && { step=header; continue; }; algo="$WIZ_VAL"
      case "$algo" in aes-256-gcm|chacha20-poly1305) ;; *) algo="aes-256-gcm";; esac
      step=health ;;
    health)
      [[ "$side" == "1" ]] && sidename="iran" || sidename="kharej"
      wask 'health port (also names the service)' "${health:-1234}"; (( WIZ_BACK )) && { step=algo; continue; }; health="$WIZ_VAL"; [[ -n "$health" ]] || health=1234
      id="${sidename}${health}"
      step=psk ;;
    psk)
      wask 'pre-shared key (blank = auto)' ""; (( WIZ_BACK )) && { step=health; continue; }; psk="$WIZ_VAL"
      [[ -n "$psk" ]] || { psk="$(gen_psk)"; warn "generated PSK — use the SAME on the other side:"; echo "   ${W}${psk}${N}"; }
      step=fwdlic ;;
    fwdlic)
      if [[ "$role" == "server" ]]; then
        echo "  ${D}Ports users hit on THIS server. Each is forwarded to the SAME port on${N}"
        echo "  ${D}127.0.0.1 on Kharej (the exit). Comma-separated ok — a port, a range, or${N}"
        echo "  ${D}PORT=FARPORT (e.g.  2096,2097  or  200-300  or  8000=9000).${N}"
        fspecs=""
        wyn '  proxy_protocol — send real client IP? (y/n)' 'n'; (( WIZ_BACK )) && { step=psk; continue; }; pp_gate="$WIZ_VAL"
        [[ "$pp_gate" == "y" ]] && echo "  ${D}proxy_protocol is asked for EACH entry (default no); it is set per-port, not globally.${N}"
        while true; do
          local line; line="$(ask '  ports e.g. 2096,2097 or 200-300 (blank = done)' '')"
          [[ -z "$line" ]] && break
          local lpp="false"
          [[ "$pp_gate" == "y" && "$(ask_yn '    proxy_protocol for these? (y/n)' 'n')" == "y" ]] && lpp="true"
          local parts; IFS=',' read -ra parts <<< "$line"
          local s
          for s in "${parts[@]}"; do
            s="$(printf '%s' "$s" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            [[ -z "$s" ]] && continue
            if [[ "$lpp" == "true" && "$s" != *proxy_protocol=* && "$s" != *pp=* ]]; then s="$s proxy_protocol=true"; fi
            fspecs="${fspecs}  \"${s}\",
"
            ok "  + ${s}"
          done
        done
        [[ -n "$fspecs" ]] || { err "an edge needs at least one forward port"; continue; }
        fwd_block="[forward]
proxy_protocol = false
ports = [
${fspecs}]
"
      else
        lic_block=""
      fi
      break ;;
    esac
  done

  mkdir -p "$INSTALL_DIR"
  local conf="${INSTALL_DIR}/${id}.toml"
  {
    echo "[transport]"
    echo "type = \"${transport}\""
    echo "mode = \"${role}\""
    if [[ "$listens" == "1" ]]; then echo "listen = \"0.0.0.0:${port}\""
    else echo "remote = \"${peer}:${port}\""; fi
    echo "pool_connection = ${pool}"
    [[ -n "$l4hdr" ]] && echo "l4_header = \"${l4hdr}\""
    if [[ "$l4_tls" == "1" ]]; then
      echo "l4_tls = true"
      echo "sni = \"${tls_sni:-www.cloudflare.com}\""
      echo "tls_fingerprint = \"${tls_fp:-chrome}\""
    fi
    [[ "$ldir" == "direct" ]] && echo "l4_direction = \"direct\""
    echo ""
    echo "[tun]"
    echo "health_port = ${health}"
    echo ""
    echo "[security]"
    echo "enable_encryption = true"
    echo "algorithm = \"${algo}\""
    echo "psk = \"${psk}\""
    echo ""
    if [[ -n "$lic_block" ]]; then printf '%s\n' "$lic_block"; fi
    echo "[health]"
    echo "heartbeat_interval = 10"
    echo "heartbeat_timeout = 25"
    echo ""
    echo "[tuning]"
    echo "auto_tuning = true"
    echo "profile = \"${tune_profile}\""
    echo "workers = ${workers}"
    echo "stream_window = ${swin:-0}"
    echo ""
    echo "[logging]"
    echo "level = \"info\""
    if [[ -n "$fwd_block" ]]; then echo ""; printf '%s\n' "$fwd_block"; fi
  } > "$conf"
  ok "config: ${conf}"

  cat > "${SERVICE_DIR}/$(svc_of "$id").service" <<EOF
[Unit]
Description=pengutunnel ${id} (${transport}/${role})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStartPre=-/bin/sh -c 'truncate -s 0 $(log_of "$id")'
ExecStart=${BIN_PATH} -config ${conf}
Restart=on-failure
RestartSec=2
TimeoutStopSec=10
LimitNOFILE=1048576
StandardOutput=append:$(log_of "$id")
StandardError=append:$(log_of "$id")
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$(svc_of "$id")" >/dev/null 2>&1
  sleep 2
  ok "tunnel ${W}${id}${N} (${role}/${transport}, ${ldir}) — $(systemctl is-active "$(svc_of "$id")")"
  echo "  ${D}config: ${conf}   log: $(log_of "$id")${N}"
  if [[ "$ldir" == "direct" ]]; then
    echo "  ${D}direct needs core 3.21.0 or newer on BOTH servers; open port ${port} on the Kharej firewall.${N}"
  fi
  pause
}

pick_tunnel(){
  local ids=(); mapfile -t ids < <(list_ids)
  [[ ${#ids[@]} -gt 0 ]] || { warn "no tunnels installed"; pause; return 1; }
  echo "Existing tunnels:"; local i=1
  for id in "${ids[@]}"; do
    local cf; cf="$(conf_of "$id")"
    local role; role="$(sed -n -e 's/^role: *//p' -e 's/^mode *= *"\([^"]*\)".*/\1/p' "$cf" 2>/dev/null | head -1)"
    [[ -n "$role" ]] || { grep -q '^auth' "$cf" 2>/dev/null && role="hysteria"; }
    echo "  ${W}${i}${N}) ${role:-?} (id: ${id})  $(systemctl is-active "$(svc_of "$id")" 2>/dev/null)"
    ((i++))
  done
  local ch; ch="$(ask 'select (0 to return)' '0')"
  [[ "$ch" =~ ^[0-9]+$ && "$ch" -ge 1 && "$ch" -le ${#ids[@]} ]] || return 1
  PICKED="${ids[$((ch-1))]}"; return 0
}

manage_menu(){
  banner
  pick_tunnel || return
  local id="$PICKED" svc; svc="$(svc_of "$id")"
  while true; do
    banner
    echo "Manage tunnel ${W}${id}${N}  (${G}$(systemctl is-active "$svc")${N})"; hr
    echo "  ${W}1${N}) Remove this tunnel"
    echo "  ${W}2${N}) Restart this tunnel"
    echo "  ${W}3${N}) View service logs"
    echo "  ${W}4${N}) View service status"
    echo "  ${W}0${N}) Back"
    hr
    case "$(ask 'choose' '')" in
      1) systemctl disable --now "$svc" 2>/dev/null; rm_icmp_rule "$id"; find "${SERVICE_DIR}" -maxdepth 1 -name "${svc}.service" -delete; find "$INSTALL_DIR" -maxdepth 1 \( -name "${id}.toml" -o -name "${id}.yaml" -o -name "${id}.log" \) -delete; systemctl daemon-reload; ok "removed ${id}"; pause; return ;;
      2) systemctl restart "$svc"; ok "restarted"; pause ;;
      3) view_logs "$id" "$svc" ;;
      4) systemctl status "$svc" --no-pager -l 2>&1 | head -20; pause ;;
      0) return ;;
    esac
  done
}

fmt_dur(){
  local s=$1 d h m; d=$((s/86400)); h=$((s%86400/3600)); m=$((s%3600/60)); s=$((s%60))
  if ((d)); then echo "${d}d ${h}h"; elif ((h)); then echo "${h}h ${m}m"; elif ((m)); then echo "${m}m ${s}s"; else echo "${s}s"; fi
}
stop_reason(){
  local lf line
  lf="$(systemctl cat "$1" 2>/dev/null | sed -n 's/^StandardOutput=[a-z]*://p' | tail -1)"
  if [[ -f "$lf" ]]; then line="$(tail -n 500 "$lf" | awk '/──────/{s=""} /⛔/{s=$0} END{print s}')"
  else line="$(journalctl -u "$1" -n 500 --no-pager -o cat 2>/dev/null | awk '/──────/{s=""} /⛔/{s=$0} END{print s}')"; fi
  [[ -n "$line" ]] || return 0
  line="${line#*⛔}"; line="${line%% — *}"
  echo "${line# }"
}
status_all(){
  banner
  local ids=(); mapfile -t ids < <(list_ids)
  [[ ${#ids[@]} -gt 0 ]] || { warn "no tunnels"; pause; return; }
  echo "${W}Tunnel status${N}"; hr
  local id
  for id in "${ids[@]}"; do
    local svc cf tn tunip h js st alive peers transport up why
    svc="$(svc_of "$id")"; cf="$(conf_of "$id")"
    tn="$(sed -n -e 's/^ *name *= *"\([^"]*\)".*/\1/p' -e 's/.*name: *\([A-Za-z0-9_-]*\).*/\1/p' "$cf" 2>/dev/null | head -1)"
    tunip="$(ip -br addr show "${tn:-peng$id}" 2>/dev/null | awk '{print $3}')"
    h="$(sed -n -e 's/^health_port *= *\([0-9][0-9]*\).*/127.0.0.1:\1/p' -e 's/.*listen: *"\(127[^"]*\)".*/\1/p' "$cf" 2>/dev/null | head -1)"
    st="$(systemctl is-active "$svc" 2>/dev/null)"
    js=""; [[ "$st" == "active" && -n "$h" ]] && js="$(curl -s --max-time 2 "http://${h}/health" 2>/dev/null)"
    alive="$(sed -n 's/.*"alive":\([a-z]*\).*/\1/p' <<<"$js")"
    peers="$(sed -n 's/.*"peers":\([0-9]*\).*/\1/p' <<<"$js")"
    transport="$(sed -n 's/.*"transport":"\([^"]*\)".*/\1/p' <<<"$js")"
    up="$(sed -n 's/.*"uptime_s":\([0-9]*\).*/\1/p' <<<"$js")"
    case "$st" in
      active)
        printf '  %s%-14s%s %s● running%s   %s\n' "$W" "$id" "$N" "$G" "$N" "${D}${transport}${N}"
        if [[ -z "$js" ]]; then
          printf '      %-12s %s\n' "connection" "${Y}starting…${N}"
        elif [[ "$alive" == "true" ]]; then
          printf '      %-12s %s\n' "connection" "${G}connected${N} · ${peers} carrier$([[ "$peers" == 1 ]] || echo s)"
        else
          printf '      %-12s %s\n' "connection" "${R}not connected${N} — waiting for the other server"
        fi
        [[ -n "$up" ]] && printf '      %-12s %s\n' "uptime" "$(fmt_dur "$up")"
        ;;
      activating)
        printf '  %s%-14s%s %s◌ starting%s\n' "$W" "$id" "$N" "$Y" "$N" ;;
      *)
        printf '  %s%-14s%s %s○ stopped%s\n' "$W" "$id" "$N" "$R" "$N"
        why="$(stop_reason "$svc")"
        [[ -n "$why" ]] && printf '      %-12s %s\n' "reason" "$why"
        case "$why" in
          *"times in a row"*|*"the proof is for"*)
            printf '      %-12s %s\n' "fix" "correct the license, then menu 2 → Restart this tunnel" ;;
          *)
            if au_enabled; then printf '      %-12s %s\n' "" "${D}auto core update is ON: it is started again within a minute${N}"
            elif [[ "$why" == *"older than the required minimum"* ]]; then printf '      %-12s %s\n' "fix" "update the core on the other server, then menu 2 → Restart this tunnel"
            else printf '      %-12s %s\n' "fix" "menu 2 → Restart this tunnel"; fi ;;
        esac
        ;;
    esac
    [[ -n "$tunip" ]] && printf '      %-12s %s\n' "tunnel IP" "$tunip"
    echo
  done
  pause
}

update_core(){
  banner
  warn "This bundle is pinned to the reviewed offline v4.2.1 core."
  warn "To upgrade, install a newly reviewed bundle on BOTH peers."
  pause
}

update_script(){ banner; warn "Use install.sh from the next reviewed offline bundle."; pause; }
AU_UNIT="pengu-core-autoupdate"
AU_SCRIPT="${INSTALL_DIR}/autoupdate.sh"
AU_LOG="${INSTALL_DIR}/autoupdate.log"
KP_UNIT="pengu-tunnel-keeper"
KP_SCRIPT="${INSTALL_DIR}/keeper.sh"
KP_LOG="${INSTALL_DIR}/keeper.log"
au_enabled(){ systemctl is-enabled "${AU_UNIT}.timer" >/dev/null 2>&1; }
au_write_script(){ return 1; }

kp_install(){
  mkdir -p "$INSTALL_DIR"
  cat > "$KP_SCRIPT" <<'KPS'
LOG=/root/pengutunnel/keeper.log
log(){ echo "$(date '+%F %T') $*" >> "$LOG"; tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"; }
exec 9>/run/pengu-tunnel-keeper.lock; flock -n 9 || exit 0
flock -n /run/pengu-core-autoupdate.lock true 2>/dev/null || exit 0
license_stop(){
  local lf last
  lf="$(systemctl cat "$1" 2>/dev/null | sed -n 's/^StandardOutput=[a-z]*://p' | tail -1)"
  if [ -f "$lf" ]; then last="$(tail -n 500 "$lf" | awk '/──────/{s=""} /⛔/{s=$0} END{print s}')"
  else last="$(journalctl -u "$1" -n 500 --no-pager -o cat 2>/dev/null | awk '/──────/{s=""} /⛔/{s=$0} END{print s}')"; fi
  case "$last" in *"times in a row"*|*"the proof is for"*) return 0;; esac
  return 1
}
for u in $(systemctl list-unit-files --type=service --no-legend 'pengutunnel-*.service' 2>/dev/null | awk '$2=="enabled"{print $1}'); do
  case "$(systemctl show -p ActiveState --value "$u" 2>/dev/null)" in active|activating|reloading|deactivating) continue;; esac
  license_stop "$u" && continue
  systemctl reset-failed "$u" 2>/dev/null
  n="${u%.service}"; n="${n#pengutunnel-}"
  if systemctl start "$u" 2>/dev/null; then log "${n} was not running — started it again"
  else log "${n} is not running and could not be started"; fi
done
KPS
  chmod 755 "$KP_SCRIPT"
  if [[ ! -f "${SERVICE_DIR}/${KP_UNIT}.service" || ! -f "${SERVICE_DIR}/${KP_UNIT}.timer" ]]; then
    cat > "${SERVICE_DIR}/${KP_UNIT}.service" <<EOF
[Unit]
Description=pengutunnel tunnel keeper (starts a stopped tunnel again)
[Service]
Type=oneshot
ExecStart=/bin/bash ${KP_SCRIPT}
EOF
    cat > "${SERVICE_DIR}/${KP_UNIT}.timer" <<EOF
[Unit]
Description=pengutunnel tunnel keeper (every minute)
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=5s
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
  fi
  systemctl is-enabled "${KP_UNIT}.timer" >/dev/null 2>&1 || systemctl enable --now "${KP_UNIT}.timer" >/dev/null 2>&1
}
au_enable(){ warn "Automatic vendor updates are disabled for this pinned offline bundle."; return 1; }

au_disable(){
  systemctl disable --now "${AU_UNIT}.timer" "${KP_UNIT}.timer" >/dev/null 2>&1
  rm -f "${SERVICE_DIR}/${AU_UNIT}.timer" "${SERVICE_DIR}/${AU_UNIT}.service" "$AU_SCRIPT" "${INSTALL_DIR}/autoupdate.failed" \
        "${SERVICE_DIR}/${KP_UNIT}.timer" "${SERVICE_DIR}/${KP_UNIT}.service" "$KP_SCRIPT"
  systemctl daemon-reload
}
auto_update_menu(){ banner; warn "Automatic vendor updates are disabled. Upgrade with a reviewed offline bundle on both peers."; pause; }

remove_core(){ banner; if [[ "$(ask_yn 'remove ALL tunnels + core? (y/n)' 'n')" == "y" ]]; then au_disable; for id in $(list_ids); do systemctl disable --now "$(svc_of "$id")" 2>/dev/null; rm_icmp_rule "$id"; find "${SERVICE_DIR}" -maxdepth 1 -name "pengutunnel-${id}.service" -delete; done; systemctl daemon-reload; find "$INSTALL_DIR" -mindepth 1 -delete 2>/dev/null; ok "removed /root/pengutunnel"; fi; pause; }

_ipl_enable(){
  local id="$1" conf="$2" mode peerip port
  if systemctl is-active x-ui >/dev/null 2>&1; then mode="watcher"; ok "x-ui detected on THIS server → role WATCHER (reads fail2ban, pushes bans)";
  else mode="enforcer"; ok "no x-ui here → role ENFORCER (applies iptables bans at the ingress)"; fi
  if [[ "$(ask_yn "  use role '${mode}' for this server? (y/n)" 'y')" != "y" ]]; then
    [[ "$mode" == "watcher" ]] && mode="enforcer" || mode="watcher"
  fi
  peerip="$(sed -n -e 's/^ *dst_ip *= *"\([^"]*\)".*/\1/p' -e 's/^ *remote *= *"\([^":]*\).*/\1/p' "$conf" 2>/dev/null | head -1)"
  port="$(ask 'control port (tun tunnels use it inside the tunnel; tcpfwd opens it only to the other server)' '1055')"
  strip_block "$conf" "xui_iplimit"
  {
    echo ""
    echo "[xui_iplimit]"
    echo "enabled = true"
    echo "mode = \"${mode}\""
    echo "control_port = ${port}"
    if [[ "$mode" == "watcher" ]]; then
      local jail sa; jail="$(ask 'fail2ban jail to mirror' '3x-ipl')"
      sa="$peerip"; [[ -n "$sa" ]] || sa="$(ask_req 'ingress (Iran) public IP')"
      echo "jail = \"${jail}\""
      echo "poll_interval = 3"
      echo "server_addr = \"${sa}:${port}\""
      systemctl is-active fail2ban >/dev/null 2>&1 || warn "fail2ban is not active here — the watcher needs it (x-ui installs it)"
    else
      [[ -n "$peerip" ]] && echo "peer_ip = \"${peerip}\""
      echo "max_ban_minutes = 45"
      command -v iptables >/dev/null 2>&1 || warn "iptables not found — the enforcer needs it"
    fi
  } >> "$conf"
  systemctl restart "$(svc_of "$id")"
  ok "x-ui ip-limit ${W}${mode}${N} enabled on ${id} — $(systemctl is-active "$(svc_of "$id")")"
  echo "  ${D}Now enable the OTHER role on the other server (x-ui side = watcher, ingress = enforcer).${N}"
  pause
}
_ipl_disable(){
  local id="$1" conf="$2"
  _ipl_enabled "$conf" || { warn "already disabled for ${id}"; pause; return; }
  strip_block "$conf" "xui_iplimit"
  systemctl restart "$(svc_of "$id")"   # SIGTERM → the enforcer flushes its iptables chain on the way out
  ok "x-ui ip-limit disabled on ${id} — $(systemctl is-active "$(svc_of "$id")")"
  pause
}
_ipl_status(){
  local id="$1" conf="$2"
  banner
  echo "  ${B}x-ui IP-limit status — ${W}${id}${N}"; echo
  if ! _ipl_enabled "$conf"; then echo "  ${D}disabled for this tunnel${N}"; pause; return; fi
  local mode port; mode="$(_ipl_field "$conf" mode)"; port="$(_ipl_field "$conf" control_port)"
  echo "  mode         : ${W}${mode}${N}"
  echo "  control_port : ${port}"
  if [[ "$mode" == "watcher" ]]; then
    echo "  jail         : $(_ipl_field "$conf" jail)"
    echo "  server_addr  : $(_ipl_field "$conf" server_addr)"
    echo; echo "  ${B}fail2ban jail banned (source of truth):${N}"
    fail2ban-client status "$(_ipl_field "$conf" jail)" 2>/dev/null | sed -n 's/.*Banned IP list:[[:space:]]*/    /p'
  else
    echo "  peer_ip      : $(_ipl_field "$conf" peer_ip)"
    echo; echo "  ${B}currently blocked at ingress (iptables ${W}PENGU-BANSYNC${N}${B}):${N}"
    iptables -S PENGU-BANSYNC 2>/dev/null | sed -n 's/.*-s \([0-9.]*\).*-j DROP/    \1/p'
    echo "  ${D}total blocked: $(iptables -S PENGU-BANSYNC 2>/dev/null | grep -c -- '-s ')${N}"
    echo -n "  control port ${port} listening: "; ss -tlnH "sport = :${port}" 2>/dev/null | grep -q . && echo "${G}yes${N}" || echo "${R}no${N}"
  fi
  echo; echo "  ${B}recent bansync log:${N}"
  grep -aE 'bansync|ip-limit|🛡|👁' "${INSTALL_DIR}/${id}.log" 2>/dev/null | tail -n 12 | sed 's/^/    /' || true
  pause
}
xui_iplimit_menu(){
  banner
  local ids=(); mapfile -t ids < <(list_ids)
  [[ ${#ids[@]} -gt 0 ]] || { warn "no tunnels — configure one first"; pause; return; }
  echo "  ${B}x-ui IP-limit ban sync${N}"
  echo "  ${D}Blocks a user on the INGRESS when x-ui's per-user IP limit bans them on the exit${N}"
  echo "  ${D}side — otherwise the ban is useless because traffic arrives via the tunnel.${N}"; echo
  local i=1 id
  for id in "${ids[@]}"; do
    local c st; c="$(conf_of "$id")"; st="${D}off${N}"; _ipl_enabled "$c" && st="${G}on ($(_ipl_field "$c" mode))${N}"
    echo "  ${W}${i}${N}) ${id}   [${st}]   $(systemctl is-active "$(svc_of "$id")" 2>/dev/null)"
    i=$((i+1))
  done
  local sel; sel="$(ask 'select tunnel #' '1')"; [[ "$sel" =~ ^[0-9]+$ ]] || return
  id="${ids[$((sel-1))]}"; [[ -n "$id" ]] || return
  local conf; conf="$(conf_of "$id")"; [[ -f "$conf" ]] || { err "config not found for ${id}"; pause; return; }
  while true; do
    banner
    local cur="${D}disabled${N}"; _ipl_enabled "$conf" && cur="${G}enabled (mode: $(_ipl_field "$conf" mode))${N}"
    echo "  ${B}x-ui IP-limit — tunnel ${W}${id}${N}   [${cur}]"; echo
    echo "  ${G}1) Enable / reconfigure${N}"
    echo "  ${R}2) Disable${N}"
    echo "  ${B}3) Status & log${N}"
    echo "  ${G}0) Back${N}"
    case "$(ask 'choose' '')" in
      1) _ipl_enable "$id" "$conf" ;;
      2) _ipl_disable "$id" "$conf" ;;
      3) _ipl_status "$id" "$conf" ;;
      0) return ;;
    esac
  done
}
FOREIGN_MIRRORS="http://archive.ubuntu.com/ubuntu http://de.archive.ubuntu.com/ubuntu http://nl.archive.ubuntu.com/ubuntu http://fr.archive.ubuntu.com/ubuntu http://mirror.hetzner.com/ubuntu/packages"
IRAN_MIRRORS="http://mirror.arvancloud.ir/ubuntu http://ir.archive.ubuntu.com/ubuntu http://mirror.aminidc.com/ubuntu http://repo.iut.ac.ir/ubuntu http://mirror.faraso.org/ubuntu http://mirror.iranserver.com/ubuntu http://ubuntu.hostiran.ir/ubuntu http://mirrors.pardisco.co/ubuntu"
MIRROR_GOOD=1.5
FOREIGN_DNS="1.1.1.1,1.0.0.1:cloudflare 8.8.8.8,8.8.4.4:google 9.9.9.9,149.112.112.112:quad9"
IRAN_DNS="178.22.122.100,185.51.200.2:shecan 10.202.10.10,10.202.10.11:radar 78.157.42.100,78.157.42.101:electro 185.55.226.26,185.55.225.25:begzar"
DNS_GOOD=150
APT_SRC="/etc/apt/sources.list.d/ubuntu.sources"
APT_BAK="/etc/apt/pengu-ubuntu-sources.bak"

_apt_code(){ . /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-noble}"; }
_bench_mirrors(){ local m t; for m in $1; do t="$(curl -o /dev/null -s -w '%{time_total}' --max-time 5 "${m}/dists/${2}/Release" 2>/dev/null)"; [[ -n "$t" && "$t" != 0.000000 ]] && echo "$t $m"; done; }
_bench_dns(){ local e pair ip name t0 t1; for e in $1; do pair="${e%%:*}"; ip="${pair%%,*}"; name="${e##*:}"; t0=$(date +%s%3N); if timeout 2 bash -c "exec 3<>/dev/tcp/${ip}/53" 2>/dev/null; then t1=$(date +%s%3N); echo "$((t1-t0)) $pair $name"; fi; done; }

_set_mirror(){
  [[ -f "$APT_BAK" ]] || cp -a "$APT_SRC" "$APT_BAK" 2>/dev/null
  cat > "$APT_SRC" <<EOF
Types: deb
URIs: ${1}/
Suites: ${2} ${2}-updates ${2}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: ${1}/
Suites: ${2}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
  ok "mirror set to ${1}  (run 'apt-get update' yourself when you want)"
}
_mirror_auto(){
  local code; code="$(_apt_code)"
  echo "testing famous foreign mirrors first (${code})..."
  local tmp; tmp="$(mktemp)"
  _bench_mirrors "$FOREIGN_MIRRORS" "$code" | sort -n > "$tmp"
  local bt=""; [[ -s "$tmp" ]] && bt="$(head -1 "$tmp" | awk '{print $1}')"
  if [[ -n "$bt" ]] && awk "BEGIN{exit !($bt <= $MIRROR_GOOD)}"; then
    :
  else
    echo "no fast-enough foreign mirror (best=${bt:-none}s) - testing Iranian mirrors..."
    _bench_mirrors "$IRAN_MIRRORS" "$code" >> "$tmp"; sort -n "$tmp" -o "$tmp"
  fi
  if [[ ! -s "$tmp" ]]; then err "no mirror reachable"; rm -f "$tmp"; return; fi
  head -6 "$tmp" | awk '{printf "   %8ss  %s\n",$1,$2}'
  local best; best="$(head -1 "$tmp" | awk '{print $2}')"; rm -f "$tmp"
  ok "fastest: $best"; _set_mirror "$best" "$code"
}
_mirror_manual(){
  local code; code="$(_apt_code)"
  local -a urls=(); local i=0 m
  for m in $FOREIGN_MIRRORS $IRAN_MIRRORS; do i=$((i+1)); urls[$i]="$m"; printf "  ${W}%2d${N}) %s\n" "$i" "$m"; done
  local n; n="$(ask 'pick mirror #' '1')"
  [[ "$n" =~ ^[0-9]+$ && -n "${urls[$n]}" ]] || { err "invalid choice"; return; }
  ok "selected: ${urls[$n]}"; _set_mirror "${urls[$n]}" "$code"
}
_mirror_restore(){ if [[ -f "$APT_BAK" ]]; then cp -a "$APT_BAK" "$APT_SRC"; ok "restored Ubuntu default sources"; else warn "no pengu backup found"; fi; }
best_mirror(){
  while true; do
    banner
    echo "  ${B}Best apt mirror (repos)${N}"; echo
    echo "  ${W}1) Auto (foreign first, then Iranian)${N}"
    echo "  ${W}2) Manual pick from list${N}"
    echo "  ${Y}3) Restore Ubuntu default${N}"
    echo "  ${G}0) Back${N}"
    case "$(ask 'choose' '')" in
      1) _mirror_auto; pause ;;
      2) _mirror_manual; pause ;;
      3) _mirror_restore; pause ;;
      0) return ;;
    esac
  done
}

_set_dns(){
  [[ -f /etc/resolv.conf.pengu-orig ]] || cp -aL /etc/resolv.conf /etc/resolv.conf.pengu-orig 2>/dev/null
  { echo "# set by pengutunnel installer"; echo "nameserver $1"; [[ -n "$2" ]] && echo "nameserver $2"; } > "/tmp/rc.$$"
  rm -f /etc/resolv.conf; mv "/tmp/rc.$$" /etc/resolv.conf
  ok "DNS set: $1${2:+, $2}"
}
_dns_auto(){
  echo "testing famous foreign DNS first..."
  local tmp; tmp="$(mktemp)"
  _bench_dns "$FOREIGN_DNS" | sort -n > "$tmp"
  local bt=""; [[ -s "$tmp" ]] && bt="$(head -1 "$tmp" | awk '{print $1}')"
  if [[ -n "$bt" && "$bt" -le "$DNS_GOOD" ]]; then
    :
  else
    echo "no fast-enough foreign DNS (best=${bt:-none}ms) - testing Iranian DNS..."
    _bench_dns "$IRAN_DNS" >> "$tmp"; sort -n "$tmp" -o "$tmp"
  fi
  if [[ ! -s "$tmp" ]]; then err "no DNS reachable"; rm -f "$tmp"; return; fi
  head -6 "$tmp" | awk '{split($2,p,","); printf "   %5sms  %-11s %s + %s\n",$1,$3,p[1],p[2]}'
  local best nm; best="$(sed -n '1p' "$tmp" | awk '{print $2}')"; nm="$(sed -n '1p' "$tmp" | awk '{print $3}')"; rm -f "$tmp"
  ok "fastest: $nm"; _set_dns "${best%%,*}" "${best#*,}"
}
_dns_manual(){
  local -a pairs=() names=(); local i=0 e pair
  for e in $FOREIGN_DNS $IRAN_DNS; do pair="${e%%:*}"; i=$((i+1)); pairs[$i]="$pair"; names[$i]="${e##*:}"; printf "  ${W}%2d${N}) %-11s %s + %s\n" "$i" "${names[$i]}" "${pair%%,*}" "${pair#*,}"; done
  local n; n="$(ask 'pick DNS #' '1')"
  [[ "$n" =~ ^[0-9]+$ && -n "${pairs[$n]}" ]] || { err "invalid choice"; return; }
  ok "selected: ${names[$n]}"; _set_dns "${pairs[$n]%%,*}" "${pairs[$n]#*,}"
}
_dns_restore(){ if [[ -f /etc/resolv.conf.pengu-orig ]]; then rm -f /etc/resolv.conf; cp -a /etc/resolv.conf.pengu-orig /etc/resolv.conf; ok "resolv.conf restored"; else rm -f /etc/resolv.conf; ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null; systemctl restart systemd-resolved 2>/dev/null; ok "restored to systemd-resolved default"; fi; }
best_dns(){
  while true; do
    banner
    echo "  ${B}Best DNS${N}"; echo
    echo "  ${W}1) Auto (foreign first, then Iranian)${N}"
    echo "  ${W}2) Manual pick from list${N}"
    echo "  ${Y}3) Restore default${N}"
    echo "  ${G}0) Back${N}"
    case "$(ask 'choose' '')" in
      1) _dns_auto; pause ;;
      2) _dns_manual; pause ;;
      3) _dns_restore; pause ;;
      0) return ;;
    esac
  done
}

ip_probe_both(){
  banner
  echo "${W}IP probe${N}"
  echo
  local peer; peer="$(ask 'Peer IP (the other server)' '')"
  [[ -z "$peer" ]] && { err 'peer IP required'; pause; return; }
  echo
  echo "${D}Source IPs — any mix of single, CIDR (1.2.3.0/28), range (1.2.3.5-1.2.3.10):${N}"
  local ranges; ranges="$(ask 'My source IPs' '')"
  [[ -z "$ranges" ]] && { err 'source IPs required'; pause; return; }
  echo
  echo "  ${G}1${N}) icmp   ${G}2${N}) ipip   ${G}3${N}) gre   ${G}4${N}) ah   ${G}5${N}) esp   ${G}6${N}) all"
  local protos
  case "$(ask 'Protocol' '6')" in
    1) protos=icmp ;;
    2) protos=ipip ;;
    3) protos=gre ;;
    4) protos=ah ;;
    5) protos=esp ;;
    *) protos="icmp,ipip,gre,ah,esp" ;;
  esac
  local rounds; rounds="$(ask 'How many rounds (how many times each source IP is sent)' '5')"
  rounds="${rounds//[^0-9]/}"
  [[ -z "$rounds" || "$rounds" -lt 1 ]] && rounds=5
  echo
  echo "${D}running: ${BIN_PATH} probe both -peer ${peer} -ranges \"${ranges}\" -proto ${protos} -rounds ${rounds}${N}"
  echo "${W}Start the SAME thing on the other server now (menu 11); they sync on their own.${N}"
  echo
  "$BIN_PATH" probe both -peer "$peer" -ranges "$ranges" -proto "$protos" -rounds "$rounds"
  echo
  pause
}


menu(){
  while true; do
    banner
    echo "  ${G}1. Configure a new tunnel${N}"
    echo "  ${R}2. Tunnel management${N}"
    echo "  ${B}3. Check tunnel status${N}"
    echo "  ${B}4. x-ui IP-limit ban sync${N}"
    echo "  ${B}5. Offline update policy${N} $(au_enabled && echo "${G}[ON]${N}" || echo "${R}[OFF]${N}")"
    echo "  ${G}6. Update core${N}"
    echo "  ${G}7. Update script${N}"
    echo "  ${G}8. Remove core${N}"
    echo "  ${B}9. Best apt mirror${N}"
    echo "  ${B}10. Best DNS${N}"
    echo "  ${B}11. IP probe${N}"
    echo "  ${G}0. Exit${N}"
    echo "${G}═══════════════════════════════════════════${N}"
    case "$(ask 'Enter your choice [0-11]' '')" in
      1) configure_new ;;
      2) manage_menu ;;
      3) status_all ;;
      4) xui_iplimit_menu ;;
      5) auto_update_menu ;;
      6) update_core ;;
      7) update_script ;;
      8) remove_core ;;
      9) best_mirror ;;
      10) best_dns ;;
      11) ip_probe_both ;;
      0) exit 0 ;;
    esac
  done
}

need_root
printf "${D}loading…${N}\r"
load_sysinfo
if au_enabled || systemctl is-active --quiet "${AU_UNIT}.timer" || systemctl is-active --quiet "${AU_UNIT}.service"; then
  warn "Disabling the previous Pengu core updater to keep this reviewed binary installed."
  systemctl disable --now "${AU_UNIT}.timer" >/dev/null 2>&1 || exit 1
  systemctl stop "${AU_UNIT}.service" >/dev/null 2>&1 || exit 1
fi
ensure_core || exit 1

menu
