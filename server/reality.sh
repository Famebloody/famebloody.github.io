#!/usr/bin/env bash
# Usage: ./check_sni.sh <domain[:port]>
#
# Скрипт производит комплексную оценку домена для Xray Reality:
#  1) Проверка домена на годность в качестве SNI (TLS 1.3, X25519, HTTP/2, HTTP/3, редиректы, CDN, пинг и т.д.).
#  2) (В конце) Проверка этого же домена:порта (или домена:443 по умолчанию) на годность в качестве "dest" для Reality:
#     - Пинг, TLS1.3, HTTP/2, отсутствие CDN и т.д.
#
# Работает на CentOS/Debian/Ubuntu (последние версии).
# При отсутствии нужных утилит (openssl, curl, dig, whois, ping) — устанавливает их
# с минимальным выводом (только «Installing ...», «installed successfully»).
#
# Пример:
#   ./check_sni.sh example.com
#   ./check_sni.sh example.com:443
#
# Автор: ChatGPT (доработан по запросам)

GREEN="\033[32m"
RED="\033[31m"
CYAN="\033[36m"
YELLOW="\033[33m"
RESET="\033[0m"

#########################################################
# 0) Определение домена и порта (если есть)
#########################################################
if [ -z "$1" ]; then
  echo -e "${RED}Usage: $0 <domain[:port]>${RESET}"
  exit 1
fi

INPUT="$1"
if [[ "$INPUT" == *:* ]]; then
  DOMAIN="${INPUT%%:*}"
  PORT="${INPUT##*:}"
else
  DOMAIN="$INPUT"
  PORT="443"
fi

# Проверка: порт должен быть числовым
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
  echo -e "${RED}Error: Port must be numeric.${RESET}"
  exit 1
fi

positives=()
negatives=()

#########################################################
# Определение пакетного менеджера (CentOS/Yum vs Debian/Apt)
#########################################################
function detect_package_manager() {
  if [ -f /etc/redhat-release ] || grep -iq 'centos' /etc/os-release 2>/dev/null; then
    PKG_MGR="yum"
  else
    PKG_MGR="apt-get"
  fi
}

detect_package_manager

#########################################################
# Установка пакетов по необходимости (минимальный вывод)
#########################################################
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
      echo -e "${RED}Failed to install '$cmd'. Please install it manually.${RESET}"
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

#########################################################
# 1) Проверка DNS (для SNI-анализа)
#########################################################
dns_ips_v4=$(dig +short A "$DOMAIN" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
dns_ips_v6=$(dig +short AAAA "$DOMAIN" | grep -E '^[0-9A-Fa-f:]+$')

if [ -z "$dns_ips_v4" ] && [ -z "$dns_ips_v6" ]; then
  negatives+=("DNS: домен не разрешается")
else
  local_v4count=$(echo "$dns_ips_v4" | sed '/^$/d' | wc -l)
  local_v6count=$(echo "$dns_ips_v6" | sed '/^$/d' | wc -l)
  positives+=("DNS: найдено $local_v4count A-записей, $local_v6count AAAA-записей")

  # Проверка приватных IP
  for ip in $dns_ips_v4 $dns_ips_v6; do
    if [[ "$ip" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^127\.|^169\.254\. ]]; then
      negatives+=("DNS: приватный IPv4 ($ip)")
    elif [[ "$ip" =~ ^fc00:|^fd00:|^fe80:|^::1$ ]]; then
      negatives+=("DNS: приватный IPv6 ($ip)")
    fi
  done
fi

#########################################################
# 2) Пинг (только по первому IP, для SNI-анализа)
#########################################################
first_ip=""
if [ -n "$dns_ips_v4" ]; then
  first_ip=$(echo "$dns_ips_v4" | head -n1)
elif [ -n "$dns_ips_v6" ]; then
  first_ip=$(echo "$dns_ips_v6" | head -n1)
fi

if [ -n "$first_ip" ]; then
  if [[ "$first_ip" =~ : ]]; then
    # IPv6
    if command -v ping6 &>/dev/null; then
      ping_cmd="ping6"
    else
      ping_cmd="ping -6"
    fi
  else
    ping_cmd="ping"
  fi

  ping_out=$($ping_cmd -c4 -W1 "$first_ip" 2>/dev/null)
  if [ $? -eq 0 ]; then
    if echo "$ping_out" | grep -q " 0% packet loss"; then
      avg_rtt=$(echo "$ping_out" | awk -F'/' '/rtt/ {print $5}')
      positives+=("Ping (для SNI): средний RTT ${avg_rtt} ms")
    else
      negatives+=("Ping: потери пакетов (не все ответы)")
    fi
  else
    negatives+=("Ping: узел не отвечает")
  fi
else
  negatives+=("Ping: нет IP для проверки")
fi

#########################################################
# 3) Проверка TLS 1.3 и X25519 (порт всегда 443 для SNI)
#########################################################
openssl_out=$(echo | timeout 5 openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" -tls1_3 2>&1)
if echo "$openssl_out" | grep -q "Protocol  : TLSv1.3"; then
  positives+=("TLS 1.3 (SNI): поддерживается")
  if echo "$openssl_out" | grep -q "Server Temp Key: X25519"; then
    positives+=("X25519 (SNI): поддерживается")
  else
    x25519_out=$(echo | timeout 5 openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" -tls1_3 -curves X25519 2>&1)
    if echo "$x25519_out" | grep -q "Protocol  : TLSv1.3"; then
      positives+=("X25519 (SNI): поддерживается")
    else
      negatives+=("X25519 (SNI): не поддерживается")
    fi
  fi
else
  negatives+=("TLS 1.3 (SNI): не поддерживается")
fi

#########################################################
# 4) Проверка HTTP/2, HTTP/3, редиректы (для SNI)
#########################################################
curl_headers=$(curl -sIk --max-time 8 "https://${DOMAIN}")
if [ -z "$curl_headers" ]; then
  negatives+=("HTTP: нет ответа (timeout/ошибка)")
else
  first_line=$(echo "$curl_headers" | head -n1)
  if echo "$first_line" | grep -q "HTTP/2"; then
    positives+=("HTTP/2 (SNI): поддерживается")
  else
    negatives+=("HTTP/2 (SNI): не поддерживается")
  fi

  if echo "$curl_headers" | grep -qi "^alt-svc: .*h3"; then
    positives+=("HTTP/3 (SNI): поддерживается")
  else
    negatives+=("HTTP/3 (SNI): не поддерживается")
  fi

  # Редирект
  status_code=$(echo "$first_line" | awk '{print $2}')
  if [[ "$status_code" =~ ^3[0-9]{2}$ ]]; then
    loc=$(echo "$curl_headers" | grep -i '^Location:' | sed 's/Location: //i')
    if [ -n "$loc" ]; then
      negatives+=("Редирект (SNI): есть -> $loc")
    else
      negatives+=("Редирект (SNI): есть")
    fi
  else
    positives+=("Редиректы (SNI): отсутствуют")
  fi
fi

#########################################################
# 5) Проверка CDN (для SNI)
#########################################################
combined_info="$curl_headers"$'\n'"$openssl_out"

if [ -n "$first_ip" ]; then
  whois_out=$(timeout 5 whois "$first_ip" 2>/dev/null || true)
  combined_info+=$'\n'"$whois_out"
  ipinfo_org=$(curl -s --max-time 5 "https://ipinfo.io/$first_ip/org" || true)
  combined_info+=$'\n'"$ipinfo_org"
fi

combined_lc=$(echo "$combined_info" | tr '[:upper:]' '[:lower:]')

cdns=(
  "\\bcloudflare\\b"
  "\\bakamai\\b"
  "\\bfastly\\b"
  "\\bincapsula\\b"
  "\\bimperva\\b"
  "\\bsucuri\\b"
  "\\bstackpath\\b"
  "\\bcdn77\\b"
  "\\bedgecast\\b"
  "\\bkeycdn\\b"
  "\\bazure\\b"
  "\\btencent\\b"
  "\\balibaba\\b"
  "\\baliyun\\b"
  "bunnycdn"
  "\\barvan\\b"
  "\\bg-core\\b"
  "\\bmail\\.ru\\b"
  "\\bmailru\\b"
  "\\bvk\\.com\\b"
  "\\bvk\\b"
  "\\blimelight\\b"
  "\\blumen\\b"
  "\\blevel[[:space:]]?3\\b"
  "\\bcenturylink\\b"
  "\\bcloudfront\\b"
  "\\bverizon\\b"
)

cdn_detected=""
cdn_name=""
for pattern in "${cdns[@]}"; do
  if echo "$combined_lc" | grep -Eq "$pattern"; then
    cdn_detected="$pattern"
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

if [ -n "$cdn_detected" ]; then
  negatives+=("CDN (SNI): обнаружен ($cdn_name)")
else
  positives+=("CDN (SNI): не обнаружен")
fi

#########################################################
# 6) Вывод результатов проверки SNI
#########################################################
echo -e "\n${CYAN}===== РЕЗУЛЬТАТЫ ПРОВЕРКИ ДОМЕНА ДЛЯ SNI =====${RESET}"
if [ ${#positives[@]} -eq 0 ]; then
  echo -e "${GREEN}Положительные аспекты: нет${RESET}"
else
  echo -e "${GREEN}Положительные аспекты:${RESET}"
  for p in "${positives[@]}"; do
    echo -e "  - $p"
  done
fi

if [ ${#negatives[@]} -eq 0 ]; then
  echo -e "${GREEN}\nНедостатки: нет${RESET}"
else
  echo -e "${RED}\nНедостатки:${RESET}"
  for n in "${negatives[@]}"; do
    echo -e "  - $n"
  done
fi

echo -e "\n${CYAN}===== ВОЗМОЖНЫЕ ПУБЛИЧНЫЕ SNI (без Microsoft/Amazon/WhatsApp) =====${RESET}"
echo -e "${GREEN}- dl.google.com${RESET} (Google Download, TLS 1.3, HTTP/2/3)"
echo -e "${GREEN}- gateway.icloud.com${RESET} (Apple iCloud, узлы в Европе)"
echo -e "${GREEN}- www.dropbox.com${RESET} (Dropbox, безопасный и популярный)"
echo -e "${GREEN}- www.wikipedia.org${RESET} (Wikipedia, нейтральный, с HTTP/2/3)"


###############################################################################
# 7) Дополнительная проверка (dest check) — та, что была во втором скрипте.
###############################################################################
function check_dest_for_reality() {
  local domain_port="$1"
  # domain:port -> host / port
  local host_name
  local port_num

  if [[ "$domain_port" == *:* ]]; then
    host_name="${domain_port%%:*}"
    port_num="${domain_port##*:}"
  else
    host_name="$domain_port"
    port_num="443"
  fi

  if ! [[ "$port_num" =~ ^[0-9]+$ ]]; then
    echo "Error: Port must be numeric."
    return
  fi

  echo -e "\n${CYAN}===== DEST-ПРОВЕРКА ДЛЯ $host_name:$port_num =====${RESET}"

  # Разрешаем IP
  resolved_ip=""
  if command -v getent >/dev/null 2>&1; then
    resolved_ip="$(getent hosts "$host_name" | awk '{ print $1; exit }')"
  fi
  if [ -z "$resolved_ip" ]; then
    if command -v dig >/dev/null 2>&1; then
      resolved_ip="$(dig +short "$host_name" | head -n1)"
    elif command -v host >/dev/null 2>&1; then
      resolved_ip="$(host -t A "$host_name" 2>/dev/null | awk '/has address/ {print $NF; exit}')"
      if [ -z "$resolved_ip" ]; then
        resolved_ip="$(host -t AAAA "$host_name" 2>/dev/null | awk '/has IPv6 address/ {print $NF; exit}')"
      fi
    fi
  fi
  if [ -z "$resolved_ip" ]; then
    # fallback ping
    resolved_ip="$(ping -c1 -W1 "$host_name" 2>/dev/null | head -n1 | awk -F'[()]' '{print $2}')"
  fi

  if [ -n "$resolved_ip" ]; then
    echo "Resolved IP: $resolved_ip"
  else
    echo "Error: Unable to resolve domain $host_name."
    return
  fi

  # Пинг
  local avg_ping="N/A"
  if [[ "$resolved_ip" == *:* ]]; then
    # IPv6
    local ping_cmd2="ping6"
    if ! command -v ping6 >/dev/null 2>&1; then
      ping_cmd2="ping -6"
    fi
    local ping_out2="$($ping_cmd2 -c4 -W2 "$resolved_ip" 2>/dev/null)"
    if [ -n "$ping_out2" ]; then
      if echo "$ping_out2" | grep -q "0 received"; then
        echo "Ping: No response (100% packet loss)"
      else
        avg_ping=$(echo "$ping_out2" | tail -1 | awk -F'/' '{print $5}')
        avg_ping=$(printf "%.0f" "${avg_ping}")
        echo "Ping: ${avg_ping} ms (average)"
      fi
    else
      echo "Ping: Unable to ping host (no output)"
    fi
  else
    # IPv4
    local ping_out2
    ping_out2="$(ping -c4 -W2 "$resolved_ip" 2>/dev/null)"
    if [ -n "$ping_out2" ]; then
      if echo "$ping_out2" | grep -q "0 received"; then
        echo "Ping: No response (100% packet loss)"
      else
        avg_ping=$(echo "$ping_out2" | tail -1 | awk -F'/' '{print $5}')
        avg_ping=$(printf "%.0f" "${avg_ping}")
        echo "Ping: ${avg_ping} ms (average)"
      fi
    else
      echo "Ping: Unable to ping host (no output)"
    fi
  fi

  # TLS1.3
  local tls13_supported="No"
  if echo | openssl s_client -connect "${host_name}:${port_num}" -tls1_3 -brief 2>/dev/null | grep -q "TLSv1.3"; then
    tls13_supported="Yes"
  fi
  echo "TLS 1.3 Supported: $tls13_supported"

  # X25519 (опционально)
  if [ "$tls13_supported" == "Yes" ]; then
    local x25519_supported="No"
    if echo | openssl s_client -connect "${host_name}:${port_num}" -tls1_3 -curves X25519 -brief 2>/dev/null | grep -q "TLSv1.3"; then
      x25519_supported="Yes"
    fi
    echo "TLS 1.3 Key Exchange (X25519): $x25519_supported"
  else
    echo "TLS 1.3 Key Exchange (X25519): N/A"
  fi

  # HTTP/2, HTTP/3, Redirect
  local headers
  headers="$(curl -s -I --connect-timeout 5 --max-time 10 "https://$host_name:$port_num")"
  local http2_supported="No"
  local http3_supported="No"
  local redirect="No"

  if [ -z "$headers" ]; then
    echo "HTTP request: No response (unable to connect or fetch headers)"
  else
    if echo "$headers" | head -1 | grep -q '^HTTP/2'; then
      http2_supported="Yes"
    fi
    echo "HTTP/2 Supported: $http2_supported"

    if echo "$headers" | grep -qi 'alt-svc: .*h3'; then
      http3_supported="Yes"
    fi
    echo "HTTP/3 Supported (Alt-Svc): $http3_supported"

    if echo "$headers" | head -1 | grep -qE 'HTTP/.* 30[1-7]'; then
      redirect="Yes"
      local location_header
      location_header=$(echo "$headers" | awk 'tolower($1) == "location:" { $1=""; print substr($0,2)}' | tr -d '\r')
      if [ -z "$location_header" ]; then
        location_header="(No Location header found)"
      fi
      echo "Redirect: Yes -> $location_header"
    else
      echo "Redirect: No"
    fi
  fi

  # CDN detection
  local cdn_detected="No"
  local cdn_provider=""
  local headers_lc
  headers_lc="$(echo "$headers" | tr '[:upper:]' '[:lower:]')"
  local org_info2=""
  if command -v curl >/dev/null 2>&1; then
    org_info2="$(curl -s --connect-timeout 5 --max-time 8 "https://ipinfo.io/${resolved_ip}/org" || true)"
  fi
  local org_info_lc
  org_info_lc="$(echo "$org_info2" | tr '[:upper:]' '[:lower:]')"

  local cert_info
  cert_info="$(echo | openssl s_client -connect "${host_name}:${port_num}" -servername "$host_name" 2>/dev/null | openssl x509 -noout -issuer -subject 2>/dev/null)"
  local cert_info_lc
  cert_info_lc="$(echo "$cert_info" | tr '[:upper:]' '[:lower:]')"
  local combined_info_dest
  combined_info_dest="$headers_lc $org_info_lc $cert_info_lc"

  if echo "$combined_info_dest" | grep -Eq "cloudflare|cf-ray"; then
    cdn_detected="Yes"
    cdn_provider="Cloudflare"
  elif echo "$combined_info_dest" | grep -Eq "akamai|akamai.?technologies"; then
    cdn_detected="Yes"
    cdn_provider="Akamai"
  elif echo "$combined_info_dest" | grep -q "fastly"; then
    cdn_detected="Yes"
    cdn_provider="Fastly"
  elif echo "$combined_info_dest" | grep -Eq "incapsula|imperva"; then
    cdn_detected="Yes"
    cdn_provider="Imperva Incapsula"
  elif echo "$combined_info_dest" | grep -q "sucuri"; then
    cdn_detected="Yes"
    cdn_provider="Sucuri"
  elif echo "$combined_info_dest" | grep -Eq "stackpath|highwinds"; then
    cdn_detected="Yes"
    cdn_provider="StackPath/Highwinds"
  elif echo "$combined_info_dest" | grep -q "cdn77"; then
    cdn_detected="Yes"
    cdn_provider="CDN77"
  elif echo "$combined_info_dest" | grep -q "edgecast"; then
    cdn_detected="Yes"
    cdn_provider="Verizon Edgecast"
  elif echo "$combined_info_dest" | grep -q "keycdn"; then
    cdn_detected="Yes"
    cdn_provider="KeyCDN"
  elif echo "$combined_info_dest" | grep -Eq "microsoft|azure"; then
    cdn_detected="Yes"
    cdn_provider="Microsoft Azure CDN"
  elif echo "$combined_info_dest" | grep -q "alibaba"; then
    cdn_detected="Yes"
    cdn_provider="Alibaba Cloud CDN"
  elif echo "$combined_info_dest" | grep -q "tencent"; then
    cdn_detected="Yes"
    cdn_provider="Tencent Cloud CDN"
  elif echo "$combined_info_dest" | grep -Eq "vk|vkontakte|mail\\.ru"; then
    cdn_detected="Yes"
    cdn_provider="VK (Mail.ru)"
  elif echo "$combined_info_dest" | grep -q "bunnycdn"; then
    cdn_detected="Yes"
    cdn_provider="BunnyCDN"
  elif echo "$combined_info_dest" | grep -q "gcorelabs"; then
    cdn_detected="Yes"
    cdn_provider="G-Core Labs"
  elif echo "$combined_info_dest" | grep -Eq "arvancloud"; then
    cdn_detected="Yes"
    cdn_provider="ArvanCloud"
  elif echo "$combined_info_dest" | grep -Eq "verizon|level3|centurylink|limelight|lumen"; then
    cdn_detected="Yes"
    cdn_provider="Verizon/Level3/Limelight (Lumen)"
  fi

  if [ "$cdn_detected" == "Yes" ]; then
    echo "CDN Detected: $cdn_provider"
  else
    echo "CDN Detected: No"
  fi

  # Requirements: TLS1.3 + HTTP/2 + no CDN
  local verdict="Suitable"
  if [ "$tls13_supported" != "Yes" ] || [ "$http2_supported" != "Yes" ] || [ "$cdn_detected" == "Yes" ]; then
    verdict="Not suitable"
  fi

  # Цветное выделение
  if [ "$verdict" = "Suitable" ]; then
    echo -e "Final Verdict: ${GREEN}Suitable${RESET} for Xray Reality"
  else
    echo -e "Final Verdict: ${RED}Not suitable${RESET} for Xray Reality"
  fi
}
