#!/bin/bash
#
# File:        secure_remail.sh
# Description: Hardened Type I remailer chainer with traffic padding and latency.
# License:     GPL3

set -e
set -o pipefail
umask 077 

# Dependencies check
command -v gpg2 >/dev/null 2>&1 || { echo >&2 "Error: gpg2 is required."; exit 1; }

PROGRAM=$(basename "$0")
DEBUG=0
ENCRYPT_MESSAGE=0
NO_ENCRYPT=0
SUBJECT=""

# Secure temporary directory
TEMP_DIR=$(mktemp -d -t remail.XXXXXX)
WORKDIR="$TEMP_DIR/payload"

trap 'cleanup' EXIT

function cleanup () {
    if [ -d "$TEMP_DIR" ]; then
        if [ $DEBUG -eq 0 ]; then
            if command -v shred >/dev/null 2>&1; then
                find "$TEMP_DIR" -type f -exec shred -u {} \;
            fi
            rm -rf "$TEMP_DIR"
        else
            echo "[DEBUG] Files preserved in: $TEMP_DIR"
        fi
    fi
}

function usage () {
    echo "Usage: $PROGRAM [options] <message_file> <recipient> <remailer_1> <remailer_2> <remailer_3> [remailer_N...]"
    echo
    echo "Options:"
    echo "  -e, --encrypt     Encrypt body to final recipient."
    echo "  -s, --subject <S> Set subject (hidden in envelope)."
    echo "  --debug           Enable debug output."
    echo
}

function get_random_latency () {
    # 0 to 6 hours delay
    local h=$((RANDOM % 6))
    local m=$((RANDOM % 60))
    printf "+%d:%02d" "$h" "$m"
}

function get_padding () {
    # 512 to 2048 bytes random padding
    local size=$(( 512 + RANDOM % 1536 ))
    local pad=$(head -c $size /dev/urandom | base64 | tr -d '\n')
    echo "##"
    echo "X-Padding: $pad"
}

# --- ARGUMENT PARSING ---

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--encrypt) ENCRYPT_MESSAGE=1; shift ;;
        -n|--no-encrypt) NO_ENCRYPT=1; shift ;;
        -s|--subject) SUBJECT="$2"; shift 2 ;;
        --debug) DEBUG=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) echo "Unknown option: $1"; usage; exit 1 ;;
        *) break ;;
    esac
done

# ENFORCE 3-HOP MINIMUM (Msg + Rcpt + 3 Remailers = 5 args)
if [ $# -lt 5 ]; then
    echo "Security Error: Minimum 3 remailers required for anonymity."
    usage
    exit 1
fi

MSG_FILE="$1"
FINAL_RCPT="$2"
shift 2

if [ ! -r "$MSG_FILE" ]; then
    echo "Error: Cannot read $MSG_FILE"
    exit 1
fi

# --- BUILD PAYLOAD ---

# 1. Construct Inner Message (Final Destination)
{
    echo "::"
    echo "Anon-To: $FINAL_RCPT"
    echo ""
    echo "##"
    [ -n "$SUBJECT" ] && echo "Subject: $SUBJECT"
    echo ""
    
    if [ "$ENCRYPT_MESSAGE" -eq 1 ]; then
        if ! gpg2 --encrypt --armor --trust-model always -r "$FINAL_RCPT" < "$MSG_FILE"; then
             echo "Error: GPG encryption to final recipient failed." >&2
             exit 1
        fi
    else
        cat "$MSG_FILE"
    fi
} > "$WORKDIR"

# 2. Build Onion Layers (Reverse Order)
for ((i=$#; i > 0; i--)); do
    CURRENT_HOP="${!i}"
    
    if [ $NO_ENCRYPT -eq 0 ]; then
         # Encrypt current payload for CURRENT_HOP
         gpg2 --encrypt --armor --trust-model always -r "$CURRENT_HOP" < "$WORKDIR" > "$WORKDIR.enc"
         mv "$WORKDIR.enc" "$WORKDIR"
         
         # Add headers for the node receiving this packet
         echo "::" > "$WORKDIR.header"
         echo "Encrypted: PGP" >> "$WORKDIR.header"
         echo "Latent-Time: $(get_random_latency)" >> "$WORKDIR.header"
         echo "" >> "$WORKDIR.header"
         
         cat "$WORKDIR.header" "$WORKDIR" > "$WORKDIR.temp"
         mv "$WORKDIR.temp" "$WORKDIR"
    fi
    
    # Prepend routing for previous hop (unless we are at the start)
    if [ $i -gt 1 ]; then
        {
            echo "::"
            echo "Anon-To: $CURRENT_HOP"
            get_padding 
            echo "" 
            cat "$WORKDIR"
        } > "$WORKDIR.next"
        mv "$WORKDIR.next" "$WORKDIR"
    fi
done

# --- OUTPUT ---

if [ $DEBUG -eq 1 ]; then
    echo "--- DEBUG: Chain complete. Send to: ${1} ---"
fi

cat "$WORKDIR"
