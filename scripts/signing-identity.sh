#!/bin/bash
# Prints the SHA-1 hash of the local self-signed code-signing identity that every NotchTheRock
# build signs with, creating it on first use. Signing with the same certificate every time keeps the
# app's designated requirement stable, so macOS privacy grants (Accessibility) survive rebuilds.
#
# Usage: scripts/signing-identity.sh [--find]
#   (no option)  create the identity when it is missing, then print its hash
#   --find       print the hash only when the identity already exists; exit 1 without output otherwise
#
# The identity lives in its own keychain with a generated password (both under SIGNING_DIR, mode
# 0700/0600) instead of the login keychain: codesign can then use the key without a GUI prompt,
# because the key partition list can be set with a password the script knows. The keychain is
# added to the user's keychain search list, which codesign needs to find the identity.
# Requires bash 3.2 or later and /usr/bin/openssl (LibreSSL, whose PKCS#12 `security` can import).
set -euo pipefail

COMMON_NAME="NotchTheRock Local Signing"
SIGNING_DIR="$HOME/Library/Application Support/NotchTheRock/Signing"
KEYCHAIN="$SIGNING_DIR/signing.keychain-db"
PASSWORD_FILE="$SIGNING_DIR/keychain-password"
RESET_HINT="'$SIGNING_DIR' 폴더를 지우고 다시 실행해 주세요."

fail() {
    printf 'signing-identity: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf '사용법: %s [--find]\n' "$0" >&2
    exit 2
}

mode=create
[ $# -le 1 ] || usage
case "${1-}" in
    "") ;;
    --find) mode=find ;;
    *) usage ;;
esac

# Adds the signing keychain to the user search list, keeping every existing entry and its order.
ensure_in_search_list() {
    local entries=() line
    while IFS= read -r line; do
        line=$(printf '%s' "$line" | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
        [ -n "$line" ] || continue
        [ "$line" = "$KEYCHAIN" ] && return 0
        entries+=("$line")
    done < <(security list-keychains -d user)
    security list-keychains -d user -s ${entries[@]+"${entries[@]}"} "$KEYCHAIN" \
        || fail "키체인 검색 목록에 서명 키체인을 추가하지 못했어요: $KEYCHAIN"
}

unlock_keychain() {
    [ -f "$PASSWORD_FILE" ] || fail "서명 키체인은 있는데 암호 파일이 없어요. $RESET_HINT"
    security unlock-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN" \
        || fail "서명 키체인을 열지 못했어요. $RESET_HINT"
}

# Prints the identity hash, or nothing when the keychain holds no identity with COMMON_NAME.
identity_hash() {
    security find-identity -p codesigning "$KEYCHAIN" \
        | awk -v name="\"$COMMON_NAME\"" 'index($0, name) { print $2; exit }'
}

create_keychain() {
    mkdir -p "$SIGNING_DIR"
    chmod 700 "$SIGNING_DIR"
    (umask 077 && /usr/bin/openssl rand -hex 24 | tr -d '\n' >"$PASSWORD_FILE")
    security create-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN" \
        || fail "서명 키체인을 만들지 못했어요: $KEYCHAIN"
    # No -t/-l options: the keychain does not lock itself after a timeout or on sleep.
    security set-keychain-settings "$KEYCHAIN" || fail "서명 키체인 설정을 바꾸지 못했어요: $KEYCHAIN"
}

import_identity() {
    local p12_password
    WORK_DIR=$(mktemp -d)
    trap 'rm -rf "$WORK_DIR"' EXIT
    cat >"$WORK_DIR/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = ext
[ dn ]
CN = $COMMON_NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -config "$WORK_DIR/cert.cnf" \
        -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" 2>/dev/null \
        || fail "자체 서명 인증서를 만들지 못했어요."
    p12_password=$(/usr/bin/openssl rand -hex 16)
    /usr/bin/openssl pkcs12 -export -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" -name "$COMMON_NAME" \
        -out "$WORK_DIR/identity.p12" -passout "pass:$p12_password" \
        || fail "인증서를 PKCS#12 파일로 묶지 못했어요."
    security import "$WORK_DIR/identity.p12" -k "$KEYCHAIN" -f pkcs12 -P "$p12_password" -T /usr/bin/codesign >/dev/null \
        || fail "서명 키체인에 인증서를 가져오지 못했어요: $KEYCHAIN"
    # Lets Apple tools (codesign) use the private key without asking.
    security set-key-partition-list -S apple-tool:,apple: -s -k "$(cat "$PASSWORD_FILE")" "$KEYCHAIN" >/dev/null \
        || fail "codesign이 서명 키를 쓰도록 허용하지 못했어요."
}

if [ ! -f "$KEYCHAIN" ]; then
    [ "$mode" = create ] || exit 1
    create_keychain
fi
unlock_keychain
ensure_in_search_list

hash=$(identity_hash)
if [ -z "$hash" ]; then
    [ "$mode" = create ] || exit 1
    import_identity
    hash=$(identity_hash)
    [ -n "$hash" ] || fail "가져온 서명 인증서를 찾지 못했어요: $COMMON_NAME"
fi
printf '%s\n' "$hash"
