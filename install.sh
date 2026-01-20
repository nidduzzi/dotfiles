# #!/usr/bin/env bash
# NOTE: Just use stow <package>, stow -D <package> to reset, stow -R <package> to reload
# set -Eeuo pipefail
#
# DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TARGET="$HOME"
# BACKUP_ROOT="$TARGET/dotfiles-backup"
# BACKUP_DIR=""
# DRY_RUN=0
#
# #######################################
# # Utility
# #######################################
# die() {
#   echo "Error: $*" >&2
#   exit 1
# }
#
# log() {
#   echo "[*] $*"
# }
#
# require() {
#   for tool in "$@"; do
#     command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
#   done
# }
#
# require stow git
#
# normalize_pkg() {
#   local pkg="$1"
#   # Remove trailing slashes and backslashes
#   pkg="${pkg%/}"
#   pkg="${pkg%\\}"
#   echo "$pkg"
# }
#
# #######################################
# # Dry-run helpers
# #######################################
# run() {
#   if [[ "$DRY_RUN" -eq 1 ]]; then
#     printf '[dry-run] %q ' "$@"; echo
#   else
#     "$@"
#   fi
# }
#
# #######################################
# # Local config generation
# #######################################
# generate_local_files() {
#   local pkg="$1"
#
#   # Use -print0 to safely handle filenames with spaces
#   find "$DOTFILES_DIR/$pkg" -type f -name "*.local.example" -print0 | while IFS= read -r -d '' example; do
#     local target="${example%.example}"
#
#     [[ -e "$target" ]] && continue
#
#     if [[ "$DRY_RUN" -eq 1 ]]; then
#       echo "[dry-run] generate ${target#$DOTFILES_DIR/}"
#     else
#       log "Generating local config: ${target#$DOTFILES_DIR/}"
#       cp "$example" "$target"
#     fi
#   done
# }
#
# #######################################
# # Backup & rollback
# #######################################
# init_backup_dir() {
#   if [[ -z "$BACKUP_DIR" ]]; then
#     BACKUP_DIR="$BACKUP_ROOT/$(date -u +%Y-%m-%d_%H%M%S)"
#     run mkdir -p "$BACKUP_DIR"
#     log "Backups will be stored in $BACKUP_DIR"
#   fi
# }
#
# # Initialize backup dir if not already
# backup_path() {
#   local abs="$1"
#
#   [[ -e "$abs" ]] || return 0
#   [[ -L "$abs" ]] && return 0
#   [[ "$abs" == "$TARGET/"* ]] || die "Refusing to back up path outside \$HOME: $abs"
#
#   local rel="${abs#$TARGET/}"
#   local dest="$BACKUP_DIR/$rel"
#
#   # Fail if backup destination exists
#   if [[ -e "$dest" ]]; then
#     die "Backup destination already exists: $dest"
#   fi
#
#   run mkdir -p "$(dirname "$dest")"
#
#   run mv "$abs" "$dest" || die "Failed to move $abs to backup"
# }
#
# backup_conflicts() {
#   local pkg="$1"
#   local output
#
#   # LC_ALL=C ensures consistent output language for parsing
#   output=$(cd "$DOTFILES_DIR" && LC_ALL=C stow -n -v -t "$TARGET" "$pkg" 2>&1 || true)
#
#   # Extract the path using a more restrictive regex
#   echo "$output" | grep "existing target is" | while read -r line; do
#     # Capture everything after the specific phrase, trimming potential trailing spaces
#     local rel_path
#     rel_path=$(echo "$line" | sed -E 's/^.*existing target is[[:space:]]+(.*)$/\1/')
#
#     [[ -z "$rel_path" ]] && continue
#     local abs_target="$TARGET/$rel_path"
#
#     # Only back up if it's a real file/dir and NOT a symlink
#     if [[ -e "$abs_target" && ! -L "$abs_target" ]]; then
#       init_backup_dir
#       log "Backing up conflict: $abs_target"
#       backup_path "$abs_target"
#     fi
#   done
# }
#
# rollback() {
#   local dir="$1"
#   [[ -n "$dir" && -d "$dir" ]] || return 0
#
#   log "Rolling back from $dir"
#
#   # Restore everything, preserving structure
#   find "$dir" -depth -print0 | while IFS= read -r -d '' src; do
#     local rel="${src#$dir/}"
#     local dest="$TARGET/$rel"
#
#     if [[ -d "$src" ]]; then
#         # Only create parent if necessary
#         run mkdir -p "$(dirname "$dest")"
#         [[ -e "$dest" && ! -d "$dest" ]] && die "Cannot rollback: $dest exists but is not a directory"
#         run mv "$src" "$dest"
#     else
#         # Regular file or symlink
#         run mkdir -p "$(dirname "$dest")"
#         [[ -e "$dest" ]] && die "Cannot rollback: $dest already exists"
#         run mv "$src" "$dest"
#     fi
#   done
# }
#
# #######################################
# # Discover apps & variants
# #######################################
# discover_packages() {
#   find "$DOTFILES_DIR" \
#     -maxdepth 1 \
#     -mindepth 1 \
#     -type d \
#     ! -name ".git" \
#     -printf "%f\n" | grep -E '^[^-]+-.+'
# }
#
# list_apps() {
#   discover_packages | cut -d- -f1 | sort -u
# }
#
# variants_for_app() {
#   local app="$1"
#   discover_packages | grep "^${app}-"
# }
#
# #######################################
# # Actions
# #######################################
# stow_install() {
#   local pkg="$1"
#   log "Installing $pkg"
#
#   generate_local_files "$pkg"
#   backup_conflicts "$pkg"
#
#   if [[ "$DRY_RUN" -eq 1 ]]; then
#     (cd "$DOTFILES_DIR" && stow -n -v -t "$TARGET" "$pkg")
#   else
#     (cd "$DOTFILES_DIR" && stow -v -t "$TARGET" "$pkg")
#   fi
# }
#
# stow_uninstall() {
#   local pkg="$1"
#   log "Uninstalling $pkg"
#
#   # Added subshell 'cd' to ensure stow finds the package directory
#   if [[ "$DRY_RUN" -eq 1 ]]; then
#     (cd "$DOTFILES_DIR" && stow -n -D -v -t "$TARGET" "$pkg")
#   else
#     (cd "$DOTFILES_DIR" && stow -D -v -t "$TARGET" "$pkg")
#   fi
# }
#
# #######################################
# # Interactive mode
# #######################################
# interactive() {
#   echo "Operation? [install/uninstall] (default: install)"
#   read -r action
#   action="${action:-install}"
#
#   [[ "$action" == "install" || "$action" == "uninstall" ]] \
#     || die "Invalid action"
#
#   git submodule update --init --recursive
#
#   while true; do
#     echo
#     echo "Available apps:"
#     select app in $(list_apps) "Done"; do
#       [[ "$app" == "Done" ]] && return
#       [[ -n "$app" ]] && break
#     done
#
#     echo
#     echo "Variants for $app:"
#     select variant in $(variants_for_app "$app") "Back"; do
#       [[ "$variant" == "Back" ]] && break
#       [[ -n "$variant" ]] || continue
#
#       if [[ "$action" == "install" ]]; then
#         stow_install "$variant"
#       else
#         stow_uninstall "$variant"
#       fi
#       break
#     done
#   done
# }
#
# #######################################
# # Non-interactive mode
# #######################################
# non_interactive() {
#   local action="${1:-}"
#   shift || true
#
#   [[ -n "$action" ]] || die "Missing action"
#
#   # Install rollback trap early
#   trap '[[ -n "$BACKUP_DIR" ]] && rollback "$BACKUP_DIR"' ERR
#
#   if [[ "$action" == "rollback" ]]; then
#     [[ $# -eq 1 ]] || die "Usage: rollback <backup-dir>"
#     rollback "$1"
#     return 0
#   fi
#
#   [[ "$action" == "install" || "$action" == "uninstall" ]] \
#     || die "First argument must be install, uninstall, or rollback"
#
#   git submodule update --init --recursive
#
#   [[ $# -gt 0 ]] || die "No packages specified"
#
#   local pkg
#   for arg in "$@"; do
#     pkg="$(normalize_pkg "$arg")"
#     [[ -d "$DOTFILES_DIR/$pkg" ]] || die "Package $pkg not found"
#
#     if [[ "$action" == "install" ]]; then
#       stow_install "$pkg"
#     else
#       stow_uninstall "$pkg"
#     fi
#   done
# }
#
# #######################################
# # Entry
# #######################################
# if [[ $# -eq 0 ]]; then
#   interactive
# else
#   if [[ "$1" == "--dry-run" ]]; then
#     DRY_RUN=1
#     shift
#   fi
#   non_interactive "$@"
# fi
#
# log "Done!"
