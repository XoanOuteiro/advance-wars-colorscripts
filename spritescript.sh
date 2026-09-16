#!/bin/sh
# spritescript.sh - print a sprite colorscript, or play an animated one.
#
# Picks an asset set by ASKING the terminal what it supports, not by matching
# $TERM_PROGRAM against a list of names. Two queries go out in one write:
#
#   kitty graphics:  ESC _ G i=31,s=1,v=1,a=q,t=d,f=24;AAAA ESC \
#                    -> ESC _ G i=31;OK ESC \      (silently eaten otherwise)
#   XTVERSION:       ESC [ > q      -> DCS > | <name> ESC \
#   DA1:             ESC [ c        -> CSI ? 62;4;... c   (a 4 means sixel)
#
# DA1 is answered by everything, so its reply is what tells us the read is
# done - no fixed timeout waiting on terminals that ignore the other two.
#
# The result is cached; you do not want three round trips on every shell start.
#
# Sprites are named <army>-<unit>: orange-star-recon, black-hole-megatank.
# A bare unit name means "that unit, any army".
#
# Usage:
#   spritescript.sh                 random sprite
#   spritescript.sh -n recon        a recon, random army
#   spritescript.sh -n blue-moon-sub  that exact sprite
#   spritescript.sh --army blue-moon  pin the army (random unit)
#   spritescript.sh -r battle       the big battle art instead of map sprites
#   spritescript.sh -r gba          the AW1-era battle art (Orange Star only)
#   spritescript.sh -d some/dir     any asset root you like
#   spritescript.sh -a [name]       play an animation (Ctrl-C to stop)
#   spritescript.sh -l              list what is available
#   spritescript.sh --probe         print the asset set and directory, then exit
#
# Env:
#   SPRITESCRIPT_DIR      asset root (default: assets/ next to the script).
#                         -r and -d override it.
#   SPRITESCRIPT_ARMY     orange-star|blue-moon|green-earth|yellow-comet|
#                         black-hole - restrict random picks to one army
#   SPRITESCRIPT_SET      force kitty|iterm|sixel|blocks|wide
#   SPRITESCRIPT_BLOCKS   which block set the "blocks" answer means:
#                         wide (default, no glyphs so no subpixel fringing)
#                         or hybrid (narrower, some glyphs)
#   SPRITESCRIPT_NO_CACHE non-empty to re-probe every time

BASE=$(dirname "$0")
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/spritescript"

# Whether *the script's* stdout is a terminal, decided out here. Inside a
# command substitution stdout is a pipe, so -t 1 would always say no.
if [ -t 1 ]; then STDOUT_TTY=1; else STDOUT_TTY=; fi

# ------------------------------------------------------------------- probing

probe_terminal() {
    # Output is going to a file or a pipe, or there is no controlling
    # terminal: nothing to ask, and graphics escapes would be wrong anyway.
    [ -n "$STDOUT_TTY" ] || { echo blocks; return; }
    { [ -r /dev/tty ] && [ -w /dev/tty ]; } || { echo blocks; return; }
    command -v stty >/dev/null 2>&1 || { echo blocks; return; }

    saved=$(stty -g < /dev/tty 2>/dev/null) || { echo blocks; return; }
    # min 0 time 4: a read returns after 0.4s even with nothing pending, and a
    # zero-length read is what stops dd. No shell-specific `read -t` needed.
    stty raw -echo min 0 time 4 < /dev/tty 2>/dev/null || { echo blocks; return; }

    printf '\033_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\033\\\033[>q\033[c' > /dev/tty
    resp=$(dd bs=1 count=512 < /dev/tty 2>/dev/null | tr -d '\000' | tr '\033' '@')

    stty "$saved" < /dev/tty 2>/dev/null

    case "$resp" in
        *'_Gi=31;OK'*) echo kitty; return ;;
    esac
    case "$resp" in
        *iTerm2*) echo iterm; return ;;
    esac
    # Sixel is capability 4 in the DA1 attribute list.
    case "$resp" in
        *';4;'*|*';4c'*|*'?4;'*|*'?4c'*) echo sixel; return ;;
    esac
    echo blocks
}

cached_set() {
    [ -n "$SPRITESCRIPT_NO_CACHE" ] && { probe_terminal; return; }
    # TERM/TERM_PROGRAM are only a cache key here - the answer still comes
    # from the probe, so a terminal that lies about its name cannot mislead us.
    key=$(printf '%s' "${TERM}_${TERM_PROGRAM}_${TERM_PROGRAM_VERSION}" \
          | tr -c 'A-Za-z0-9._-' '_')
    cache="$CACHE_DIR/set-$key"
    if [ -r "$cache" ]; then
        cat "$cache"
        return
    fi
    result=$(probe_terminal)
    if mkdir -p "$CACHE_DIR" 2>/dev/null; then
        printf '%s\n' "$result" > "$cache" 2>/dev/null
    fi
    printf '%s\n' "$result"
}

# Map an asset set to a directory, falling back through what actually exists.
resolve_dir() {
    want=$1
    [ "$want" = blocks ] && want="${SPRITESCRIPT_BLOCKS:-wide}"
    case "$want" in
        hybrid|half) want="blocks hybrid" ;;   # blocks/ is the hybrid set
        wide)        want="wide blocks hybrid" ;;
    esac
    # Fall back only to glyph sets. Never fall *up* into a graphics protocol
    # the terminal did not claim - that prints raw escape garbage.
    # shellcheck disable=SC2086
    for d in $want wide blocks hybrid; do
        [ -d "$DIR/$d" ] && { echo "$DIR/$d"; return; }
    done
    echo "$DIR"  # flat layout
}

# ------------------------------------------------------------------ playback

random_of() {
    # POSIX-safe random pick without shuf/gshuf. A bare srand() seeds from the
    # time of day in *seconds*, so two runs in the same second pick the same
    # sprite; re-seeding with the pid mixed in decorrelates them.
    [ "$#" -gt 0 ] || return 1
    n=$(awk -v n="$#" -v pid="$$" \
        'BEGIN{srand(); srand(int(rand()*100000)+pid); print int(rand()*n)+1}')
    eval "printf '%s\n' \"\${$n}\""
}

play_anim() {
    d=$1
    [ -r "$d/meta" ] || { echo "no meta in $d" >&2; exit 1; }
    rows=$(sed -n 's/^rows=//p' "$d/meta")
    secs=$(sed -n 's/^delays=//p' "$d/meta" \
           | awk -F, '{for(i=1;i<=NF;i++) printf "%.3f ", $i/1000}')
    [ -n "$rows" ] || rows=1

    printf '\033[?25l'
    trap 'printf "\033[?25h"; exit 0' INT TERM HUP
    first=1
    while :; do
        # shellcheck disable=SC2086
        set -- $secs
        for f in "$d"/frame-*.txt; do
            # Back up *before* drawing, not after, so an interrupt always
            # leaves the cursor below the art instead of on top of it.
            [ -n "$first" ] || printf '\033[%dA' "$rows"
            first=
            cat "$f"
            sleep "${1:-0.1}"
            [ "$#" -gt 0 ] && shift
        done
    done
}

# ------------------------------------------------------------------- picking

# Every asset is named <army>-<unit>. These two turn what the user asked for
# into a list of candidate paths, which random_of then picks from: one exact
# hit stays one candidate, a bare unit name fans out to every army, and no
# name at all fans out to everything the pinned army has.

still_candidates() {
    if [ -n "$NAME" ]; then
        [ -r "$SRC/$NAME.txt" ] && { printf '%s\n' "$SRC/$NAME.txt"; return; }
        if [ -n "$ARMY" ]; then set -- "$SRC/$ARMY-$NAME.txt"
        else set -- "$SRC"/*-"$NAME".txt; fi
    elif [ -n "$ARMY" ]; then
        set -- "$SRC/$ARMY"-*.txt
    else
        set -- "$SRC"/*.txt
    fi
    for f do [ -e "$f" ] && printf '%s\n' "$f"; done
}

anim_candidates() {
    if [ -n "$NAME" ]; then
        [ -d "$SRC/anim/$NAME" ] && { printf '%s\n' "$SRC/anim/$NAME"; return; }
        if [ -n "$ARMY" ]; then set -- "$SRC/anim/$ARMY-$NAME"
        else set -- "$SRC"/anim/*-"$NAME"; fi
    elif [ -n "$ARMY" ]; then
        set -- "$SRC/anim/$ARMY"-*
    else
        set -- "$SRC"/anim/*
    fi
    for d do [ -d "$d" ] && printf '%s\n' "$d"; done
}

# ---------------------------------------------------------------------- main

MODE=still
NAME=""
ARMY="${SPRITESCRIPT_ARMY:-}"
SET="${SPRITESCRIPT_SET:-}"
DIR=""
ROOT=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        -a|--animate) MODE=anim; [ -n "$2" ] && case "$2" in -*) ;; *) NAME=$2; shift ;; esac ;;
        -n|--name) NAME=$2; shift ;;
        --army) ARMY=$2; shift ;;
        -r|--root) ROOT=$2; shift ;;
        -d|--dir) DIR=$2; shift ;;
        -l|--list) MODE=list ;;
        -s|--set) SET=$2; shift ;;
        --probe) MODE=probe ;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

# Which asset root. --dir wins, then --root, then the environment, then the
# assets/ a clone ships; a flat directory of .txt files next to the script is
# still a valid root, which is the last fallback.
if [ -z "$DIR" ]; then
    if [ -n "$ROOT" ]; then
        case "$ROOT" in
            map|"") DIR="$BASE/assets" ;;
            *)      DIR="$BASE/assets-$ROOT" ;;
        esac
        [ -d "$DIR" ] || { echo "no such root: $ROOT (looked in $DIR)" >&2; exit 1; }
    elif [ -n "$SPRITESCRIPT_DIR" ]; then
        DIR="$SPRITESCRIPT_DIR"
    elif [ -d "$BASE/assets" ]; then
        DIR="$BASE/assets"
    else
        DIR="$BASE"
    fi
fi
[ -d "$DIR" ] || { echo "no such asset directory: $DIR" >&2; exit 1; }

[ -n "$SET" ] || SET=$(cached_set)

if [ "$MODE" = probe ]; then
    printf '%s\t%s\n' "$SET" "$(resolve_dir "$SET")"
    exit 0
fi

SRC=$(resolve_dir "$SET")

if [ "$MODE" = list ]; then
    still_candidates | while read -r f; do
        b=${f##*/}; b=${b%.txt}
        if [ -d "$SRC/anim/$b" ]; then printf '%s\t(animated)\n' "$b"
        else printf '%s\n' "$b"; fi
    done
    exit 0
fi

if [ "$MODE" = anim ]; then
    # shellcheck disable=SC2046
    set -- $(anim_candidates)
    [ "$#" -gt 0 ] || { echo "no animation for: ${NAME:-any}${ARMY:+ ($ARMY)}" >&2; exit 1; }
    play_anim "$(random_of "$@")"
    exit 0
fi

# shellcheck disable=SC2046
set -- $(still_candidates)
[ "$#" -gt 0 ] || { echo "no sprite for: ${NAME:-any}${ARMY:+ ($ARMY)}" >&2; exit 1; }
cat "$(random_of "$@")"
