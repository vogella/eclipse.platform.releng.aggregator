#!/usr/bin/env bash
#
# Upload the generated p2 update site and the patched Windows SDK archive to
# eclipsercp.de. Both are uploaded on every run:
#
#   sites/eclipse-platform-repository/target/repository
#       -> https://eclipsercp.de/download/update-site/
#   /home/vogella/dev/eclipse-SDK-vogella-win32-x86_64.zip
#       -> https://eclipsercp.de/download/products/
#
# The aggregator build produces the p2 repository (content.jar, artifacts.jar,
# features/, plugins/, binary/, p2.index); apply_prs.sh --build produces the
# Windows archive (patched SDK with EGit and m2e pre-installed).
#
# eclipsercp.de is deployed by Jenkins via rsync, but that pipeline deliberately
# excludes the large binary artifacts under download/*/ (see the Jenkinsfile and
# CLAUDE.md in the eclipsercp repo). Those directories are filled "out of band",
# which is what this script does.
#
# The web paths map to /var/www/vhosts/eclipsercp/www/download/{update-site,products}/.
# Both directories also hold a hand-maintained index.html landing page which is
# not part of the uploaded content: the update-site sync excludes it so --delete
# never removes it, and the products upload only ever writes its one archive.
#
# The target directories are owned by the "jenkins" user, so the remote write is
# performed as jenkins via passwordless sudo: rsync is invoked on the server as
# `sudo -u jenkins rsync` (--rsync-path). You connect with your own SSH account
# but the files are created, updated and deleted as jenkins, in one pass.
# Requires NOPASSWD sudo for `sudo -u jenkins rsync` on the server.
#
# Usage:
#   ./upload-update-site.sh [options]
#
# Options:
#   -u USER      SSH user (default: $REMOTE_USER, else current $USER)
#   -h HOST      Remote host          (default: eclipsercp.de)
#   -s SOURCE    Local p2 repository  (default: sites/eclipse-platform-repository/target/repository)
#   -d DIR       Remote update site   (default: /var/www/vhosts/eclipsercp/www/download/update-site)
#   -S USER      Run the remote rsync as this user via sudo (default: jenkins)
#   -p, --product FILE
#                Product archive to upload (default: /home/vogella/dev/eclipse-SDK-vogella-win32-x86_64.zip)
#   -D, --product-dir DIR
#                Remote product directory (default: /var/www/vhosts/eclipsercp/www/download/products)
#   --no-product Upload only the update site, skip the product archive
#   --product-only
#                Upload only the product archive, skip the update site
#   --usage-data-update-site
#                Upload only the usage data update site, skip everything else
#   --no-sudo    Write as the SSH user directly, no sudo (use when you own the dir)
#   -n           Dry run: show what rsync would transfer, change nothing
#   -k           Keep remote extras: do not pass --delete (leaves stale files in place)
#   --help       Show this help
#
# Environment overrides: REMOTE_USER, REMOTE_HOST, SOURCE, REMOTE_DIR, RUN_AS,
#                        PRODUCT, PRODUCT_DIR, USAGE_DATA_SOURCE, USAGE_DATA_DIR
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REMOTE_USER="${REMOTE_USER:-$USER}"
REMOTE_HOST="${REMOTE_HOST:-eclipsercp.de}"
SOURCE="${SOURCE:-$SCRIPT_DIR/sites/eclipse-platform-repository/target/repository}"
REMOTE_DIR="${REMOTE_DIR:-/var/www/vhosts/eclipsercp/www/download/update-site}"
# Stable file name, so the download link on eclipsercp.de survives every rebuild.
PRODUCT="${PRODUCT:-/home/vogella/dev/eclipse-SDK-vogella-win32-x86_64.zip}"
PRODUCT_DIR="${PRODUCT_DIR:-/var/www/vhosts/eclipsercp/www/download/products}"
# Usage data update site, built from the org.eclipse.epp.usagedata repository.
USAGE_DATA_SOURCE="${USAGE_DATA_SOURCE:-$HOME/git/org.eclipse.epp.usagedata/org.eclipse.epp.usagedata.repository/target/repository}"
USAGE_DATA_DIR="${USAGE_DATA_DIR:-/var/www/vhosts/eclipsercp/www/download/usage-data-update-site}"
RUN_AS="${RUN_AS:-jenkins}"   # remote user to sudo to for the write; empty = no sudo
DRY_RUN=0
DELETE="--delete"
DO_SITE=1
DO_PRODUCT=1
DO_USAGE_DATA=0

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
        -p|--product) PRODUCT="$2"; shift 2;;
        -D|--product-dir) PRODUCT_DIR="$2"; shift 2;;
        --no-product) DO_PRODUCT=0; shift;;
        --product-only) DO_SITE=0; shift;;
        --usage-data-update-site) DO_SITE=0; DO_PRODUCT=0; DO_USAGE_DATA=1; shift;;
        --no-sudo) RUN_AS=""; shift;;
        -n) DRY_RUN=1;        shift;;
        -k) DELETE="";        shift;;
        --help) usage 0;;
        *) echo "Unknown argument: $1" >&2; usage 1;;
    esac
done

# --- Validate the sources -----------------------------------------------------
if [[ $DO_SITE -eq 1 ]]; then
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
fi
if [[ $DO_PRODUCT -eq 1 && ! -f "$PRODUCT" ]]; then
    echo "ERROR: product archive does not exist: $PRODUCT" >&2
    echo "Build it with ./apply_prs.sh --build, point -p at an existing archive," >&2
    echo "or pass --no-product to upload the update site only." >&2
    exit 1
fi
if [[ $DO_USAGE_DATA -eq 1 ]]; then
    if [[ ! -d "$USAGE_DATA_SOURCE" ]]; then
        echo "ERROR: usage data update site does not exist: $USAGE_DATA_SOURCE" >&2
        echo "Build it first in ~/git/org.eclipse.epp.usagedata or set USAGE_DATA_SOURCE." >&2
        exit 1
    fi
    if [[ ! -f "$USAGE_DATA_SOURCE/artifacts.jar" && ! -f "$USAGE_DATA_SOURCE/artifacts.xml.xz" ]] \
       || [[ ! -f "$USAGE_DATA_SOURCE/content.jar" && ! -f "$USAGE_DATA_SOURCE/content.xml.xz" ]]; then
        echo "ERROR: $USAGE_DATA_SOURCE does not look like a p2 repository" >&2
        echo "       (no content.jar / artifacts.jar found)." >&2
        exit 1
    fi
fi

REMOTE="${REMOTE_USER}@${REMOTE_HOST}"
SSH_OPTS="ssh -o StrictHostKeyChecking=accept-new"
SITE_URL="https://${REMOTE_HOST}${REMOTE_DIR##*/www}/"
PRODUCT_URL="https://${REMOTE_HOST}${PRODUCT_DIR##*/www}/$(basename "$PRODUCT")"
USAGE_DATA_URL="https://${REMOTE_HOST}${USAGE_DATA_DIR##*/www}/"

# Run the remote write as RUN_AS via sudo, unless it's disabled or we already
# connect as that user. The remote rsync becomes `sudo -u RUN_AS rsync`, so
# files are created/owned by RUN_AS even though we log in as our own account.
RSYNC_PATH_ARG=()
WRITE_AS="$REMOTE_USER"
if [[ -n "$RUN_AS" && "$RUN_AS" != "$REMOTE_USER" ]]; then
    RSYNC_PATH_ARG=(--rsync-path="sudo -u $RUN_AS rsync")
    WRITE_AS="$RUN_AS (sudo)"
fi

echo "Host       : ${REMOTE}"
echo "Write as   : ${WRITE_AS}"
if [[ $DO_SITE -eq 1 ]]; then
    echo "Update site: $SOURCE  ($(du -sh "$SOURCE" | cut -f1))"
    echo "          -> ${REMOTE_DIR}/  (${SITE_URL})"
fi
if [[ $DO_PRODUCT -eq 1 ]]; then
    echo "Product    : $PRODUCT  ($(du -sh "$PRODUCT" | cut -f1))"
    echo "          -> ${PRODUCT_DIR}/  (${PRODUCT_URL})"
fi
if [[ $DO_USAGE_DATA -eq 1 ]]; then
    echo "Usage data : $USAGE_DATA_SOURCE  ($(du -sh "$USAGE_DATA_SOURCE" | cut -f1))"
    echo "          -> ${USAGE_DATA_DIR}/  (${USAGE_DATA_URL})"
fi
[[ $DRY_RUN -eq 1 ]] && echo "Mode       : DRY RUN (no changes)"
[[ -z "$DELETE" ]] && echo "Note       : --delete disabled, stale remote files will be kept"
echo

# --- Make sure the remote directories exist -----------------------------------
# With sudo, rsync (running as RUN_AS) creates the final directory itself, since
# its parent download/ already exists. We only pre-create the path in the no-sudo
# case, where mkdir runs as our own writable account. This keeps the sudo surface
# limited to exactly `rsync` (matching a NOPASSWD rsync rule).
if [[ $DRY_RUN -eq 0 && ${#RSYNC_PATH_ARG[@]} -eq 0 ]]; then
    if [[ $DO_SITE -eq 1 ]]; then
        $SSH_OPTS "$REMOTE" "mkdir -p '$REMOTE_DIR'"
    fi
    if [[ $DO_PRODUCT -eq 1 ]]; then
        $SSH_OPTS "$REMOTE" "mkdir -p '$PRODUCT_DIR'"
    fi
    if [[ $DO_USAGE_DATA -eq 1 ]]; then
        $SSH_OPTS "$REMOTE" "mkdir -p '$USAGE_DATA_DIR'"
    fi
fi

# --- Upload the update site ---------------------------------------------------
# Trailing slash on SOURCE => copy the *contents* into REMOTE_DIR.
# --delete keeps the remote an exact mirror so p2 metadata (content/artifacts)
# always matches the plugins/ and features/ actually present.
# --exclude='index.html' protects the hand-maintained listing page: it is not in
# the generated repository, and rsync does not delete excluded files (that would
# need --delete-excluded), so the page is neither overwritten nor removed.
# --no-perms/owner/group: shared hosting target, do not try to set ownership.
SITE_ARGS=(-rltvz --human-readable --no-perms --no-owner --no-group $DELETE --exclude='index.html')
[[ $DRY_RUN -eq 1 ]] && SITE_ARGS+=(--dry-run)

if [[ $DO_SITE -eq 1 ]]; then
    echo "--- Update site ---"
    rsync "${SITE_ARGS[@]}" "${RSYNC_PATH_ARG[@]}" -e "$SSH_OPTS" \
        "${SOURCE%/}/" "${REMOTE}:${REMOTE_DIR}/"
    echo
fi

if [[ $DO_USAGE_DATA -eq 1 ]]; then
    echo "--- Usage data update site ---"
    rsync "${SITE_ARGS[@]}" "${RSYNC_PATH_ARG[@]}" -e "$SSH_OPTS" \
        "${USAGE_DATA_SOURCE%/}/" "${REMOTE}:${USAGE_DATA_DIR}/"
    echo
fi

# --- Upload the product archive -----------------------------------------------
# No -z for an already-compressed archive, and no --delete: the landing page and
# archives for other platforms in that directory must survive. rsync writes to a
# temp file and renames, so a half-transferred zip is never served.
if [[ $DO_PRODUCT -eq 1 ]]; then
    echo "--- Windows product ---"
    PRODUCT_ARGS=(-ltv --human-readable --no-perms --no-owner --no-group)
    [[ $DRY_RUN -eq 1 ]] && PRODUCT_ARGS+=(--dry-run)
    rsync "${PRODUCT_ARGS[@]}" "${RSYNC_PATH_ARG[@]}" -e "$SSH_OPTS" \
        "$PRODUCT" "${REMOTE}:${PRODUCT_DIR}/"
    echo
fi

if [[ $DRY_RUN -eq 1 ]]; then
    echo "Dry run complete. Re-run without -n to upload."
else
    echo "Done."
    if [[ $DO_SITE -eq 1 ]]; then
        echo "  Update site: ${SITE_URL}"
    fi
    if [[ $DO_PRODUCT -eq 1 ]]; then
        echo "  Download   : ${PRODUCT_URL}"
    fi
    if [[ $DO_USAGE_DATA -eq 1 ]]; then
        echo "  Update site: ${USAGE_DATA_URL}"
    fi
fi
