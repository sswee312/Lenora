# Sourced by scripts/dev. Works in macOS bash 3.2.

# Sets app_env to `env` arguments for launching the editor: every key named in the .env
# file ($1) and every exported LENORA_* variable is removed, even if the parent shell
# exported it, then only the backend URL ($2), the backend token and the agent's BYOK
# keys are passed back. The rest of the caller's environment is left intact.
lenora_app_env() {
  local env_file=$1 backend_url=$2 name
  local allowed=" LENORA_BACKEND_URL LENORA_TOKEN ANTHROPIC_API_KEY OPENAI_API_KEY "
  app_env=()
  while IFS= read -r name; do
    case "$allowed" in *" $name "*) continue ;; esac
    app_env+=(-u "$name")
  done < <(
    {
      sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$env_file"
      compgen -e | grep '^LENORA_' || true
    } | sort -u
  )
  app_env+=(LENORA_BACKEND_URL="$backend_url" LENORA_TOKEN="$LENORA_TOKEN")
  # Debug builds read the agent's BYOK keys from the environment.
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] && app_env+=(ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY")
  [[ -n "${OPENAI_API_KEY:-}" ]] && app_env+=(OPENAI_API_KEY="$OPENAI_API_KEY")
  return 0
}
