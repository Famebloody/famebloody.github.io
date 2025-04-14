#!/usr/bin/env bash
# Usage: ./reality_check.sh <domain[:port]>
#
# Делает единый DNS резолв (A/AAAA). Сохранённый IP используется и для SNI, и для Dest.
# Так CDN, пинг, заголовки, whois — будут одинаковыми.
#
# Логика Suitability по Xray Reality:
#   - TLS 1.3 = Yes
#   - HTTP/2 = Yes
#   - CDN = No
# (HTTP/3, X25519, редиректы, ping и т.п. выводим, но не влияют на verdict.)


GREEN="\033[32m"
RED="\033[31m"
CYAN="\033[36m"
YELLOW="\033[33m"
BG_GREEN="\033[30;42m"
BG_RED="\033[97;41m"
RESET="\033[0m"

if [ -z "$1" ]; then
  echo -e "${RED}Usage: $0 <domain[:port]>${RESET}"
  exit 1
fi

# Разбор domain[:port]
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

##############################################################################
# Определение пакетного менеджера
##############################################################################
function detect_package_manager() {
  if [ -f /etc/redhat-release ] || grep -iq 'centos' /etc/os-release 2>/dev/null; then
    PKG_MGR="yum"
  else
    PKG_MGR="apt-get"
  fi
}
detect_package_manager

##############################################################################
# Проверка/установка утилит
##############################################################################
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
      echo -e "${RED}Failed to install '$cmd'. Please install manually.${RESET}"
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

##############################################################################
# 1) Единый DNS резолв: A и AAAA
##############################################################################
dns_v4=$(dig +short A "$DOMAIN" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
dns_v6=$(dig +short AAAA "$DOMAIN" | grep -E '^[0-9A-Fa-f:]+$')

# Выберем первый IP для всех дальнейших проверок (как SNI, так и dest).
main_ip=""
if [ -n "$dns_v4" ]; then
  main_ip=$(echo "$dns_v4" | head -n1)
elif [ -n "$dns_v6" ]; then
  main_ip=$(echo "$dns_v6" | head -n1)
fi

##############################################################################
# 2) Проверка DNS
##############################################################################
DNS_P=()  # positives
DNS_N=()  # negatives

if [ -z "$dns_v4" ] && [ -z "$dns_v6" ]; then
  DNS_N+=("DNS: домен не разрешается")
else
  local_v4count=$(echo "$dns_v4" | sed '/^$/d' | wc -l)
  local_v6count=$(echo "$dns_v6" | sed '/^$/d' | wc -l)
  DNS_P+=("DNS: $local_v4count A, $local_v6count AAAA")

  # Проверка приватных
  for ip in $dns_v4 $dns_v6; do
    if [[ "$ip" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^127\.|^169\.254\. ]]; then
      DNS_N+=("DNS: приватный IPv4 $ip")
    elif [[ "$ip" =~ ^fc00:|^fd00:|^fe80:|^::1$ ]]; then
      DNS_N+=("DNS: приватный IPv6 $ip")
    fi
  done
fi

##############################################################################
# 3) Пинг по main_ip
##############################################################################
PING_P=()
PING_N=()

if [ -z "$main_ip" ]; then
  PING_N+=("Ping: нет IP для проверки")
else
  ping_cmd="ping"
  if [[ "$main_ip" =~ : ]]; then
    if command -v ping6 &>/dev/null; then
      ping_cmd="ping6"
    else
      ping_cmd="ping -6"
    fi
  fi
  ping_out=$($ping_cmd -c4 -W1 "$main_ip" 2>/dev/null)
  if [ $? -eq 0 ] && echo "$ping_out" | grep -q "0% packet loss"; then
    avg_rtt=$(echo "$ping_out" | awk -F'/' '/rtt/ {print $5}')
    PING_P+=("Ping: ~${avg_rtt} ms")
  else
    PING_N+=("Ping: нет ответа или потери")
  fi
fi

##############################################################################
# 4) Проверка TLS 1.3, X25519
##############################################################################
TLS_P=()
TLS_N=()

if [ -n "$main_ip" ]; then
  tls_out=$(echo | timeout 5 openssl s_client -connect "$main_ip:$PORT" -servername "$DOMAIN" -tls1_3 2>&1)
  local tls13="No"
  if echo "$tls_out" | grep -q "Protocol  : TLSv1.3"; then
    tls13="Yes"
  fi
  if [ "$tls13" = "Yes" ]; then
    TLS_P+=("TLS 1.3: Yes")
    # X25519
    if echo "$tls_out" | grep -q "Server Temp Key: X25519"; then
      TLS_P+=("X25519: Yes")
    else
      # Пробуем явно curves X25519
      x2=$(echo | timeout 5 openssl s_client -connect "$main_ip:$PORT" -servername "$DOMAIN" -tls1_3 -curves X25519 2>&1)
      if echo "$x2" | grep -q "Protocol  : TLSv1.3"; then
        TLS_P+=("X25519: Yes")
      else
        TLS_N+=("X25519: No")
      fi
    fi
  else
    TLS_N+=("TLS 1.3: No")
  fi
else
  TLS_N+=("TLS: нет IP => не проверено")
fi

##############################################################################
# 5) HTTP/2, HTTP/3, Redirect
##############################################################################
HTTP_P=()
HTTP_N=()

if [ -n "$main_ip" ]; then
  # Указываем curl --resolve, чтобы гарантированно обратиться к main_ip
  # (SNI = $DOMAIN), порт = $PORT
  # => это общий чек для SNI + dest
  curl_out=$(curl -sIk --max-time 8 --resolve "${DOMAIN}:${PORT}:${main_ip}" "https://${DOMAIN}:${PORT}")
  if [ -z "$curl_out" ]; then
    HTTP_N+=("HTTP: нет ответа")
  else
    local line1
    line1=$(echo "$curl_out" | head -n1)
    if echo "$line1" | grep -q "HTTP/2"; then
      HTTP_P+=("HTTP/2: Yes")
    else
      HTTP_N+=("HTTP/2: No")
    fi

    if echo "$curl_out" | grep -qi "^alt-svc: .*h3"; then
      HTTP_P+=("HTTP/3: Yes")
    else
      HTTP_N+=("HTTP/3: No")
    fi

    local sc
    sc=$(echo "$line1" | awk '{print $2}')
    if [[ "$sc" =~ ^3[0-9]{2}$ ]]; then
      # редирект
      loc=$(echo "$curl_out" | grep -i '^Location:' | sed 's/Location: //i')
      if [ -z "$loc" ]; then
        loc="(no Location header?)"
      fi
      HTTP_N+=("Redirect: Yes -> $loc")
    else
      HTTP_P+=("Redirect: No")
    fi
  fi
else
  HTTP_N+=("HTTP: нет IP")
fi

##############################################################################
# 6) CDN
##############################################################################
CDN_P=()
CDN_N=()

CDN_DETECTED="No"
CDN_NAME=""
CDNS=(
  "\\bcloudflare\\b" "\\bakamai\\b" "\\bfastly\\b" "\\bincapsula\\b" "\\bimperva\\b"
  "\\bsucuri\\b" "\\bstackpath\\b" "\\bcdn77\\b" "\\bedgecast\\b" "\\bkeycdn\\b"
  "\\bazure\\b" "\\btencent\\b" "\\balibaba\\b" "\\baliyun\\b" "bunnycdn" "\\barvan\\b"
  "\\bg-core\\b" "\\bmail\\.ru\\b" "\\bmailru\\b" "\\bvk\\.com\\b" "\\bvk\\b"
  "\\blimelight\\b" "\\blumen\\b" "\\blevel[[:space:]]?3\\b" "\\bcenturylink\\b"
  "\\bcloudfront\\b" "\\bverizon\\b"
)

COMBINED_INFO=""

if [ -n "$main_ip" ]; then
  # Собираем SSL/HTTP
  COMBINED_INFO+="$curl_out"
  COMBINED_INFO+=$'\n'"$tls_out"

  # whois
  whois_out=$(timeout 5 whois "$main_ip" 2>/dev/null || true)
  COMBINED_INFO+=$'\n'"$whois_out"
  # ipinfo
  ipinfo_org=$(curl -s --max-time 5 "https://ipinfo.io/$main_ip/org" || true)
  COMBINED_INFO+=$'\n'"$ipinfo_org"

  COMBINED_LC=$(echo "$COMBINED_INFO" | tr '[:upper:]' '[:lower:]')

  for pattern in "${CDNS[@]}"; do
    if echo "$COMBINED_LC" | grep -Eq "$pattern"; then
      CDN_DETECTED="Yes"
      case "$pattern" in
        *cloudflare*) CDN_NAME="Cloudflare" ;;
        *akamai*) CDN_NAME="Akamai" ;;
        *fastly*) CDN_NAME="Fastly" ;;
        *incapsula*|*imperva*) CDN_NAME="Imperva Incapsula" ;;
        *sucuri*) CDN_NAME="Sucuri" ;;
        *stackpath*) CDN_NAME="StackPath" ;;
        *cdn77*) CDN_NAME="CDN77" ;;
        *edgecast*|*verizon*) CDN_NAME="Verizon EdgeCast" ;;
        *keycdn*) CDN_NAME="KeyCDN" ;;
        *azure*) CDN_NAME="Azure CDN" ;;
        *tencent*) CDN_NAME="Tencent CDN" ;;
        *alibaba*|*aliyun*) CDN_NAME="Alibaba CDN" ;;
        *bunnycdn*) CDN_NAME="BunnyCDN" ;;
        *arvan*) CDN_NAME="ArvanCloud" ;;
        *g-core*) CDN_NAME="G-Core Labs" ;;
        *mail\.ru*|*mailru*) CDN_NAME="Mail.ru (VK) CDN" ;;
        *vk\.com*) CDN_NAME="VK CDN" ;;
        *vk*) CDN_NAME="VK CDN" ;;
        *limelight*) CDN_NAME="Limelight" ;;
        *lumen*) CDN_NAME="Lumen (CenturyLink)" ;;
        *level[[:space:]]?3*) CDN_NAME="Level3/CenturyLink" ;;
        *centurylink*) CDN_NAME="CenturyLink" ;;
        *cloudfront*) CDN_NAME="Amazon CloudFront" ;;
        *) CDN_NAME="$pattern" ;;
      esac
      break
    fi
  done

  if [ "$CDN_DETECTED" = "Yes" ]; then
    CDN_N+=("CDN: обнаружен ($CDN_NAME)")
  else
    CDN_P+=("CDN: нет")
  fi
else
  CDN_N+=("CDN: нет IP => не проверено")
fi

##############################################################################
# Вывод всех результатов
##############################################################################
echo -e "\n${CYAN}===== DNS =====${RESET}"
if [ ${#DNS_P[@]} -eq 0 ]; then
  echo -e "${GREEN}Нет положительных DNS-аспектов${RESET}"
else
  for p in "${DNS_P[@]}"; do
    echo -e "${GREEN}+ $p${RESET}"
  done
fi
if [ ${#DNS_N[@]} -gt 0 ]; then
  for n in "${DNS_N[@]}"; do
    echo -e "${RED}- $n${RESET}"
  done
fi

echo -e "\n${CYAN}===== PING =====${RESET}"
if [ ${#PING_P[@]} -eq 0 ] && [ ${#PING_N[@]} -eq 0 ]; then
  echo "No results"
else
  for p in "${PING_P[@]}"; do
    echo -e "${GREEN}+ $p${RESET}"
  done
  for n in "${PING_N[@]}"; do
    echo -e "${RED}- $n${RESET}"
  done
fi

echo -e "\n${CYAN}===== TLS =====${RESET}"
for p in "${TLS_P[@]}"; do
  echo -e "${GREEN}+ $p${RESET}"
done
for n in "${TLS_N[@]}"; do
  echo -e "${RED}- $n${RESET}"
done

echo -e "\n${CYAN}===== HTTP =====${RESET}"
for p in "${HTTP_P[@]}"; do
  echo -e "${GREEN}+ $p${RESET}"
done
for n in "${HTTP_N[@]}"; do
  echo -e "${RED}- $n${RESET}"
done

echo -e "\n${CYAN}===== CDN =====${RESET}"
for p in "${CDN_P[@]}"; do
  echo -e "${GREEN}+ $p${RESET}"
done
for n in "${CDN_N[@]}"; do
  echo -e "${RED}- $n${RESET}"
done

##############################################################################
# Финальный verdict: TLS1.3=Yes, HTTP/2=Yes, CDN=No => Suitable
##############################################################################
function check_value() {
  # ищем в positives/nаgatives
  # param: "TLS 1.3: Yes" / "HTTP/2: Yes" / "CDN: нет"
  local needed="$1"
  if echo "${TLS_P[@]} ${HTTP_P[@]} ${CDN_P[@]}" | grep -q "$needed"; then
    return 0
  fi
  return 1
}

OVERALL="Suitable"
if ! check_value "TLS 1.3: Yes"; then
  OVERALL="Not suitable"
fi
if ! check_value "HTTP/2: Yes"; then
  OVERALL="Not suitable"
fi

if echo "${CDN_N[@]}" | grep -q "CDN: обнаружен"; then
  OVERALL="Not suitable"
fi

echo -e "\n${CYAN}===== OVERALL VERDICT =====${RESET}"
if [ "$OVERALL" = "Suitable" ]; then
  echo -e "Overall: ${BG_GREEN} SUITABLE ${RESET}"
else
  echo -e "Overall: ${BG_RED} NOT SUITABLE ${RESET}"
fi

exit 0
