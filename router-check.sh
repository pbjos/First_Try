#!/usr/bin/env bash
# router-check.sh - home network / router slowdown diagnostics for macOS and Linux.
#
# Usage:   bash router-check.sh
# Output:  printed to the screen and saved to router-report-<date>.txt
#
# Read-only: it changes no settings. It only pings, looks up DNS names, and
# downloads/uploads test data to speed.cloudflare.com (about 150 MB in total).
# MAC addresses are shortened to the manufacturer part, and Wi-Fi network
# names are not recorded.

OUT="router-report-$(date +%Y%m%d-%H%M%S).txt"
OS="$(uname -s)"
exec > >(tee "$OUT") 2>&1

section() { printf '\n==================== %s ====================\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ping_summary HOST COUNT -> prints the loss and min/avg/max lines
ping_raw() {
  ping -c "$2" -i 0.2 "$1" 2>/dev/null || ping -c "$2" "$1" 2>/dev/null
}
ping_summary() {
  ping_raw "$1" "$2" | grep -E 'packet loss|rtt|round-trip'
}
avg_from() { grep -E 'rtt|round-trip' | awk -F'/' '{print $5}'; }

section "SYSTEM"
echo "Date: $(date)"
echo "OS:   $OS $(uname -r)"

section "CONNECTION"
if [ "$OS" = "Darwin" ]; then
  GW="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')"
  IF="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
  WIFI_IF="$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi|AirPort/{getline; print $2}')"
  [ "$IF" = "$WIFI_IF" ] && CONN="Wi-Fi" || CONN="Wired/other"
else
  GW="$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')"
  IF="$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')"
  [ -d "/sys/class/net/$IF/wireless" ] && CONN="Wi-Fi" || CONN="Wired/other"
fi
echo "Router (gateway): ${GW:-NOT FOUND}"
echo "Interface:        ${IF:-?} ($CONN)"
if [ -z "$GW" ]; then echo "No default gateway - are you connected?"; exit 1; fi

section "ROUTER IDENTITY (admin page)"
if have curl; then
  curl -s -m 4 -I "http://$GW" | grep -iE '^(server|www-authenticate):' || echo "(no server header)"
  curl -s -m 4 -L "http://$GW" | grep -io '<title>[^<]*' | head -1 | sed 's/<title>/Page title: /I'
fi

if [ "$CONN" = "Wi-Fi" ]; then
  section "WI-FI LINK"
  if [ "$OS" = "Darwin" ]; then
    SP="$(system_profiler SPAirPortDataType 2>/dev/null)"
    echo "$SP" | awk '/Current Network Information/{f=1} /Other Local Wi-Fi Networks/{f=0} f' \
      | grep -E 'PHY Mode|Channel|Signal / Noise|Transmit Rate|Security' | sed 's/^ *//'
    echo "--- Nearby networks per channel (crowding) ---"
    echo "$SP" | awk '/Other Local Wi-Fi Networks/{f=1} f' | grep 'Channel:' \
      | awk '{print $2}' | sort -n | uniq -c | awk '{printf "channel %-4s %s networks\n",$2,$1}'
  elif have nmcli; then
    nmcli -t -f ACTIVE,CHAN,FREQ,RATE,SIGNAL,SECURITY dev wifi 2>/dev/null | grep '^yes' \
      | awk -F: '{print "Channel: "$2"\nFreq: "$3"\nRate: "$4"\nSignal: "$5"%\nSecurity: "$6}'
    echo "--- Nearby networks per channel (crowding) ---"
    nmcli -t -f CHAN dev wifi 2>/dev/null | sort -n | uniq -c | awk '{printf "channel %-4s %s networks\n",$2,$1}'
  elif have iw; then
    iw dev "$IF" link
  fi
fi

section "INTERFACE ERRORS / DROPS"
if [ "$OS" = "Darwin" ]; then netstat -i -I "$IF" 2>/dev/null | head -3
else ip -s link show dev "$IF" 2>/dev/null | sed -n '3,6p'; fi

section "LATENCY & PACKET LOSS (idle, 30 pings each)"
for h in "$GW" 1.1.1.1 8.8.8.8; do
  echo "--- $h ---"; ping_summary "$h" 30
done

section "ROUTE TO INTERNET (first hops)"
if have traceroute; then traceroute -n -m 5 -w 1 -q 2 1.1.1.1 2>/dev/null
else echo "(traceroute not installed)"; fi

section "DNS LOOKUP SPEED"
NAMES="google.com wikipedia.org netflix.com amazon.com"
for s in "$GW" 1.1.1.1 8.8.8.8; do
  echo "--- DNS server $s ---"
  for n in $NAMES; do
    if have dig; then
      t="$(dig @"$s" "$n" +tries=1 +time=2 2>/dev/null | awk '/Query time/{print $4" ms"}')"
    else
      a=$(date +%s%N 2>/dev/null); nslookup "$n" "$s" >/dev/null 2>&1; b=$(date +%s%N 2>/dev/null)
      t="$(( (b-a)/1000000 )) ms"
    fi
    printf '  %-15s %s\n' "$n" "${t:-FAILED/timeout}"
  done
done

section "SPEED TEST (Cloudflare)"
DOWN_URL="https://speed.cloudflare.com/__down?bytes=100000000"
UP_URL="https://speed.cloudflare.com/__up"
d=$(curl -s -o /dev/null -m 15 -w '%{speed_download}' "$DOWN_URL")
echo "Download: $(awk -v b="$d" 'BEGIN{printf "%.1f Mbps", b*8/1000000}')"
u=$(head -c 25000000 /dev/zero | curl -s -o /dev/null -m 15 -w '%{speed_upload}' --data-binary @- "$UP_URL")
echo "Upload:   $(awk -v b="$u" 'BEGIN{printf "%.1f Mbps", b*8/1000000}')"

section "BUFFERBLOAT (latency while the line is busy)"
idle=$(ping_raw 1.1.1.1 15 | avg_from)
curl -s -o /dev/null -m 12 "https://speed.cloudflare.com/__down?bytes=250000000" &
sleep 1; dl=$(ping_raw 1.1.1.1 15 | avg_from); wait
head -c 50000000 /dev/zero | curl -s -o /dev/null -m 12 --data-binary @- "$UP_URL" &
sleep 1; ul=$(ping_raw 1.1.1.1 15 | avg_from); wait
echo "Idle ping:            ${idle:-?} ms"
echo "Ping while download:  ${dl:-?} ms"
echo "Ping while upload:    ${ul:-?} ms"
awk -v i="$idle" -v d="$dl" -v u="$ul" 'BEGIN{
  if (i=="" || (d=="" && u=="")) exit; m=(d>u?d:u)-i;
  g=(m<30?"A (good)":m<60?"B":m<200?"C (noticeable lag under load)":"F (severe - enable QoS/SQM)");
  printf "Added latency under load: %.0f ms -> grade %s\n", m, g }'

section "DEVICES ON THE NETWORK"
PFX="${GW%.*}"
echo "Scanning $PFX.1-254 ..."
for i in $(seq 1 254); do
  if [ "$OS" = "Darwin" ]; then ping -c 1 -t 1 "$PFX.$i" >/dev/null 2>&1 &
  else ping -c 1 -W 1 "$PFX.$i" >/dev/null 2>&1 & fi
done; wait
if [ "$OS" = "Darwin" ]; then
  LIST="$(arp -an | grep -v incomplete | awk '{gsub(/[()]/,"",$2); print $2, $4}')"
else
  LIST="$(ip neigh show 2>/dev/null | grep -E 'lladdr' | awk '{print $1, $5}')"
fi
echo "$LIST" | grep "^$PFX\." | while read -r ip mac; do
  v="$(echo "$mac" | cut -d: -f1-3)"
  second="$(echo "$mac" | cut -d: -f1 | cut -c2)"
  case "$second" in 2|6|a|A|e|E) note="(private/random MAC)";; *) note="";; esac
  printf '  %-16s vendor-prefix %s %s\n' "$ip" "$v" "$note"
done
echo "Total devices answering: $(echo "$LIST" | grep -c "^$PFX\.")"

section "DONE"
echo "Report saved to: $OUT"
