#!/bin/bash
# Stable local code-signing identity for development builds.
#
# Ad-hoc signatures pin macOS privacy grants (screen, camera, microphone) to the
# code hash, so every code-changing rebuild silently revokes them. A persistent
# self-signed certificate makes the designated requirement
#   identifier "dev.sapunov.FocusRecorder" and certificate leaf = H"<sha1>"
# which stays identical across rebuilds. The certificate is not trusted system-wide
# and is not a distribution signature; it only gives local builds a stable identity.
#
# The identity lives in its own keychain outside the synced workspace. The login
# keychain and system trust settings are never modified.
#
# Sourced by build-app.sh. Defines focus_sign <bundle> <entitlements>.

SIGNING_DIR="${REKORD_SIGNING_DIR:-${FOCUS_SIGNING_DIR:-$HOME/Library/Application Support/Rekord/signing}}"
LEGACY_SIGNING_DIR="$HOME/Library/Application Support/Focus Recorder/signing"
# Identity created before the rename: move it, so the certificate (and with it the privacy grants) stays the same.
if [[ ! -d "$SIGNING_DIR" && -d "$LEGACY_SIGNING_DIR" ]]; then
    mkdir -p "$(dirname "$SIGNING_DIR")" && mv "$LEGACY_SIGNING_DIR" "$SIGNING_DIR"
    [[ -f "$SIGNING_DIR/focus-recorder-signing.keychain-db" ]] && mv "$SIGNING_DIR/focus-recorder-signing.keychain-db" "$SIGNING_DIR/rekord-signing.keychain-db"
fi
SIGNING_KEYCHAIN="$SIGNING_DIR/rekord-signing.keychain-db"
SIGNING_PASSWORD_FILE="$SIGNING_DIR/keychain-password"
SIGNING_HASH_FILE="$SIGNING_DIR/identity-sha1"
BUNDLE_ID="dev.sapunov.FocusRecorder"

focus_create_identity() {
    mkdir -p "$SIGNING_DIR"
    chmod 700 "$SIGNING_DIR"
    local work
    work="$(mktemp -d)"
    cat > "$work/cert.cnf" <<'EOF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Rekord Local Development
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
    openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -config "$work/cert.cnf" \
        -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
    local transfer
    transfer="$(openssl rand -hex 16)"
    # macOS `security` only reads PKCS#12 with legacy algorithms.
    openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" \
        -out "$work/identity.p12" -passout "pass:$transfer" 2>/dev/null \
      || openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
        -out "$work/identity.p12" -passout "pass:$transfer"
    (umask 077; openssl rand -hex 24 > "$SIGNING_PASSWORD_FILE")
    local password
    password="$(cat "$SIGNING_PASSWORD_FILE")"
    rm -f "$SIGNING_KEYCHAIN"
    security create-keychain -p "$password" "$SIGNING_KEYCHAIN"
    security set-keychain-settings "$SIGNING_KEYCHAIN"   # no auto-lock timeout
    security unlock-keychain -p "$password" "$SIGNING_KEYCHAIN"
    security import "$work/identity.p12" -k "$SIGNING_KEYCHAIN" -P "$transfer" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$SIGNING_KEYCHAIN" >/dev/null
    openssl x509 -in "$work/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d : > "$SIGNING_HASH_FILE"
    chmod 600 "$SIGNING_KEYCHAIN"
    rm -rf "$work"
    echo "Created local signing identity $(cat "$SIGNING_HASH_FILE") in $SIGNING_DIR"
}

focus_sign() {
    local app="$1" entitlements="$2"
    # Helper executables inside Contents/MacOS (e.g. the MCP server) are signed first, as nested code.
    local helpers=()
    for helper in "$app"/Contents/MacOS/*; do [[ "$(basename "$helper")" != "Rekord" ]] && helpers+=("$helper"); done
    if [[ "${REKORD_SIGNING:-${FOCUS_SIGNING:-stable}}" == "adhoc" ]]; then
        for helper in "${helpers[@]}"; do codesign --force --sign - --identifier "$BUNDLE_ID.$(basename "$helper")" "$helper"; done
        codesign --force --sign - --identifier "$BUNDLE_ID" --entitlements "$entitlements" "$app"
        return
    fi
    if [[ ! -f "$SIGNING_KEYCHAIN" || ! -s "$SIGNING_HASH_FILE" || ! -s "$SIGNING_PASSWORD_FILE" ]]; then
        focus_create_identity
    fi
    local hash password original=()
    hash="$(cat "$SIGNING_HASH_FILE")"
    password="$(cat "$SIGNING_PASSWORD_FILE")"
    security unlock-keychain -p "$password" "$SIGNING_KEYCHAIN"
    # codesign resolves identities only through the keychain search list. Add the
    # signing keychain for this one call and restore the user's list afterwards.
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
        [[ -n "$line" ]] && original+=("$line")
    done < <(security list-keychains -d user)
    security list-keychains -d user -s "${original[@]}" "$SIGNING_KEYCHAIN"
    local status=0
    for helper in "${helpers[@]}"; do
        codesign --force --sign "$hash" --identifier "$BUNDLE_ID.$(basename "$helper")" --timestamp=none "$helper" || status=$?
    done
    codesign --force --sign "$hash" --identifier "$BUNDLE_ID" --timestamp=none \
        --entitlements "$entitlements" "$app" || status=$?
    security list-keychains -d user -s "${original[@]}"
    return $status
}
