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
# Lid presence and battery presence are detected independently (HAS_LID / HAS_BATTERY).
# A lidless desktop (Mac mini/Studio/iMac/Mac Pro) only ever sees A or B — Mode C and
# every lid note are skipped — and its always-on-AC power state is hidden entirely.
#
# Dropdown layout (top to bottom):
#   1. Reason section      — the title spelled out: what keeps it running / when
#                            it sleeps, plus a lid-close note where useful and, when
#                            staying awake on battery, a battery-drain warning.
#   2. Info section        — neutral state dump: power source, external display,
#                            system-wide disablesleep state, and what's holding sleep
#                            open — the permanent holders if any, else the temporary
#                            ones (flagged).
#   3. Keep-awake controls — a caffeinate on/off toggle and a system-wide disablesleep
#                            on/off toggle, both independent of the reported mode.
#   4. Extra actions       — open Battery settings, dump full pmset assertions.
#
# Clamshell note
#   Whether closing the lid sleeps the Mac (CLAM_SLEEP) follows Apple's closed-
#   display-mode requirement and what we measured on an M3 Pro (macOS 26): the lid
#   stays "awake" closed only when (a) pmset disablesleep is on — the kernel master
#   switch overrides the lid-close sleep (on AC always; on battery only for Apple
#   Silicon — Intel is assumed to still need AC, untested as we have no Intel Mac),
#   or (b) an external display is connected AND on AC (the ordinary supported setup).
#   By DEFAULT (no disablesleep) a closed-lid Apple Silicon laptop on battery sleeps
#   within ~1 min — this is measured, contradicting the widespread "M-series stays
#   awake clamshell on battery" claim, and caffeinate does NOT prevent it. This rule
#   runs only when HAS_LID=yes, so it never touches a lidless desktop. We do NOT read
#   ioreg AppleClamshellCausesSleep: while the lid is open it tracks transient
#   display-on state and flip-flops, so it mispredicts what closing the lid will do.
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
    disablesleep-on)
        # Needs root; prompt via the native admin dialog (no sudoers editing).
        # disablesleep (SleepDisabled) is global, so -a is the clearest scope.
        osascript -e 'do shell script "/usr/bin/pmset -a disablesleep 1" with administrator privileges' >/dev/null 2>&1
        exit 0
        ;;
    disablesleep-off)
        osascript -e 'do shell script "/usr/bin/pmset -a disablesleep 0" with administrator privileges' >/dev/null 2>&1
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

# Hardware shape — two independent (orthogonal) traits. Today's Mac line-up binds
# them (laptops have both, desktops neither), but each rides its own signal:
#   HAS_LID     — does the Mac have a display lid? The AppleClamshellState ioreg key
#                 is published only by lidded devices, so its mere presence is a
#                 reliable lid test. Gates all clamshell/lid logic below.
#   HAS_BATTERY — is an internal battery installed? Gates power handling: a
#                 batteryless desktop is always on AC, and power then has no bearing
#                 on sleep, so we don't even show it.
if printf '%s' "$IOREG" | grep -q AppleClamshellState; then HAS_LID="yes"; else HAS_LID="no"; fi
if ioreg -rc AppleSmartBattery 2>/dev/null | grep -q '"BatteryInstalled" = Yes'; then
    HAS_BATTERY="yes"
else
    HAS_BATTERY="no"
fi

# Power source. With no battery the Mac is always on AC; otherwise read it live.
if [ "$HAS_BATTERY" = "no" ]; then
    SRC="AC"
elif echo "$BATT" | grep -q "'AC Power'"; then
    SRC="AC"
else
    SRC="BATT"
fi

# CPU architecture. Only matters for the clamshell rule below, and only alongside
# disablesleep: with disablesleep on, an Apple Silicon laptop holds clamshell on
# battery, whereas Intel is assumed to still need AC (untested — no Intel Mac here).
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then
    ARCH="Apple Silicon"
else
    ARCH="Intel"
fi

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

# pmset disablesleep — the kernel-level master switch (live key SleepDisabled). When
# on, it blocks ALL system sleep (idle, clamshell, standby) on every power source,
# overriding caffeinate and every timer below; it is the strongest keep-awake there
# is. The key is absent from `pmset -g live` when off, so an empty value means "off".
SLEEP_DISABLED=$(getlive SleepDisabled)

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

# Lid state and clamshell behavior — only meaningful on devices with a lid.
# LID (from ioreg): AppleClamshellState — Yes = lid closed, No = lid open; a direct,
# reliable hardware state. CLAM_SLEEP answers "would closing the lid sleep the Mac?".
# Closed-display (clamshell) mode keeps the Mac running only when disablesleep is on
# (it overrides the lid-close sleep: AC always, battery only on Apple Silicon — Intel
# assumed to still need AC), or an external display is connected AND on AC. Otherwise
# closing the lid sleeps — including, by default, an Apple Silicon laptop on battery
# (~1 min, measured; caffeinate does not save it). We avoid ioreg
# AppleClamshellCausesSleep — it flip-flops while the lid is open; see the header
# note. On a lidless desktop both are inert: no lid to close, so the path is skipped.
if [ "$HAS_LID" = "yes" ]; then
    LID=$(clamval AppleClamshellState)
    [ -z "$LID" ] && LID="No"
    if [ "$SLEEP_DISABLED" = "1" ] && { [ "$SRC" = "AC" ] || [ "$ARCH" = "Apple Silicon" ]; }; then
        CLAM_SLEEP="No"   # disablesleep overrides the lid-close sleep
    elif [ "$EXT_DISPLAY" = "yes" ] && [ "$SRC" = "AC" ]; then
        CLAM_SLEEP="No"   # ordinary closed-display mode, on power
    else
        CLAM_SLEEP="Yes"  # closing the lid sleeps
    fi
else
    LID="No"          # no lid; treat as "not closed" so the mode logic stays clean
    CLAM_SLEEP="No"   # no lid-close path to sleep through
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

# A keep-awake holder only works while the Mac CAN stay awake; the one thing that
# overrides it is the closed-lid (clamshell) standby path. So a holder counts only when
# the lid is open OR closing it would not sleep (CLAM_SLEEP=No, i.e. external-display+AC
# or disablesleep) — exactly the condition under which the Mac stays awake closed. It is
# voided only when the lid is closed AND that closure sleeps (CLAM_SLEEP=Yes): there a
# power-assertion hold does not survive (measured with caffeinate; every keep-awake we
# detect is just such an assertion — we only parse "SystemSleep named:" assertions), so
# only disablesleep holds. LID_SLEEPS marks that override state.
LID_SLEEPS="no"
[ "$HAS_LID" = "yes" ] && [ "$LID" = "Yes" ] && [ "$CLAM_SLEEP" = "Yes" ] && LID_SLEEPS="yes"

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
       && ! { [ "$pname" = "caffeinate" ] && [ "$(caffeinate_is_permanent "$pid")" != "yes" ]; } \
       && [ "$LID_SLEEPS" != "yes" ]; then
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

# Short phrase for why the Mac will stay awake (non-empty = "staying awake"), ordered
# strongest-first. disablesleep holds in every state. When the lid is closed and that
# sleeps it (LID_SLEEPS) nothing else survives the clamshell standby path — holders are
# demoted above and the idle-path timers (sleep=0 / displaysleep=0) don't hold either —
# so we stop at disablesleep there. Otherwise a disabled idle/display timer or a
# permanent holder counts.
STAY_WHY=""
if [ "$SLEEP_DISABLED" = "1" ]; then
    STAY_WHY="system-wide disablesleep enabled"
elif [ "$LID_SLEEPS" = "yes" ]; then
    STAY_WHY=""   # lid closed & it sleeps: only disablesleep (handled above) holds
elif [ "$SLEEP" = "0" ]; then
    STAY_WHY="idle sleep is disabled"
elif [ "$DISPLAYSLEEP" = "0" ]; then
    STAY_WHY="display sleep disabled"
elif [ -n "$PERM_HOLDERS" ]; then
    STAY_WHY="kept awake by $(echo "$PERM_HOLDERS" | head -1)"
fi

# Reason phrase shown in the "keep running" line. disablesleep is the strongest
# guarantee, so name it whenever it's on; else, if our own caffeinate toggle is the
# holder, name it explicitly; else fall back to the detected reason.
if [ "$KA_ACTIVE" = "1" ] && [ "$SLEEP_DISABLED" != "1" ]; then
    KEEP_WHY="caffeinate enabled"
else
    KEEP_WHY="$STAY_WHY"
fi

# ============================================================================
# Decide the mode. Idle sleep is the dominant constraint: closed-display
# (clamshell) mode only protects the lid-close path, NOT the idle timer, so it
# never makes the Mac "stay awake" on its own — only a permanent holder, a disabled
# sleep timer, or system-wide disablesleep, i.e. STAY_WHY, does.
#   kept awake (STAY_WHY set):
#     lid open AND closing it would sleep -> C (the lid is the one thing that
#                                            would sleep it) ; else -> A
#   not kept awake -> B (idle-sleeps after IDLE_SLEEP min, regardless of the lid
#                        or clamshell state)
# ============================================================================
MODE=""
AWAKE_WHY=""   # reason phrase for the Mode A "keep running" line

if [ -n "$STAY_WHY" ]; then
    if [ "$HAS_LID" = "yes" ] && [ "$LID" = "No" ] && [ "$CLAM_SLEEP" = "Yes" ]; then
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
        # Lid note only applies to devices with a lid. A lid that would sleep is
        # classified as Mode C, so in Mode A the lid is always clamshell-safe:
        # open -> a forward-looking note, closed -> confirm it's running with the
        # lid shut. A lidless desktop gets no lid line at all.
        if [ "$HAS_LID" = "yes" ]; then
            if [ "$LID" = "No" ]; then
                REASON="$REASON
🟢 Closing the lid also keeps it running"
            else
                REASON="$REASON
🟢 Running with the lid closed"
            fi
        fi
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

# Staying awake (Mode A/C) on battery drains it — warn that it will sleep once empty.
if { [ "$MODE" = "A" ] || [ "$MODE" = "C" ]; } && [ "$SRC" = "BATT" ]; then
    REASON="$REASON
🔋 The battery may run out"
fi

echo "---"
echo "$REASON"

# ============================================================================
# Info section — neutral state, same set in every mode
# ============================================================================
echo "---"
# Power line is only meaningful with a battery; a batteryless desktop is always on
# AC and power then has no bearing on sleep, so we omit it entirely. The arch tag
# rides along here because it only matters for the (lid-bound) clamshell rule.
if [ "$HAS_BATTERY" = "yes" ]; then
    echo "Power: $([ "$SRC" = "AC" ] && echo "AC" || echo "Battery") ($ARCH)"
fi
if [ "$EXT_DISPLAY" = "yes" ]; then
    echo "External display: ${EXT_NAMES:-connected}"
else
    echo "No external display"
fi
echo "System-wide disablesleep: $([ "$SLEEP_DISABLED" = "1" ] && echo "On" || echo "Off")"
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
# Keep-awake controls. Two levers, each for a different need:
#   caffeinate   — light, user-level, no admin; blocks idle sleep. Effective on AC
#                  (and battery with the lid open), but NOT battery + lid closed.
#   disablesleep — the kernel master switch; the only thing that holds on battery in
#                  clamshell. Needs admin (osascript prompts), is global, and never
#                  lets the Mac sleep until you turn it back off — so use sparingly.
# ============================================================================
echo "---"
if [ "$KA_ACTIVE" = "1" ]; then
    echo "☕ Turn off caffeinate | shell=\"$SELF\" param1=off terminal=false refresh=true"
else
    echo "💤 Turn on caffeinate | shell=\"$SELF\" param1=on terminal=false refresh=true"
fi
if [ "$SLEEP_DISABLED" = "1" ]; then
    echo "🛡️ Turn off system-wide disablesleep | shell=\"$SELF\" param1=disablesleep-off terminal=false refresh=true"
else
    echo "🛡️ Force system-wide disablesleep | shell=\"$SELF\" param1=disablesleep-on terminal=false refresh=true"
fi

# ============================================================================
# Extra actions
# ============================================================================
echo "---"
# The pane is "Battery" on laptops but "Energy Saver" on batteryless desktops.
# Battery uses the modern settings-extension anchor; Energy Saver keeps the legacy
# prefpane identifier (System Settings still maps it). The desktop anchor is from a
# community reference, not verified on desktop hardware here.
if [ "$HAS_BATTERY" = "yes" ]; then
    echo "Open Battery Settings | shell=open param1=x-apple.systempreferences:com.apple.Battery-Settings.extension terminal=false"
else
    echo "Open Energy Saver Settings | shell=open param1=x-apple.systempreferences:com.apple.preferences.EnergySaverPrefPane terminal=false"
fi
echo "Full pmset assertions | shell=/usr/bin/pmset param1=-g param2=assertions terminal=true"
