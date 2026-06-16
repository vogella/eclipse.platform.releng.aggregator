#!/usr/bin/env bash
#
# Upload the generated p2 update site to https://eclipsercp.de/download/update-site/
#
# The aggregator build produces a full p2 repository under
#   sites/eclipse-platform-repository/target/repository
# (content.jar, artifacts.jar, features/, plugins/, binary/, p2.index).
#
# eclipsercp.de is deployed by Jenkins via rsync, but that pipeline deliberately
# excludes the large binary artifacts under download/*/ (see the Jenkinsfile and
# CLAUDE.md in the eclipsercp repo). Those directories are filled "out of band",
# which is what this script does.
#
# The web path https://eclipsercp.de/download/update-site/ maps to the server
# directory /var/www/vhosts/eclipsercp/www/download/update-site/.
#
# That directory also holds a hand-maintained index.html listing page which is
# NOT part of the generated p2 repository. It is excluded from the sync so
# --delete never removes or overwrites it.
#
# Usage:
#   ./upload-update-site.sh [options]
#
# The target directory is owned by the "jenkins" user, so the remote write is
# performed as jenkins via passwordless sudo: rsync is invoked on the server as
# `sudo -u jenkins rsync` (--rsync-path). You connect with your own SSH account
# but the files are created, updated and deleted as jenkins, in one pass.
# Requires NOPASSWD sudo for `sudo -u jenkins rsync` on the server.
#
# Usage:
#   ./upload-update-site.sh [options]
#
# Options:
#   -u USER     SSH user (default: $REMOTE_USER, else current $USER)
#   -h HOST     Remote host          (default: eclipsercp.de)
#   -s SOURCE   Local p2 repository  (default: sites/eclipse-platform-repository/target/repository)
#   -d DIR      Remote directory     (default: /var/www/vhosts/eclipsercp/www/download/update-site)
#   -S USER     Run the remote rsync as this user via sudo (default: jenkins)
#   --no-sudo   Write as the SSH user directly, no sudo (use when you own the dir)
#   -n          Dry run: show what rsync would transfer, change nothing
#   -k          Keep remote extras: do not pass --delete (leaves stale files in place)
#   --help      Show this help
#
# Environment overrides: REMOTE_USER, REMOTE_HOST, SOURCE, REMOTE_DIR, RUN_AS
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REMOTE_USER="${REMOTE_USER:-$USER}"
REMOTE_HOST="${REMOTE_HOST:-eclipsercp.de}"
SOURCE="${SOURCE:-$SCRIPT_DIR/sites/eclipse-platform-repository/target/repository}"
REMOTE_DIR="${REMOTE_DIR:-/var/www/vhosts/eclipsercp/www/download/update-site}"
RUN_AS="${RUN_AS:-jenkins}"   # remote user to sudo to for the write; empty = no sudo
DRY_RUN=0
DELETE="--delete"

usage() {
    # Print the leading comment block (skip the shebang, stop at first non-# line).
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u) REMOTE_USER="$2"; shift 2;;
        -h) REMOTE_HOST="$2"; shift 2;;
        -s) SOURCE="$2";      shift 2;;
        -d) REMOTE_DIR="$2";  shift 2;;
        -S) RUN_AS="$2";      shift 2;;
        --no-sudo) RUN_AS=""; shift;;
        -n) DRY_RUN=1;        shift;;
        -k) DELETE="";        shift;;
        --help) usage 0;;
        *) echo "Unknown argument: $1" >&2; usage 1;;
    esac
done

# --- Validate the source is actually a p2 update site -------------------------
if [[ ! -d "$SOURCE" ]]; then
    echo "ERROR: source directory does not exist: $SOURCE" >&2
    echo "Build it first, e.g.:" >&2
    echo "  mvn -f eclipse.platform.releng.tycho4-api/pom.xml ... clean verify" >&2
    echo "or point -s at an existing p2 repository." >&2
    exit 1
fi
if [[ ! -f "$SOURCE/artifacts.jar" && ! -f "$SOURCE/artifacts.xml.xz" ]] \
   || [[ ! -f "$SOURCE/content.jar" && ! -f "$SOURCE/content.xml.xz" ]]; then
    echo "ERROR: $SOURCE does not look like a p2 repository" >&2
    echo "       (no content.jar / artifacts.jar found)." >&2
    exit 1
fi

REMOTE="${REMOTE_USER}@${REMOTE_HOST}"
SSH_OPTS="ssh -o StrictHostKeyChecking=accept-new"

# Run the remote write as RUN_AS via sudo, unless it's disabled or we already
# connect as that user. The remote rsync becomes `sudo -u RUN_AS rsync`, so
# files are created/owned by RUN_AS even though we log in as our own account.
RSYNC_PATH_ARG=()
WRITE_AS="$REMOTE_USER"
if [[ -n "$RUN_AS" && "$RUN_AS" != "$REMOTE_USER" ]]; then
    RSYNC_PATH_ARG=(--rsync-path="sudo -u $RUN_AS rsync")
    WRITE_AS="$RUN_AS (sudo)"
fi

echo "Source   : $SOURCE  ($(du -sh "$SOURCE" | cut -f1))"
echo "Target   : ${REMOTE}:${REMOTE_DIR}/"
echo "Write as : ${WRITE_AS}"
echo "URL      : https://${REMOTE_HOST}/download/update-site/"
[[ $DRY_RUN -eq 1 ]] && echo "Mode     : DRY RUN (no changes)"
[[ -z "$DELETE" ]] && echo "Note     : --delete disabled, stale remote files will be kept"
echo

# --- Make sure the remote directory exists -----------------------------------
# With sudo, rsync (running as RUN_AS) creates the final "update-site" directory
# itself, since its parent download/ already exists. We only pre-create the path
# in the no-sudo case, where mkdir runs as our own writable account. This keeps
# the sudo surface limited to exactly `rsync` (matching a NOPASSWD rsync rule).
if [[ $DRY_RUN -eq 0 && ${#RSYNC_PATH_ARG[@]} -eq 0 ]]; then
    $SSH_OPTS "$REMOTE" "mkdir -p '$REMOTE_DIR'"
fi

# --- Upload -------------------------------------------------------------------
# Trailing slash on SOURCE => copy the *contents* into REMOTE_DIR.
# --delete keeps the remote an exact mirror so p2 metadata (content/artifacts)
# always matches the plugins/ and features/ actually present.
# --exclude='index.html' protects the hand-maintained listing page: it is not in
# the generated repository, and rsync does not delete excluded files (that would
# need --delete-excluded), so the page is neither overwritten nor removed.
# --no-perms/owner/group: shared hosting target, do not try to set ownership.
RSYNC_ARGS=(-rltvz --human-readable --no-perms --no-owner --no-group $DELETE --exclude='index.html')
[[ $DRY_RUN -eq 1 ]] && RSYNC_ARGS+=(--dry-run)

rsync "${RSYNC_ARGS[@]}" "${RSYNC_PATH_ARG[@]}" -e "$SSH_OPTS" \
    "${SOURCE%/}/" "${REMOTE}:${REMOTE_DIR}/"

echo
if [[ $DRY_RUN -eq 1 ]]; then
    echo "Dry run complete. Re-run without -n to upload."
else
    echo "Done. Update site available at: https://${REMOTE_HOST}/download/update-site/"
fi
