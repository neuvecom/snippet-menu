#!/bin/bash
# Creates a self-signed code signing certificate in the login keychain.
# Signing every build with the same certificate keeps the Accessibility
# permission across rebuilds. Run this once per Mac.
set -euo pipefail

NAME="SnippetMenu Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl  # LibreSSL writes a .p12 that `security import` can read.

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "証明書「$NAME」はすでにあります。"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=$(uuidgen)

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/cert.p12" -passout "pass:$PASS"

security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "証明書を信頼済みにします。Macのログインパスワードを求められたら入力してください。"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" \
  || echo "信頼の設定はスキップしました（署名には影響しません）。"

echo "証明書「$NAME」を作成しました。続けて ./build.sh を実行してください。"
