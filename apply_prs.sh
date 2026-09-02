#!/bin/bash
set -e

# --- Configuration ---
# Define the PRs to be applied as a comma-separated list.
# Each entry may be in owner/repo#number form or as a full GitHub PR URL. It is
# fetched from the matching repo URL and applied to the submodule named after the
# repo, e.g.
#   "vogella/eclipse.platform.ui#13"                       -> eclipse.platform.ui submodule
#   "vogella/eclipse.platform#4"                           -> eclipse.platform submodule
#   "eclipse-platform/eclipse.platform.ui#4092"            -> eclipse.platform.ui submodule
#   "https://github.com/eclipse-pde/eclipse.pde/pull/2387" -> eclipse.pde submodule
#PRS="vogella/eclipse.platform.ui#15, vogella/eclipse.platform#5, vogella/eclipse.platform#4"
PRS=""
RUN_BUILD=false
# Default: fetch upstream, reset each submodule to its remote master tip, then
# apply the PRS list on top, so a build always uses the latest submodule state
# plus the specified PRs. Pass --ignoreGit to instead build the current working
# tree as-is (keeps local, unpushed submodule commits).
IGNORE_GIT=false
EXCLUDE_CSS_SPY=false
# With --upload the build result is pushed to eclipsercp.de afterwards: the p2
# update site plus the zipped Windows product.
UPLOAD=false
# Target environments to build. The <environments> block in
# eclipse-platform-parent/pom.xml is pruned to this list for the duration of the
# build, so the SDK product is only materialised for the platforms actually
# needed. Default: linux/gtk/x86_64 only; --upload adds win32/win32/x86_64 for
# the Windows zip; --allPlatforms leaves the pom untouched (all eight platforms).
ENVIRONMENTS="linux/gtk/x86_64"
ALL_PLATFORMS=false

# --- Argument Parsing ---
for arg in "$@"; do
  case $arg in
    --build)
      RUN_BUILD=true
      ;;
    --ignoreGit)
      # Skip all git operations and build whatever is currently checked out.
      IGNORE_GIT=true
      ;;
    --excludeCssSpy)
      EXCLUDE_CSS_SPY=true
      ;;
    --upload)
      UPLOAD=true
      ;;
    --allPlatforms)
      ALL_PLATFORMS=true
      ;;
  esac
done

if [ "$UPLOAD" = true ]; then
    ENVIRONMENTS="$ENVIRONMENTS win32/win32/x86_64"
fi

if [ "$IGNORE_GIT" = true ]; then
    echo "--- Skipping git operations (--ignoreGit) ---"
else
    echo "--- 1. Pulling all changes for the aggregator ---"
    git fetch origin master

    echo "--- 2. Resetting aggregator to origin/master ---"
    # apply_prs.sh and upload-update-site.sh are untracked and listed in
    # .git/info/exclude, so neither the reset nor the clean below removes them.
    git reset --hard origin/master
    git clean -fd

    echo "--- 3. Updating submodules ---"
    git submodule update --init --recursive --remote --force

    echo "--- Cleaning up all submodules ---"
    git submodule foreach --recursive 'git reset --hard && git clean -fd'
fi

AGG_ROOT="$(pwd)"

# Short label for the window title, e.g. "pde#2417, platform.ui#4237".
PR_LABELS=""
for pr in ${PRS//,/ }; do
    if [[ "$pr" =~ ^https?://github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
        repo="${BASH_REMATCH[2]}"
        num="${BASH_REMATCH[3]}"
    elif [[ "$pr" == *"#"* ]]; then
        repo="${pr%#*}"
        repo="${repo##*/}"
        num="${pr##*#}"
    else
        continue
    fi
    PR_LABELS="${PR_LABELS:+$PR_LABELS, }${repo#eclipse.}#${num}"
done

if [ "$IGNORE_GIT" = true ]; then
    echo "--- 4. Skipping PR application (--ignoreGit) ---"
else
    echo "--- 4. Applying PRs to their target submodules ---"
fi
for pr in ${PRS//,/ }; do
    if [ "$IGNORE_GIT" = true ]; then
        break
    fi
    # Accept two forms:
    #   owner/repo#number                           (e.g. eclipse-platform/eclipse.platform.ui#4092)
    #   https://github.com/owner/repo/pull/number   (full GitHub PR URL)
    if [[ "$pr" =~ ^https?://github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
        owner_repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        number="${BASH_REMATCH[3]}"
    elif [[ "$pr" == *"#"* ]]; then
        owner_repo="${pr%#*}"
        number="${pr##*#}"
    else
        echo "Error: PR entry '$pr' must be in owner/repo#number form (e.g. eclipse-platform/eclipse.platform.ui#4092) or a full GitHub PR URL (e.g. https://github.com/owner/repo/pull/123)"
        exit 1
    fi
    # submodule = repo basename, fetch from the repo URL
    submodule="${owner_repo##*/}"
    fork_url="https://github.com/${owner_repo}.git"
    fetch_remote="$fork_url"
    fetch_ref="pull/${number}/head"
    merge_label="#${number} from ${owner_repo}"

    if [ ! -d "$AGG_ROOT/$submodule" ]; then
        echo "Error: submodule directory '$submodule' not found for PR ${merge_label}!"
        exit 1
    fi

    echo "--- Processing PR ${merge_label} -> ${submodule} ---"
    cd "$AGG_ROOT/$submodule"
    git fetch "$fetch_remote" "$fetch_ref"
    echo "Merging PR ${merge_label} into ${submodule}..."
    # -X theirs favors incoming PR changes on conflict with previously merged PRs.
    git merge FETCH_HEAD --no-edit -X theirs
    cd "$AGG_ROOT"
done

if [ "$IGNORE_GIT" = true ]; then
    echo "--- 4a. Skipping local eclipse.platform merge (--ignoreGit) ---"
else
    echo "--- 4a. Merging local ../eclipse.platform HEAD into eclipse.platform submodule ---"
    LOCAL_PLATFORM_REPO="$AGG_ROOT/../eclipse.platform"
    if [ -d "$LOCAL_PLATFORM_REPO/.git" ]; then
        cd "$AGG_ROOT/eclipse.platform"
        git fetch "$LOCAL_PLATFORM_REPO" HEAD
        echo "Merging $(git log -1 --oneline FETCH_HEAD) from $LOCAL_PLATFORM_REPO..."
        git merge FETCH_HEAD --no-edit -X theirs
        cd "$AGG_ROOT"
    else
        echo "Warning: $LOCAL_PLATFORM_REPO not found, skipping local merge"
    fi
fi

if [ "$EXCLUDE_CSS_SPY" = true ]; then
    echo "--- 4b. Excluding org.eclipse.pde.spy.css from build ---"
    PDE_UI_POM="$AGG_ROOT/eclipse.pde/ui/pom.xml"
    SPIES_FEATURE="$AGG_ROOT/eclipse.pde/features/org.eclipse.pde.spies-feature/feature.xml"
    if [ -f "$PDE_UI_POM" ]; then
        sed -i '/<module>org\.eclipse\.pde\.spy\.css<\/module>/d' "$PDE_UI_POM"
    else
        echo "Warning: $PDE_UI_POM not found"
    fi
    if [ -f "$SPIES_FEATURE" ]; then
        # Remove the multi-line <plugin id="org.eclipse.pde.spy.css" version="..."/> block.
        perl -i -0pe 's|\s*<plugin\s+id="org\.eclipse\.pde\.spy\.css"\s+version="[^"]*"\s*/>||g' "$SPIES_FEATURE"
    else
        echo "Warning: $SPIES_FEATURE not found"
    fi
fi

if [ "$IGNORE_GIT" = true ]; then
    echo "--- 4c. Skipping SDK product name marking (--ignoreGit) ---"
else
    echo "--- 4c. Marking SDK product name as VOGELLA build ---"
    SDK_PROPS="eclipse.platform/platform/org.eclipse.sdk/plugin.properties"
    if [ -f "$SDK_PROPS" ]; then
        sed -i "s|^productName=.*|productName=Eclipse SDK (VOGELLA: ${PR_LABELS})|" "$SDK_PROPS"
    else
        echo "Warning: $SDK_PROPS not found, skipping title customization"
    fi
fi

# --- Optional Build ---
if [ "$RUN_BUILD" = true ]; then
    if [ "$ALL_PLATFORMS" = false ]; then
        echo "--- 4d. Restricting target environments to: $ENVIRONMENTS ---"
        PARENT_POM="eclipse-platform-parent/pom.xml"
        PARENT_POM_BACKUP="$(mktemp)"
        cp "$PARENT_POM" "$PARENT_POM_BACKUP"
        # Restore the pom whatever happens, so the working tree stays clean.
        trap 'cp "$PARENT_POM_BACKUP" "$PARENT_POM"; rm -f "$PARENT_POM_BACKUP"' EXIT
        ENV_XML=$(for env in $ENVIRONMENTS; do
            IFS=/ read -r os ws arch <<< "$env"
            printf '\n            <environment>\n              <os>%s</os>\n              <ws>%s</ws>\n              <arch>%s</arch>\n            </environment>' "$os" "$ws" "$arch"
        done)
        ENV_XML="$ENV_XML" perl -i -0pe 's|<environments>.*?</environments>|"<environments>$ENV{ENV_XML}\n          </environments>"|se' "$PARENT_POM"
    fi

    echo "--- 5. Running build ---"
    mvn clean verify -Dnative=gtk.linux.x86_64 -DskipTests -T6 -Dtycho.baseline.replace=none

    echo "--- 6. Copying build result ---"
    # Features installed on top of the plain SDK, for every platform we ship.
    REPOS="https://download.eclipse.org/releases/2026-06,https://download.eclipse.org/egit/updates-nightly/,https://vogellacompany.github.io/eclipse-mcp-server/,https://vogellacompany.github.io/eclipse-themes/"
    INSTALL_IUS="org.eclipse.m2e.pde.feature.feature.group,org.eclipse.egit.feature.group"
    INSTALL_IUS="$INSTALL_IUS,com.vogella.eclipse.mcp.feature.feature.group"
    INSTALL_IUS="$INSTALL_IUS,com.vogella.eclipse.themes.dracula.feature.feature.group"
    INSTALL_IUS="$INSTALL_IUS,com.vogella.eclipse.themes.github.feature.feature.group"
    INSTALL_IUS="$INSTALL_IUS,com.vogella.eclipse.themes.neon.feature.feature.group"
    INSTALL_IUS="$INSTALL_IUS,com.vogella.eclipse.themes.nord.feature.feature.group"
    INSTALL_IUS="$INSTALL_IUS,com.vogella.eclipse.themes.onelight.feature.feature.group"
    INSTALL_IUS="$INSTALL_IUS,com.vogella.eclipse.themes.vscode.feature.feature.group"
    BUILD_RESULT="products/eclipse-sdk/target/products/org.eclipse.sdk.ide/linux/gtk/x86_64/eclipse"
    TIMESTAMP=$(date +%Y%m%d-%H%M)
    DEST="/home/vogella/dev/eclipse-SDK-Vogella-${TIMESTAMP}-linux-gtk-x86_64"
    if [ -d "$BUILD_RESULT" ]; then
        cp -r "$BUILD_RESULT" "$DEST"
        echo "Copied build result to $DEST"

        echo "--- 7. Installing features via p2 ---"
        "$DEST/eclipse" \
            -application org.eclipse.equinox.p2.director \
            -repository "$REPOS" \
            -installIU "$INSTALL_IUS" \
            -destination "$DEST" \
            -noSplash

        echo "--- 8. Setting preferences ---"
        PREFS_DIR="$DEST/configuration/.settings"
        mkdir -p "$PREFS_DIR"
        cat > "$PREFS_DIR/org.eclipse.e4.ui.workbench.renderers.swt.prefs" <<EOF
eclipse.preferences.version=1
SHOW_DIRTY_INDICATOR_ON_TABS=true
EOF

        echo "--- 9. Creating startup trace script ---"
        STARTUP_SCRIPT="$DEST/startup-trace.sh"
        cat > "$STARTUP_SCRIPT" <<EOF
#!/bin/bash
for i in \$(seq 1 5); do
    "$DEST/eclipse" -data ~/workspace/platform -vmargs -Dstartup.trace.autoExitSeconds=8
done
EOF
        chmod +x "$STARTUP_SCRIPT"
        echo "Created $STARTUP_SCRIPT"
    else
        echo "Warning: $BUILD_RESULT not found, skipping copy"
    fi

    echo "--- 10. Preparing Windows product for download ---"
    WIN_BUILD_RESULT="products/eclipse-sdk/target/products/org.eclipse.sdk.ide/win32/win32/x86_64/eclipse"
    # Only present with --upload or --allPlatforms.
    WIN_STAGE="/home/vogella/dev/eclipse-SDK-Vogella-${TIMESTAMP}-win32-x86_64"
    # Stable file name so the link on eclipsercp.de stays valid across builds.
    WIN_ZIP="/home/vogella/dev/eclipse-SDK-vogella-win32-x86_64.zip"
    # The director needs a launcher to run in; the Windows install has only
    # eclipse.exe, so drive it from the Linux product built above.
    DIRECTOR_LAUNCHER="$DEST/eclipse"
    [ -x "$DIRECTOR_LAUNCHER" ] || DIRECTOR_LAUNCHER="$BUILD_RESULT/eclipse"
    if [ ! -d "$WIN_BUILD_RESULT" ]; then
        echo "Warning: $WIN_BUILD_RESULT not found, skipping Windows product"
    elif [ ! -x "$DIRECTOR_LAUNCHER" ]; then
        echo "Warning: no Linux launcher to run the p2 director, skipping Windows product"
    else
        rm -rf "$WIN_STAGE" "$WIN_ZIP"
        mkdir -p "$WIN_STAGE"
        # Nested "eclipse" directory: the archive must unpack to eclipse/ like the
        # official Windows downloads do.
        cp -r "$WIN_BUILD_RESULT" "$WIN_STAGE/eclipse"

        echo "--- 11. Installing features into the Windows product via p2 ---"
        # The staged SDKProfile already records osgi.os=win32, so the resolution
        # picks the Windows fragments even though the director runs on Linux.
        "$DIRECTOR_LAUNCHER" \
            -application org.eclipse.equinox.p2.director \
            -repository "$REPOS" \
            -installIU "$INSTALL_IUS" \
            -destination "$WIN_STAGE/eclipse" \
            -profile SDKProfile \
            -p2.os win32 -p2.ws win32 -p2.arch x86_64 \
            -noSplash

        echo "--- 12. Setting preferences ---"
        WIN_PREFS_DIR="$WIN_STAGE/eclipse/configuration/.settings"
        mkdir -p "$WIN_PREFS_DIR"
        cat > "$WIN_PREFS_DIR/org.eclipse.e4.ui.workbench.renderers.swt.prefs" <<EOF
eclipse.preferences.version=1
SHOW_DIRTY_INDICATOR_ON_TABS=true
EOF

        echo "--- 13. Zipping Windows product ---"
        (cd "$WIN_STAGE" && zip -q -r "$WIN_ZIP" eclipse)
        rm -rf "$WIN_STAGE"
        echo "Created $WIN_ZIP ($(du -h "$WIN_ZIP" | cut -f1))"

        if [ "$UPLOAD" = true ]; then
            echo "--- 14. Uploading update site and Windows product ---"
            "$AGG_ROOT/upload-update-site.sh" --product "$WIN_ZIP"
        else
            echo "Upload it with: ./upload-update-site.sh"
        fi
    fi
fi

echo "--- Build script completed successfully ---"
