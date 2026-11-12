#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools python3 gpg gpgconf base64

dump_dir=kubernetes/infrastructure/configs/cnpg/dumps
restore_test=scripts/restore-test.sh
fake_id=fake-access-key-id
fake_secret=fake-secret-access-key

python3 -I -B -m unittest discover -s "$dump_dir" -p 'test_*.py' -v

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/kubectl" <<FAKE
#!/usr/bin/env bash
template="\${*: -1}"
template="\${template#jsonpath=}"
template="\${template//'{.data.ACCESS_KEY_ID}'/$(printf '%s' "$fake_id" | base64)}"
template="\${template//'{.data.ACCESS_SECRET_KEY}'/$(printf '%s' "$fake_secret" | base64)}"
template="\${template//'{"\\n"}'/\$'\\n'}"
printf '%s' "\$template"
FAKE
chmod +x "$work/bin/kubectl"

sed -n '/^dumps_credentials() {$/,/^}$/p' "$restore_test" > "$work/credentials.sh"
[ -s "$work/credentials.sh" ] || fail "$restore_test defines no dumps_credentials function"
cat >> "$work/credentials.sh" <<CHECK
set -euo pipefail
fail() { echo "FAIL: \$*" >&2; exit 1; }
POSTGRES_NAMESPACE=postgres
DUMPS_CREDENTIALS_SECRET=postgres-backup-s3
dumps_credentials
[ "\$AWS_ACCESS_KEY_ID" = "$fake_id" ] && [ "\$AWS_SECRET_ACCESS_KEY" = "$fake_secret" ]
CHECK
PATH="$work/bin:$PATH" bash "$work/credentials.sh" \
  || fail "dumps_credentials in $restore_test does not read both keys from kubectl jsonpath output under set -e"
echo "dumps_credentials reads both keys from jsonpath output"
