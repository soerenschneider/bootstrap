#!/usr/bin/env bash
# bootstrap.sh — machine bootstrap script
# Usage: bash bootstrap.sh [--dry-run] [--skip-ansible] [--skip-ssh] [--skip-gpg]
#
# Exit codes:
#   0  success
#   1  general error
#   2  unsupported OS / distro
#   3  dependency check failed
#   4  network / download failure

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly GITHUB_USER="soerenschneider"
readonly GIT_HOST="git@github.com:${GITHUB_USER}"
readonly GIT_PASS_REPO="abrakadabra"
readonly GIT_REPOS=(
  "ansible"
  "ansible-inventory-prod"
  "dotfiles"
)
readonly GPG_KEY_URLS=(
  "https://nas.dd.soeren.cloud/pub/crypto/gpg-soerenschneider.pub"
  "https://nas.ez.soeren.cloud/pub/crypto/gpg-soerenschneider.pub"
)
readonly GPG_KEY_ID="0x5ADFB1F470E97637"
readonly SSH_KEY_PATH="${HOME}/.ssh/id_ed25519"
readonly SSH_KEY_TITLE="$(hostname)-bootstrap-$(date +%Y%m%d)"
readonly CURL_OPTS=(--fail --location --silent --show-error --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2)
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="${TMPDIR:-/tmp}/bootstrap-$(date +%Y%m%d-%H%M%S).log"
readonly MIN_BASH_VERSION=4

# ---------------------------------------------------------------------------
# Runtime state (mutable)
# ---------------------------------------------------------------------------
DRY_RUN=false
SKIP_ANSIBLE=false
SKIP_SSH=false
SKIP_GPG=false
SSH_KEY_EXISTS_IN_GITHUB=false
GIT_PROJECTS=""
OS=""

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# Log levels: DEBUG INFO WARN ERROR
_log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts="$(date '+%Y-%m-%dT%H:%M:%S')"
    local line="${ts} [${level}] ${msg}"

    # Write to log file unconditionally
    echo "${line}" >> "${LOG_FILE}"

    # Colorised console output
    case "${level}" in
        INFO)  printf '\033[0;32m[INFO]\033[0m  %s\n' "${msg}" ;;
        WARN)  printf '\033[0;33m[WARN]\033[0m  %s\n' "${msg}" ;;
        ERROR) printf '\033[0;31m[ERROR]\033[0m %s\n' "${msg}" >&2 ;;
        DEBUG) [[ "${BOOTSTRAP_DEBUG:-0}" == "1" ]] && printf '\033[0;36m[DEBUG]\033[0m %s\n' "${msg}" || true ;;
        *)     printf '%s\n' "${msg}" ;;
    esac
}

log()       { _log INFO  "$*"; }
log_warn()  { _log WARN  "$*"; }
log_err()   { _log ERROR "$*"; }
log_debug() { _log DEBUG "$*"; }

die() {
    log_err "$*"
    log_err "Full log: ${LOG_FILE}"
    exit 1
}

# Print a banner and show where logs go
print_banner() {
    printf '\n\033[1;34m══════════════════════════════════════════\033[0m\n'
    printf '\033[1;34m  Bootstrap — %s\033[0m\n' "$(hostname)"
    printf '\033[1;34m══════════════════════════════════════════\033[0m\n\n'
    log "Log file: ${LOG_FILE}"
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_warn "DRY-RUN mode — no changes will be made"
    fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)      DRY_RUN=true ;;
            --skip-ansible) SKIP_ANSIBLE=true ;;
            --skip-ssh)     SKIP_SSH=true ;;
            --skip-gpg)     SKIP_GPG=true ;;
            --help|-h)      usage; exit 0 ;;
            *) die "Unknown argument: $1. Run with --help for usage." ;;
        esac
        shift
    done
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Bootstrap a new machine with GPG, SSH keys, pass store, and Ansible.

Options:
  --dry-run        Print actions without executing them
  --skip-ansible   Skip Ansible checkout and playbook
  --skip-ssh       Skip GitHub SSH key registration
  --skip-gpg       Skip GPG key import
  --help           Show this help message

Environment:
  BOOTSTRAP_DEBUG=1   Enable debug logging
EOF
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
check_bash_version() {
    if (( BASH_VERSINFO[0] < MIN_BASH_VERSION )); then
        die "Bash ${MIN_BASH_VERSION}+ required (found ${BASH_VERSION}). On macOS, run: brew install bash"
    fi
}

detect_os() {
    OS="$(uname -s)"
    case "${OS}" in
        Darwin)
            GIT_PROJECTS="${HOME}/Private/github"
            ;;
        Linux)
            GIT_PROJECTS="${HOME}/src/github"
            if [[ ! -f /etc/redhat-release ]]; then
                die "Unsupported Linux distribution. Only RHEL-based distros are supported."
            fi
            ;;
        *)
            die "Unsupported OS: ${OS}. Only macOS and RHEL Linux are supported."
            ;;
    esac
    log "Detected OS: ${OS}"
}

check_required_env() {
    # HOME must be set and be a real directory
    [[ -n "${HOME:-}" && -d "${HOME}" ]] || die "HOME is unset or not a directory."
}

# ---------------------------------------------------------------------------
# Dry-run helper
# ---------------------------------------------------------------------------
# Wrap any destructive/side-effectful command with this.
# In dry-run mode it prints the command instead of running it.
run() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        printf '\033[0;35m[DRY-RUN]\033[0m %s\n' "$*"
        return 0
    fi
    "$@"
}

# ---------------------------------------------------------------------------
# Package installation
# ---------------------------------------------------------------------------
installRequirements() {
    log "Installing required packages..."

    if [[ "${OS}" == "Linux" ]]; then
        local packages=(ansible git gnupg2 make pass pcsc-lite pcsc-cyberjack stow zsh)
        run sudo dnf -qy install "${packages[@]}"
        run sudo systemctl enable --now pcscd
        log "RHEL packages installed."
    elif [[ "${OS}" == "Darwin" ]]; then
        if ! command -v brew &>/dev/null; then
            die "Homebrew not found. Install it first: https://brew.sh"
        fi
        local packages=(ansible git gnupg make pass stow zsh)
        run brew install "${packages[@]}"
        log "macOS packages installed."
    fi
}

# ---------------------------------------------------------------------------
# GPG
# ---------------------------------------------------------------------------
ensureGpgKeyImported() {
    if [[ "${SKIP_GPG}" == "true" ]]; then
        log "Skipping GPG import (--skip-gpg)."
        return 0
    fi

    if gpg --list-keys "${GPG_KEY_ID}" &>/dev/null; then
        log "GPG key ${GPG_KEY_ID} already in keychain — skipping import."
        return 0
    fi

    local tmp_key
    tmp_key="$(mktemp /tmp/gpg-key.XXXXXX.pub)"
    # Ensure temp file is cleaned up on exit
    trap 'rm -f "${tmp_key}"' RETURN

    local downloaded=false
    for url in "${GPG_KEY_URLS[@]}"; do
        log_debug "Trying GPG key URL: ${url}"
        if run curl "${CURL_OPTS[@]}" -o "${tmp_key}" "${url}"; then
            log "Downloaded GPG key from: ${url}"
            downloaded=true
            break
        else
            log_warn "Failed to download from: ${url}"
        fi
    done

    if [[ "${downloaded}" != "true" ]]; then
        die "All GPG key download attempts failed. Check network connectivity."
    fi

    # Validate the key file looks like a PGP key before importing
    if ! grep -q -E 'BEGIN PGP|-----' "${tmp_key}" 2>/dev/null; then
        # Binary/armored check — just attempt import and let gpg validate
        log_debug "Key file does not appear to be ASCII-armored; proceeding with import."
    fi

    run gpg --import "${tmp_key}"
    log "GPG key ${GPG_KEY_ID} imported successfully."
}

# ---------------------------------------------------------------------------
# GPG-agent SSH support
# ---------------------------------------------------------------------------
ensureSshSupportForGpgAgent() {
    # Initialise gpg homedir with correct permissions
    gpg --list-keys &>/dev/null || true

    local ssh_enabled
    ssh_enabled=$(gpgconf --list-options gpg-agent 2>/dev/null \
        | awk -F: '$1 == "enable-ssh-support" { print $NF }') || true

    if [[ "${ssh_enabled}" == "1" ]]; then
        log "GPG-agent SSH support already enabled."
        return 0
    fi

    log "Enabling SSH support in gpg-agent..."
    run gpgconf --kill gpg-agent
    sleep 0.5
    run gpg-agent --daemon --enable-ssh-support
    log "gpg-agent restarted with SSH support."
}

# ---------------------------------------------------------------------------
# SSH helpers
# ---------------------------------------------------------------------------
_gpg_git_env() {
    # Returns env prefix to use GPG agent's SSH socket when needed
    if [[ "${SSH_KEY_EXISTS_IN_GITHUB}" == "true" ]]; then
        echo ""
    else
        local sock
        sock="$(gpgconf --list-dirs agent-ssh-socket 2>/dev/null)" || die "Cannot locate gpg-agent SSH socket."
        echo "SSH_AUTH_SOCK=${sock}"
    fi
}

_git_with_env() {
    # Run a git command, optionally prefixing env vars
    local env_prefix
    env_prefix="$(_gpg_git_env)"
    if [[ -n "${env_prefix}" ]]; then
        run env "${env_prefix}" git "$@"
    else
        run git "$@"
    fi
}

# ---------------------------------------------------------------------------
# Pass store checkout
# ---------------------------------------------------------------------------
checkoutPassStore() {
    local target="${GIT_PROJECTS}/${GIT_PASS_REPO}"

    run mkdir -p "${GIT_PROJECTS}"

    if [[ -d "${target}/.git" ]]; then
        log "Updating pass store at ${target}..."
        _git_with_env -C "${target}" pull --ff-only
    else
        log "Cloning pass store into ${target}..."
        _git_with_env clone "${GIT_HOST}/${GIT_PASS_REPO}" "${target}"
    fi

    local store_link="${HOME}/.password-store"
    if [[ ! -e "${store_link}" ]]; then
        log "Creating symlink: ${store_link} -> ${target}"
        run ln -s "${target}" "${store_link}"
    elif [[ "$(readlink "${store_link}")" != "${target}" ]]; then
        log_warn "${store_link} exists but points elsewhere — leaving it untouched."
    fi
}

# ---------------------------------------------------------------------------
# Ansible repo checkout
# ---------------------------------------------------------------------------
checkoutAnsible() {
    if [[ "${SKIP_ANSIBLE}" == "true" ]]; then
        log "Skipping Ansible checkout (--skip-ansible)."
        return 0
    fi

    run mkdir -p "${GIT_PROJECTS}"

    for repo in "${GIT_REPOS[@]}"; do
        local target="${GIT_PROJECTS}/${repo}"
        if [[ -d "${target}/.git" ]]; then
            log "Updating ${repo}..."
            run git -C "${target}" pull --ff-only
        else
            log "Cloning ${repo}..."
            run git clone "${GIT_HOST}/${repo}" "${target}"
        fi
    done
}

# ---------------------------------------------------------------------------
# Ansible playbook
# ---------------------------------------------------------------------------
runAnsibleBootstrapPlaybook() {
    if [[ "${SKIP_ANSIBLE}" == "true" ]]; then
        log "Skipping Ansible playbook (--skip-ansible)."
        return 0
    fi

    local ansible_dir="${GIT_PROJECTS}/ansible"
    local playbook="${SCRIPT_DIR}/playbook/playbook.yaml"

    if [[ ! -f "${playbook}" ]]; then
        die "Ansible playbook not found at: ${playbook}"
    fi

    # Ensure .ansible/roles symlink exists
    local roles_link="${HOME}/.ansible/roles"
    if [[ ! -L "${roles_link}" ]]; then
        run mkdir -p "${HOME}/.ansible"
        run ln -s "${ansible_dir}/roles" "${roles_link}"
    fi

    log "Running Ansible bootstrap playbook..."
    run ansible-playbook "${playbook}"
}

# ---------------------------------------------------------------------------
# GitHub SSH key registration
# ---------------------------------------------------------------------------
ensureGithubSshKey() {
    if [[ "${SKIP_SSH}" == "true" ]]; then
        log "Skipping GitHub SSH key registration (--skip-ssh)."
        return 0
    fi

    # Generate key if missing
    if [[ ! -f "${SSH_KEY_PATH}" ]]; then
        log "No SSH key at ${SSH_KEY_PATH} — generating ed25519 key..."
        run ssh-keygen -t ed25519 -C "${GITHUB_USER}@bootstrap" -f "${SSH_KEY_PATH}" -N ""
        log "SSH key generated."
    fi

    local pub_key_path="${SSH_KEY_PATH}.pub"
    [[ -f "${pub_key_path}" ]] || die "Public key not found at ${pub_key_path}"

    local pub_key
    pub_key="$(< "${pub_key_path}")"

    # Compare only type + base64 blob, ignore comment
    local key_body
    key_body="$(awk '{print $1, $2}' <<< "${pub_key}")"

    log "Checking if SSH key is already registered on GitHub..."
    local existing
    existing=$(curl "${CURL_OPTS[@]}" "https://github.com/${GITHUB_USER}.keys") \
        || die "Failed to fetch SSH keys from GitHub."

    if echo "${existing}" | grep -qF "${key_body}"; then
        log "SSH key already registered on GitHub."
        SSH_KEY_EXISTS_IN_GITHUB=true
        return 0
    fi

    # Retrieve PAT from pass
    local pat
    pat="$(pass tokens/github/bootstrap 2>/dev/null)" || true

    if [[ -z "${pat}" ]]; then
        log_warn "No GitHub PAT found in pass (tokens/github/bootstrap) — skipping SSH key registration."
        log_warn "You will need to register the SSH key manually."
        return 0
    fi

    log "Registering SSH key on GitHub (title: ${SSH_KEY_TITLE})..."

    local response http_code body
    response=$(curl "${CURL_OPTS[@]}" \
        --write-out '\n%{http_code}' \
        --output - \
        -X POST \
        -H "Authorization: Bearer ${pat}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        https://api.github.com/user/keys \
        -d "{\"title\":\"${SSH_KEY_TITLE}\",\"key\":\"${pub_key}\"}") \
        || die "Failed to call GitHub API."

    http_code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [[ "${http_code}" == "201" ]]; then
        log "SSH key registered on GitHub successfully."
        SSH_KEY_EXISTS_IN_GITHUB=true
    elif [[ "${http_code}" == "422" ]]; then
        log_warn "GitHub returned 422 — key may already exist under a different title. Body: ${body}"
        SSH_KEY_EXISTS_IN_GITHUB=true
    else
        die "GitHub API returned HTTP ${http_code}. Body: ${body}"
    fi
}

# ---------------------------------------------------------------------------
# Cleanup / trap
# ---------------------------------------------------------------------------
on_exit() {
    local code=$?
    if (( code != 0 )); then
        log_err "Bootstrap failed (exit code ${code}). See log: ${LOG_FILE}"
    else
        log "Bootstrap complete. Log: ${LOG_FILE}"
    fi
}

trap on_exit EXIT

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_bash_version
    check_required_env
    detect_os
    print_banner

    installRequirements
    ensureGpgKeyImported
    ensureSshSupportForGpgAgent
    checkoutPassStore
    ensureGithubSshKey
    checkoutAnsible
    runAnsibleBootstrapPlaybook
}

main "$@"
