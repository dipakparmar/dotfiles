#!/usr/bin/env bash
set -euo pipefail

# ----- Global options -----
DRY_RUN=0
STEP="all"
FORCE=0

# Keep bootstrap deterministic and avoid Homebrew API refreshes during local
# install/link checks.
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_FROM_API=1

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf 'DRY-RUN: %s\n' "$*"
  else
    eval "$@"
  fi
}

should_run() {
  local prompt="$1"
  local default="${2:-y}"

  if [[ $DRY_RUN -eq 1 ]]; then
    return 0
  fi

  if [[ $FORCE -eq 1 ]]; then
    return 0
  fi

  ask_yes_no "$prompt" "$default"
}

brew_formula_installed() {
  local formula="$1"
  brew --prefix "$formula" >/dev/null 2>&1
}

run_brew_link() {
  local formula="$1"
  local overwrite="${2:-0}"
  local output
  local status

  if [[ $DRY_RUN -eq 1 ]]; then
    if [[ "$overwrite" == "1" ]]; then
      printf 'DRY-RUN: brew link --overwrite %s\n' "$formula"
    else
      printf 'DRY-RUN: brew link %s\n' "$formula"
    fi
    return 0
  fi

  if [[ "$overwrite" == "1" ]]; then
    if output=$(brew link --overwrite "$formula" 2>&1); then
      status=0
    else
      status=$?
    fi
  else
    if output=$(brew link "$formula" 2>&1); then
      status=0
    else
      status=$?
    fi
  fi

  if [[ -n "$output" ]]; then
    if [[ $status -eq 0 ]]; then
      printf '%s\n' "$output"
    else
      printf '%s\n' "$output" >&2
    fi
  fi

  if [[ $status -ne 0 ]] && grep -q "Already linked:" <<<"$output"; then
    return 0
  fi

  return "$status"
}

show_brew_link_conflicts() {
  local formula="$1"
  local output

  if [[ $DRY_RUN -eq 1 ]]; then
    printf 'DRY-RUN: brew link --overwrite %s --dry-run\n' "$formula"
    return
  fi

  if output=$(brew link --overwrite "$formula" --dry-run 2>&1); then
    :
  else
    true
  fi

  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
  fi

  if grep -q "MacGPG2" <<<"$output"; then
    warn "Conflict points at MacGPG2. Overwriting will replace the current /usr/local/bin/gpg shim."
  fi
}

install_brew_formula() {
  local formula="$1"

  if ! should_run "Install brew package: $formula?" "y"; then
    warn "Skipping brew package: $formula"
    return
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    printf 'DRY-RUN: brew install %s\n' "$formula"
    return
  fi

  log "Installing brew package: $formula"
  brew install "$formula"
}

link_brew_formula() {
  local formula="$1"

  if ! should_run "Link brew package if needed: $formula?" "y"; then
    warn "Skipping brew link for $formula"
    return
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    run_brew_link "$formula"
    return
  fi

  log "Linking brew package: $formula"
  if run_brew_link "$formula"; then
    return
  fi

  warn "brew link failed for $formula."
  warn "If this is a file conflict, Homebrew can show what overwrite would delete."
  if should_run "Show overwrite dry-run for $formula?" "n"; then
    show_brew_link_conflicts "$formula"
  fi

  if should_run "Overwrite conflicting Homebrew links for $formula?" "n"; then
    log "Overwriting conflicting Homebrew links for $formula"
    run_brew_link "$formula" "1"
  else
    warn "Leaving $formula unlinked."
  fi
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    if ! should_run "Back up $f?" "y"; then
      warn "Skipping backup for $f"
      return
    fi

    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local backup="${f}.bak-${ts}"
    log "Backing up $f -> $backup"
    run "cp '$f' '$backup'"
  fi
}

ensure_dir_secure() {
  local d="$1"
  if [[ ! -d "$d" ]]; then
    if ! should_run "Create directory $d?" "y"; then
      warn "Skipping directory creation: $d"
      return
    fi

    log "Creating directory $d"
    run "mkdir -p '$d'"
  fi

  if should_run "Set permissions on $d to 700?" "y"; then
    log "Setting permissions on $d"
    run "chmod 700 '$d'"
  else
    warn "Skipping chmod 700 for $d"
  fi
}

append_if_missing() {
  local file="$1"
  local line="$2"
  if [[ -f "$file" ]] && grep -Fq "$line" "$file"; then
    log "Line already present in $file: $line"
  else
    if ! should_run "Add line to $file: $line?" "y"; then
      warn "Skipping line for $file: $line"
      return
    fi

    log "Adding line to $file: $line"
    if [[ $DRY_RUN -eq 1 ]]; then
      printf 'DRY-RUN: append line to %s: %s\n' "$file" "$line"
    else
      printf '%s\n' "$line" >> "$file"
    fi
  fi
}

replace_or_append_line() {
  local file="$1"
  local pattern="$2"
  local line="$3"

  if [[ -f "$file" ]] && grep -Fq "$line" "$file"; then
    log "Line already present in $file: $line"
  elif [[ -f "$file" ]] && grep -Eq "$pattern" "$file"; then
    if ! should_run "Replace matching line in $file with: $line?" "y"; then
      warn "Skipping replacement in $file: $line"
      return
    fi

    log "Replacing matching line in $file: $line"
    if [[ $DRY_RUN -eq 1 ]]; then
      printf 'DRY-RUN: remove lines matching %s from %s\n' "$pattern" "$file"
      printf 'DRY-RUN: append line to %s: %s\n' "$file" "$line"
    else
      perl -0pi -e "s|^${pattern}\n?||mg" "$file"
      printf '%s\n' "$line" >> "$file"
    fi
  else
    append_if_missing "$file" "$line"
  fi
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-y}"  # y or n
  local ans

  while true; do
    if [[ -t 0 ]]; then
      if [[ "$default" == "y" ]]; then
        read -r -n 1 -p "$prompt [Y/n] " ans || ans=""
        ans=${ans:-y}
      else
        read -r -n 1 -p "$prompt [y/N] " ans || ans=""
        ans=${ans:-n}
      fi
      printf '\n'
    else
      if [[ "$default" == "y" ]]; then
        read -r -p "$prompt [Y/n] " ans || ans=""
        ans=${ans:-y}
      else
        read -r -p "$prompt [y/N] " ans || ans=""
        ans=${ans:-n}
      fi
    fi

    case "$ans" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

usage() {
  cat <<EOF
Usage: $0 [--dry-run] [--force|--yes|--no-prompt] [--step STEP]

Steps:
  bootstrap   - Install deps + configure gpg-agent and SSH env.
  create-keys - Create GPG master + subkeys on disk (interactive).
  backup      - Export and encrypt GPG key backup.
  to-primary  - Move subkeys to primary YubiKey.
  to-backup   - Move subkeys to backup YubiKey.
  ssh-gpg     - Ensure SSH via gpg-agent is configured.
  git-sign    - Configure Git to sign commits with this key.
  all         - Run all steps in sequence (default).

Examples:
  $0 --dry-run --step bootstrap
  $0 --step bootstrap
  $0 --yes --step bootstrap
EOF
}

# ----- Parse args -----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --step) STEP="${2:-all}"; shift 2 ;;
    --force|--yes|--no-prompt) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown arg: $1" ;;
  esac
done

# ----- Step: bootstrap -----
step_bootstrap() {
  log "Step: bootstrap (macOS tooling + GPG/SSH env)"

  local uname_out
  uname_out=$(uname -s)
  if [[ "$uname_out" != "Darwin" ]]; then
    die "This bootstrap step is designed for macOS (Darwin), got: $uname_out"
  fi

  if ! command -v brew >/dev/null 2>&1; then
    if should_run "Homebrew not found. Install Homebrew?" "y"; then
      warn "Homebrew not found. Installing Homebrew."
      run '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    else
      die "Homebrew is required for bootstrap."
    fi
  else
    log "Homebrew is already installed."
  fi

  local pkgs=("gnupg" "yubikey-personalization" "ykman" "pinentry-mac")
  for pkg in "${pkgs[@]}"; do
    if brew_formula_installed "$pkg"; then
      log "brew package already installed: $pkg"
    else
      install_brew_formula "$pkg"
    fi
  done

  ensure_dir_secure "$HOME/.gnupg"
  ensure_dir_secure "$HOME/.ssh"
  if should_run "Set file permissions under $HOME/.gnupg to 600?" "y"; then
    run "chmod 600 $HOME/.gnupg/* 2>/dev/null || true"
  else
    warn "Skipping chmod 600 for $HOME/.gnupg files"
  fi
  if should_run "Set file permissions under $HOME/.ssh to 600?" "y"; then
    run "chmod 600 $HOME/.ssh/* 2>/dev/null || true"
  else
    warn "Skipping chmod 600 for $HOME/.ssh files"
  fi

  local gpg_agent_conf="$HOME/.gnupg/gpg-agent.conf"
  local pinentry_program
  pinentry_program="$(brew --prefix pinentry-mac)/bin/pinentry-mac"
  backup_file "$gpg_agent_conf"
  replace_or_append_line "$gpg_agent_conf" "pinentry-program .*" "pinentry-program $pinentry_program"
  append_if_missing "$gpg_agent_conf" "default-cache-ttl 3600"
  append_if_missing "$gpg_agent_conf" "default-cache-ttl-ssh 3600"
  append_if_missing "$gpg_agent_conf" "max-cache-ttl 7200"
  append_if_missing "$gpg_agent_conf" "max-cache-ttl-ssh 7200"
  append_if_missing "$gpg_agent_conf" "enable-ssh-support"

  local scdaemon_conf="$HOME/.gnupg/scdaemon.conf"
  backup_file "$scdaemon_conf"
  append_if_missing "$scdaemon_conf" "disable-ccid"

  local zshrc="$HOME/.zshrc"
  local gnupg_prefix
  local gpg_bin
  local gpgconf_bin
  local gpg_connect_agent_bin
  gnupg_prefix="$(brew --prefix gnupg)"
  gpg_bin="$gnupg_prefix/bin/gpg"
  gpgconf_bin="$gnupg_prefix/bin/gpgconf"
  gpg_connect_agent_bin="$gnupg_prefix/bin/gpg-connect-agent"

  backup_file "$zshrc"
  replace_or_append_line "$zshrc" "export GPG_TTY=.*" "export GPG_TTY=\$(tty)"
  replace_or_append_line "$zshrc" "export SSH_AUTH_SOCK=.*gpgconf --list-dirs agent-ssh-socket.*" "export SSH_AUTH_SOCK=\$($gpgconf_bin --list-dirs agent-ssh-socket)"
  replace_or_append_line "$zshrc" "alias gpgreset=.*gpg-connect-agent.*" "alias gpgreset='$gpg_connect_agent_bin killagent /bye; $gpg_connect_agent_bin updatestartuptty /bye; $gpg_connect_agent_bin /bye'"

  log "Bootstrap step complete."
  log "Open a new terminal or run: exec \$SHELL -l"
  log "Then run: gpgreset"
}

# ----- Helper: list keys & choose fingerprint -----
choose_gpg_key() {
  log "Listing existing secret keys:"
  run "gpg --list-secret-keys --keyid-format=long" || true

  printf "Enter GPG key fingerprint (or leave empty to cancel): "
  local fp
  read -r fp || fp=""
  if [[ -z "$fp" ]]; then
    die "No fingerprint provided."
  fi
  echo "$fp"
}

# ----- Step: create-keys -----
step_create_keys() {
  log "Step: create-keys (GPG master + subkeys)"

  # Show existing keys if any
  if gpg --list-secret-keys >/dev/null 2>&1; then
    log "Existing GPG secret keys detected."
    if ! ask_yes_no "Do you want to create a NEW identity/keypair for YubiKey?" "y"; then
      warn "Skipping key creation. You can reuse an existing key in later steps."
      return
    fi
  else
    log "No existing GPG secret keys found. A new keypair will be created."
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    warn "Dry-run: not calling gpg --full-generate-key. You must run it manually without --dry-run."
    return
  fi

  log "Launching interactive GPG key creation."
  log "Recommended choices:"
  log "  - Key type: (9) ECC and ECC"
  log "  - Curve: ed25519"
  log "  - Usage: Sign, Certify (SC)"
  log "  - Expiry: e.g. 3y"
  run "gpg --full-generate-key"

  log "New keypair created. Listing keys:"
  run "gpg --list-secret-keys --keyid-format=long"

  log "Now we will add subkeys for Sign, Encrypt, and Authenticate."
  local fp
  fp=$(choose_gpg_key)

  if [[ $DRY_RUN -eq 1 ]]; then
    warn "Dry-run: not entering gpg --edit-key; follow drduh-style guide to add subkeys manually."
    return
  fi

  cat <<EOF

[Manual step - but wizard guided]

The script will now open:
  gpg --edit-key $fp

Inside that prompt, do:

  1) addkey
     - choose (9) ECC and ECC
     - choose ed25519
     - set usage: Sign (S)
     - set expiry (e.g. 2y)

  2) addkey
     - choose (9) ECC and ECC
     - choose cv25519
     - set usage: Encrypt (E)
     - set expiry (e.g. 2y)

  3) addkey
     - choose (9) ECC and ECC
     - choose ed25519
     - set usage: Authenticate (A)
     - set expiry (e.g. 2y)

  4) save

Press Enter to continue and open the gpg edit prompt.
EOF
  read -r _dummy
  run "gpg --edit-key $fp"
  log "Subkey creation done (assuming you followed the steps)."
}

# ----- Step: backup -----
step_backup() {
  log "Step: backup (export GPG keys)"

  local backup_dir="$HOME/gpg-backup"
  ensure_dir_secure "$backup_dir"

  log "You need to choose which key fingerprint to backup."
  local fp
  fp=$(choose_gpg_key)

  if [[ $DRY_RUN -eq 1 ]]; then
    warn "Dry-run: would export keys for fingerprint $fp to $backup_dir."
    return
  fi

  local master_file="$backup_dir/master-and-subkeys.sec"
  local subkeys_file="$backup_dir/subkeys-only.sec"
  local pub_file="$backup_dir/public.asc"

  log "Exporting full secret keys to: $master_file"
  run "gpg --export-secret-keys $fp > '$master_file'"

  log "Exporting secret subkeys to: $subkeys_file"
  run "gpg --export-secret-subkeys $fp > '$subkeys_file'"

  log "Exporting public key to: $pub_file"
  run "gpg --export --armor $fp > '$pub_file'"

  log "Now we can optionally zip + encrypt these exports."
  if ask_yes_no "Zip and password-protect the backup in gpg-backup.zip?" "y"; then
    (
      cd "$backup_dir" || exit 1
      run "zip -e gpg-backup.zip master-and-subkeys.sec subkeys-only.sec public.asc"
      log "Securely deleting raw export files."
      run "shred master-and-subkeys.sec subkeys-only.sec public.asc"
    )
  else
    warn "Leaving raw .sec and .asc files in $backup_dir. Ensure the directory is encrypted or moved to secure storage."
  fi

  log "Backup step complete."
}

# ----- Helper: move subkeys to card -----
move_subkeys_to_card() {
  local fp="$1"
  local which="$2"  # primary or backup (for messaging only)

  if [[ $DRY_RUN -eq 1 ]]; then
    warn "Dry-run: would run gpg --edit-key $fp and 'keytocard' subkeys to $which YubiKey."
    return
  fi

  cat <<EOF

[Manual step - moving subkeys to $which YubiKey]

The script will open:

  gpg --edit-key $fp

In the prompt:

  key 1
  keytocard
  # choose slot 1 (Signature)

  key 2
  keytocard
  # choose slot 2 (Encryption)

  key 3
  keytocard
  # choose slot 3 (Authentication)

  save

Press Enter when the $which YubiKey is inserted and you're ready.
EOF
  read -r _dummy
  run "gpg --edit-key $fp"
  log "Assuming key 1/2/3 were moved to card for $which YubiKey."
}

# ----- Step: to-primary -----
step_to_primary() {
  log "Step: to-primary (move subkeys to PRIMARY YubiKey)"

  log "Insert your PRIMARY YubiKey now."
  read -r -p "Press Enter when inserted..." _dummy

  log "Checking card status:"
  run "gpg --card-status || true"

  local fp
  fp=$(choose_gpg_key)

  move_subkeys_to_card "$fp" "PRIMARY"
}

# ----- Step: to-backup -----
step_to_backup() {
  log "Step: to-backup (move subkeys to BACKUP YubiKey)"

  log "Insert your BACKUP YubiKey now."
  read -r -p "Press Enter when inserted..." _dummy

  log "Checking card status:"
  run "gpg --card-status || true"

  local fp
  fp=$(choose_gpg_key)

  # If you previously removed the master key from this machine,
  # you would re-import from backup before this step.
  warn "Ensure this machine has the private subkeys available (from backup) before running keytocard."

  move_subkeys_to_card "$fp" "BACKUP"
}

# ----- Step: ssh-gpg -----
step_ssh_gpg() {
  log "Step: ssh-gpg (wire GPG to SSH agent)"

  if [[ $DRY_RUN -eq 1 ]]; then
    warn "Dry-run: would call gpgreset and ssh-add -L to verify."
    return
  fi

  log "Reloading gpg-agent and SSH socket via gpgreset alias (if defined)."
  if command -v gpgreset >/dev/null 2>&1; then
    run "gpgreset"
  else
    run "gpg-connect-agent killagent /bye || true"
    run "gpg-connect-agent updatestartuptty /bye || true"
    run "gpg-connect-agent /bye || true"
  fi

  log "Listing SSH keys exposed by gpg-agent (if any):"
  run "ssh-add -L || true"

  log "If an ssh-ed25519 key appears here with your UID, that's your YubiKey auth subkey."
  log "You can export that SSH public key to a file like this:"
  log "  gpg --export-ssh-key \"you@example.com\" > ~/.ssh/yubikey.pub"
}

# ----- Step: git-sign -----
step_git_sign() {
  log "Step: git-sign (configure Git commit signing)"

  local fp
  fp=$(choose_gpg_key)

  if [[ $DRY_RUN -eq 1 ]]; then
    warn "Dry-run: would set git config user.signingkey=$fp and commit.gpgsign=true"
    return
  fi

  log "Setting Git global signing key to $fp"
  run "git config --global user.signingkey $fp"
  log "Enabling global signed commits"
  run "git config --global commit.gpgsign true"
  log "Setting gpg.program to gpg"
  run "git config --global gpg.program gpg"

  log "Git signing configured. Test it with:"
  log "  git commit -S -m \"Test signed commit\""
}

# ----- Dispatcher -----
case "$STEP" in
  bootstrap)   step_bootstrap ;;
  create-keys) step_create_keys ;;
  backup)      step_backup ;;
  to-primary)  step_to_primary ;;
  to-backup)   step_to_backup ;;
  ssh-gpg)     step_ssh_gpg ;;
  git-sign)    step_git_sign ;;
  all)
    step_bootstrap
    step_create_keys
    step_backup
    step_to_primary
    step_to_backup
    step_ssh_gpg
    step_git_sign
    ;;
  *)
    die "Unknown step: $STEP"
    ;;
esac
