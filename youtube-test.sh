#!/bin/sh
# Routerich zapret2 1.0.5.2-r15; OpenWrt 24.10/25.12. No package installation.
set -eu
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
# Worker/watchdog ignore SSH hangup explicitly, without requiring nohup.
case "${1:-}" in --worker|--watch) trap '' 1 ;; esac
BASE=/opt/zapret2
LOCK=/tmp/youtube-test.lock
LISTS='geoblock block porn meta tiktok telegram cloudflare google_play'
BC_SHA=58b2f17980b2812088e8cbd739c88e35969e22b13aad6e46e5952f539d5b83c7
GEN_SHA=53ab7e77be9c810a54090aab22489bbd39f1b346e7ef08c374df95f68a738e33
fail() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
say() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
result() {
    color=$1; shift
    # ANSI colors are also retained in the log (view with cat).
    printf '\033[%sm%s\033[0m\n' "$color" "$*"
}
hash_is() { [ "$(sha256sum "$1" | awk '{print $1}')" = "$2" ]; }
process_running() {
    local proc_dir proc_name
    for proc_dir in /proc/[0-9]*; do
        [ -r "$proc_dir/comm" ] || continue
        IFS= read -r proc_name < "$proc_dir/comm" || continue
        if [ "$proc_name" = "$1" ] && kill -0 "${proc_dir##*/}" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}
running() {
    case "$1" in
        podkop)
            # Podkop's start command configures sing-box/firewall and exits.
            # The procd wrapper's running state is not its dataplane health.
            process_running sing-box &&
                nft list table inet PodkopTable >/dev/null 2>&1
            ;;
        *) /etc/init.d/"$1" running >/dev/null 2>&1 ;;
    esac
}
detach() {
    # Ignore HUP during launch; worker/watchdog also set this explicitly.
    # setsid separates the task from SSH; callers redirect all streams.
    (trap '' HUP; exec setsid "$@")
}
restore() {
    # Only this transaction's files, never all of /etc/config or firewall ruleset.
    [ -f "$RUN/armed" ] || return 0
    mkdir "$RUN/recover-lock" 2>/dev/null || return 0
    result 33 'RESTORING: configuration and original Zapret2 state'
    if [ -f "$RUN/child" ]; then
        read -r cp < "$RUN/child"
        case "$cp" in ''|*[!0-9]*) ;; *)
            # The isolated process group belongs to this recorded blockcheck run.
            kill -TERM -- "-$cp" 2>/dev/null || true
            sleep 3
            kill -KILL -- "-$cp" 2>/dev/null || true
            # Do not flush nftables: only the recorded blockcheck table.
            nft delete table inet "blockcheck$cp" 2>/dev/null || true
            ;; esac
    fi
    /etc/init.d/zapret2 stop >> "$RUN/recovery.log" 2>&1 || true
    ok=1
    uci -q revert podkop || true
    uci -q revert zapret2 || true
    for f in podkop zapret2 dhcp sing-box; do
        [ ! -f "$RUN/backup/$f" ] || cp -p "$RUN/backup/$f" "/etc/config/$f" || ok=0
    done
    cp -p "$RUN/backup/zapret2-config" "$BASE/config" || ok=0
    /etc/init.d/podkop restart >> "$RUN/recovery.log" 2>&1 || ok=0
    if [ "$(cat "$RUN/was-running")" = 1 ]; then
        /etc/init.d/zapret2 start >> "$RUN/recovery.log" 2>&1 || ok=0
        sleep 3
        running zapret2 || ok=0
    fi
    running podkop || ok=0
    if [ "$ok" = 1 ]; then
        rm -f "$RUN/armed"
        echo RESTORED > "$RUN/status"
        result 33 "RESTORED: original configuration. Details: $RUN/run.log"
    else
        echo RECOVERY_FAILED > "$RUN/status"
        say "Recovery needs attention: $RUN/recovery.log"
        result 31 "RECOVERY FAILED: $RUN/recovery.log"
    fi
    rmdir "$RUN/recover-lock"
}
case "${1:-}" in
    --recover|--rollback|--watch)
        RUN=${2:-}
        case "$RUN" in /root/youtube-test/run-*) ;; *) fail 'Invalid recovery directory';; esac
        [ -d "$RUN/backup" ] || fail 'Backup missing'
        if [ "$1" = --watch ]; then
            # Detached watchdog also covers killed worker / interrupted SSH.
            n=0
            while [ -f "$RUN/armed" ]; do
                sleep 5
                n=$((n+1))
                if ! kill -0 "$(cat "$RUN/worker")" 2>/dev/null || [ "$n" -ge 1440 ] ||
                    [ "$(df -Pk /root | awk 'END{print $4}')" -lt 2048 ]; then
                    kill -TERM "$(cat "$RUN/worker")" 2>/dev/null || true
                    sleep 5
                    restore
                    rmdir "$LOCK" 2>/dev/null || true
                    exit 0
                fi
            done
        else
            if [ "$1" = --rollback ]; then
                [ ! -d "$LOCK" ] || fail 'A transaction is active; rollback refused'
                touch "$RUN/armed"
            fi
            restore
        fi
        exit 0 ;;
esac

preflight() {
    [ "$(id -u)" = 0 ] || fail 'Run as root'
    [ -r /etc/openwrt_release ] || fail 'OpenWrt required'
    . /etc/openwrt_release
    case "$DISTRIB_RELEASE" in 24.10*|25.12*) ;; *) fail 'Only OpenWrt 24.10/25.12';; esac
    for c in uci nft ip curl ncat sha256sum awk sed sort uniq setsid flock pgrep; do
        command -v "$c" >/dev/null || fail "Missing dependency: $c (nothing installed automatically)"
    done
    [ -x /etc/init.d/podkop ] && [ -x /etc/init.d/zapret2 ] || fail 'Podkop/Zapret2 missing'
    [ -x "$BASE/nfq2/nfqws2" ] && [ -x "$BASE/mdig/mdig" ] || fail 'nfqws2/mdig missing'
    [ -f "$BASE/config" ] || fail 'Zapret2 generated config missing'
    hash_is "$BASE/blockcheck2.sh" "$BC_SHA" || fail 'Unreviewed blockcheck2 version; refusing changes'
    hash_is "$BASE/init.d/openwrt/uci2config" "$GEN_SHA" || fail 'Unreviewed UCI generator; refusing changes'
    [ -z "$(uci changes)" ] || fail 'Apply or discard pending UCI edits first'
    [ -z "$(pgrep -f 'blockcheck2[.]sh|blockcheck_r[u]n' || true)" ] || fail 'Blockcheck already running'
    [ -z "$(uci -q get zapret2.TEST || true)" ] || fail 'TEST already exists; it will not be overwritten'
    [ "$(uci -q get zapret2.main)" = zapret2 ] || fail 'Unknown Zapret2 UCI schema'
    if ! running podkop; then
        if process_running sing-box; then
            result 33 'Podkop diagnostic: sing-box process exists'
        else
            result 31 'Podkop diagnostic: sing-box process is absent'
        fi
        if nft list table inet PodkopTable >/dev/null 2>&1; then
            result 33 'Podkop diagnostic: inet PodkopTable exists'
        else
            result 31 'Podkop diagnostic: inet PodkopTable is absent'
        fi
        fail 'Podkop dataplane not active; inspect Podkop before running tests (no changes made)'
    fi
    curl --version | grep -qw HTTP3 || fail 'curl has no HTTP3; full QUIC test is impossible'
    curl --help all | grep -q -- '--tls-max' || fail 'curl lacks TLS version control'
    curl --help all | grep -q -- '--tlsv1.3' || fail 'curl lacks TLS1.3 option'
    curl --version | grep -Eq 'OpenSSL|LibreSSL|BoringSSL|GnuTLS|quictls' || fail 'curl backend cannot enforce TLS1.2 maximum'
    if process_running nfqws; then fail 'Another DPI bypass (nfqws) is running'; fi
    # Ambiguous sections must be selected explicitly; do not edit every section.
    sections=$(uci show podkop | sed -n 's/^podkop\.\([^.=]*\)=section$/\1/p')
    section=${PODKOP_SECTION:-}
    if [ -z "$section" ]; then
        [ "$(printf '%s\n' "$sections" | wc -l)" -eq 1 ] || fail 'Multiple Podkop sections; set PODKOP_SECTION'
        section=$sections
    fi
    case "$section" in ''|*[!a-zA-Z0-9_]*) fail 'A named Podkop section is required';; esac
    [ "$(uci -q get "podkop.$section")" = section ] || fail 'Podkop section not found'
    # A missing hostlist must never produce a global TEST strategy.
    [ "$(uci -q get zapret2.list_hosts_youtube)" = list ] || fail 'youtube hostlist section missing'
    hl=$(uci -q get zapret2.list_hosts_youtube.path)
    [ -s "$hl" ] || fail 'youtube hostlist is empty/missing'
    grep -Eq '^(youtube\.com|\.youtube\.com)$' "$hl" || fail 'Hostlist must contain youtube.com'
    [ -n "${SSH_CONNECTION:-}" ] || fail 'Launch through SSH so recovery route can be checked'
    peer=${SSH_CONNECTION%% *}
    peer_route=$(ip route get "$peer" | head -n 1)
    case "$peer_route" in *' dev br-lan '*|*' dev tailscale0 '*) ;; *) fail 'Use LAN (br-lan) or Tailscale SSH';; esac
    # Guard against silently forcing remote/router traffic through a proxy.
    [ "$(df -Pk /root | awk 'END{print $4}')" -ge 8192 ] || fail 'Need 8 MiB free under /root'
}

if [ "${1:-}" != --worker ]; then
    preflight
    mkdir "$LOCK" 2>/dev/null || fail "Another run/unfinished lock: $LOCK"
    trap 'rmdir "$LOCK" 2>/dev/null || true' 0
    RUN=/root/youtube-test/run-$(date +%Y%m%d-%H%M%S)-$$
    mkdir -p "$RUN/backup"
    cp "$0" "$RUN/run.sh"
    # Config/backups/logs contain sensitive router data: directory mode 700.
    printf '%s\n' "$section" > "$RUN/section"
    printf '%s\n' "$peer" > "$RUN/peer"
    printf '%s\n' "$peer_route" > "$RUN/route"
    detach sh "$RUN/run.sh" --worker "$RUN" </dev/null > "$RUN/run.log" 2>&1 &
    result 36 "STARTED: $RUN"
    echo "Results: $RUN/status ; log: $RUN/run.log"
    trap - 0
    if [ "${YT_FOLLOW:-0}" = 1 ]; then
        # Viewer only: worker/watchdog remain detached if this SSH session closes.
        tail -n +1 -f "$RUN/run.log" & viewer=$!
        trap 'kill "$viewer" 2>/dev/null || true' 0
        trap 'exit 1' 1 2 15
        while :; do
            state=$(cat "$RUN/status" 2>/dev/null || true)
            case "$state" in
                SUCCESS) sleep 2; exit 0 ;;
                RESTORED|RECOVERY_FAILED|FAILED) sleep 2; exit 1 ;;
            esac
            sleep 2
        done
    fi
    exit 0
fi

RUN=$2
section=$(cat "$RUN/section")
peer=$(cat "$RUN/peer")
finished=0
exit_cleanup() {
    rc=$?
    trap - 0 1 2 15
    if [ "$finished" != 1 ]; then restore; fi
    [ -f "$RUN/status" ] || echo FAILED > "$RUN/status"
    [ "$rc" = 0 ] || result 31 "FAILED: see $RUN/run.log and $RUN/status"
    rmdir "$LOCK" 2>/dev/null || true
    exit "$rc"
}
trap exit_cleanup 0
trap 'exit 1' 2 15
say 'Saving backups'
for f in podkop zapret2 dhcp sing-box; do
    [ ! -f "/etc/config/$f" ] || cp -p "/etc/config/$f" "$RUN/backup/$f"
done
cp -p "$BASE/config" "$RUN/backup/zapret2-config"
was=0
running zapret2 && was=1
printf '%s\n' "$was" > "$RUN/was-running"
echo $$ > "$RUN/worker"
touch "$RUN/armed"
detach sh "$RUN/run.sh" --watch "$RUN" </dev/null > "$RUN/watch.log" 2>&1 &
echo RUNNING > "$RUN/status"

# Instrument a private copy: gracefully finish after 5 successful strategies.
# No guessed upstream MAX/COLLECT variables; no global killall.
awk '
{print}
index($0,"report_append \"$dom\" \"$testf ipv${IPV}\"") {
 print "        YT_OK=$((${YT_OK:-0}+1))"
 print "        if [ ${YT_LIMIT:-0} -gt 0 ] && [ $YT_OK -ge $YT_LIMIT ]; then"
 print "            echo YT_LIMIT_REACHED; unprepare_all; exitp 0"
 print "        fi"
 n++
}
END{if(n!=1)exit 1}
' "$BASE/blockcheck2.sh" > "$RUN/blockcheck.sh"
: > "$RUN/empty-config"
say "Setting eight community lists in Podkop section $section"
uci -q delete "podkop.$section.community_lists" || true
for l in $LISTS; do uci add_list "podkop.$section.community_lists=$l"; done
uci commit podkop
[ "$(uci get "podkop.$section.community_lists")" = "$LISTS" ] || fail 'List verification failed'
/etc/init.d/podkop restart
sleep 5
running podkop || fail 'Podkop did not return'
[ "$(ip route get "$peer" | head -n 1)" = "$(cat "$RUN/route")" ] || fail 'SSH route changed'
say 'Stopping Zapret2'
/etc/init.d/zapret2 stop
sleep 2
if process_running nfqws2; then fail 'nfqws2 remains; no other processes will be killed'; fi
# Do not accept FakeIP as a DPI test destination. DNS-only check, no config edits.
curl -4 --noproxy '*' --connect-timeout 5 --max-time 10 -sS -I -o /dev/null \
    -w '%{remote_ip}\n' https://youtube.com > "$RUN/remote-ip" 2> "$RUN/dns-probe.log" || true
ytip=$(cat "$RUN/remote-ip")
case "$ytip" in 198.18.*|198.19.*|127.*|10.*|192.168.*|0.0.0.0|'') fail 'No public destination/FakeIP detected; inspect Podkop DNS/routing';; esac
ip route get "$ytip" > "$RUN/youtube-route"
case "$(cat "$RUN/youtube-route")" in *' dev tailscale0 '*|*' dev tun'*|*' dev wg'*|*' dev awg'*) fail 'YouTube route uses a VPN';; esac

scan() {
    label=$1; testset=$2; limit=$3; t12=$4; t13=$5; h3=$6
    say "Blockcheck $label: repeats=3, successful-strategy limit=$limit"
    env -i PATH="$PATH" BATCH=1 ZAPRET_BASE="$BASE" ZAPRET_CONFIG="$RUN/empty-config" \
        DOMAINS=youtube.com IPVS=4 TEST="$testset" SCANLEVEL=force REPEATS=3 PARALLEL=0 \
        ENABLE_HTTP=0 ENABLE_HTTPS_TLS12="$t12" ENABLE_HTTPS_TLS13="$t13" ENABLE_HTTP3="$h3" \
        SKIP_DNSCHECK=0 SKIP_IPBLOCK=0 CURL_MAX_TIME=3 YT_LIMIT="$limit" \
        LIST_HTTPS_TLS12="$RUN/candidates.txt" LIST_HTTPS_TLS13="$RUN/candidates.txt" \
        setsid sh "$RUN/blockcheck.sh" > "$RUN/$label.log" 2>&1 &
    child=$!
    echo "$child" > "$RUN/child"
    if wait "$child"; then rc=0; else rc=$?; fi
    # Upstream cleanup is synchronous. Keep the child record for recovery on failure.
    [ "$rc" = 0 ] || fail "Blockcheck $label failed ($rc); see $RUN/$label.log"
    rm -f "$RUN/child"
    grep -Eq 'YT_LIMIT_REACHED|\* SUMMARY' "$RUN/$label.log" || fail 'Incomplete blockcheck output'
    ! grep -Eq 'tests disabled|cannot.*TLS|BAD STRATEGY|POSSIBLE DNS HIJACK' "$RUN/$label.log" || fail 'Unsupported protocol/DNS interference; inspect log'
    parse < "$RUN/$label.log" > "$RUN/$label.tsv"
}
parse() {
    awk '
    /^- curl_test_/ {
        s=""; p=$2; good=0
        if($3=="ipv4" && $4=="youtube.com" && index($0,": nfqws2 ")) {
            s=$0; sub(/^.*: nfqws2 /,"",s)
        }
    }
    s!="" && /^\[attempt [123]\] AVAILABLE$/ {good++}
    /UNAVAILABLE/ {s="";good=0}
    s!="" && /^!!!!! AVAILABLE !!!!!/ {
        if(good==3)print p "\t" s
        s="";good=0
    }'
}
scan tls12 standard 5 1 0 0
scan tls13 standard 5 0 1 0
scan quic standard 5 0 0 1
[ -s "$RUN/quic.tsv" ] || fail 'No successful QUIC strategy; TEST will not be installed'

# Conservative compatibility subset: no external blobs, Lua code, paths, shell
# quoting, profile separators, filters or per-process options from logs.
awk -F '\t' '{print $2}' "$RUN/tls12.tsv" "$RUN/tls13.tsv" | sort -u | awk '
/^--payload=tls_client_hello --lua-desync=(tcpseg|multisplit|multidisorder):pos=[a-z0-9,+_-]+(:ip_id=rnd)?(:repeats=[1-9][0-9]*)?$/ {print;next}
/^--in-range=-s1 --lua-desync=oob:urp=[a-z0-9,+_-]+$/ {print}
' > "$RUN/candidates.txt"
[ -s "$RUN/candidates.txt" ] || fail 'No supported TCP/TLS candidate; manual analysis required'
scan verify custom 0 1 1 0
awk -F '\t' '
 $1=="curl_test_https_tls12" {a[$2]=1}
 $1=="curl_test_https_tls13" {b[$2]=1}
 END {for(s in a)if(b[s]) {
   rank=4
   if(s~/--lua-desync=tcpseg:/)rank=1
   else if(s~/--lua-desync=multisplit:/)rank=2
   else if(s~/--lua-desync=multidisorder:/)rank=3
   print rank "\t" length(s) "\t" s
 }}' "$RUN/verify.tsv" | sort -t "$(printf '\t')" -k1,1n -k2,2n -k3,3 > "$RUN/ranking.tsv"
winner=$(head -n 1 "$RUN/ranking.tsv" | cut -f3-)
[ -n "$winner" ] || fail 'No candidate passed 3/3 on BOTH TLS1.2 and TLS1.3'
printf '%s\n' "$winner" > "$RUN/winner.txt"

say 'Creating enabled TEST, IPv4 TCP 443 TLS, youtube hostlist, autolist off'
uci set zapret2.main.enabled=1
uci set zapret2.main.nfqws_ports_tcp=443
# Custom scripts can launch additional nfqws2 instances outside strategy sections.
uci set zapret2.main.custom_scripts=0
uci set zapret2.TEST=strategy
uci set zapret2.TEST.enabled=1
uci set zapret2.TEST.port=443
uci add_list zapret2.TEST.filter_l3=ipv4
uci add_list zapret2.TEST.protocol=tcp
uci add_list zapret2.TEST.filter_l7=tls
uci add_list zapret2.TEST.hostlist=list_hosts_youtube
uci set zapret2.TEST.autohostlist=0
uci set "zapret2.TEST.script=$winner"
# Enumerate every strategy, including disabled and anonymous sections.
uci show zapret2 | sed -n 's/^zapret2\.\([^.=]*\)=strategy$/\1/p' > "$RUN/strategy-sections"
while IFS= read -r strategy_section; do
    [ "$strategy_section" = TEST ] || uci set "zapret2.$strategy_section.enabled=0"
done < "$RUN/strategy-sections"
uci reorder zapret2.TEST=0
uci commit zapret2
# Re-enumerate: moving TEST changes numeric @strategy[index] references.
uci show zapret2 | sed -n 's/^zapret2\.\([^.=]*\)=strategy$/\1/p' > "$RUN/strategy-sections"
"$BASE/init.d/openwrt/uci2config" --check > "$RUN/config-check.log" 2>&1
"$BASE/init.d/openwrt/uci2config" >> "$RUN/config-check.log" 2>&1
# TEST is first and is the only enabled strategy. No strategy is deleted.
/etc/init.d/zapret2 restart
sleep 4
running zapret2 || fail 'Zapret2 did not start'
[ ! -s /tmp/zapret2/config-error ] || fail 'Zapret2 reports config error'
grep -q -- '--name=TEST' "$BASE/config" || fail 'TEST not found in generated config'
enabled_count=0
while IFS= read -r strategy_section; do
    value=$(uci -q get "zapret2.$strategy_section.enabled" || echo 1)
    [ "$value" != 1 ] || enabled_count=$((enabled_count+1))
done < "$RUN/strategy-sections"
[ "$enabled_count" = 1 ] && [ "$(uci get zapret2.TEST.enabled)" = 1 ] || fail 'TEST must be the only enabled strategy'
[ "$(head -n 1 "$RUN/strategy-sections")" = TEST ] || fail 'TEST is not the first strategy'
for tls in 1.2 1.3; do
    n=1
    while [ "$n" -le 3 ]; do
        curl -4 --noproxy '*' --tlsv"$tls" --tls-max "$tls" --connect-timeout 5 --max-time 10 \
            -fsSI https://youtube.com -o /dev/null >> "$RUN/final-probe.log" 2>&1 || fail "Live TLS$tls probe failed"
        n=$((n+1))
    done
    result 32 "YouTube TLS$tls: 3/3 OK"
done
[ "$(ip route get "$peer" | head -n 1)" = "$(cat "$RUN/route")" ] || fail 'SSH route changed'
running podkop || fail 'Podkop lost'
uci export podkop > "$RUN/podkop-after.uci"
uci export zapret2 > "$RUN/zapret2-after.uci"
rm -f "$RUN/armed"
finished=1
echo SUCCESS > "$RUN/status"
result 32 "SUCCESS: TEST enabled and first; other strategies disabled; Zapret2 restarted; YouTube TLS1.2 + TLS1.3 = 6/6 OK"
say "Winner: $winner"
say "Backup/log directory: $RUN"
