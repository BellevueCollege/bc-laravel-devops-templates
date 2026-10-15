#!/usr/bin/env bash
#
# Laravel deploy script for on-prem Apache (split docroot).
# Runs on the target VM via an Azure DevOps Environment deployment agent.
# Arguments are paths and flags only (no secret values).
#
# Usage: deploy-laravel.sh APP_NAME SERVER_APP_ROOT SERVER_PUBLIC_ROOT
#        SERVER_TEMP_ROOT SERVER_BACKUP_PATH ARCHIVE_PATH ENV_FILE INDEX_FILE
#        CACHE_ROUTES RUN_MIGRATIONS
#
# BUILD_ID is parsed from ARCHIVE_PATH (${APP_NAME}_<buildId>.tar.gz).

set -Eeuo pipefail

readonly BACKUP_RETENTION_COUNT=3

APP_NAME="${1:?app name required}"
SERVER_APP_ROOT="${2:?server app root required}"
SERVER_PUBLIC_ROOT="${3:?server public root required}"
SERVER_TEMP_ROOT="${4:?server temp root required}"
SERVER_BACKUP_PATH="${5:?server backup path required}"
ARCHIVE_PATH="${6:?archive path required}"
ENV_FILE="${7:?env file path required}"
INDEX_FILE="${8:?index file path required}"
CACHE_ROUTES="${9:-true}"
RUN_MIGRATIONS="${10:-false}"

ARCHIVE_BASENAME="$(basename "$ARCHIVE_PATH")"
BUILD_ID="${ARCHIVE_BASENAME#${APP_NAME}_}"
BUILD_ID="${BUILD_ID%.tar.gz}"

if [[ -z "$BUILD_ID" ]] || [[ "$BUILD_ID" == "$ARCHIVE_BASENAME" ]]; then
  echo "ERROR: Could not parse build ID from archive name ${ARCHIVE_BASENAME}" >&2
  exit 1
fi

EXTRACT_DIR="${SERVER_TEMP_ROOT}/${APP_NAME}_${BUILD_ID}_extract"
BACKUP_ROOT="${SERVER_BACKUP_PATH}/${APP_NAME}_${BUILD_ID}"

SWAP_STARTED=false
APP_SWAP_DONE=false
PUBLIC_SWAP_DONE=false

log_phase() {
  echo "=== $1 ==="
}

log_agent_context() {
  # Identity of the deployment agent — useful when diagnosing PATH/ACL issues.
  echo "Agent user: $(whoami)"
  echo "Hostname: $(hostname)"
  echo "umask: $(umask)"
}

fail_with_message() {
  echo "ERROR: $1" >&2
  exit 1
}

assert_absolute_path() {
  local label="$1"
  local path_value="$2"
  case "$path_value" in
    /*) ;;
    *) fail_with_message "${label} must be an absolute path (got: ${path_value})" ;;
  esac
}

validate_paths() {
  assert_absolute_path "serverAppRoot" "$SERVER_APP_ROOT"
  assert_absolute_path "serverPublicRoot" "$SERVER_PUBLIC_ROOT"
  assert_absolute_path "serverTempRoot" "$SERVER_TEMP_ROOT"
  assert_absolute_path "serverBackupPath" "$SERVER_BACKUP_PATH"
}

# List archive members once. Avoids tar|grep under pipefail: when grep exits
# early on a match, tar gets SIGPIPE and the pipeline falsely fails.
archive_contains_member() {
  local pattern="$1"
  printf '%s\n' "${ARCHIVE_MEMBER_LIST}" | grep -Eq "$pattern"
}

validate_archive() {
  log_phase "Validate archive"
  echo "Build ID: ${BUILD_ID}"
  echo "Archive path: ${ARCHIVE_PATH}"

  if [[ ! -f "$ARCHIVE_PATH" ]]; then
    echo "Archive not found. Staging directory listing:"
    ls -la "$SERVER_TEMP_ROOT" || true
    fail_with_message "Archive missing at ${ARCHIVE_PATH}"
  fi

  if ! tar -tzf "$ARCHIVE_PATH" >/dev/null 2>&1; then
    fail_with_message "Archive is not readable or is corrupt"
  fi

  ARCHIVE_MEMBER_LIST="$(tar -tzf "$ARCHIVE_PATH")"

  if ! archive_contains_member '(^|/)artisan$'; then
    echo "Archive members matching artisan / public/index.php:"
    printf '%s\n' "${ARCHIVE_MEMBER_LIST}" | grep -E 'artisan|public/index\.php' || true
    echo "Archive members (first 40):"
    printf '%s\n' "${ARCHIVE_MEMBER_LIST}" | head -40 || true
    fail_with_message "Archive must contain artisan at the application root"
  fi

  if ! archive_contains_member 'public/index\.php$'; then
    fail_with_message "Archive must contain public/index.php"
  fi
}

extract_archive() {
  log_phase "Extract archive"
  echo "Extract directory: ${EXTRACT_DIR}"
  rm -rf "$EXTRACT_DIR"
  mkdir -p "$EXTRACT_DIR"
  tar -xzf "$ARCHIVE_PATH" \
    --no-same-owner \
    --no-same-permissions \
    --touch \
    -C "$EXTRACT_DIR"
}

preserve_live_storage() {
  if [[ ! -d "$SERVER_APP_ROOT/storage" ]]; then
    echo "No live storage directory; skipping preserve."
    return 0
  fi

  log_phase "Preserve storage from live app"
  mkdir -p "$EXTRACT_DIR/storage"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "${SERVER_APP_ROOT}/storage/" "${EXTRACT_DIR}/storage/"
  else
    cp -a "${SERVER_APP_ROOT}/storage/." "${EXTRACT_DIR}/storage/"
  fi
}

apply_deploy_config_files() {
  log_phase "Apply deploy config files"

  if [[ ! -f "$ENV_FILE" ]]; then
    fail_with_message "Filled .env file missing at ${ENV_FILE}"
  fi
  if grep -qE '#\{[^}]+\}#' "$ENV_FILE"; then
    fail_with_message "Filled .env still contains token placeholders: $(grep -oE '#\{[^}]+\}#' "$ENV_FILE" | sort -u | paste -sd ', ' -)"
  fi

  if [[ ! -f "$INDEX_FILE" ]]; then
    fail_with_message "Filled index.php missing at ${INDEX_FILE}"
  fi
  if grep -qE '#\{[^}]+\}#' "$INDEX_FILE"; then
    fail_with_message "Filled index.php still contains token placeholders: $(grep -oE '#\{[^}]+\}#' "$INDEX_FILE" | sort -u | paste -sd ', ' -)"
  fi

  cp "$ENV_FILE" "${EXTRACT_DIR}/.env"
  rm -f "${EXTRACT_DIR}/public/index.php"
  cp "$INDEX_FILE" "${EXTRACT_DIR}/public/index.php"
}

validate_php_before_swap() {
  log_phase "Validate PHP and artisan"
  php --version || fail_with_message "php not found in PATH"
  php "${EXTRACT_DIR}/artisan" --version || fail_with_message "artisan not executable"
}

backup_live_directories() {
  if [[ -d "$BACKUP_ROOT" ]]; then
    echo "Backup for build ${BUILD_ID} already exists; skipping new backup snapshot."
    if [[ -d "$SERVER_APP_ROOT" ]]; then
      rm -rf "${BACKUP_ROOT}/previous_attempt_app"
      echo "Moving current app aside to ${BACKUP_ROOT}/previous_attempt_app"
      mv -T "$SERVER_APP_ROOT" "${BACKUP_ROOT}/previous_attempt_app"
    fi
    return 0
  fi

  if [[ ! -d "$SERVER_APP_ROOT" ]] && [[ ! -d "$SERVER_PUBLIC_ROOT" ]]; then
    echo "First install; skipping backup."
    return 0
  fi

  log_phase "Backup live directories"
  mkdir -p "$BACKUP_ROOT"

  if [[ -d "$SERVER_APP_ROOT" ]]; then
    echo "Backing up app to ${BACKUP_ROOT}/app"
    mv -T "$SERVER_APP_ROOT" "${BACKUP_ROOT}/app"
  fi

  if [[ -d "$SERVER_PUBLIC_ROOT" ]]; then
    echo "Backing up public to ${BACKUP_ROOT}/public"
    cp -a "${SERVER_PUBLIC_ROOT}/." "${BACKUP_ROOT}/public/"
  fi
}

ensure_runtime_writable_directories() {
  log_phase "Ensure storage and bootstrap/cache are writable"
  local app_root="$SERVER_APP_ROOT"

  mkdir -p \
    "${app_root}/storage/framework/cache/data" \
    "${app_root}/storage/framework/sessions" \
    "${app_root}/storage/framework/views" \
    "${app_root}/storage/logs" \
    "${app_root}/bootstrap/cache"

  # Deploy agent and PHP-FPM (www-data) must both write here; group perms help when umask allows.
  chmod -R u+rwX,g+rwX "${app_root}/storage" "${app_root}/bootstrap/cache" 2>/dev/null \
    || chmod -R u+rwX "${app_root}/storage" "${app_root}/bootstrap/cache"
}

swap_app_directory() {
  log_phase "Swap app directory"
  SWAP_STARTED=true

  if [[ -d "$SERVER_APP_ROOT" ]]; then
    fail_with_message "serverAppRoot still exists before swap; backup step should have moved it"
  fi

  mv -T "$EXTRACT_DIR" "$SERVER_APP_ROOT"
  APP_SWAP_DONE=true
  echo "App root now at ${SERVER_APP_ROOT}"
}

run_artisan_down() {
  log_phase "Maintenance mode"
  cd "$SERVER_APP_ROOT"
  php artisan down
}

run_artisan_up() {
  log_phase "Leave maintenance mode"
  cd "$SERVER_APP_ROOT"
  php artisan up
}

swap_public_directory() {
  log_phase "Swap public directory"
  local public_parent
  local staging_dir
  local aside_dir

  public_parent="$(dirname "$SERVER_PUBLIC_ROOT")"
  staging_dir="${public_parent}/${APP_NAME}_${BUILD_ID}_public_staging"
  aside_dir="${public_parent}/${APP_NAME}_${BUILD_ID}_public_aside"

  rm -rf "$staging_dir" "$aside_dir"
  mkdir -p "$staging_dir"

  echo "Copying public files onto html filesystem: ${staging_dir}"
  cp -a "${SERVER_APP_ROOT}/public/." "$staging_dir/"

  if [[ ! -f "${staging_dir}/index.php" ]]; then
    fail_with_message "Staging public copy missing index.php"
  fi

  if [[ -d "$SERVER_PUBLIC_ROOT" ]]; then
    # Move the live docroot aside (not delete) so the new tree can take SERVER_PUBLIC_ROOT
    # in one rename; rollback can restore this folder if post-swap steps fail.
    echo "Moving live public aside to ${aside_dir}"
    mv -T "$SERVER_PUBLIC_ROOT" "$aside_dir"
  fi

  echo "Activating new public at ${SERVER_PUBLIC_ROOT}"
  mv -T "$staging_dir" "$SERVER_PUBLIC_ROOT"
  PUBLIC_SWAP_DONE=true
}

clear_bootstrap_cache() {
  log_phase "Clear bootstrap cache before caching"
  rm -f "${SERVER_APP_ROOT}/bootstrap/cache/"*.php
}

run_post_swap_artisan() {
  log_phase "Post-deploy artisan commands"
  cd "$SERVER_APP_ROOT"

  if [[ "$RUN_MIGRATIONS" == "true" ]] || [[ "$RUN_MIGRATIONS" == "True" ]]; then
    php artisan migrate --force
  fi

  php artisan config:cache

  # Non-secret runtime check — catches Library/token mismatches before queue:restart.
  # Use the configured default connection (mysql for idlookup, da/sqlsrv for data-api, etc.).
  php artisan tinker --execute="\$connection = config('database.default'); echo 'app.env=' . config('app.env') . PHP_EOL . 'cache.default=' . config('cache.default') . PHP_EOL . 'queue.default=' . config('queue.default') . PHP_EOL . 'session.driver=' . config('session.driver') . PHP_EOL . 'db.connection=' . \$connection . PHP_EOL . 'db.driver=' . config('database.connections.' . \$connection . '.driver') . PHP_EOL . 'db.host=' . config('database.connections.' . \$connection . '.host') . PHP_EOL . 'db.database=' . config('database.connections.' . \$connection . '.database') . PHP_EOL;"

  php artisan event:cache
  php artisan view:cache

  if [[ "$CACHE_ROUTES" == "true" ]] || [[ "$CACHE_ROUTES" == "True" ]]; then
    php artisan route:cache
  fi

  php artisan queue:restart
}

restore_from_backup() {
  log_phase "Rollback"
  local public_parent
  local aside_dir

  public_parent="$(dirname "$SERVER_PUBLIC_ROOT")"
  aside_dir="${public_parent}/${APP_NAME}_${BUILD_ID}_public_aside"

  if [[ -d "${BACKUP_ROOT}/app" ]]; then
    rm -rf "$SERVER_APP_ROOT"
    mv -T "${BACKUP_ROOT}/app" "$SERVER_APP_ROOT"
    echo "Restored app from backup."
  fi

  if [[ -d "${BACKUP_ROOT}/public" ]]; then
    rm -rf "$SERVER_PUBLIC_ROOT"
    mkdir -p "$SERVER_PUBLIC_ROOT"
    cp -a "${BACKUP_ROOT}/public/." "$SERVER_PUBLIC_ROOT/"
    echo "Restored public from backup."
  elif [[ -d "$aside_dir" ]]; then
    rm -rf "$SERVER_PUBLIC_ROOT"
    mv -T "$aside_dir" "$SERVER_PUBLIC_ROOT"
    echo "Restored public from aside directory."
  fi

  (cd "$SERVER_APP_ROOT" && php artisan up) \
    || echo "WARNING: artisan up failed - manual intervention required"
}

on_error() {
  local exit_code=$?
  if [[ "$SWAP_STARTED" == true ]]; then
    restore_from_backup || echo "WARNING: rollback failed - manual intervention required"
  fi
  exit "$exit_code"
}

prune_old_backups() {
  log_phase "Prune old backups"
  local backup_dirs=()
  local dir

  shopt -s nullglob
  for dir in "${SERVER_BACKUP_PATH}/${APP_NAME}_"*; do
    [[ -d "$dir" ]] && backup_dirs+=("$dir")
  done
  shopt -u nullglob

  if [[ ${#backup_dirs[@]} -le BACKUP_RETENTION_COUNT ]]; then
    echo "Backup count within retention limit."
    return 0
  fi

  IFS=$'\n' sorted=( $(printf '%s\n' "${backup_dirs[@]}" | sort -r) )
  unset IFS

  local index
  for (( index=BACKUP_RETENTION_COUNT; index<${#sorted[@]}; index++ )); do
    echo "Removing old backup: ${sorted[$index]}"
    rm -rf "${sorted[$index]}"
  done
}

remove_public_aside_directory() {
  local aside_dir="$1"

  if [[ ! -d "$aside_dir" ]]; then
    return 0
  fi

  if rm -rf "$aside_dir"; then
    echo "Removed public aside directory ${aside_dir}"
    return 0
  fi

  echo "WARNING: Could not remove public aside ${aside_dir} (often Apache-owned files under the old docroot)."
  echo "WARNING: Deploy succeeded; remove the aside directory manually or fix ACLs on the parent path."
  return 0
}

cleanup_success() {
  log_phase "Post-success cleanup"
  rm -rf "$EXTRACT_DIR"

  local public_parent
  local aside_dir
  public_parent="$(dirname "$SERVER_PUBLIC_ROOT")"
  aside_dir="${public_parent}/${APP_NAME}_${BUILD_ID}_public_aside"
  remove_public_aside_directory "$aside_dir"

  echo "Archive retained at ${ARCHIVE_PATH}"
  echo "Deploy completed at $(date -u +"%Y-%m-%dT%H:%M:%SZ") for build ${BUILD_ID}"
}

main() {
  trap on_error ERR
  log_agent_context
  validate_paths
  validate_archive
  extract_archive
  preserve_live_storage
  apply_deploy_config_files
  validate_php_before_swap
  backup_live_directories
  swap_app_directory
  ensure_runtime_writable_directories
  run_artisan_down
  swap_public_directory
  clear_bootstrap_cache
  run_post_swap_artisan
  run_artisan_up
  trap - ERR
  cleanup_success
  prune_old_backups
}

main "$@"
