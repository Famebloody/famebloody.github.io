#!/usr/bin/env bash
# Usage: ./reality_check.sh <domain[:port]>
#
# Оценивает домен:
#   1) Как SNI (TLS 1.3, HTTP/2, CDN, пинг и т.д.)
#   2) Как dest (с учётом порта, если указан; иначе 443)
# По итогам даёт цветной общий вердикт.
#
# HTTP/3 и редиректы не влияют на Suitability. Основные критерии:
#   - TLS 1.3
#   - HTTP/2
#   - CDN = No
#
# Работает на CentOS / Debian / Ubuntu.
# Требует sudo для автоустановки отсутствующих утилит.

GREEN="\033[32m"
RED="\033[31m"
CYAN="\033[36m"
YELLOW="\033[33m"
BOLD="\033[1m"
RESET="\033[0m"

# Для выделения фона (черный текст на зелёном / белый текст на красном):
BG_GREEN="\033[30;42m"
BG_RED="\033[97;41m"

if [ -z "$1" ]; then
  echo -e "${RED}Usage: $0 <domain[:port]>${RESET}"
  exit 1
fi

# Разберём domain[:port]
INPUT="$1"
if [[ "$INPUT" == *:* ]]; then
  DOMAIN="${INPUT%%:*}"
  PORT="${INPUT##*:}"
else
  DOMAIN="$INPUT"
  PORT="443"
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
  echo -e "${RED}Error: Port must be numeric.${RESET}"
  exit 1
fi

################################################################################
# Определение пакетного менеджера
################################################################################
function detect_package_manager() {
  if [ -f /etc/redhat-release ] || grep -iq 'centos' /etc/os-release 2>/dev/null; then
    PKG_MGR="yum"
  else
    PKG_MGR="apt-get"
  fi
}

detect_package_manager

################################################################################
# Установка необходимых утилит (минимальный вывод)
################################################################################
function check_and_install_command() {
  local cmd="$1"
  if ! command -v "$cmd" &>/dev/null; then
    echo "Installing $cmd..."
    if [ "$PKG_MGR" = "yum" ]; then
      sudo yum install -y "$cmd" >/dev/null 2>&1
    else
      sudo apt-get update -y >/dev/null 2>&1
      sudo apt-get install -y "$cmd" >/dev/null 2>&1
    fi
    if ! command -v "$cmd" &>/dev/null; then
      echo -e "${RED}Failed to install '$cmd'. Install manually.${RESET}"
      exit 1
    else
      echo "$cmd installed successfully."
    fi
  fi
}

NEEDED_CMDS=(openssl curl dig whois ping)
for cmd in "${NEEDED_CMDS[@]}"; do
  check_and_install_command "$cmd"
done

################################################################################
# Глобальные переменные (вердикты)
################################################################################
SNI_FINAL="Not checked"
DEST_FINAL="Not checked"

################################################################################
# Проверка на пригодность в качестве SNI
################################################################################
sni_positives=()
sni_negatives=()

function check_sni() {
  # --- 1) DNS (A/AAAA) ---
  dns_v4=$(dig +short A "$DOMAIN" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
  dns_v6=$(dig +short AAAA "$DOMAIN" | grep -E '^[0-9A-Fa-f:]+$')

  if [ -z "$dns_v4" ] && [ -z "$dns_v6" ]; then
    sni_negatives+=("DNS: домен не разрешается")
  else
    local c4=$(echo "$dns_v4" | sed '/^$/d' | wc -l)
    local c6=$(echo "$dns_v6" | sed '/^$/d' | wc -l)
    sni_positives+=("DNS: найдено $c4 A, $c6 AAAA")

    # Проверка приватных IP
    for ip in $dns_v4 $dns_v6; do
      if [[ "$ip" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^127\.|^169\.254\. ]]; then
        sni_negatives+=("DNS: приватный IPv4 ($ip)")
      elif [[ "$ip" =~ ^fc00:|^fd00:|^fe80:|^::1$ ]]; then
        sni_negatives+=("DNS: приватный IPv6 ($ip)")
      fi
    done
  fi

  # --- 2) Пинг (берём первый IP для SNI) ---
  local first_ip=""
  if [ -n "$dns_v4" ]; then
    first_ip=$(echo "$dns_v4" | head -n1)
  elif [ -n "$dns_v6" ]; then
    first_ip=$(echo "$dns_v6" | head -n1)
  fi
  if [ -n "$first_ip" ]; then
    local ping_cmd2="ping"
    if [[ "$first_ip" =~ : ]]; then
      if command -v ping6 &>/dev/null; then
        ping_cmd2="ping6"
      else
        ping_cmd2="ping -6"
      fi
    fi
    local ping_out
    ping_out=$($ping_cmd2 -c4 -W1 "$first_ip" 2>/dev/null)
    if [ $? -eq 0 ] && echo "$ping_out" | grep -q "0% packet loss"; then
      local avg_rtt
      avg_rtt=$(echo "$ping_out" | awk -F'/' '/rtt/ {print $5}')
      sni_positives+=("Ping (SNI): средний RTT ${avg_rtt} ms")
    else
      sni_negatives+=("Ping (SNI): нет ответа или потери")
    fi
  else
    sni_negatives+=("Ping (SNI): нет IP")
  fi

  # --- 3) TLS 1.3 + X25519 (порт фиксирован 443 для SNI) ---
  local sni_tls_out
  sni_tls_out=$(echo | timeout 5 openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" -tls1_3 2>&1)
  local sni_tls13="No"
  if echo "$sni_tls_out" | grep -q "Protocol  : TLSv1.3"; then
    sni_tls13="Yes"
  fi
  if [ "$sni_tls13" = "Yes" ]; then
    sni_positives+=("TLS 1.3 (SNI): поддерживается")
    if echo "$sni_tls_out" | grep -q "Server Temp Key: X25519"; then
      sni_positives+=("X25519 (SNI): поддерживается")
    else
      local x25519_test
      x25519_test=$(echo | timeout 5 openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" -tls1_3 -curves X25519 2>&1)
      if echo "$x25519_test" | grep -q "Protocol  : TLSv1.3"; then
        sni_positives+=("X25519 (SNI): поддерживается")
      else
        sni_negatives+=("X25519 (SNI): не поддерживается")
      fi
    fi
  else
    sni_negatives+=("TLS 1.3 (SNI): не поддерживается")
  fi

  # --- 4) HTTP/2, HTTP/3, редирект (SNI) ---
  local sni_curl
  sni_curl=$(curl -sIk --max-time 8 "https://${DOMAIN}")
  if [ -z "$sni_curl" ]; then
    sni_negatives+=("HTTP (SNI): нет ответа")
  else
    local line1
    line1=$(echo "$sni_curl" | head -n1)
    if echo "$line1" | grep -q "HTTP/2"; then
      sni_positives+=("HTTP/2 (SNI): поддерживается")
    else
      sni_negatives+=("HTTP/2 (SNI): не поддерживается")
    fi

    if echo "$sni_curl" | grep -qi "^alt-svc: .*h3"; then
      sni_positives+=("HTTP/3 (SNI): поддерживается")
    else
      sni_negatives+=("HTTP/3 (SNI): не поддерживается")
    fi

    local sc
    sc=$(echo "$line1" | awk '{print $2}')
    if [[ "$sc" =~ ^3[0-9]{2}$ ]]; then
      local loc
      loc=$(echo "$sni_curl" | grep -i '^Location:' | sed 's/Location: //i')
      if [ -n "$loc" ]; then
        sni_negatives+=("Редирект (SNI): есть -> $loc")
      else
        sni_negatives+=("Редирект (SNI): есть")
      fi
    else
      sni_positives+=("Редиректы (SNI): отсутствуют")
    fi
  fi

  # --- 5) CDN (SNI) ---
  local combined_sni
  combined_sni="$sni_curl"$'\n'"$sni_tls_out"

  if [ -n "$first_ip" ]; then
    local sni_whois
    sni_whois=$(timeout 5 whois "$first_ip" 2>/dev/null || true)
    combined_sni+=$'\n'"$sni_whois"
    local sni_ipinfo
    sni_ipinfo=$(curl -s --max-time 5 "https://ipinfo.io/$first_ip/org" || true)
    combined_sni+=$'\n'"$sni_ipinfo"
  fi

  local sni_lc
  sni_lc=$(echo "$combined_sni" | tr '[:upper:]' '[:lower:]')

  local cdns_list=(
    "\\bcloudflare\\b" "\\bakamai\\b" "\\bfastly\\b" "\\bincapsula\\b" "\\bimperva\\b"
    "\\bsucuri\\b" "\\bstackpath\\b" "\\bcdn77\\b" "\\bedgecast\\b" "\\bkeycdn\\b"
    "\\bazure\\b" "\\btencent\\b" "\\balibaba\\b" "\\baliyun\\b" "bunnycdn" "\\barvan\\b"
    "\\bg-core\\b" "\\bmail\\.ru\\b" "\\bmailru\\b" "\\bvk\\.com\\b" "\\bvk\\b"
    "\\blimelight\\b" "\\blumen\\b" "\\blevel[[:space:]]?3\\b" "\\bcenturylink\\b"
    "\\bcloudfront\\b" "\\bverizon\\b"
  )

  local cdn_found="No"
  local cdn_name=""
  for pattern in "${cdns_list[@]}"; do
    if echo "$sni_lc" | grep -Eq "$pattern"; then
      cdn_found="Yes"
      case "$pattern" in
        *cloudflare*) cdn_name="Cloudflare" ;;
        *akamai*) cdn_name="Akamai" ;;
        *fastly*) cdn_name="Fastly" ;;
        *incapsula*|*imperva*) cdn_name="Imperva Incapsula" ;;
        *sucuri*) cdn_name="Sucuri" ;;
        *stackpath*) cdn_name="StackPath" ;;
        *cdn77*) cdn_name="CDN77" ;;
        *edgecast*|*verizon*) cdn_name="Verizon EdgeCast" ;;
        *keycdn*) cdn_name="KeyCDN" ;;
        *azure*) cdn_name="Azure CDN" ;;
        *tencent*) cdn_name="Tencent CDN" ;;
        *alibaba*|*aliyun*) cdn_name="Alibaba CDN" ;;
        *bunnycdn*) cdn_name="BunnyCDN" ;;
        *arvan*) cdn_name="ArvanCloud" ;;
        *g-core*) cdn_name="G-Core Labs" ;;
        *mail\.ru*|*mailru*) cdn_name="Mail.ru (VK) CDN" ;;
        *vk\.com*) cdn_name="VK CDN" ;;
        *vk*) cdn_name="VK CDN" ;;
        *limelight*) cdn_name="Limelight" ;;
        *lumen*) cdn_name="Lumen (CenturyLink)" ;;
        *level[[:space:]]?3*) cdn_name="Level3/CenturyLink" ;;
        *centurylink*) cdn_name="CenturyLink" ;;
        *cloudfront*) cdn_name="Amazon CloudFront" ;;
        *) cdn_name="$pattern" ;;
      esac
      break
    fi
  done

  if [ "$cdn_found" = "Yes" ]; then
    sni_negatives+=("CDN (SNI): обнаружен ($cdn_name)")
  else
    sni_positives+=("CDN (SNI): не обнаружен")
  fi

  # --- 6) Формируем вердикт SNI (SNI_FINAL)
  # Игнорируем HTTP/3, редирект, X25519, пинг – для финала SNI ориентируемся только на:
  #    TLS1.3 == Yes AND HTTP/2 == Yes AND CDN == No
  local sni_tls_ok="No"
  local sni_http2_ok="No"
  local sni_cdn="No"

  # Ищем: "TLS 1.3 (SNI): поддерживается"
  #       "HTTP/2 (SNI): поддерживается"
  #       "CDN (SNI): не обнаружен"
  # Можно пройти по sni_positives/negatives
  for p in "${sni_positives[@]}"; do
    [[ "$p" == *"TLS 1.3 (SNI): поддерживается"* ]] && sni_tls_ok="Yes"
    [[ "$p" == *"HTTP/2 (SNI): поддерживается"* ]] && sni_http2_ok="Yes"
    [[ "$p" == *"CDN (SNI): не обнаружен"* ]] && sni_cdn="No"
  done
  # Или проверим, не попало ли в negatives
  for n in "${sni_negatives[@]}"; do
    [[ "$n" == *"TLS 1.3 (SNI): не поддерживается"* ]] && sni_tls_ok="No"
    [[ "$n" == *"HTTP/2 (SNI): не поддерживается"* ]] && sni_http2_ok="No"
    [[ "$n" == *"CDN (SNI): обнаружен"* ]] && sni_cdn="Yes"
  done

  if [ "$sni_tls_ok" = "Yes" ] && [ "$sni_http2_ok" = "Yes" ] && [ "$sni_cdn" = "No" ]; then
    SNI_FINAL="Suitable"
  else
    SNI_FINAL="Not suitable"
  fi
}

################################################################################
# Проверка Dest
################################################################################
dest_positives=()
dest_negatives=()

function check_dest() {
  echo -e "\n${CYAN}===== DEST-ПРОВЕРКА ДЛЯ $DOMAIN:$PORT =====${RESET}"

  # Разрешим IP
  local resolved_ip=""
  if command -v getent >/dev/null 2>&1; then
    resolved_ip="$(getent hosts "$DOMAIN" | awk '{print $1; exit}')"
  fi
  if [ -z "$resolved_ip" ]; then
    if command -v dig >/dev/null 2>&1; then
      resolved_ip="$(dig +short "$DOMAIN" | head -n1)"
    elif command -v host >/dev/null 2>&1; then
      resolved_ip="$(host -t A "$DOMAIN" 2>/dev/null | awk '/has address/ {print $NF; exit}')"
      if [ -z "$resolved_ip" ]; then
        resolved_ip="$(host -t AAAA "$DOMAIN" 2>/dev/null | awk '/has IPv6 address/ {print $NF; exit}')"
      fi
    fi
  fi
  if [ -z "$resolved_ip" ]; then
    # fallback ping
    resolved_ip="$(ping -c1 -W1 "$DOMAIN" 2>/dev/null | head -n1 | awk -F'[()]' '{print $2}')"
  fi

  if [ -n "$resolved_ip" ]; then
    dest_positives+=("Resolved IP: $resolved_ip")
  else
    dest_negatives+=("Unable to resolve domain $DOMAIN")
    DEST_FINAL="Not suitable"
    return
  fi

  # Пинг
  local ping_cmd2="ping"
  if [[ "$resolved_ip" =~ : ]]; then
    if command -v ping6 &>/dev/null; then
      ping_cmd2="ping6"
    else
      ping_cmd2="ping -6"
    fi
  fi
  local ping_out2
  ping_out2=$($ping_cmd2 -c4 -W2 "$resolved_ip" 2>/dev/null)
  if [ -n "$ping_out2" ]; then
    if echo "$ping_out2" | grep -q "0 received"; then
      dest_negatives+=("Ping: No response (100% loss)")
    else
      local avgp
      avgp=$(echo "$ping_out2" | tail -1 | awk -F'/' '{print $5}')
      dest_positives+=("Ping: ~${avgp} ms")
    fi
  else
    dest_negatives+=("Ping: no output")
  fi

  # TLS1.3
  local tls13_supported="No"
  if echo | openssl s_client -connect "${DOMAIN}:${PORT}" -tls1_3 -brief 2>/dev/null | grep -q "TLSv1.3"; then
    tls13_supported="Yes"
    dest_positives+=("TLS 1.3: Yes")
  else
    dest_negatives+=("TLS 1.3: No")
  fi

  # X25519
  if [ "$tls13_supported" = "Yes" ]; then
    local x2="No"
    if echo | openssl s_client -connect "${DOMAIN}:${PORT}" -tls1_3 -curves X25519 -brief 2>/dev/null | grep -q "TLSv1.3"; then
      x2="Yes"
    fi
    dest_positives+=("TLS 1.3 Key Exchange (X25519): $x2")
  else
    dest_negatives+=("TLS 1.3 Key Exchange: N/A")
  fi

  # HTTP/2, HTTP/3, Redirect
  local dest_curl
  dest_curl=$(curl -s -I --connect-timeout 5 --max-time 10 "https://${DOMAIN}:${PORT}")
  local http2_ok="No"
  local http3_ok="No"
  local redirect="No"

  if [ -z "$dest_curl" ]; then
    dest_negatives+=("HTTP request: no response")
  else
    if echo "$dest_curl" | head -1 | grep -q '^HTTP/2'; then
      http2_ok="Yes"
      dest_positives+=("HTTP/2: Yes")
    else
      dest_negatives+=("HTTP/2: No")
    fi
    if echo "$dest_curl" | grep -qi 'alt-svc: .*h3'; then
      http3_ok="Yes"
      dest_positives+=("HTTP/3: Yes")
    else
      dest_negatives+=("HTTP/3: No")
    fi
    if echo "$dest_curl" | head -1 | grep -qE 'HTTP/.* 30[1-7]'; then
      redirect="Yes"
      local loc
      loc=$(echo "$dest_curl" | awk 'tolower($1)=="location:" { $1=""; print substr($0,2)}' | tr -d '\r')
      [ -z "$loc" ] && loc="(No Location header)"
      dest_negatives+=("Redirect: Yes -> $loc")
    else
      dest_positives+=("Redirect: No")
    fi
  fi

  # CDN
  local combined_dest="$dest_curl"
  local ci
  ci=$(echo | openssl s_client -connect "${DOMAIN}:${PORT}" -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -issuer -subject 2>/dev/null)
  combined_dest+=$'\n'"$ci"
  if command -v curl >/dev/null 2>&1; then
    local org2
    org2=$(curl -s --connect-timeout 5 --max-time 8 "https://ipinfo.io/${resolved_ip}/org" || true)
    combined_dest+=$'\n'"$org2"
  fi
  local dest_lc
  dest_lc=$(echo "$combined_dest" | tr '[:upper:]' '[:lower:]')

  local cdn_found="No"
  local cdn_name=""
  for pattern in "${cdns_list[@]}"; do
    if echo "$dest_lc" | grep -Eq "$pattern"; then
      cdn_found="Yes"
      case "$pattern" in
        *cloudflare*) cdn_name="Cloudflare" ;;
        *akamai*) cdn_name="Akamai" ;;
        *fastly*) cdn_name="Fastly" ;;
        *incapsula*|*imperva*) cdn_name="Imperva Incapsula" ;;
        *sucuri*) cdn_name="Sucuri" ;;
        *stackpath*) cdn_name="StackPath" ;;
        *cdn77*) cdn_name="CDN77" ;;
        *edgecast*|*verizon*) cdn_name="Verizon EdgeCast" ;;
        *keycdn*) cdn_name="KeyCDN" ;;
        *azure*) cdn_name="Azure CDN" ;;
        *tencent*) cdn_name="Tencent CDN" ;;
        *alibaba*|*aliyun*) cdn_name="Alibaba CDN" ;;
        *bunnycdn*) cdn_name="BunnyCDN" ;;
        *arvan*) cdn_name="ArvanCloud" ;;
        *g-core*) cdn_name="G-Core Labs" ;;
        *mail\.ru*|*mailru*) cdn_name="Mail.ru (VK) CDN" ;;
        *vk\.com*) cdn_name="VK CDN" ;;
        *vk*) cdn_name="VK CDN" ;;
        *limelight*) cdn_name="Limelight" ;;
        *lumen*) cdn_name="Lumen (CenturyLink)" ;;
        *level[[:space:]]?3*) cdn_name="Level3/CenturyLink" ;;
        *centurylink*) cdn_name="CenturyLink" ;;
        *cloudfront*) cdn_name="Amazon CloudFront" ;;
        *) cdn_name="$pattern" ;;
      esac
      break
    fi
  done

  if [ "$cdn_found" = "Yes" ]; then
    dest_negatives+=("CDN: $cdn_name")
  else
    dest_positives+=("CDN: No")
  fi

  # Итог по Dest — DEST_FINAL
  # Условие: TLS1.3 = Yes, HTTP/2 = Yes, CDN = No => Suitable
  # Всё остальное => Not suitable
  local final="Suitable"
  if [ "$tls13_supported" != "Yes" ] || [ "$http2_ok" != "Yes" ] || [ "$cdn_found" = "Yes" ]; then
    final="Not suitable"
  fi
  DEST_FINAL="$final"
  if [ "$DEST_FINAL" = "Suitable" ]; then
    echo -e "Final Verdict (dest): ${GREEN}Suitable${RESET} for Xray Reality"
  else
    echo -e "Final Verdict (dest): ${RED}Not suitable${RESET} for Xray Reality"
  fi
}

################################################################################
# 1) Выполняем проверку SNI
################################################################################
check_sni

################################################################################
# Формируем вывод для SNI
################################################################################
echo -e "\n${CYAN}===== РЕЗУЛЬТАТЫ ПРОВЕРКИ ДОМЕНА ДЛЯ SNI =====${RESET}"

if [ ${#sni_positives[@]} -eq 0 ]; then
  echo -e "${GREEN}Положительные аспекты: нет${RESET}"
else
  echo -e "${GREEN}Положительные аспекты:${RESET}"
  for p in "${sni_positives[@]}"; do
    echo -e "  - $p"
  done
fi

if [ ${#sni_negatives[@]} -eq 0 ]; then
  echo -e "${GREEN}\nНедостатки: нет${RESET}"
else
  echo -e "${RED}\nНедостатки:${RESET}"
  for n in "${sni_negatives[@]}"; do
    echo -e "  - $n"
  done
fi

# Печатаем SNI итог
if [ "$SNI_FINAL" = "Suitable" ]; then
  echo -e "\nSNI Final Verdict: ${GREEN}Suitable${RESET}"
else
  echo -e "\nSNI Final Verdict: ${RED}Not suitable${RESET}"
fi

# Подсказка
echo -e "\n${CYAN}===== ВОЗМОЖНЫЕ ПУБЛИЧНЫЕ SNI (без Microsoft/Amazon/WhatsApp) =====${RESET}"
echo -e "${GREEN}- dl.google.com${RESET} (TLS 1.3, HTTP/2/3)"
echo -e "${GREEN}- gateway.icloud.com${RESET} (Apple iCloud)"
echo -e "${GREEN}- www.dropbox.com${RESET} (Dropbox)"
echo -e "${GREEN}- www.wikipedia.org${RESET} (Wikipedia)"

################################################################################
# 2) Выполняем проверку Dest
################################################################################
check_dest

################################################################################
# Формируем вывод по Dest
################################################################################
echo -e "\n${CYAN}===== ИТОГИ DEST-ПРОВЕРКИ =====${RESET}"

if [ ${#dest_positives[@]} -eq 0 ]; then
  echo -e "${GREEN}Положительные аспекты: нет${RESET}"
else
  echo -e "${GREEN}Положительные аспекты:${RESET}"
  for p in "${dest_positives[@]}"; do
    echo -e "  - $p"
  done
fi

if [ ${#dest_negatives[@]} -eq 0 ]; then
  echo -e "${GREEN}\nНедостатки: нет${RESET}"
else
  echo -e "${RED}\nНедостатки:${RESET}"
  for n in "${dest_negatives[@]}"; do
    echo -e "  - $n"
  done
fi

if [ "$DEST_FINAL" = "Suitable" ]; then
  echo -e "\nDest Final Verdict: ${GREEN}Suitable${RESET}"
else
  echo -e "\nDest Final Verdict: ${RED}Not suitable${RESET}"
fi

################################################################################
# 3) Общий итог (SNI_FINAL и DEST_FINAL)
#   - Если и SNI_FINAL = Suitable, и DEST_FINAL = Suitable => Overall = Suitable
#   - Иначе Not suitable
################################################################################
echo -e "\n${CYAN}===== OVERALL VERDICT (SNI + DEST) =====${RESET}"

if [ "$SNI_FINAL" = "Suitable" ] && [ "$DEST_FINAL" = "Suitable" ]; then
  echo -e "Overall: ${BG_GREEN} SUITABLE ${RESET}"
else
  echo -e "Overall: ${BG_RED} NOT SUITABLE ${RESET}"
fi

exit 0
