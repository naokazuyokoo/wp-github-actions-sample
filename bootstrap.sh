#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE=".deploy.env"
KNOWN_HOSTS_FILE="/tmp/prod_known_hosts"

prompt_required() {
  local var_name="$1"
  local prompt="$2"
  local value=""
  while [ -z "$value" ]; do
    read -r -p "$prompt: " value
  done
  printf -v "$var_name" '%s' "$value"
}

prompt_default() {
  local var_name="$1"
  local prompt="$2"
  local default_value="$3"
  local value=""
  read -r -p "$prompt [$default_value]: " value
  if [ -z "$value" ]; then
    value="$default_value"
  fi
  printf -v "$var_name" '%s' "$value"
}

confirm_yes_no() {
  local message="$1"
  local ans=""
  while true; do
    read -r -p "$message (y/n): " ans
    case "$ans" in
      y|Y) return 0 ;;
      n|N) return 1 ;;
      *) echo "Please enter y or n." ;;
    esac
  done
}

confirm_block() {
  local description="$1"
  local commands="$2"
  local editable_command=""
  local command_line=""
  local bash_major_version=0
  echo "---"
  echo "Description:"
  printf '%s\n' "$description"
  echo ""
  echo "Commands:"
  printf '%s\n' "$commands"
  echo "---"
  if confirm_yes_no "Do you want to proceed?"; then
    # Show a one-line editable command buffer before the scripted step runs.
    command_line="${commands//$'\n'/; }"
    if [ -n "${BASH_VERSINFO:-}" ]; then
      bash_major_version="${BASH_VERSINFO[0]}"
    fi

    if [ "$bash_major_version" -ge 4 ]; then
      read -e -r -p "Press Enter to run (editable): " -i "$command_line" editable_command
    else
      echo "Your Bash (${BASH_VERSION}) does not support read -i (prefilled editable input)."
      printf 'Command: %s\n' "$command_line"
      read -e -r -p "Edit command (blank = use shown command): " editable_command
      if [ -z "$editable_command" ]; then
        editable_command="$command_line"
      fi
    fi
    return 0
  fi
  echo "Skipped."
  return 1
}

check_required_vars() {
  local missing=0
  local required_vars=(
    GITHUB_OWNER
    GITHUB_REPO
    PROD_DOMAIN
    SSH_KEY_NAME
    SSH_ALIAS_OR_USER_AT_HOST
    PROD_HOST
    PROD_USER
    PROD_PORT
    PROD_PATH_TO_THEME
  )

  for key in "${required_vars[@]}"; do
    if [ -z "${!key:-}" ]; then
      echo "Missing required value in ${ENV_FILE}: ${key}"
      missing=1
    fi
  done

  if [ "$missing" -ne 0 ]; then
    echo "Please fix ${ENV_FILE} and rerun."
    exit 1
  fi
}

echo "Bootstrap start: ${SCRIPT_DIR}"

if [ -f "$ENV_FILE" ]; then
  echo "${ENV_FILE} already exists. Input step is skipped."
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
  check_required_vars
else
  echo "${ENV_FILE} not found. Starting interactive setup."

  default_repo="$(basename "$SCRIPT_DIR")"

  prompt_required GITHUB_OWNER "GitHub owner (user/org)"
  prompt_default GITHUB_REPO "GitHub repository name" "$default_repo"
  prompt_required PROD_DOMAIN "Production domain (example.com)"

  if confirm_yes_no "Use existing SSH private key under ~/.ssh?"; then
    while true; do
      prompt_required SSH_KEY_NAME "Existing SSH key file name (without .pub)"
      if [ -f "$HOME/.ssh/${SSH_KEY_NAME}" ]; then
        break
      fi
      echo "Not found: $HOME/.ssh/${SSH_KEY_NAME}"
    done
  else
    prompt_default SSH_KEY_NAME "New SSH key file name" "gha_prod_ed25519"
  fi

  prompt_required SSH_ALIAS_OR_USER_AT_HOST "SSH login target for key registration (user@host or alias)"
  prompt_required PROD_HOST "Production host for rsync (example.com)"
  prompt_required PROD_USER "Production SSH user"
  prompt_default PROD_PORT "Production SSH port" "22"
  prompt_required PROD_PATH_TO_THEME "Production theme path"

  echo ""
  echo "Please confirm the values:"
  echo "GITHUB_OWNER=${GITHUB_OWNER}"
  echo "GITHUB_REPO=${GITHUB_REPO}"
  echo "PROD_DOMAIN=${PROD_DOMAIN}"
  echo "SSH_KEY_NAME=${SSH_KEY_NAME}"
  echo "SSH_ALIAS_OR_USER_AT_HOST=${SSH_ALIAS_OR_USER_AT_HOST}"
  echo "PROD_HOST=${PROD_HOST}"
  echo "PROD_USER=${PROD_USER}"
  echo "PROD_PORT=${PROD_PORT}"
  echo "PROD_PATH_TO_THEME=${PROD_PATH_TO_THEME}"

  if ! confirm_yes_no "Save these values to ${ENV_FILE}?"; then
    echo "Canceled."
    exit 1
  fi

  cat > "$ENV_FILE" <<ENV
GITHUB_OWNER=${GITHUB_OWNER}
GITHUB_REPO=${GITHUB_REPO}
PROD_DOMAIN=${PROD_DOMAIN}
SSH_KEY_NAME=${SSH_KEY_NAME}
SSH_ALIAS_OR_USER_AT_HOST=${SSH_ALIAS_OR_USER_AT_HOST}
PROD_HOST=${PROD_HOST}
PROD_USER=${PROD_USER}
PROD_PORT=${PROD_PORT}
PROD_PATH_TO_THEME=${PROD_PATH_TO_THEME}
ENV

  chmod 600 "$ENV_FILE"

  if [ -f .gitignore ]; then
    if ! rg -n "^\\.deploy\\.env$" .gitignore >/dev/null 2>&1; then
      echo ".deploy.env" >> .gitignore
      echo "Added .deploy.env to .gitignore"
    fi
  else
    echo ".deploy.env" > .gitignore
    echo "Created .gitignore with .deploy.env"
  fi

  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Git repository not found in this directory."
  if confirm_block \
    "Initialize a Git repository in this directory." \
    "git init"; then
    git init
  else
    echo "Git repository is required. Exiting."
    exit 1
  fi
fi

if confirm_block \
  "Check whether GitHub CLI authentication is already configured." \
  $'gh auth status'; then
  if ! gh auth status; then
    echo "GitHub CLI is not authenticated. Run: gh auth login"
    exit 1
  fi
fi

if confirm_block \
  "Stage all changes and create the initial commit if there are staged changes." \
  $'git add .\ngit commit -m "Initial commit for GitHub Actions sample"'; then
  git add .
  if git diff --cached --quiet; then
    echo "No staged changes. Commit skipped."
  else
    git commit -m "Initial commit for GitHub Actions sample"
  fi
fi

if confirm_block \
  "When cloned from another repository, rename existing 'origin' to 'upstream' before creating your own origin." \
  "git remote rename origin upstream"; then
  if git remote get-url upstream >/dev/null 2>&1; then
    echo "Remote 'upstream' already exists. Rename skipped."
  elif git remote get-url origin >/dev/null 2>&1; then
    git remote rename origin upstream
  else
    echo "Remote 'origin' does not exist. Rename skipped."
  fi
fi

if confirm_block \
  "Create a private GitHub repository and set it as the 'origin' remote." \
  "gh repo create \"${GITHUB_OWNER}/${GITHUB_REPO}\" --private --source . --remote origin"; then
  if git remote get-url origin >/dev/null 2>&1; then
    echo "Remote 'origin' already exists. Repo create skipped."
  else
    gh repo create "${GITHUB_OWNER}/${GITHUB_REPO}" --private --source . --remote origin
  fi
fi

if [ -f "$HOME/.ssh/${SSH_KEY_NAME}" ]; then
  echo "Using existing SSH key: $HOME/.ssh/${SSH_KEY_NAME}"
else
  if confirm_block \
    "Generate a new SSH key pair used by GitHub Actions deployment." \
    "ssh-keygen -t ed25519 -C \"github-actions@${PROD_DOMAIN}\" -f \"$HOME/.ssh/${SSH_KEY_NAME}\" -N \"\""; then
    ssh-keygen -t ed25519 -C "github-actions@${PROD_DOMAIN}" -f "$HOME/.ssh/${SSH_KEY_NAME}" -N ""
  fi
fi

if confirm_block \
  "Register the public SSH key on the target server using ssh-copy-id." \
  "ssh-copy-id -f -i \"$HOME/.ssh/${SSH_KEY_NAME}.pub\" \"${SSH_ALIAS_OR_USER_AT_HOST}\""; then
  ssh-copy-id -f -i "$HOME/.ssh/${SSH_KEY_NAME}.pub" "${SSH_ALIAS_OR_USER_AT_HOST}"
fi

if confirm_block \
  "Collect the production host key and display its fingerprint for verification." \
  "ssh-keyscan -H \"${PROD_HOST}\" > ${KNOWN_HOSTS_FILE}
ssh-keygen -lf ${KNOWN_HOSTS_FILE}"; then
  ssh-keyscan -H "${PROD_HOST}" > "${KNOWN_HOSTS_FILE}"
  ssh-keygen -lf "${KNOWN_HOSTS_FILE}"
fi

if confirm_block \
  "Store deployment settings and SSH credentials as GitHub Actions repository secrets." \
  "gh secret set PROD_HOST --body \"${PROD_HOST}\"
gh secret set PROD_USER --body \"${PROD_USER}\"
gh secret set PROD_PORT --body \"${PROD_PORT}\"
gh secret set PROD_PATH --body \"${PROD_PATH_TO_THEME}\"
gh secret set PROD_SSH_KEY < \"${HOME}/.ssh/${SSH_KEY_NAME}\"
gh secret set PROD_KNOWN_HOSTS < \"${KNOWN_HOSTS_FILE}\""; then
  gh secret set PROD_HOST --body "${PROD_HOST}"
  gh secret set PROD_USER --body "${PROD_USER}"
  gh secret set PROD_PORT --body "${PROD_PORT}"
  gh secret set PROD_PATH --body "${PROD_PATH_TO_THEME}"
  gh secret set PROD_SSH_KEY < "${HOME}/.ssh/${SSH_KEY_NAME}"
  gh secret set PROD_KNOWN_HOSTS < "${KNOWN_HOSTS_FILE}"
fi

CURRENT_BRANCH="$(git branch --show-current)"
if [ -z "${CURRENT_BRANCH}" ]; then
  CURRENT_BRANCH="master"
fi

PUSH_REMOTE="origin"
if git remote get-url origin >/dev/null 2>&1; then
  PUSH_REMOTE="origin"
elif git remote get-url upstream >/dev/null 2>&1; then
  PUSH_REMOTE="upstream"
fi

if confirm_block \
  "Push the current branch to GitHub and set upstream tracking." \
  "git push -u ${PUSH_REMOTE} ${CURRENT_BRANCH}"; then
  git push -u "${PUSH_REMOTE}" "${CURRENT_BRANCH}"
fi

LATEST_PUSH_RUN_ID=""
if confirm_block \
  "Check the latest GitHub Actions run triggered by a push on this branch." \
  "gh run list --workflow \"deploy-production.yml\" --branch ${CURRENT_BRANCH} --event push --limit 1"; then
  gh run list --workflow "deploy-production.yml" --branch "${CURRENT_BRANCH}" --event push --limit 1
  LATEST_PUSH_RUN_ID="$(
    gh run list \
      --workflow "deploy-production.yml" \
      --branch "${CURRENT_BRANCH}" \
      --event push \
      --limit 1 \
      --json databaseId \
      --jq '.[0].databaseId'
  )"
  if [ -n "${LATEST_PUSH_RUN_ID}" ] && [ "${LATEST_PUSH_RUN_ID}" != "null" ]; then
    if confirm_block \
      "Watch the latest workflow run and wait until it completes." \
      "gh run watch ${LATEST_PUSH_RUN_ID} --exit-status"; then
      gh run watch "${LATEST_PUSH_RUN_ID}" --exit-status
    fi
  else
    echo "No push-triggered run found yet."
    if confirm_block \
      "Trigger the deployment workflow manually for the current branch." \
      "gh workflow run \"Deploy Theme to Production\" --ref ${CURRENT_BRANCH}"; then
      gh workflow run "Deploy Theme to Production" --ref "${CURRENT_BRANCH}"
    fi
  fi
fi

echo "Bootstrap completed."
