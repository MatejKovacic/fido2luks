#!/bin/sh

cleanup () {
    rm -f "$ASSERT_PARAMS" "$LUKS_TOKEN" "$LUKS_TOKEN_LIST" \
          "${FIDO2_OUT:-}" "${FIDO2_ERR:-}" "${FIDO2_ERR_FILTERED:-}" "${FIDO2_PIN:-}"
}

ASSERT_PARAMS=$(mktemp -t params.XXXXXX)
LUKS_TOKEN_LIST=$(mktemp -t tokenlist.XXXXXX)
LUKS_TOKEN=$(mktemp -t token.XXXXXX)
trap cleanup INT EXIT

# Enable or disable technical/debug messages shown via Plymouth (and in text mode).
# Default is 0 so normal users see only human-readable recovery messages.
FIDO2LUKS_DEBUG=${FIDO2LUKS_DEBUG:-1}

# Language for user-facing messages: en, sl.
# Default is English unless explicitly changed in this script or environment.
FIDO2LUKS_LANG=${FIDO2LUKS_LANG:-en}

# Return success only when the Plymouth client exists and
# the Plymouth daemon is currently running in the initramfs.
plymouth_available () {
    command -v plymouth >/dev/null 2>&1 && plymouth --ping >/dev/null 2>&1
}

# Translate user-facing messages. Keep technical/debug strings outside this
# function so they remain useful for troubleshooting and upstream reports.
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

# Print a status message to the text console as before, and
# also mirror it to Plymouth when Plymouth is available.
plymouth_message () {
    echo "*** $*" >&2
    if plymouth_available; then
        plymouth display-message --text="$*" >/dev/null 2>&1 || true
    fi
}

# Print technical/debug messages only when FIDO2LUKS_DEBUG=1.
# Human-readable recovery messages should use plymouth_message directly.
debug_message () {
    if [ "$FIDO2LUKS_DEBUG" = "1" ]; then
        plymouth_message "$@"
    fi
}

# Show an explicit hint for the required physical touch step.
# This is especially useful with graphical Plymouth themes,
# because the FIDO2 authenticator itself gives no text prompt.
plymouth_touch_hint () {
    if [ "$REQ_UP" = "true" ]; then
        plymouth_message "$(msg_text touch_hint)"
    fi
}

try_fido2_unlock () {
    # Get all tokens from the LUKS header with FIDO2 credentials.
    # Sort the array, placing entries with "fido2-uv-required: true" at the end.
    if ! cryptsetup luksDump --dump-json-metadata "$CRYPTTAB_SOURCE" | \
            jq -e '[.tokens[] | select(."fido2-credential" != null)] | sort_by(."fido2-uv-required")' > "$LUKS_TOKEN_LIST"; then
        debug_message "Error reading LUKS header in $CRYPTTAB_SOURCE"
        return 1
    fi

    # Count how many tokens we have.
    NTOKENS=$(jq length "$LUKS_TOKEN_LIST")
    if [ -z "$NTOKENS" ] || [ "$NTOKENS" = "0" ]; then
        debug_message "No FIDO2 credentials found in $CRYPTTAB_SOURCE"
        return 1
    fi

    # Check if the FIDO2 authenticator is inserted
    plymouth_message "$(msg_text waiting_key)"
    for _f in $(seq 5); do
        FIDO2_AUTHENTICATOR=$(fido2-token -L)
        sleep 1
        [ -n "$FIDO2_AUTHENTICATOR" ] && break
    done

    if [ -z "$FIDO2_AUTHENTICATOR" ]; then
        plymouth_message "$(msg_text no_key)"
        return 1
    fi

    debug_message "Found FIDO2 authenticator $FIDO2_AUTHENTICATOR"
    FIDO2_DEV=${FIDO2_AUTHENTICATOR%%:*}

    # Look for a credential that is valid for the inserted FIDO2
    # authenticator. For that we try to get an assertion from the
    # device, with 'up' and 'pin' set to false, so it requires no user
    # interaction.
    for i in $(seq "$NTOKENS"); do
        jq ".[$i-1]" "$LUKS_TOKEN_LIST" > "$LUKS_TOKEN"
        jq -r '"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
               ."fido2-rp",
               ."fido2-credential",
               ."fido2-salt"' "$LUKS_TOKEN" > "$ASSERT_PARAMS"
        REQ_UV=$(jq -r '."fido2-uv-required"' "$LUKS_TOKEN")
        # If a credential has the 'uv' option set then unfortunately
        # we cannot check if it's valid for the inserted FIDO2
        # authenticator without requiring user interaction.
        # So this is what we do:
        # - The array of credentials is sorted, those that require UV
        #   are at the end.
        # - All credentials that don't require UV are tested first,
        #   we can do that silently with the fido2-assert call.
        # - Once we find a credential that requires UV we assume
        #   that we can use it with the inserted authenticator.
        # - Not all authenticators support 'uv' so pass '-t uv' only
        #   when needed using the UV_OPT variable.
        if [ "$REQ_UV" = "true" ]; then
            UV_OPT="-t uv=true"
            break
        else
            UV_OPT=""
            if fido2-assert -G -t up=false -t pin=false -i "$ASSERT_PARAMS" \
                            -o /dev/null "$FIDO2_DEV" 2> /dev/null; then
                break
            fi
        fi
        rm -f "$LUKS_TOKEN" "$ASSERT_PARAMS"
    done

    if [ ! -f "$LUKS_TOKEN" ] || [ ! -f "$ASSERT_PARAMS" ]; then
        debug_message "No valid credential found for this FIDO2 authenticator"
        return 1
    fi

    # Now that we have a valid credential use it to compute the
    # hmac-secret, which is what unlocks the LUKS volume.
    REQ_PIN=$(jq -r '."fido2-clientPin-required"' "$LUKS_TOKEN")
    REQ_UP=$(jq -r '."fido2-up-required"' "$LUKS_TOKEN")

    if [ "$REQ_PIN" = "true" ] && plymouth_available; then
        # When Plymouth is active, collect the FIDO2 PIN through
        # Plymouth's normal password dialog. This gives the user
        # a proper graphical input field instead of a hidden tty
        # prompt from fido2-assert.
        PIN=$(plymouth ask-for-password --prompt="$(msg_text pin_prompt)")

        # Capture fido2-assert output and errors separately so
        # Plymouth can show a live touch countdown and useful
        # error messages before falling back to the passphrase.
        FIDO2_OUT=$(mktemp -t fido2out.XXXXXX)
        FIDO2_ERR=$(mktemp -t fido2err.XXXXXX)
        FIDO2_ERR_FILTERED=$(mktemp -t fido2err-filtered.XXXXXX)
        FIDO2_PIN=$(mktemp -t fido2pin.XXXXXX)
        chmod 600 "$FIDO2_PIN" 2>/dev/null || true
        printf "%s\n" "$PIN" > "$FIDO2_PIN"

        # Clear the shell variable after writing the one-shot PIN
        # to the initramfs tmpfs file used as fido2-assert stdin.
        # This is not perfect memory erasure, but avoids keeping
        # the PIN around longer than necessary in the shell.
        PIN=""

        # fido2-assert uses /dev/tty for PIN entry when a tty is
        # available. Run it in a new session and feed stdin from
        # the PIN file. Do not use "setsid -w" because busybox
        # setsid in initramfs may not support it.
        setsid fido2-assert \
            -G -h -t up="$REQ_UP" -t pin="$REQ_PIN" $UV_OPT \
            -i "$ASSERT_PARAMS" "$FIDO2_DEV" \
            < "$FIDO2_PIN" > "$FIDO2_OUT" 2> "$FIDO2_ERR" &
        FIDO2_PID=$!

        # While fido2-assert waits for user presence, keep the
        # Plymouth screen informative. If the key is not touched
        # in time, fall back to the regular disk passphrase.
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
            # The touch prompt timed out. Stop fido2-assert so the
            # boot can proceed to the backup passphrase prompt.
            kill "$FIDO2_PID" 2>/dev/null || true
            wait "$FIDO2_PID" 2>/dev/null || true
            plymouth_message "$(msg_text touch_timeout)"
            sleep 5
            SECRET=""
        else
            wait "$FIDO2_PID" 2>/dev/null || true
            SECRET=$(tail -n 1 "$FIDO2_OUT")
        fi

        # fido2-assert still prints its own "Enter PIN for ..."
        # prompt even when the PIN is supplied on stdin. Filter
        # that duplicate prompt, but keep real errors visible.
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
            # Without Plymouth, keep the original console behavior
            # but make the expected touch step explicit.
            plymouth_message "$(msg_text console_pin_touch)"
            stty -echo
        elif [ "$REQ_UP" = "true" ]; then
            # If no PIN is required, the user may still need to touch
            # the authenticator. Make that visible in Plymouth.
            plymouth_touch_hint
        fi

        SECRET=$(fido2-assert -G -h -t up="$REQ_UP" -t pin="$REQ_PIN" $UV_OPT \
                              -i "$ASSERT_PARAMS" "$FIDO2_DEV" | tail -n 1)

        if [ "$REQ_PIN" = "true" ]; then
            stty echo
        fi
    fi

    if [ -z "$SECRET" ]; then
        # Show one combined recovery message so Plymouth themes
        # do not immediately overwrite earlier lines.
        plymouth_message "$(msg_text fido_failed)"

        # Give the user time to read the recovery instruction
        # before falling back to the regular passphrase prompt.
        sleep 5
        return 1
    fi

    echo >&2
    printf "%s" "$SECRET"
    return 0
}

# Main execution
if try_fido2_unlock; then
    exit 0
fi

plymouth_message "$(msg_text passphrase_fallback)"
/lib/cryptsetup/askpass "$(msg_text passphrase_prompt)"
