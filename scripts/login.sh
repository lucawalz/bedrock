#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools sops pbcopy

secrets_repo="${BEDROCK_SECRETS:-$repo_root/../bedrock-secrets}"
apps_secrets=clusters/home/apps
litellm_ui_user="admin"

known_apps="paperless grafana litellm ntfy"

usage() {
  echo "usage: login.sh <app> [show]; known apps: $known_apps" >&2
  exit 1
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
app="$1"
show="${2:-false}"
[ "$show" = true ] || [ "$show" = false ] || { echo "show must be true or false, got '$show'" >&2; exit 1; }

user_key=""
user=""
case "$app" in
  paperless) host=paperless.syslabs.dev file=paperless.sops.yaml user_key=PAPERLESS_ADMIN_USER password_key=PAPERLESS_ADMIN_PASSWORD ;;
  grafana) host=grafana.syslabs.dev file=grafana.sops.yaml user_key=admin-user password_key=admin-password ;;
  litellm) host=litellm.syslabs.dev file=litellm.sops.yaml user="$litellm_ui_user" password_key=LITELLM_MASTER_KEY ;;
  ntfy) host=ntfy.syslabs.dev file=ntfy.sops.yaml user=phone password_key=phone-password ;;
  *) echo "unknown app '$app'; known apps: $known_apps" >&2; exit 1 ;;
esac

secret_file="$secrets_repo/$apps_secrets/$file"
[ -f "$secret_file" ] || { echo "$secret_file does not exist; set BEDROCK_SECRETS" >&2; exit 1; }

read_key() {
  sops -d --extract "[\"stringData\"][\"$1\"]" "$secret_file" 2>/dev/null || { echo "cannot decrypt $1 from $file" >&2; return 1; }
}

if [ -n "$user_key" ]; then
  user="$(read_key "$user_key")"
fi
password="$(read_key "$password_key")"
[ -n "$user" ] && [ -n "$password" ] || { echo "$file holds an empty user or password for $app" >&2; exit 1; }

printf '%s' "$password" | pbcopy
echo "url:  https://$host"
echo "user: $user"
if [ "$show" = true ]; then
  echo "password: $password"
else
  echo "password copied to the clipboard"
fi
