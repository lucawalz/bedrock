#!/usr/bin/env bash
set -euo pipefail
umask 077

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools openssl age nix-instantiate jq tar

[ "$#" -eq 0 ] || { echo "usage: generate-cluster-ca.sh" >&2; exit 1; }

product=k3s
root_ca_dir="$HOME/.config/bedrock/k3s-root-ca"
root_cert="$root_ca_dir/root-ca.pem"
root_key="$root_ca_dir/root-ca.key"
identity="$HOME/.ssh/id_ed25519"
ca_secret=k3s-ca.age
token_secret=k3s-token.age
token_user=server
root_rsa_bits=4096
intermediate_rsa_bits=4096
service_rsa_bits=2048
leaf_curve=prime256v1
root_days=7300
intermediate_days=3700
leaf_days=3700
seconds_per_day=86400
leaf_cas=(client server request-header etcd/peer etcd/server)
# server-ca.crt goes last so an interrupted unpack leaves the install unit armed to retry.
tarball_members=(
  service.key
  client-ca.crt client-ca.key
  request-header-ca.crt request-header-ca.key
  etcd/peer-ca.crt etcd/peer-ca.key
  etcd/server-ca.crt etcd/server-ca.key
  server-ca.key server-ca.crt
)

openssl version | grep -q '^OpenSSL 3' || { echo "openssl must be OpenSSL 3, got: $(openssl version)" >&2; exit 1; }
[ -f "$identity" ] || { echo "$identity is missing; it decrypts $token_secret" >&2; exit 1; }
[ -f "secrets/$token_secret" ] || { echo "secrets/$token_secret is missing" >&2; exit 1; }
if { [ -e "$root_cert" ] && [ ! -e "$root_key" ]; } || { [ ! -e "$root_cert" ] && [ -e "$root_key" ]; }; then
  echo "$root_ca_dir holds only one of root-ca.pem and root-ca.key" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
tls="$work/tls"
mkdir -p "$tls/etcd"
timestamp="$(date +%s)"

cat >"$work/openssl.cnf" <<'EOF'
[req]
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, keyEncipherment, keyCertSign
EOF

sign() {
  local key="$1" name="$2" days="$3" issuer_cert="$4" issuer_key="$5" out="$6"
  openssl req -new -key "$key" -subj "/CN=$product-$name@$timestamp" -config "$work/openssl.cnf" |
    openssl x509 -req -sha256 -days "$days" -CA "$issuer_cert" -CAkey "$issuer_key" \
      -extfile "$work/openssl.cnf" -extensions v3_ca -out "$out" 2>/dev/null
}

if [ -e "$root_cert" ]; then
  echo "Reusing the root CA in $root_ca_dir"
else
  echo "Generating a root CA in $root_ca_dir"
  mkdir -p "$root_ca_dir"
  openssl genrsa -traditional -out "$root_key" "$root_rsa_bits" 2>/dev/null
  openssl req -x509 -new -sha256 -days "$root_days" -key "$root_key" \
    -subj "/CN=$product-root-ca@$timestamp" -config "$work/openssl.cnf" -extensions v3_ca -out "$root_cert"
fi
chmod 700 "$root_ca_dir"
chmod 600 "$root_key"
openssl x509 -in "$root_cert" -noout -checkend "$((intermediate_days * seconds_per_day))" >/dev/null ||
  { echo "the root CA expires within the intermediate lifetime; rotate the root" >&2; exit 1; }

intermediate_key="$work/intermediate-ca.key"
intermediate_cert="$work/intermediate-ca.pem"
openssl genrsa -traditional -out "$intermediate_key" "$intermediate_rsa_bits" 2>/dev/null
sign "$intermediate_key" intermediate-ca "$intermediate_days" "$root_cert" "$root_key" "$intermediate_cert"

for type in "${leaf_cas[@]}"; do
  openssl ecparam -name "$leaf_curve" -genkey -noout -out "$tls/$type-ca.key"
  sign "$tls/$type-ca.key" "$(echo "$type" | tr / -)-ca" "$leaf_days" "$intermediate_cert" "$intermediate_key" "$work/leaf.pem"
  openssl verify -CAfile "$root_cert" -untrusted "$intermediate_cert" "$work/leaf.pem" >/dev/null
  cat "$work/leaf.pem" "$intermediate_cert" "$root_cert" >"$tls/$type-ca.crt"
done
openssl genrsa -traditional -out "$tls/service.key" "$service_rsa_bits" 2>/dev/null

recipients() {
  nix-instantiate --eval --strict --json -E "(import $repo_root/secrets/secrets.nix).\"$1\".publicKeys" | jq -r '.[]'
}

tar --format ustar -cf "$work/ca.tar" -C "$tls" "${tarball_members[@]}"
age -R <(recipients "$ca_secret") -o "$work/$ca_secret" "$work/ca.tar"
mv "$work/$ca_secret" "secrets/$ca_secret"

# k3s hashes the DER of the root certificate when the served CA bundle holds a chain.
ca_hash="$(openssl x509 -in "$root_cert" -outform DER | openssl dgst -sha256 -r | cut -d' ' -f1)"
token="$(age -d -i "$identity" "secrets/$token_secret")"
[[ "$token" =~ ^K10[0-9a-f]{64}::$token_user:([^[:space:]]+)$ ]] ||
  { echo "secrets/$token_secret is not a K10 secure token for user $token_user" >&2; exit 1; }
password="${BASH_REMATCH[1]}"
unset token
printf 'K10%s::%s:%s\n' "$ca_hash" "$token_user" "$password" |
  age -R <(recipients "$token_secret") -o "$work/$token_secret"
unset password
mv "$work/$token_secret" "secrets/$token_secret"

echo "Wrote secrets/$ca_secret and secrets/$token_secret; the token pins CA hash $ca_hash"
