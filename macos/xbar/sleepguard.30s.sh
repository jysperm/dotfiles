#!/bin/bash
#
# <xbar.title>Sleep Guard</xbar.title>
# <xbar.version>v1.0</xbar.version>
# <xbar.author>jysperm</xbar.author>
# <xbar.author.github>jysperm</xbar.author.github>
# <xbar.desc>Shows whether the Mac will sleep — and whether background network apps keep running — after you leave (lock screen / long idle). Based on pmset settings, power assertions, and clamshell state. Includes a Coffee-Buzz-style keep-awake toggle (caffeinate).</xbar.desc>
# <xbar.dependencies>pmset,ioreg,caffeinate</xbar.dependencies>
#
# ============================================================================
# DESIGN
# ============================================================================
#
# Purpose
#   Tell the user, at a glance, whether leaving the computer now will let it
#   sleep — where "sleep" means background network services stop running (the
#   machine becomes unreachable). It also says *why*, and offers a manual
#   keep-awake toggle (like Coffee Buzz / Amphetamine), backed by `caffeinate`.
#
# Three modes, chosen from the lid state, whether anything is holding idle sleep
# open, and whether closing the lid would sleep the Mac (see the decision logic):
#   A  Staying awake   — background services keep running if you walk away.
#   B  Will sleep      — idle sleep kicks in after ~N min; the lid is irrelevant.
#   C  Sleeps on close — it would stay running, but closing the lid (no external
#                        display on power) is the one thing that sleeps it.
#
# Dropdown layout (top to bottom):
#   1. Reason section      — the title spelled out: what keeps it running / when
#                            it sleeps, plus a lid-close note where useful.
#   2. Info section        — neutral state dump: power source, external display,
#                            and what's holding sleep open — the permanent holders
#                            if any, otherwise the temporary ones (flagged).
#   3. Keep-awake control  — single caffeinate on/off toggle, independent of mode.
#   4. Extra actions       — open Battery settings, dump full pmset assertions.
#
# Clamshell note
#   Whether closing the lid sleeps the Mac (CLAM_SLEEP) is derived from Apple's
#   closed-display-mode requirement — an external display AND power must both be
#   present, else the lid sleeps. We do NOT read ioreg AppleClamshellCausesSleep:
#   while the lid is open it tracks transient display-on state and flip-flops, so
#   it mispredicts what closing the lid will do.
# ============================================================================

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export LC_ALL=C

# Path xbar invoked us with; used as the shell= target for the toggle actions.
SELF="$0"

# ============================================================================
# Keep-awake control (Coffee-Buzz-style toggle, backed by caffeinate -i).
# Independent of the reported mode; only overrides *idle* system sleep.
# ============================================================================
PIDFILE="$HOME/.config/sleepguard/caffeinate.pid"

ka_stop() {
    if [ -f "$PIDFILE" ]; then
        kill "$(head -1 "$PIDFILE" 2>/dev/null)" 2>/dev/null
        rm -f "$PIDFILE"
    fi
}

# Handle click actions (param1) and exit before rendering the menu.
case "$1" in
    on)
        mkdir -p "$(dirname "$PIDFILE")"
        ka_stop
        nohup caffeinate -i >/dev/null 2>&1 &
        printf '%s\n' "$!" > "$PIDFILE"
        exit 0
        ;;
    off)
        ka_stop
        exit 0
        ;;
esac

# Detect whether our managed caffeinate is currently running.
KA_ACTIVE=0
if [ -f "$PIDFILE" ]; then
    kpid=$(head -1 "$PIDFILE" 2>/dev/null)
    if [ -n "$kpid" ] && kill -0 "$kpid" 2>/dev/null \
       && [ "$(basename "$(ps -p "$kpid" -o comm= 2>/dev/null)" 2>/dev/null)" = "caffeinate" ]; then
        KA_ACTIVE=1
    else
        rm -f "$PIDFILE"
    fi
fi

# ============================================================================
# Gather system state
# ============================================================================
ASSERT=$(pmset -g assertions 2>/dev/null)
LIVE=$(pmset -g live 2>/dev/null)
BATT=$(pmset -g batt 2>/dev/null)
IOREG=$(ioreg -r -k AppleClamshellState -d 4 2>/dev/null)

getlive()  { echo "$LIVE"  | awk -v k="$1" '$1==k {print $2; exit}'; }
clamval()  { echo "$IOREG" | grep "\"$1\"" | head -1 | sed -E 's/.*= //' | tr -d ' \t'; }

# Power source
if echo "$BATT" | grep -q "'AC Power'"; then SRC="AC"; else SRC="BATT"; fi

# External display: any display that is not the built-in one. EXT_DISPLAY (yes/no)
# drives the clamshell logic; EXT_NAMES holds the external display name(s) for the
# info label. A display block is internal iff it has "Connection Type: Internal".
SPD=$(system_profiler SPDisplaysDataType 2>/dev/null)
DISP_TOTAL=$(echo "$SPD" | grep -c "Resolution:")
DISP_INTERNAL=$(echo "$SPD" | grep -c "Connection Type: Internal")
if [ "$DISP_TOTAL" -gt "$DISP_INTERNAL" ]; then EXT_DISPLAY="yes"; else EXT_DISPLAY="no"; fi
EXT_NAMES=$(echo "$SPD" | awk '
/^        [^ ].*:$/ { name=$0; sub(/^ +/,"",name); sub(/:$/,"",name); order[++c]=name; cur=name; next }
/Connection Type:[[:space:]]*Internal/ { if (cur!="") intl[cur]=1 }
END { for (i=1;i<=c;i++) if (!intl[order[i]]) { if (out) out=out", "; out=out order[i] } print out }
')

# Idle-to-sleep time. The system can't idle-sleep while the display is on, so the
# real wait before sleep is max(sleep, displaysleep) — both timers run off the same
# idle clock. A 0 in EITHER means "never": sleep=0 disables system sleep; and with
# displaysleep=0 the display never turns off, so the system never idle-sleeps.
# IDLE_SLEEP is the effective minutes (0 = never, "?" = unknown).
SLEEP=$(getlive sleep)
DISPLAYSLEEP=$(getlive displaysleep)
if [ -z "$SLEEP" ] || [ -z "$DISPLAYSLEEP" ]; then
    IDLE_SLEEP="?"
elif [ "$SLEEP" = "0" ] || [ "$DISPLAYSLEEP" = "0" ]; then
    IDLE_SLEEP="0"
elif [ "$SLEEP" -ge "$DISPLAYSLEEP" ]; then
    IDLE_SLEEP="$SLEEP"
else
    IDLE_SLEEP="$DISPLAYSLEEP"
fi

# Lid state (from ioreg): AppleClamshellState — Yes = lid closed, No = lid open.
# A direct hardware state, reliable.
LID=$(clamval AppleClamshellState)
[ -z "$LID" ] && LID="No"

# Will closing the lid force sleep? Derived from Apple's closed-display-mode
# requirement: needs an external display AND power, else the lid sleeps. (We avoid
# ioreg AppleClamshellCausesSleep — it flip-flops while the lid is open; see the
# clamshell note in the header.)
if [ "$EXT_DISPLAY" = "yes" ] && [ "$SRC" = "AC" ]; then
    CLAM_SLEEP="No"   # closed-display (clamshell) mode keeps it running
else
    CLAM_SLEEP="Yes"  # closing the lid sleeps
fi

# ============================================================================
# Parse system-sleep assertions and split the holders into:
#   PERM_HOLDERS — keep the Mac awake indefinitely, so walking away is safe:
#                  a caffeinate with no timeout and no command to wait on, plus
#                  known keep-awake apps (Amphetamine, Coffee Buzz, ...).
#   TEMP_HOLDERS — release on their own, so the Mac still sleeps if you leave:
#                  a timed / command-wrapping caffeinate, audio (coreaudiod), and
#                  any other process holding system sleep open.
# Only PERM_HOLDERS count as "staying awake". Assertions held merely "while the
# display is on" are dropped entirely — they are the display gate, not a holder,
# and are already folded into the idle-sleep timer. awk emits "pid|pname|desc".
# ============================================================================
KEEPAWAKE_RE='Coffee Buzz|Amphetamine|Caffeine|KeepingYouAwake|caffeinate|Lungo|Theine|Owly|Wimoweh|NoSleep|Jiggler|Aerial|Caffeinated|Anti-Sleep'

PERM_HOLDERS=""   # newline-separated process names (indefinite holders)
TEMP_HOLDERS=""   # newline-separated process names (self-releasing holders)

# A caffeinate is permanent only if its args carry no timeout (-t), no
# wait-for-pid (-w) and no trailing command — i.e. only boolean flags. If the
# process is already gone, treat it as temporary (don't claim "staying awake").
caffeinate_is_permanent() {
    local args
    args=$(ps -p "$1" -o args= 2>/dev/null)
    [ -z "$args" ] && { echo "no"; return; }
    echo "$args" | awk '{
        for (i = 2; i <= NF; i++) {
            if ($i !~ /^-/)  { print "no"; exit }   # a command/value -> bounded
            if ($i ~ /[tw]/) { print "no"; exit }   # -t timeout or -w wait-pid
        }
        print "yes"
    }'
}

while IFS='|' read -r pid pname desc; do
    [ -z "$pname" ] && continue
    echo "$desc" | grep -qi "display is on" && continue
    if echo "$pname" | grep -qiE "$KEEPAWAKE_RE" \
       && ! { [ "$pname" = "caffeinate" ] && [ "$(caffeinate_is_permanent "$pid")" != "yes" ]; }; then
        PERM_HOLDERS="$PERM_HOLDERS$pname
"
    else
        TEMP_HOLDERS="$TEMP_HOLDERS$pname
"
    fi
done <<< "$(echo "$ASSERT" | awk '
/pid [0-9]+\(.*\): .*SystemSleep named:/ {
    pid=$0;   sub(/^[[:space:]]*pid /, "", pid);           sub(/\(.*/, "", pid)
    pname=$0; sub(/^[[:space:]]*pid [0-9]+\(/, "", pname); sub(/\).*/, "", pname)
    desc=$0;  sub(/.*named: "/, "", desc);                 sub(/".*/, "", desc)
    print pid "|" pname "|" desc
}
')"

# Short phrase for why the Mac will stay awake (also: non-empty = "staying
# awake"). Only permanent holders / disabled timers count here.
STAY_WHY=""
if [ "$SLEEP" = "0" ]; then
    STAY_WHY="idle sleep is disabled"
elif [ "$DISPLAYSLEEP" = "0" ]; then
    STAY_WHY="display sleep disabled"
elif [ -n "$PERM_HOLDERS" ]; then
    STAY_WHY="kept awake by $(echo "$PERM_HOLDERS" | head -1)"
fi

# Reason phrase shown in the "keep running" line. If our own caffeinate toggle is
# the holder, name it explicitly; otherwise use the detected reason.
if [ "$KA_ACTIVE" = "1" ]; then
    KEEP_WHY="caffeinate enabled"
else
    KEEP_WHY="$STAY_WHY"
fi

# ============================================================================
# Decide the mode. Idle sleep is the dominant constraint: closed-display
# (clamshell) mode only protects the lid-close path, NOT the idle timer, so it
# never makes the Mac "stay awake" on its own — only a permanent holder (or a
# disabled idle timer), i.e. STAY_WHY, does.
#   kept awake (STAY_WHY set):
#     lid open AND closing it would sleep -> C (the lid is the one thing that
#                                            would sleep it) ; else -> A
#   not kept awake -> B (idle-sleeps after IDLE_SLEEP min, regardless of the lid
#                        or clamshell state)
# ============================================================================
MODE=""
AWAKE_WHY=""   # reason phrase for the Mode A "keep running" line

if [ -n "$STAY_WHY" ]; then
    if [ "$LID" = "No" ] && [ "$CLAM_SLEEP" = "Yes" ]; then
        MODE="C"
    else
        MODE="A"
        AWAKE_WHY="$KEEP_WHY"
    fi
else
    MODE="B"
fi

# ============================================================================
# Menu bar title (first line) + reason section (REASON, may be multi-line)
# ============================================================================
case "$MODE" in
    A)
        echo "🟢 Staying awake"
        REASON="🟢 Background apps keep running${AWAKE_WHY:+ ($AWAKE_WHY)}"
        # A lid that would sleep is classified as Mode C, so in Mode A closing
        # the (open) lid is always clamshell-safe.
        [ "$LID" = "No" ] && REASON="$REASON
🟢 Closing the lid also keeps it running"
        ;;
    B)
        echo "💤 Will sleep"
        REASON="💤 Sleeps after ${IDLE_SLEEP} min idle"
        ;;
    C)
        echo "⚠️ Sleeps on close"
        REASON="🟢 Background apps keep running (${KEEP_WHY})
⚠️ Closing the lid puts it to sleep"
        ;;
esac

echo "---"
echo "$REASON"

# ============================================================================
# Info section — neutral state, same set in every mode
# ============================================================================
echo "---"
echo "Power: $([ "$SRC" = "AC" ] && echo "AC" || echo "Battery")"
if [ "$EXT_DISPLAY" = "yes" ]; then
    echo "External display: ${EXT_NAMES:-connected}"
else
    echo "No external display"
fi
# Holders of system sleep. Prefer the permanent ones (what actually keeps it
# awake); only when there are none do we surface the temporary ones, flagged as
# such since they don't survive you walking away. Duplicates are kept on purpose
# (e.g. two caffeinate processes is worth seeing).
join_holders() { echo "$1" | awk 'NF { printf "%s%s", (n++ ? ", " : ""), $0 }'; }
PERM_LIST=$(join_holders "$PERM_HOLDERS")
TEMP_LIST=$(join_holders "$TEMP_HOLDERS")
if [ -n "$PERM_LIST" ]; then
    echo "Holding awake by: $PERM_LIST"
elif [ -n "$TEMP_LIST" ]; then
    echo "Temporarily held by: $TEMP_LIST"
fi

# ============================================================================
# Keep-awake control — single on/off toggle, independent of mode
# ============================================================================
echo "---"
if [ "$KA_ACTIVE" = "1" ]; then
    echo "☕ Turn off caffeinate | shell=\"$SELF\" param1=off terminal=false refresh=true"
else
    echo "💤 Turn on caffeinate | shell=\"$SELF\" param1=on terminal=false refresh=true"
fi

# ============================================================================
# Extra actions
# ============================================================================
echo "---"
echo "Open Battery Settings | shell=open param1=x-apple.systempreferences:com.apple.Battery-Settings.extension terminal=false"
echo "Full pmset assertions | shell=/usr/bin/pmset param1=-g param2=assertions terminal=true"
