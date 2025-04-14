#!/bin/bash
# Usage: ./check_sni.sh <domain>

domain="$1"
if [[ -z "$domain" ]]; then
    echo "Usage: $0 <domain>"
    exit 1
fi

# Arrays to accumulate output points
positives=()
negatives=()

# DNS resolution (A and AAAA records)
dns_ips=$(dig +short A "$domain")
dns_ips_v6=$(dig +short AAAA "$domain")
if [[ -z "$dns_ips" && -z "$dns_ips_v6" ]]; then
    negatives+=("DNS: домен не разрешается")
    # If no DNS resolution, further checks cannot proceed
else
    # Count IPv4 and IPv6 addresses
    count_v4=$(echo "$dns_ips" | sed '/^$/d' | wc -l)
    count_v6=$(echo "$dns_ips_v6" | sed '/^$/d' | wc -l)
    dns_msg="DNS: "
    if [[ $count_v4 -gt 0 ]]; then
        # IPv4 addresses present
        if [[ $count_v4 -eq 1 ]]; then
            dns_msg+="1 IPv4-адрес"
        else
            # Proper pluralization for Russian (адреса/адресов)
            if [[ $((count_v4 % 100)) -ge 11 && $((count_v4 % 100)) -le 19 ]]; then
                dns_msg+="$count_v4 IPv4-адресов"
            else
                case $((count_v4 % 10)) in
                    1) dns_msg+="$count_v4 IPv4-адрес";;
                    2|3|4) dns_msg+="$count_v4 IPv4-адреса";;
                    *) dns_msg+="$count_v4 IPv4-адресов";;
                esac
            fi
        fi
    fi
    if [[ $count_v6 -gt 0 ]]; then
        # If both v4 and v6, separate with comma
        [[ $count_v4 -gt 0 ]] && dns_msg+=", "
        if [[ $count_v6 -eq 1 ]]; then
            dns_msg+="1 IPv6-адрес"
        else
            if [[ $((count_v6 % 100)) -ge 11 && $((count_v6 % 100)) -le 19 ]]; then
                dns_msg+="$count_v6 IPv6-адресов"
            else
                case $((count_v6 % 10)) in
                    1) dns_msg+="$count_v6 IPv6-адрес";;
                    2|3|4) dns_msg+="$count_v6 IPv6-адреса";;
                    *) dns_msg+="$count_v6 IPv6-адресов";;
                esac
            fi
        fi
    fi
    positives+=("$dns_msg")

    # Check for private/reserved IPs (which would be incorrect for public domain)
    for ip in $dns_ips $dns_ips_v6; do
        if [[ "$ip" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^127\.|^169\.254\. ]] || [[ "$ip" == ::1 || "$ip" =~ ^fc00:|^fd00:|^fe80: ]]; then
            negatives+=("DNS: возвращается приватный/зарезервированный IP ($ip)")
        fi
    done
fi

# If domain resolved (positives contains DNS or negatives contains DNS issue)
if [[ ! -z "$dns_ips$dns_ips_v6" ]]; then
    # TLS 1.3 support check
    openssl_out=$(echo | timeout 5 openssl s_client -connect "$domain:443" -servername "$domain" -tls1_3 2>&1)
    if echo "$openssl_out" | grep -q "Protocol *: *TLSv1\.3"; then
        positives+=("TLS 1.3: поддерживается")
        tls13_supported=true
        # X25519 support check (TLS 1.3)
        if echo "$openssl_out" | grep -q "Server Temp Key: X25519" ; then
            positives+=("X25519: поддерживается")
        else
            # Try forcing X25519
            x25519_out=$(echo | timeout 5 openssl s_client -connect "$domain:443" -servername "$domain" -tls1_3 -curves X25519 2>&1)
            if echo "$x25519_out" | grep -q "Protocol *: *TLSv1\.3"; then
                positives+=("X25519: поддерживается")
            else
                negatives+=("X25519: не поддерживается")
            fi
        fi
    else
        # Determine reason for TLS1.3 failure if possible
        if echo "$openssl_out" | grep -qi "unsupported protocol"; then
            negatives+=("TLS 1.3: не поддерживается (только более старые версии)")
        elif echo "$openssl_out" | grep -qi "handshake failure"; then
            negatives+=("TLS 1.3: не поддерживается")
        elif echo "$openssl_out" | grep -qi "Connection refused"; then
            negatives+=("TLS: не удалось подключиться к порту 443")
        elif echo "$openssl_out" | grep -qi "getaddrinfo: Name or service not known"; then
            negatives+=("TLS: не удалось разрешить домен")
        else
            negatives+=("TLS 1.3: не поддерживается")
        fi
    fi

    # HTTP/2 and HTTP/3 support, and redirect check using curl
    curl_headers=$(curl -sI -k -m 8 "https://$domain")
    if [[ -n "$curl_headers" ]]; then
        # Check HTTP version from status line
        status_line=$(echo "$curl_headers" | head -1)
        if echo "$status_line" | grep -q "HTTP/2"; then
            positives+=("HTTP/2: поддерживается")
        else
            negatives+=("HTTP/2: не поддерживается")
        fi
        # Check HTTP/3 via Alt-Svc header for h3 or draft versions
        if echo "$curl_headers" | grep -qi "^Alt-Svc: .*h3"; then
            positives+=("HTTP/3: поддерживается")
        elif echo "$curl_headers" | grep -qi "^Alt-Svc: .*h3-"; then
            positives+=("HTTP/3: поддерживается")
        else
            negatives+=("HTTP/3: не поддерживается")
        fi
        # Check for redirects (3xx status)
        status_code=$(echo "$status_line" | awk '{print $2}')
        if [[ "$status_code" =~ ^3 ]]; then
            location=$(echo "$curl_headers" | grep -i "^Location:" | sed -e 's/Location: *//I')
            if [[ -n "$location" ]]; then
                negatives+=("Редирект: $location")
            else
                negatives+=("Редирект: присутствует")
            fi
        else
            positives+=("Редиректы: отсутствуют")
        fi
    else
        negatives+=("HTTP: нет ответа")
    fi

    # CDN detection via headers, certificate, ASN/org info
    cdn_detected=""
    cdn_name=""
    ip_to_check=""
    # Use the first resolved IP (prefer IPv4 over IPv6 for checks)
    if [[ -n "$dns_ips" ]]; then
        ip_to_check=$(echo "$dns_ips" | head -1)
    elif [[ -n "$dns_ips_v6" ]]; then
        ip_to_check=$(echo "$dns_ips_v6" | head -1)
    fi
    # Gather clues for CDN
    combined_info="$curl_headers"$'\n'"$openssl_out"
    if [[ -n "$ip_to_check" ]]; then
        # ipinfo for org
        ipinfo_org=$(curl -s -m 5 "https://ipinfo.io/$ip_to_check/org" || true)
        # whois for additional clues
        whois_out=$(timeout 5 whois "$ip_to_check" 2>/dev/null || true)
        combined_info+=$'\n'"$ipinfo_org"$'\n'"$whois_out"
    fi
    combined_lc=$(echo "$combined_info" | tr '[:upper:]' '[:lower:]')
    # Known CDN patterns
    cdn_patterns=("cloudflare" "akamai" "fastly" "incapsula" "imperva" "sucuri" "stackpath" "cdn77" "edgecast" "keycdn" "azure" "tencent" "alibaba" "aliyun" "bunnycdn" "arvan" "g-core" "mail.ru" "vk" "limelight" "lumen" "level 3" "level3" "centurylink" "cloudfront" "verizon")
    for cdn in "${cdn_patterns[@]}"; do
        if [[ "$combined_lc" == *"$cdn"* ]]; then
            cdn_detected="$cdn"
            case "$cdn_detected" in
                "cloudflare") cdn_name="Cloudflare";;
                "akamai") cdn_name="Akamai";;
                "fastly") cdn_name="Fastly";;
                "incapsula"|"imperva") cdn_name="Imperva Incapsula";;
                "sucuri") cdn_name="Sucuri";;
                "stackpath") cdn_name="StackPath";;
                "cdn77") cdn_name="CDN77";;
                "edgecast"|"verizon") cdn_name="Verizon EdgeCast";;
                "keycdn") cdn_name="KeyCDN";;
                "azure") cdn_name="Azure CDN";;
                "tencent") cdn_name="Tencent CDN";;
                "alibaba"|"aliyun") cdn_name="Alibaba CDN";;
                "bunnycdn") cdn_name="BunnyCDN";;
                "arvan") cdn_name="ArvanCloud";;
                "g-core") cdn_name="G-Core Labs";;
                "mail.ru") cdn_name="Mail.ru CDN";;
                "vk") cdn_name="VK CDN";;
                "limelight") cdn_name="Limelight";;
                "lumen") cdn_name="Lumen (CenturyLink)";;
                "level 3"|"level3"|"centurylink") cdn_name="Level3/CenturyLink";;
                "cloudfront") cdn_name="Amazon CloudFront";;
                *) cdn_name="$cdn_detected";;
            esac
            break
        fi
    done
    if [[ -n "$cdn_detected" ]]; then
        negatives+=("CDN: обнаружен ($cdn_name)")
    else
        positives+=("CDN: не обнаружен")
    fi
fi

# Output results
echo "Положительные аспекты:"
if [[ ${#positives[@]} -eq 0 ]]; then
    echo " - не выявлено"
else
    for p in "${positives[@]}"; do
        echo " - $p"
    done
fi
echo "Недостатки:"
if [[ ${#negatives[@]} -eq 0 ]]; then
    echo " - не выявлено"
else
    for n in "${negatives[@]}"; do
        echo " - $n"
    done
fi

echo -e "\n${CYAN}===== ВОЗМОЖНЫЕ ПУБЛИЧНЫЕ SNI (без Microsoft/Amazon/WhatsApp) =====${RESET}"
echo -e "${GREEN}- dl.google.com${RESET} (Google Download, TLS 1.3, HTTP/2/3)"
echo -e "${GREEN}- gateway.icloud.com${RESET} (Apple iCloud, очень быстрые узлы в Европе)"
echo -e "${GREEN}- www.dropbox.com${RESET} (Dropbox, безопасный и популярный)"
echo -e "${GREEN}- www.wikipedia.org${RESET} (Wikipedia, нейтральный, с HTTP/2/3)"

exit 0
