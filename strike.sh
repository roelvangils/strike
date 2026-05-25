#!/bin/bash

# ============================================================================
# swatch - Modern CSS Compiler using Lightning CSS
# ============================================================================
# A fast, modern CSS build tool that bundles, minifies, and watches CSS files
# Uses Lightning CSS (Rust-based) for maximum performance
# ============================================================================

# ANSI Color Codes
GRAY='\033[0;90m'      # Gray for most output
WHITE='\033[1;97m'     # Bright white for filenames
RESET='\033[0m'        # Reset color

# ----------------------------------------------------------------------------
# Configuration & Defaults
# ----------------------------------------------------------------------------
VERSION="1.0.0"       # Version number
WATCH_MODE=true       # Watch for file changes by default
SOURCE_MAPS=false     # No source maps by default (production-optimized)
MINIFY=true           # Minify output by default
SHOW_HELP=false       # Show help text
DEBUG=false           # Debug mode off by default
WATCH_DIR="."         # Always watch current directory
COMPILING=false       # Mutex to prevent concurrent compilations
BROWSER_TARGETS="${BROWSER_TARGETS:-">= 0.25%"}"  # Browser targets (configurable via env var)

# ----------------------------------------------------------------------------
# Parse Command Line Arguments
# ----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            SHOW_HELP=true
            shift
            ;;
        -v|--version)
            echo "swatch v$VERSION"
            exit 0
            ;;
        -w|--watch)
            WATCH_MODE=true
            shift
            ;;
        --no-watch)
            WATCH_MODE=false
            shift
            ;;
        -s|--sourcemap)
            SOURCE_MAPS=true
            shift
            ;;
        -m|--minify)
            MINIFY=true
            shift
            ;;
        --no-minify)
            MINIFY=false
            shift
            ;;
        -d|--debug)
            DEBUG=true
            shift
            ;;
        *)
            echo -e "${GRAY}Error: Unknown option: $1${RESET}" >&2
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# ----------------------------------------------------------------------------
# Help Text
# ----------------------------------------------------------------------------
if [ "$SHOW_HELP" = true ]; then
    cat << 'EOF'
strike - Modern CSS Compiler (Lightning CSS)

USAGE:
    strike [OPTIONS]

OPTIONS:
    -h, --help        Show this help message
    -v, --version     Show version information
    -w, --watch       Watch for file changes (default: on)
    --no-watch        Compile once and exit
    -s, --sourcemap   Include inline source maps (for debugging)
    -m, --minify      Minify the output (default: on)
    --no-minify       Don't minify (keep readable)
    -d, --debug       Show debug information (commands being run)

EXAMPLES:
    strike                    # Default: watch + minify, no source maps
    strike --no-watch         # Compile once and exit
    strike -s                 # Include source maps for debugging
    strike --no-minify -s     # Debug mode: readable + source maps

INPUT/OUTPUT:
    Compiles source files matching: src.*.css
    Example: src.theverge.com.css → theverge.com.css

@IMPORTS:
    @import statements are resolved recursively and bundled into the output.
    Any .css file that's imported (partials, helpers, etc.) is watched too —
    changing a partial recompiles every source that depends on it.

CHANGE DETECTION:
    A bundle hash (source + all transitive imports) is computed on every save.
    If the hash matches the previous compile, the recompile is skipped — so
    editors that re-save without content changes won't trigger needless work.

ENV VARS:
    BROWSER_TARGETS   Browserslist query for Lightning CSS targets
                      (default: ">= 0.25%")

NOTES:
    - Only files matching src.*.css are compiled as entry points
    - Output filename strips the src. prefix (src.foo.css → foo.css)
    - Source maps are embedded inline when enabled (-s flag)
    - Default mode is optimized for production (minified, no maps)
    - File watchers tried in order: watchman > fswatch > inotifywait > polling

EOF
    exit 0
fi

# ----------------------------------------------------------------------------
# Dependency Checks
# ----------------------------------------------------------------------------

# Check for Lightning CSS (required)
if ! command -v lightningcss &>/dev/null; then
    echo "Lightning CSS is not installed"
    echo "   Install with: npm install -g lightningcss-cli"
    echo "   or: brew install lightningcss"
    exit 1
fi

# Check for gum (optional, only needed for directory selection in watch mode)
if ! command -v gum &>/dev/null && [ "$WATCH_MODE" = true ]; then
    # Don't fail, just skip the directory selector
    HAS_GUM=false
else
    HAS_GUM=true
fi

# ----------------------------------------------------------------------------
# UI Header
# ----------------------------------------------------------------------------
echo -e "${GRAY}⚡ Lightning CSS + Watchman = 🚀${RESET}"
echo -e "${GRAY}Only processes files matching pattern: src.*.css${RESET}"
echo ""

# ----------------------------------------------------------------------------
# Directory Selection (Watch Mode Only)
# ----------------------------------------------------------------------------
OUTPUT_DIR=""
CURRENT_DIR=$(pwd)

# Only offer directory selection if in watch mode and gum is available
if [ "$WATCH_MODE" = true ] && [ "$HAS_GUM" = true ]; then
    echo -e "${GRAY}Where should I put your compiled CSS?${RESET}"

    # Get parent directory
    PARENT_DIR=$(dirname "$CURRENT_DIR")

    # Build arrays of sibling directories
    declare -a display_names
    declare -a full_paths

    # Find all sibling directories
    for dir in "$PARENT_DIR"/*; do
        if [ -d "$dir" ]; then
            full_paths+=("$dir")
            folder_name=$(basename "$dir")

            # Mark current directory with (*)
            if [ "$dir" = "$CURRENT_DIR" ]; then
                display_names+=("$folder_name (*)")
            else
                display_names+=("$folder_name")
            fi
        fi
    done

    # Use gum for interactive selection
    current_dir_name=$(basename "$CURRENT_DIR")
    if selected=$(printf "%s\n" "${display_names[@]}" | \
        gum choose \
        --cursor.foreground="#FFA500" \
        --selected.foreground="#FFA500" \
        --height=10 \
        --cursor="> " \
        --header="Press Enter to use the current directory" \
        --limit=1 \
        --selected="$current_dir_name (*)"); then

        # Map selection back to full path
        if [ -n "$selected" ]; then
            # Remove (*) suffix if present
            clean_selected=${selected% (*)}

            # Find matching path
            for i in "${!display_names[@]}"; do
                clean_display=${display_names[$i]% (*)}
                if [ "$clean_display" = "$clean_selected" ]; then
                    OUTPUT_DIR="${full_paths[$i]}"
                    break
                fi
            done

            # Validate that we found a match
            if [ -z "$OUTPUT_DIR" ]; then
                echo -e "${GRAY}Warning: Selection not found, using current directory${RESET}"
                OUTPUT_DIR="$CURRENT_DIR"
            fi
        fi
    else
        # User cancelled (Ctrl+C), use current directory
        echo -e "${GRAY}Selection cancelled, using current directory${RESET}"
    fi
fi

# Default to current directory if no selection made
if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$CURRENT_DIR"
    [ "$WATCH_MODE" = true ] && echo -e "${GRAY}Using current directory for output${RESET}"
else
    echo -e "${GRAY}Selected output directory: $OUTPUT_DIR${RESET}"
fi
echo ""

# ----------------------------------------------------------------------------
# Import / Dependency Resolution
# ----------------------------------------------------------------------------
# Parses @import statements (both `@import "x";` and `@import url("x");` forms)
# and emits one resolved absolute path per line. Used to build a bundle hash
# so we can skip recompiles when nothing in the dependency graph has changed.

extract_imports() {
    local file="$1"
    [ -f "$file" ] || return 0
    # url(...) form
    grep -hE "@import[[:space:]]+url\\(" "$file" 2>/dev/null | \
        sed -E "s/.*@import[[:space:]]+url\\([[:space:]]*[\"']?//; s/[\"']?[[:space:]]*\\).*//"
    # quoted form
    grep -hE "@import[[:space:]]+[\"']" "$file" 2>/dev/null | \
        sed -E "s/.*@import[[:space:]]+[\"']//; s/[\"'].*//"
}

# Recursively resolve all transitive imports for a source file.
# Outputs sorted, deduplicated absolute paths (source file included).
# Implemented with a tempfile seen-set for bash 3.2 compatibility.
_resolve_deps_walk() {
    local current="$1"
    local seen="$2"
    # Skip if already visited
    grep -qxF "$current" "$seen" 2>/dev/null && return
    echo "$current" >> "$seen"
    local dir; dir=$(dirname "$current")
    local imp resolved canonical
    while IFS= read -r imp; do
        [ -z "$imp" ] && continue
        if [[ "$imp" == /* ]]; then
            resolved="$imp"
        else
            resolved="$dir/$imp"
        fi
        # Canonicalize path so "../foo" and "foo" hash to the same dep
        canonical=$(cd "$(dirname "$resolved")" 2>/dev/null && pwd)/$(basename "$resolved")
        [ -f "$canonical" ] && _resolve_deps_walk "$canonical" "$seen"
    done < <(extract_imports "$current")
}

resolve_deps() {
    local seen
    seen=$(mktemp) || return 1
    _resolve_deps_walk "$1" "$seen"
    sort -u "$seen"
    rm -f "$seen"
}

# Hash the entire bundle (source + all transitive imports). Used to detect
# whether anything that affects compilation output has actually changed.
bundle_hash() {
    local src="$1"
    resolve_deps "$src" | xargs shasum -a 1 2>/dev/null | shasum -a 1 | awk '{print $1}'
}

# Path to the cached hash file for a given source.
hash_file_for() {
    [ -z "$HASH_DIR" ] && return 1
    echo "$HASH_DIR/$(basename "$1").hash"
}

# ----------------------------------------------------------------------------
# Core Compilation Function
# ----------------------------------------------------------------------------
compile_css() {
    # Prevent concurrent compilations
    if [ "$COMPILING" = true ]; then
        return 0
    fi
    COMPILING=true

    local is_initial=false
    local changed_file=""

    # Handle parameters:
    # - compile_css "file.css" initial  -> compile specific file with initial display
    # - compile_css "file.css"          -> compile specific file with change display
    # - compile_css initial             -> find first file with initial display (legacy)
    if [ "$2" = "initial" ]; then
        is_initial=true
        changed_file="$1"
    elif [ "$1" = "initial" ]; then
        is_initial=true
    else
        changed_file="$1"
    fi

    local main_file=""
    local base_name=""
    local output_file=""

    # If a specific file was provided, use it (only if it matches src.*.css pattern)
    if [ -n "$changed_file" ]; then
        # Convert to full path if it's just a filename
        if [[ "$changed_file" != /* ]]; then
            changed_file="$WATCH_DIR/$changed_file"
        fi

        base_name=$(basename "$changed_file")

        # Only process files matching src.*.css pattern (and not partials)
        if [[ "$base_name" =~ ^src\..*\.css$ ]] && [[ ! "$base_name" =~ ^_ ]]; then
            main_file="$changed_file"
        fi
    fi

    # If no specific file or it didn't match pattern, find the first source file
    if [ -z "$main_file" ]; then
        for css_file in "$WATCH_DIR"/src.*.css; do
            [ ! -f "$css_file" ] && continue

            base_name=$(basename "$css_file")

            # Skip partials (start with _)
            if [[ ! "$base_name" =~ ^_ ]]; then
                main_file="$css_file"
                break
            fi
        done
    fi

    # Check if we found a source file
    if [ -z "$main_file" ]; then
        echo "No source CSS file found"
        echo "Looking for: src.*.css (not _*.css)"
        COMPILING=false
        return 1
    fi

    # Prepare output filename: src.example.com.css → example.com.css
    base_name=$(basename "$main_file")
    # Remove 'src.' prefix
    output_name="${base_name#src.}"           # Remove src. prefix
    output_file="$OUTPUT_DIR/${output_name}"

    # Bundle-hash skip: if neither the source nor any of its transitive imports
    # have changed since the last compile, do nothing. This avoids the
    # "editor saved but content is identical" recompile loop.
    if [ "$is_initial" = false ] && [ -n "$HASH_DIR" ]; then
        local current_hash cached_hash hf
        current_hash=$(bundle_hash "$main_file")
        hf=$(hash_file_for "$main_file") || hf=""
        if [ -n "$hf" ] && [ -f "$hf" ]; then
            cached_hash=$(cat "$hf" 2>/dev/null)
            if [ -n "$current_hash" ] && [ "$current_hash" = "$cached_hash" ]; then
                echo -e "  ${GRAY}↘ ${WHITE}$base_name${GRAY} unchanged, skipped${RESET}"
                COMPILING=false
                return 0
            fi
        fi
    fi

    # Build Lightning CSS command with options
    local cmd_args=()

    # Always bundle (inline @imports)
    cmd_args+=("--bundle")

    # Add minification if enabled
    if [ "$MINIFY" = true ]; then
        cmd_args+=("--minify")
    fi

    # Add source maps if enabled (inline for simplicity)
    if [ "$SOURCE_MAPS" = true ]; then
        cmd_args+=("--sourcemap=inline")
    fi

    # Browser targets (configurable via BROWSER_TARGETS environment variable)
    cmd_args+=("--targets" "$BROWSER_TARGETS")

    # Write to a temp file in the same directory, then atomically rename.
    # Prevents readers (browser extensions, hot-reloaders, etc.) from seeing
    # an empty file during the brief moment lightningcss has it open-for-write.
    local output_tmp="${output_file}.tmp.$$.$RANDOM"
    cmd_args+=("$main_file" "-o" "$output_tmp")

    # Show debug output if enabled
    if [ "$DEBUG" = true ]; then
        echo -e "${GRAY}Debug: Running command: lightningcss ${cmd_args[*]}${RESET}"
    fi

    # Execute compilation with timing
    # Use bash's time and TIMEFORMAT to get milliseconds directly
    TIMEFORMAT='%3R'
    local timing_output
    { timing_output=$( { time lightningcss "${cmd_args[@]}" 1>/dev/null 2>&1; } 2>&1 ); }
    local result=$?

    if [ $result -eq 0 ]; then
        # Atomic publish: rename temp → final. Readers see old-or-new, never empty.
        mv -f "$output_tmp" "$output_file"
        # Persist the bundle hash so future identical saves are skipped.
        if [ -n "$HASH_DIR" ]; then
            local hf_out
            hf_out=$(hash_file_for "$main_file") && bundle_hash "$main_file" > "$hf_out"
        fi
        # TIMEFORMAT gives us seconds with 3 decimal places (e.g., "0.023")
        # Convert to milliseconds by removing the decimal point
        if [[ "$timing_output" =~ ([0-9]+)\.([0-9]{3}) ]]; then
            local secs="${BASH_REMATCH[1]}"
            local ms="${BASH_REMATCH[2]}"
            # Remove leading zeros from ms
            ms=$((10#$ms))
            local total_ms=$((secs * 1000 + ms))
            # Compile output during initial run
            if [ "$is_initial" = true ]; then
                echo -e "${GRAY}Recompiling ${WHITE}$(basename "$main_file")${GRAY} → ${WHITE}$(basename "$output_file")${GRAY} (${total_ms}ms)${RESET}"
            else
                # File change notification was already shown, just show compile
                echo -e "  ${GRAY}↘ ${WHITE}$(basename "$main_file")${GRAY} → ${WHITE}$(basename "$output_file")${GRAY} (${total_ms}ms)${RESET}"
            fi
        else
            if [ "$is_initial" = true ]; then
                echo -e "${GRAY}Recompiling ${WHITE}$(basename "$main_file")${GRAY} → ${WHITE}$(basename "$output_file")${RESET}"
            else
                echo -e "  ${GRAY}↘ ${WHITE}$(basename "$main_file")${GRAY} → ${WHITE}$(basename "$output_file")${RESET}"
            fi
        fi
        COMPILING=false
        return 0
    else
        echo "Compilation failed"
        # Clean up the temp file so it doesn't accumulate
        rm -f "$output_tmp"
        # Re-run with error output for debugging (writing to final path now,
        # since we've already failed — diagnostic output is what matters)
        local debug_args=("${cmd_args[@]}")
        debug_args[${#debug_args[@]}-1]="$output_file"
        lightningcss "${debug_args[@]}"
        COMPILING=false
        return 1
    fi
}

# ----------------------------------------------------------------------------
# Compile every source affected by a change.
# - If the changed file is a src.*.css, compile only that one.
# - If it's an imported partial, recompile only the sources that actually
#   import it (transitively).
# - If it's some unrelated .css file sitting in the watch dir (e.g. a stale
#   output, a leftover), do nothing — no noise.
# ----------------------------------------------------------------------------
compile_affected() {
    local changed="$1"
    local base; base=$(basename "$changed")
    if [[ "$base" =~ ^src\..*\.css$ ]]; then
        compile_css "$changed"
        return 0
    fi

    # Canonicalize so the path matches what resolve_deps emits
    local changed_canonical
    changed_canonical=$(cd "$(dirname "$changed")" 2>/dev/null && pwd)/$(basename "$changed")

    # Find sources that import this file (directly or transitively)
    local affected=""
    for css_file in "$WATCH_DIR"/src.*.css; do
        [ ! -f "$css_file" ] && continue
        if resolve_deps "$css_file" | grep -qxF "$changed_canonical"; then
            affected="$affected $css_file"
        fi
    done

    # Nothing imports this file — ignore the event silently
    [ -z "$affected" ] && return 1

    for src in $affected; do
        compile_css "$src"
    done
    return 0
}

# ----------------------------------------------------------------------------
# Output Directory Validation
# ----------------------------------------------------------------------------
if [ ! -d "$OUTPUT_DIR" ]; then
    echo -e "${GRAY}Error: Output directory does not exist: $OUTPUT_DIR${RESET}" >&2
    exit 1
fi

if [ ! -w "$OUTPUT_DIR" ]; then
    echo -e "${GRAY}Error: Output directory is not writable: $OUTPUT_DIR${RESET}" >&2
    exit 1
fi

# Content-hash cache: skip recompiles when an editor re-saves a file with no
# byte changes (common with autosave / atomic-rename editors).
HASH_DIR=$(mktemp -d -t strike-hashes.XXXXXX 2>/dev/null) || HASH_DIR=""

# ----------------------------------------------------------------------------
# Show Current Configuration
# ----------------------------------------------------------------------------
echo -e "${GRAY}Settings:${RESET}"
echo -e "${GRAY}$([ "$MINIFY" = true ] && echo "✓" || echo "𐄂") Minify${RESET}"
echo -e "${GRAY}$([ "$SOURCE_MAPS" = true ] && echo "✓" || echo "𐄂") Source Maps${RESET}"
echo -e "${GRAY}$([ "$WATCH_MODE" = true ] && echo "✓" || echo "𐄂") Watch Mode${RESET}"
echo ""

# ----------------------------------------------------------------------------
# Initial Compilation - Compile all source CSS files
# ----------------------------------------------------------------------------
# Run initial compiles in parallel — each lightningcss invocation is independent
# (different output paths, distinct HASH_DIR entries) so there's no shared state
# to contend over. Output order will follow completion order, not glob order.
for css_file in "$WATCH_DIR"/src.*.css; do
    [ ! -f "$css_file" ] && continue
    base_name=$(basename "$css_file")
    # Skip partials (start with _)
    if [[ ! "$base_name" =~ ^_ ]]; then
        compile_css "$css_file" initial &
    fi
done
wait

# Exit if not in watch mode
if [ "$WATCH_MODE" = false ]; then
    exit 0
fi

# ----------------------------------------------------------------------------
# Signal Handling & Cleanup
# ----------------------------------------------------------------------------
cleanup() {
    echo ''
    echo -e "${GRAY}Stopping...${RESET}"
    # Clean up watchman watch if it was initialized
    if command -v watchman &>/dev/null; then
        watchman watch-del "$WATCH_DIR" >/dev/null 2>&1
    fi
    # Remove the per-session hash cache
    [ -n "$HASH_DIR" ] && [ -d "$HASH_DIR" ] && rm -rf "$HASH_DIR"
    exit 0
}

# Set up signal handlers for all watch modes
trap cleanup INT TERM HUP QUIT

# When the same file is saved repeatedly, collapse the previous 2-line block
# (saved + compile result) in place instead of scrolling the terminal.
# No-op when stdout isn't a TTY (piped output, etc.).
overwrite_prev_block() {
    [ -t 1 ] && printf '\033[2A\033[J'
}

# ----------------------------------------------------------------------------
# File Watching Setup
# ----------------------------------------------------------------------------
echo ""
echo -e "${GRAY}• Watching for changes in current directory${RESET}"
echo -e "${GRAY}• Output directory: $OUTPUT_DIR${RESET}"

# ----------------------------------------------------------------------------
# File Watcher Selection (in order of preference)
# ----------------------------------------------------------------------------

# Option 1: Watchman (fastest, most efficient)
if command -v watchman &>/dev/null; then
    echo -e "${GRAY}• Using Watchman for file watching (most efficient)${RESET}"
    echo -e "${GRAY}• Press Ctrl+C to stop watching${RESET}"
    echo ""

    # Initialize Watchman on current directory with error handling
    if ! watchman watch "$WATCH_DIR" >/dev/null 2>&1; then
        echo -e "${GRAY}Warning: Watchman failed to watch directory${RESET}"
        echo -e "${GRAY}Falling back to alternative file watcher...${RESET}"
        # Set flag to skip watchman and try next watcher
        WATCHMAN_FAILED=true
    else
        WATCHMAN_FAILED=false
    fi

    # Watch for changes using watchman-wait if setup succeeded.
    # Watches ALL .css files so @import partials trigger rebuilds too.
    # Outer `while true` restarts watchman-wait if the stream dies.
    if [ "$WATCHMAN_FAILED" = false ]; then
        # Use process substitution (not a pipe) so the while-read loop runs in
        # the main shell. This keeps $LAST_FILE alive across watchman-wait
        # restarts — watchman-wait exits after each event by default, so the
        # subshell trick wouldn't persist state between events.
        LAST_FILE=""
        while true; do
            while read -r file; do
                if [ "$file" = "$LAST_FILE" ]; then
                    overwrite_prev_block
                fi
                current_time=$(date +"%H:%M")
                echo -e "${WHITE}$file${GRAY} saved (${current_time})${RESET}"
                compile_affected "$file"
                if [[ "$(basename "$file")" =~ ^src\..*\.css$ ]]; then
                    LAST_FILE="$file"
                else
                    LAST_FILE=""
                fi
            done < <(watchman-wait "$WATCH_DIR" --fields name -p '*.css' 2>/dev/null)
            # watchman-wait exits per event by default; brief pause before reconnect
            sleep 0.1
        done
    fi
fi

# Option 2: fswatch (native macOS, good performance)
# Only use if watchman is not available or failed
if (! command -v watchman &>/dev/null || [ "$WATCHMAN_FAILED" = true ]) && command -v fswatch &>/dev/null; then
    echo -e "${GRAY}• Using fswatch for file watching${RESET}"
    echo -e "${GRAY}• Press Ctrl+C to stop watching${RESET}"
    echo ""

    # Watch all .css files (sources and partials)
    fswatch \
        --include '\.css$' \
        "$WATCH_DIR" 2>/dev/null | (
        LAST_FILE=""
        while read -r path; do
            if [ "$path" = "$LAST_FILE" ]; then
                overwrite_prev_block
            fi
            current_time=$(date +"%H:%M")
            echo -e "${WHITE}$(basename "$path")${GRAY} saved (${current_time})${RESET}"
            compile_affected "$path"
            if [[ "$(basename "$path")" =~ ^src\..*\.css$ ]]; then
                LAST_FILE="$path"
            else
                LAST_FILE=""
            fi
        done
    )

# Option 3: inotifywait (Linux, good performance)
# Only use if watchman and fswatch are not available or failed
elif (! command -v watchman &>/dev/null || [ "$WATCHMAN_FAILED" = true ]) && command -v inotifywait &>/dev/null; then
    echo -e "${GRAY}• Using inotifywait for file watching${RESET}"
    echo -e "${GRAY}• Press Ctrl+C to stop watching${RESET}"
    echo ""

    LAST_FILE=""
    while true; do
        # Wait for any .css file change (sources and partials)
        file=$(inotifywait -q -e modify,create,delete,move \
            --include '\.css$' \
            --format '%f' \
            "$WATCH_DIR" 2>/dev/null)

        if [[ -n "$file" ]]; then
            if [ "$file" = "$LAST_FILE" ]; then
                overwrite_prev_block
            fi
            current_time=$(date +"%H:%M")
            echo -e "${WHITE}$file${GRAY} saved (${current_time})${RESET}"
            compile_affected "$file"
            if [[ "$file" =~ ^src\..*\.css$ ]]; then
                LAST_FILE="$file"
            else
                LAST_FILE=""
            fi
        fi
    done

# Option 4: Polling fallback (works everywhere, less efficient)
else
    echo -e "${GRAY}• No file watcher found (watchman, fswatch, or inotifywait)${RESET}"
    echo -e "${GRAY}• Using polling (less efficient but works everywhere)${RESET}"
    echo -e "${GRAY}• Tip: Install watchman for best performance:${RESET}"
    echo -e "${GRAY}     macOS: brew install watchman${RESET}"
    echo -e "${GRAY}     Linux: apt-get install watchman${RESET}"
    echo -e "${GRAY}• Press Ctrl+C to stop watching${RESET}"
    echo ""

    # Polling requires bash 4+ for associative arrays. macOS ships bash 3.2
    # by default, so guard with a clear error rather than failing cryptically.
    if ! declare -A _strike_assoc_test 2>/dev/null; then
        echo -e "${GRAY}Error: polling fallback requires bash 4+ (or install watchman/fswatch)${RESET}" >&2
        exit 1
    fi
    unset _strike_assoc_test

    stat_mtime() {
        if [[ "$OSTYPE" == "darwin"* ]]; then
            stat -f "%m" "$1" 2>/dev/null
        else
            stat -c "%Y" "$1" 2>/dev/null
        fi
    }

    # Track mtimes for all .css files (sources AND partials, so @imports work)
    declare -A file_times
    for file in "$WATCH_DIR"/*.css; do
        [ -f "$file" ] || continue
        file_times["$file"]=$(stat_mtime "$file")
    done

    # Poll for changes every second
    LAST_FILE=""
    while true; do
        for file in "$WATCH_DIR"/*.css; do
            [ -f "$file" ] || continue
            current_mtime=$(stat_mtime "$file")
            if [ "${file_times[$file]:-}" != "$current_mtime" ]; then
                file_times["$file"]=$current_mtime
                if [ "$file" = "$LAST_FILE" ]; then
                    overwrite_prev_block
                fi
                time_now=$(date +"%H:%M")
                echo -e "${WHITE}$(basename "$file")${GRAY} saved (${time_now})${RESET}"
                compile_affected "$file"
                if [[ "$(basename "$file")" =~ ^src\..*\.css$ ]]; then
                    LAST_FILE="$file"
                else
                    LAST_FILE=""
                fi
            fi
        done
        sleep 1
    done
fi
