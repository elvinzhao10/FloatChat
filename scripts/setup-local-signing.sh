#!/usr/bin/env bash
# Set up a reusable identity for this Mac's local builds.
set -euo pipefail
umask 077

support="$HOME/Library/Application Support/dev.quickchat.omni"
identity_file="$support/local-signing.sha1"
keychain="$HOME/Library/Keychains/login.keychain-db"
if [[ -f "$identity_file" ]]; then
  echo "FloatChat already has a configured local signing identity."
  exit 0
fi
[[ -f "$keychain" ]] || { echo "The login Keychain is unavailable." >&2; exit 1; }
if security find-certificate -c "FloatChat Local Updates" "$keychain" >/dev/null 2>&1; then
  echo "A FloatChat Local Updates certificate already exists. Check its signing identity before creating another." >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export FLOATCHAT_SIGNING_TEMP_PASSWORD="$(openssl rand -hex 32)"
cat > "$work/certificate.cnf" <<'CONFIG'
[req]
distinguished_name = name
x509_extensions = signing
prompt = no
[name]
CN = FloatChat Local Updates
[signing]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CONFIG
openssl req -new -x509 -newkey rsa:3072 -days 3650 -config "$work/certificate.cnf" \
  -passout env:FLOATCHAT_SIGNING_TEMP_PASSWORD -keyout "$work/key.pem" -out "$work/cert.pem"
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/signing.p12" \
  -passin env:FLOATCHAT_SIGNING_TEMP_PASSWORD -passout env:FLOATCHAT_SIGNING_TEMP_PASSWORD
fingerprint="$(openssl x509 -in "$work/cert.pem" -fingerprint -sha1 -noout | cut -d= -f2 | tr -d ':')"
[[ "$fingerprint" =~ ^[0-9A-Fa-f]{40}$ ]]
mkdir -p "$support"
security import "$work/signing.p12" -k "$keychain" -P "$FLOATCHAT_SIGNING_TEMP_PASSWORD" -T /usr/bin/codesign
printf '%s\n' "$fingerprint" > "$identity_file"
echo "Configured stable signing for local FloatChat builds."
