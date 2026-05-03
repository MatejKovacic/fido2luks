#!/bin/sh

cleanup () {
    rm -f "$ASSERT_PARAMS" "$LUKS_TOKEN" "$LUKS_TOKEN_LIST" \
          "${FIDO2_OUT:-}" "${FIDO2_ERR:-}" "${FIDO2_ERR_FILTERED:-}" "${FIDO2_PIN:-}"
}

ASSERT_PARAMS=$(mktemp -t params.XXXXXX)
LUKS_TOKEN_LIST=$(mktemp -t tokenlist.XXXXXX)
LUKS_TOKEN=$(mktemp -t token.XXXXXX)
trap cleanup INT EXIT

# Enable technical/debug messages shown via Plymouth and text console.
# Set to 1 while testing. After everything works reliably, you can set this back to 0.
FIDO2LUKS_DEBUG=${FIDO2LUKS_DEBUG:-1}

# Language for user-facing messages: en, sl.
FIDO2LUKS_LANG=${FIDO2LUKS_LANG:-en}

# How long to wait for the FIDO2 USB key to appear during initramfs boot.
FIDO2LUKS_WAIT_SECONDS=${FIDO2LUKS_WAIT_SECONDS:-20}

plymouth_available () {
    command -v plymouth >/dev/null 2>&1 && plymouth --ping >/dev/null 2>&1
}

msg_text () {
    _msg_id=$1
    _arg1=${2:-}

    case "$FIDO2LUKS_LANG:$_msg_id" in
        sl:waiting_key)
            printf '%s\n' "Čakam na varnostni USB ključ..." ;;
        *:waiting_key)
            printf '%s\n' "Waiting for the security USB key..." ;;

        sl:no_key)
            printf '%s\n' "Varnostnega USB ključa ni bilo mogoče najti!" ;;
        *:no_key)
            printf '%s\n' "No security USB key found!" ;;

        sl:pin_prompt)
            printf '%s\n' "Vnesite PIN za varnostni USB ključ" ;;
        *:pin_prompt)
            printf '%s\n' "Enter PIN for security USB key" ;;

        sl:touch_hint)
            cat <<EOF
Potrdite svojo prisotnost.
Dotaknite se varnostnega USB ključa ZDAJ.
EOF
            ;;

        *:touch_hint)
            cat <<EOF
Please confirm your presence.
Touch the security USB key NOW.
EOF
            ;;

        sl:touch_countdown)
            cat <<EOF
Potrdite svojo prisotnost.
Dotaknite se varnostnega USB ključa ZDAJ.

Prehod na obnovitveno šifrirno geslo čez ${_arg1}s.
EOF
            ;;

        *:touch_countdown)
            cat <<EOF
Please confirm your presence.
Touch the security USB key NOW.

Falling back to recovery encryption passphrase in ${_arg1}s.
EOF
            ;;

        sl:touch_timeout)
            cat <<EOF
Varnostnega ključa se niste pravočasno dotaknili.
Znova vstavite ključ in ponovno zaženite računalnik,
ali vnesite obnovitveno šifrirno geslo.
EOF
            ;;

        *:touch_timeout)
            cat <<EOF
Security key was not touched in time.
Reinsert the key and reboot computer to retry,
or enter recovery encryption passphrase.
EOF
            ;;

        sl:console_pin_touch)
            cat <<EOF
Vnesite PIN za varnostni USB ključ, pritisnite Enter,
nato se dotaknite varnostnega USB ključa za potrditev prisotnosti.
EOF
            ;;

        *:console_pin_touch)
            cat <<EOF
Enter PIN for your security USB key, press Enter,
then touch the security USB key to confirm your presence.
EOF
            ;;

        sl:fido_failed)
            cat <<EOF
Odklepanje diska z varnostnim USB ključem ni uspelo.
Znova vstavite ključ in ponovno zaženite računalnik,
ali vnesite obnovitveno šifrirno geslo.
EOF
            ;;

        *:fido_failed)
            cat <<EOF
Unlocking disk with security USB key failed.
Reinsert the key and reboot computer to retry,
or enter recovery encryption passphrase.
EOF
            ;;

        sl:passphrase_fallback)
            printf '%s\n' "Odklepanje diska z obnovitvenim šifrirnim geslom" ;;
        *:passphrase_fallback)
            printf '%s\n' "Unlocking disk using a recovery encryption passphrase" ;;

        sl:passphrase_prompt)
            printf '%s\n' "Vnesite obnovitveno šifrirno geslo: " ;;
        *:passphrase_prompt)
            printf '%s\n' "Enter recovery encryption passphrase: " ;;
    esac
}

plymouth_message () {
    echo "*** $*" >&2
    if plymouth_available; then
        plymouth display-message --text="$*" >/dev/null 2>&1 || true
    fi
}

debug_message () {
    if [ "$FIDO2LUKS_DEBUG" = "1" ]; then
        plymouth_message "DEBUG: $*"
    fi
}

plymouth_touch_hint () {
    if [ "$REQ_UP" = "true" ]; then
        plymouth_message "$(msg_text touch_hint)"
    fi
}

try_fido2_unlock () {
    debug_message "Starting FIDO2 LUKS unlock"
    debug_message "CRYPTTAB_SOURCE=$CRYPTTAB_SOURCE"
    debug_message "PATH=$PATH"
    debug_message "cryptsetup path=$(command -v cryptsetup || echo missing)"
    debug_message "jq path=$(command -v jq || echo missing)"
    debug_message "fido2-token path=$(command -v fido2-token || echo missing)"
    debug_message "fido2-assert path=$(command -v fido2-assert || echo missing)"

    if [ -z "$CRYPTTAB_SOURCE" ]; then
        debug_message "CRYPTTAB_SOURCE is empty"
        return 1
    fi

    # Read FIDO2 tokens from the LUKS2 header.
    # Important: ignore orphaned tokens with empty keyslots.
    if ! cryptsetup luksDump --dump-json-metadata "$CRYPTTAB_SOURCE" | \
            jq -e '[.tokens[]
                    | select(."fido2-credential" != null)
                    | select((.keyslots // []) | length > 0)]
                   | sort_by(."fido2-uv-required")' > "$LUKS_TOKEN_LIST"; then
        debug_message "Error reading usable FIDO2 tokens from LUKS header: $CRYPTTAB_SOURCE"
        return 1
    fi

    NTOKENS=$(jq length "$LUKS_TOKEN_LIST")
    debug_message "Found $NTOKENS usable FIDO2 LUKS token(s)"

    if [ -z "$NTOKENS" ] || [ "$NTOKENS" = "0" ]; then
        debug_message "No usable FIDO2 credentials found in $CRYPTTAB_SOURCE"
        return 1
    fi

    # Wait for FIDO2 authenticator.
    plymouth_message "$(msg_text waiting_key)"

    FIDO2_AUTHENTICATOR=""
    _i=0
    while [ "$_i" -lt "$FIDO2LUKS_WAIT_SECONDS" ]; do
        FIDO2_AUTHENTICATOR=$(fido2-token -L 2>/dev/null)
        debug_message "fido2-token -L attempt $_i returned: $FIDO2_AUTHENTICATOR"

        if [ -n "$FIDO2_AUTHENTICATOR" ]; then
            break
        fi

        _i=$((_i + 1))
        sleep 1
    done

    if [ -z "$FIDO2_AUTHENTICATOR" ]; then
        plymouth_message "$(msg_text no_key)"
        return 1
    fi

    FIDO2_DEV=${FIDO2_AUTHENTICATOR%%:*}
    debug_message "Using FIDO2 authenticator: $FIDO2_AUTHENTICATOR"
    debug_message "Using FIDO2 device: $FIDO2_DEV"

    # Use the first usable token.
    # This avoids the old silent pre-check path which could interact badly
    # with PIN-required credentials.
    jq ".[0]" "$LUKS_TOKEN_LIST" > "$LUKS_TOKEN"

    jq -r '"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
           ."fido2-rp",
           ."fido2-credential",
           ."fido2-salt"' "$LUKS_TOKEN" > "$ASSERT_PARAMS"

    REQ_UV=$(jq -r '."fido2-uv-required"' "$LUKS_TOKEN")
    REQ_PIN=$(jq -r '."fido2-clientPin-required"' "$LUKS_TOKEN")
    REQ_UP=$(jq -r '."fido2-up-required"' "$LUKS_TOKEN")

    if [ "$REQ_UV" = "true" ]; then
        UV_OPT="-t uv=true"
    else
        UV_OPT=""
    fi

    debug_message "Selected FIDO2 token: pin=$REQ_PIN up=$REQ_UP uv=$REQ_UV dev=$FIDO2_DEV"

    if [ "$REQ_PIN" = "true" ] && plymouth_available; then
        PIN=$(plymouth ask-for-password --prompt="$(msg_text pin_prompt)")

        FIDO2_OUT=$(mktemp -t fido2out.XXXXXX)
        FIDO2_ERR=$(mktemp -t fido2err.XXXXXX)
        FIDO2_ERR_FILTERED=$(mktemp -t fido2err-filtered.XXXXXX)
        FIDO2_PIN=$(mktemp -t fido2pin.XXXXXX)

        chmod 600 "$FIDO2_PIN" 2>/dev/null || true
        printf "%s\n" "$PIN" > "$FIDO2_PIN"
        PIN=""

        setsid fido2-assert \
            -G -h -t up="$REQ_UP" -t pin="$REQ_PIN" $UV_OPT \
            -i "$ASSERT_PARAMS" "$FIDO2_DEV" \
            < "$FIDO2_PIN" > "$FIDO2_OUT" 2> "$FIDO2_ERR" &

        FIDO2_PID=$!

        if [ "$REQ_UP" = "true" ]; then
            for _seconds in 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1; do
                if ! kill -0 "$FIDO2_PID" 2>/dev/null; then
                    break
                fi
                plymouth_message "$(msg_text touch_countdown "$_seconds")"
                sleep 1
            done
        fi

        if kill -0 "$FIDO2_PID" 2>/dev/null; then
            kill "$FIDO2_PID" 2>/dev/null || true
            wait "$FIDO2_PID" 2>/dev/null || true
            plymouth_message "$(msg_text touch_timeout)"
            sleep 5
            SECRET=""
        else
            wait "$FIDO2_PID" 2>/dev/null || true
            SECRET=$(tail -n 1 "$FIDO2_OUT")
        fi

        if [ -z "$SECRET" ] && [ -s "$FIDO2_ERR" ]; then
            grep -v "^Enter PIN for " "$FIDO2_ERR" > "$FIDO2_ERR_FILTERED" || true
            if [ -s "$FIDO2_ERR_FILTERED" ]; then
                debug_message "$(tail -n 1 "$FIDO2_ERR_FILTERED")"
                sleep 3
            fi
        fi

        rm -f "$FIDO2_OUT" "$FIDO2_ERR" "$FIDO2_ERR_FILTERED" "$FIDO2_PIN"

    else
        if [ "$REQ_PIN" = "true" ]; then
            plymouth_message "$(msg_text console_pin_touch)"
            stty -echo 2>/dev/null || true
        elif [ "$REQ_UP" = "true" ]; then
            plymouth_touch_hint
        fi

        SECRET=$(fido2-assert \
                    -G -h -t up="$REQ_UP" -t pin="$REQ_PIN" $UV_OPT \
                    -i "$ASSERT_PARAMS" "$FIDO2_DEV" | tail -n 1)

        if [ "$REQ_PIN" = "true" ]; then
            stty echo 2>/dev/null || true
            echo >&2
        fi
    fi

    if [ -z "$SECRET" ]; then
        plymouth_message "$(msg_text fido_failed)"
        sleep 5
        return 1
    fi

    echo >&2
    printf "%s" "$SECRET"
    return 0
}

if try_fido2_unlock; then
    exit 0
fi

plymouth_message "$(msg_text passphrase_fallback)"
/lib/cryptsetup/askpass "$(msg_text passphrase_prompt)"
