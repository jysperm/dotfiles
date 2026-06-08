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
#                            and any process holding sleep open.
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
# Parse sleep-preventing assertions to see what is holding idle sleep open.
# We only care about two kinds:
#   KEEP_APPS   — persistent keep-awake tools (caffeinate, Amphetamine, ...)
#   AUDIO_HELD  — coreaudiod (audio device in use)
# Two kinds are ignored because they won't actually keep the Mac awake if you
# walk away:
#   - assertions held only "while the display is on" (they release when the
#     display sleeps, i.e. when you walk away);
#   - a caffeinate whose timeout (caffeinate -t) fires before idle sleep would —
#     it releases before the machine would have slept anyway, so it changes
#     nothing, and these short-lived caffeinates would otherwise cause flicker.
# awk emits one record per assertion as "pname|desc|timeout_secs".
# ============================================================================
KEEPAWAKE_RE='Coffee Buzz|Amphetamine|Caffeine|KeepingYouAwake|caffeinate|Lungo|Theine|Owly|Wimoweh|NoSleep|Jiggler|Aerial|Caffeinated|Anti-Sleep'

KEEP_APPS=""      # newline-separated process names of active keep-awake tools
AUDIO_HELD=0

# Effective idle-sleep window in seconds, or 0 when idle sleep never fires /
# is unknown (in which case the caffeinate-timeout filter is skipped).
if [ "$IDLE_SLEEP" != "0" ] && [ "$IDLE_SLEEP" != "?" ]; then
    IDLE_SLEEP_SECS=$((IDLE_SLEEP * 60))
else
    IDLE_SLEEP_SECS=0
fi

while IFS='|' read -r pname desc tmo; do
    [ -z "$pname" ] && continue
    echo "$desc" | grep -qi "display is on" && continue
    if echo "$pname" | grep -qiE "$KEEPAWAKE_RE"; then
        # Ignore a caffeinate that will time out before idle sleep would fire.
        if [ "$pname" = "caffeinate" ] && [ -n "$tmo" ] \
           && [ "$IDLE_SLEEP_SECS" -gt 0 ] && [ "$tmo" -lt "$IDLE_SLEEP_SECS" ]; then
            continue
        fi
        KEEP_APPS="$KEEP_APPS$pname
"
    elif [ "$pname" = "coreaudiod" ]; then
        AUDIO_HELD=1
    fi
done <<< "$(echo "$ASSERT" | awk '
/pid [0-9]+\(.*\): .*named:/ {
    if (have) print pname "|" desc "|" tmo
    have=1; tmo=""
    pname=$0; sub(/.*pid [0-9]+\(/, "", pname); sub(/\).*/, "", pname)
    desc=$0;  sub(/.*named: "/, "", desc);      sub(/".*/, "", desc)
    next
}
/Timeout will fire in [0-9]+ secs/ {
    t=$0; sub(/.*Timeout will fire in /, "", t); sub(/ secs.*/, "", t); tmo=t
}
END { if (have) print pname "|" desc "|" tmo }
')"

# Short phrase for why idle sleep is held off (also: non-empty = "kept awake").
STAY_WHY=""
if [ "$SLEEP" = "0" ]; then
    STAY_WHY="idle sleep is disabled"
elif [ "$DISPLAYSLEEP" = "0" ]; then
    STAY_WHY="display sleep disabled"
elif [ -n "$KEEP_APPS" ]; then
    STAY_WHY="kept awake by $(echo "$KEEP_APPS" | head -1)"
elif [ "$AUDIO_HELD" = "1" ]; then
    STAY_WHY="audio is in use"
fi

# Reason phrase shown in the "keep running" line. If our own caffeinate toggle is
# the holder, name it explicitly; otherwise use the detected reason.
if [ "$KA_ACTIVE" = "1" ]; then
    KEEP_WHY="caffeinate enabled"
else
    KEEP_WHY="$STAY_WHY"
fi

# ============================================================================
# Decide the mode
#   lid closed in clamshell mode (external display + power) -> A (keeps running)
#     (lid closed otherwise means the Mac is asleep and not rendering this menu)
#   lid open, kept awake: clamshell sleeps -> C (the lid is the one thing that
#                         would sleep it) ; else -> A
#   lid open, not kept awake -> B (idle sleep applies regardless of the lid)
# ============================================================================
MODE=""
AWAKE_WHY=""   # reason phrase for the Mode A "keep running" line

if [ "$LID" = "Yes" ] && [ "$CLAM_SLEEP" = "No" ]; then
    MODE="A"
    AWAKE_WHY="lid closed in clamshell mode"
elif [ -n "$STAY_WHY" ]; then
    if [ "$CLAM_SLEEP" = "Yes" ]; then
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
# Processes holding idle sleep open, if any (duplicates kept on purpose — e.g.
# two caffeinate processes is worth seeing).
HOLD_NAMES=$(echo "$KEEP_APPS" | awk 'NF { printf "%s%s", (n++ ? ", " : ""), $0 }')
[ "$AUDIO_HELD" = "1" ] && HOLD_NAMES="${HOLD_NAMES:+$HOLD_NAMES, }coreaudiod"
[ -n "$HOLD_NAMES" ] && echo "Holding awake by: $HOLD_NAMES"

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
