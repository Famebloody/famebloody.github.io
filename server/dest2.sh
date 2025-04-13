#!/usr/bin/env bash
# Usage: ./check_reality_domain.sh <domain:port>
# This script checks if the given domain is suitable for use as an Xray Reality target.
# It verifies TLS1.3 support, HTTP/2 and HTTP/3, absence of CDN, etc., and outputs a verdict.
# 
# **Improvements in this version:**
# - Robust domain:port parsing (with default port 443 if not specified).
# - Reliable TLS 1.3 check using explicit OpenSSL handshake.
# - HTTP/2 detection by inspecting the actual response protocol.
# - HTTP/3 detection via Alt-Svc header (advertisement of h3 support).
# - CDN detection through multiple signals (headers, ASN via ipinfo, certificate issuer).
# - Removed file outputs; using variables/streams for stability.
# - Added timeouts to prevent hanging on unreachable hosts.
# - Comments explaining each step and fix.

# Exit on unset variables or errors in pipeline
set -o nounset
set -o pipefail

# Require an argument (domain:port)
if [ $# -lt 1 ]; then
  echo "Usage: $0 <domain:port>"
  exit 1
fi

# Parse domain and port from argument
# If no port specified, default to 443 (HTTPS)
if [[ "$1" == *:* ]]; then
  host="${1%%:*}"   # part before colon
  port="${1##*:}"   # part after last colon
else
  host="$1"
  port="443"
fi

# Basic validation for port (must be numeric)
if ! [[ "$port" =~ ^[0-9]+$ ]]; then
  echo "Error: Port must be numeric."
  exit 1
fi

echo "Target: $host:$port"

# Resolve the domain to an IP address (for ping and CDN ASN check)
# Using getent (if available) for DNS lookup, falling back to other methods.
ip=""
if command -v getent >/dev/null 2>&1; then
  ip="$(getent hosts "$host" | awk '{ print $1; exit }')"
fi
if [ -z "$ip" ]; then
  if command -v dig >/dev/null 2>&1; then
    ip="$(dig +short "$host" | head -n1)"
  elif command -v host >/dev/null 2>&1; then
    # 'host' command output parsing for A or AAAA records
    ip="$(host -t A "$host" 2>/dev/null | awk '/has address/ {print $NF; exit}')"
    if [ -z "$ip" ]; then
      ip="$(host -t AAAA "$host" 2>/dev/null | awk '/has IPv6 address/ {print $NF; exit}')"
    fi
  fi
fi
if [ -z "$ip" ]; then
  # Fallback: use ping to retrieve IP (ping prints IP in output even if no response).
  ip="$(ping -c1 -W1 "$host" 2>/dev/null | head -n1 | awk -F'[()]' '{print $2}')"
fi

if [ -n "$ip" ]; then
  echo "Resolved IP: $ip"
else
  echo "Error: Unable to resolve domain $host."
  exit 1
fi

# Ping the host to check availability and latency.
# Uses ping or ping6 depending on IP version. This provides average ping for rating.
avg_ping="N/A"
if [[ "$ip" == *:* ]]; then
  # IPv6 address detected
  if command -v ping6 >/dev/null 2>&1; then
    ping_cmd="ping6"
  else
    ping_cmd="ping -6"  # some systems use `ping -6` for IPv6
  fi
else
  ping_cmd="ping"
fi

# Ping 4 packets with a short timeout for each
ping_output="$($ping_cmd -c4 -W2 "$ip" 2>/dev/null)"
if [ -n "$ping_output" ]; then
  if echo "$ping_output" | grep -q "0 received"; then
    echo "Ping: No response (100% packet loss)"
  else
    # Extract average round-trip time from ping summary
    avg_ping=$(echo "$ping_output" | tail -1 | awk -F'/' '{print $5}')
    # Round the average ping to nearest integer (optional)
    avg_ping=$(printf "%.0f" "${avg_ping}")
    echo "Ping: ${avg_ping} ms (average)"
  end
else
  echo "Ping: Unable to ping host (no output)"
fi

# Check TLS 1.3 support using OpenSSL.
# We force a TLS1.3 handshake; if successful, the domain supports TLS 1.3.
tls13_supported="No"
# Use openssl s_client with -tls1_3 to ensure only TLS1.3 is attempted.
if echo | openssl s_client -connect "${host}:${port}" -tls1_3 -brief 2>/dev/null | grep -q "TLSv1.3"; then
  tls13_supported="Yes"
fi
echo "TLS 1.3 Supported: $tls13_supported"

# Check if the TLS key exchange uses X25519 (Curve25519), if TLS1.3 is supported.
# Reality requires X25519 as the ECDH algorithm for TLS&#8203;:contentReference[oaicite:5]{index=5}.
if [ "$tls13_supported" == "Yes" ]; then
  x25519_supported="No"
  # Restrict OpenSSL to use only X25519 curve for handshake. If handshake succeeds, server supports X25519.
  if echo | openssl s_client -connect "${host}:${port}" -tls1_3 -curves X25519 -brief 2>/dev/null | grep -q "TLSv1.3"; then
    x25519_supported="Yes"
  fi
  echo "TLS 1.3 Key Exchange (X25519): $x25519_supported"
else
  echo "TLS 1.3 Key Exchange (X25519): N/A"
fi

# Perform an HTTPS HEAD request to get headers (and HTTP version).
# Using a short timeout to avoid hang if host is unresponsive.
headers="$(curl -s -I --connect-timeout 5 --max-time 10 "https://$host:$port")"
if [ -z "$headers" ]; then
  echo "HTTP request: No response (unable to connect or fetch headers)"
else
  # Determine HTTP/2 support by checking the first line of the response for HTTP/2.
  http2_supported="No"
  if echo "$headers" | head -1 | grep -q '^HTTP/2'; then
    http2_supported="Yes"
  fi
  echo "HTTP/2 Supported: $http2_supported"

  # Determine HTTP/3 support by looking for an Alt-Svc header advertising h3.
  # If the server supports HTTP/3, it typically announces it to HTTP/1.1 or 2 clients&#8203;:contentReference[oaicite:6]{index=6}.
  http3_supported="No"
  if echo "$headers" | grep -qi 'alt-svc: .*h3'; then
    http3_supported="Yes"
  fi
  echo "HTTP/3 Supported (Alt-Svc): $http3_supported"

  # Check for HTTP redirects (3xx status code) by looking for a Location header.
  redirect="No"
  redirect_target=""
  if echo "$headers" | head -1 | grep -qE 'HTTP/.* 30[1-7]'; then
    redirect="Yes"
    # Extract the Location header value if present
    redirect_target=$(echo "$headers" | awk 'tolower($1) ~ /^location:$/ { $1=""; print substr($0,2) }' | tr -d '\r')
    # If there's a redirect but no Location header (should not happen in well-formed response), note it
    if [ -z "$redirect_target" ]; then
      redirect_target="(Location header not found)"
    fi
    echo "Redirect: Yes -> $redirect_target"
  else
    echo "Redirect: No"
  fi
fi

# CDN detection: check if the domain is behind a known CDN by examining headers, ASN info, and certificate.
cdn_detected="No"
cdn_provider=""

# Convert headers to lowercase for easier searching
headers_lc="$(echo "$headers" | tr '[:upper:]' '[:lower:]')"

# Get ASN/organization info for the IP (using ipinfo.io).
org_info=""
if command -v curl >/dev/null 2>&1; then
  org_info="$(curl -s --connect-timeout 5 --max-time 8 "https://ipinfo.io/${ip}/org" || true)"
fi
org_info_lc="$(echo "$org_info" | tr '[:upper:]' '[:lower:]')"

# Get SSL certificate issuer for the domain (to detect Cloudflare or other CDN-issued certs).
cert_info="$(echo | openssl s_client -connect "${host}:${port}" -servername "$host" 2>/dev/null | openssl x509 -noout -issuer -subject 2>/dev/null)"
cert_info_lc="$(echo "$cert_info" | tr '[:upper:]' '[:lower:]')"

# Look for keywords of major CDN providers in either headers, org info, or certificate.
# This covers Cloudflare, Fastly, Akamai, Incapsula (Imperva), etc.
if echo "$headers_lc $org_info_lc $cert_info_lc" | grep -q "cloudflare"; then
  cdn_detected="Yes"
  cdn_provider="Cloudflare"
elif echo "$headers_lc $org_info_lc $cert_info_lc" | grep -q "akamai"; then
  cdn_detected="Yes"
  cdn_provider="Akamai"
elif echo "$headers_lc $org_info_lc $cert_info_lc" | grep -q "fastly"; then
  cdn_detected="Yes"
  cdn_provider="Fastly"
elif echo "$headers_lc $org_info_lc $cert_info_lc" | grep -q "incapsula"; then
  cdn_detected="Yes"
  cdn_provider="Imperva Incapsula"
fi

if [ "$cdn_detected" == "Yes" ]; then
  echo "CDN Detected: $cdn_provider"
else
  echo "CDN Detected: No"
fi

# Final verdict: Domain is suitable for Reality if it meets critical requirements:
# TLS 1.3 supported, HTTP/2 supported, and not using a CDN. (We also consider X25519 and no redirect as good to have.)
verdict="Suitable"
if [ "$tls13_supported" != "Yes" ] || [ "$http2_supported" != "Yes" ] || [ "$cdn_detected" == "Yes" ]; then
  verdict="Not suitable"
fi

echo "Final Verdict: $verdict for Xray Reality"
# If not suitable, the above individual outputs (TLS/HTTP2/CDN) indicate which criteria failed.
