#!/bin/bash

# === CONFIGURATION ===
URL="https://127.0.0.1:8080/app"           # Target API endpoint
AUTH_URL="https://127.0.0.1:8080/auth"     # Authentication endpoint
USERNAME="admin"
PASSWORD="admin123"
DURATION=60           # Total duration in seconds
INTERVAL=10           # Interval between benchmarks
CONNECTIONS=100       # Number of connections
THREADS=8             # Number of threads
FINAL_JSON="chart_metrics.json" # Final JSON array file for Chart.js

# === REQUIREMENTS CHECK ===
command -v curl >/dev/null || { echo "curl is required"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }
command -v wrk >/dev/null || { echo "wrk is required"; exit 1; }

# Disable certificate verification for self-signed TLS
export CURL_CA_BUNDLE=""

# Initialize metrics array (start of JSON array)
echo "[" > "$FINAL_JSON"
FIRST=true

# === Safe conversion function (us/ms/s to ms) ===
convert_latency() {
    local val="$1"
    if [[ "$val" == *ms ]]; then
        echo "${val%ms}"
    elif [[ "$val" == *us ]]; then
        base="${val%us}"
        if [[ -n "$base" ]]; then
            echo "$(echo "scale=3; $base / 1000" | bc)"
        else
            echo "0"
        fi
    elif [[ "$val" == *s ]]; then
        base="${val%s}"
        if [[ -n "$base" ]]; then
            echo "$(echo "$base * 1000" | bc)"
        else
            echo "0"
        fi
    else
        echo "0"
    fi
}

# === START BENCHMARK LOOP ===
SECONDS=0
while [ $SECONDS -lt $DURATION ]; do
    echo "[+] Authenticating..."

    # Request token from auth endpoint
    RESPONSE=$(curl -k -s -X POST "$AUTH_URL" \
        -H "Content-Type: application/json" \
        -d "{\"username\": \"$USERNAME\", \"password\": \"$PASSWORD\"}")
    TOKEN=$(echo "$RESPONSE" | jq -r .token)

    if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
        echo "❌ Token not received. Full response: $RESPONSE"
        exit 1
    fi

    echo "[+] Token received, running wrk for $INTERVAL seconds..."

    # Run wrk with Authorization header
    OUT=$(wrk -t$THREADS -c$CONNECTIONS -d${INTERVAL}s \
        -H "Authorization: Bearer $TOKEN" "$URL" 2>&1)

    # Extract metrics
    RPS=$(echo "$OUT" | grep "Requests/sec" | awk '{print $2}')
    LATENCY=$(echo "$OUT" | grep -m1 "Latency" | awk '{print $2}')
    MAX_LATENCY=$(echo "$OUT" | grep -m1 "Latency" | awk '{print $4}')
    NOW=$(date +%s)

    # Default to 0ms if extraction fails
    LATENCY=${LATENCY:-0ms}
    MAX_LATENCY=${MAX_LATENCY:-0ms}

    LAT_MS=$(convert_latency "$LATENCY")
    MAX_LAT_MS=$(convert_latency "$MAX_LATENCY")

    # Generate JSON object
    METRIC=$(jq -n \
      --argjson timestamp "$NOW" \
      --argjson rps "${RPS:-0}" \
      --argjson latency "${LAT_MS:-0}" \
      --argjson max_latency "${MAX_LAT_MS:-0}" \
      '{timestamp: $timestamp, rps: $rps, latency_ms: $latency, max_latency_ms: $max_latency}')

    # Append JSON to file with proper comma separation
    if [ "$FIRST" = true ]; then
        FIRST=false
        echo "$METRIC" >> "$FINAL_JSON"
    else
        echo ", $METRIC" >> "$FINAL_JSON"
    fi

    echo "[+] $NOW : RPS=$RPS, Latency=$LAT_MS ms, Max=$MAX_LAT_MS ms"
done

# Close the JSON array
echo "]" >> "$FINAL_JSON"

echo "[x] JSON metrics exported to $FINAL_JSON"
