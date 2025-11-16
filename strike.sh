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
swatch - Modern CSS Compiler (Lightning CSS)

USAGE:
    swatch [OPTIONS]

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
    swatch                    # Default: watch + minify, no source maps
    swatch --no-watch         # Compile once and exit
    swatch -s                 # Include source maps for debugging
    swatch --no-minify -s     # Debug mode: readable + source maps

OUTPUT:
    Automatically detects main CSS file (non-partial)
    Outputs to: [filename].compiled.css

NOTES:
    - Partials (files starting with _) are imported but not compiled directly
    - Source maps are embedded inline when enabled (-s flag)
    - Default mode is optimized for production (minified, no maps)
    - Uses Watchman for fastest possible file watching (if available)

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
# Core Compilation Function
# ----------------------------------------------------------------------------
compile_css() {
    # Prevent concurrent compilations
    if [ "$COMPILING" = true ]; then
        return 0
    fi
    COMPILING=true

    local changed_file="$1"  # Optional: specific file that changed
    local main_file=""
    local base_name=""
    local output_file=""

    # If a specific file was provided, use it (unless it's a partial)
    if [ -n "$changed_file" ]; then
        # Convert to full path if it's just a filename
        if [[ "$changed_file" != /* ]]; then
            changed_file="$WATCH_DIR/$changed_file"
        fi

        base_name=$(basename "$changed_file")

        # If it's a partial, we need to compile all main CSS files
        # If it's not a partial and not compiled, use it directly
        if [[ ! "$base_name" =~ ^_ ]] && [[ ! "$base_name" =~ \.compiled\.css$ ]]; then
            main_file="$changed_file"
        fi
    fi

    # If no specific file or it was a partial, find the first main CSS file
    if [ -z "$main_file" ]; then
        for css_file in "$WATCH_DIR"/*.css; do
            [ ! -f "$css_file" ] && continue

            base_name=$(basename "$css_file")

            # Skip partials (start with _) and compiled files
            if [[ ! "$base_name" =~ ^_ ]] && [[ ! "$base_name" =~ \.compiled\.css$ ]]; then
                main_file="$css_file"
                break
            fi
        done
    fi

    # Check if we found a main file
    if [ -z "$main_file" ]; then
        echo "No main CSS file found"
        echo "Looking for: *.css (not _*.css or *.compiled.css)"
        COMPILING=false
        return 1
    fi

    # Prepare output filename
    base_name=$(basename "$main_file" .css)
    output_file="$OUTPUT_DIR/${base_name}.compiled.css"

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

    # Add input and output files
    cmd_args+=("$main_file" "-o" "$output_file")

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
        # TIMEFORMAT gives us seconds with 3 decimal places (e.g., "0.023")
        # Convert to milliseconds by removing the decimal point
        if [[ "$timing_output" =~ ([0-9]+)\.([0-9]{3}) ]]; then
            local secs="${BASH_REMATCH[1]}"
            local ms="${BASH_REMATCH[2]}"
            # Remove leading zeros from ms
            ms=$((10#$ms))
            local total_ms=$((secs * 1000 + ms))
            # Compile output during initial run
            if [ "$1" = "initial" ]; then
                echo -e "${GRAY}Recompiling ${WHITE}$(basename "$main_file")${GRAY} → ${WHITE}$(basename "$output_file")${GRAY} (${total_ms}ms)${RESET}"
            else
                # File change notification was already shown, just show compile
                echo -e "  ${GRAY}↘ ${WHITE}$(basename "$main_file")${GRAY} → ${WHITE}$(basename "$output_file")${GRAY} (${total_ms}ms)${RESET}"
            fi
        else
            if [ "$1" = "initial" ]; then
                echo -e "${GRAY}Recompiling ${WHITE}$(basename "$main_file")${GRAY} → ${WHITE}$(basename "$output_file")${RESET}"
            else
                echo -e "  ${GRAY}↘ ${WHITE}$(basename "$main_file")${GRAY} → ${WHITE}$(basename "$output_file")${RESET}"
            fi
        fi
        COMPILING=false
        return 0
    else
        echo "Compilation failed"
        # Re-run with error output for debugging
        lightningcss "${cmd_args[@]}"
        COMPILING=false
        return 1
    fi
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

# ----------------------------------------------------------------------------
# Show Current Configuration
# ----------------------------------------------------------------------------
echo -e "${GRAY}Settings:${RESET}"
echo -e "${GRAY}$([ "$MINIFY" = true ] && echo "✓" || echo "𐄂") Minify${RESET}"
echo -e "${GRAY}$([ "$SOURCE_MAPS" = true ] && echo "✓" || echo "𐄂") Source Maps${RESET}"
echo -e "${GRAY}$([ "$WATCH_MODE" = true ] && echo "✓" || echo "𐄂") Watch Mode${RESET}"
echo ""

# ----------------------------------------------------------------------------
# Initial Compilation
# ----------------------------------------------------------------------------
compile_css initial

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
    exit 0
}

# Set up signal handlers for all watch modes
trap cleanup INT TERM HUP QUIT

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

    # Only proceed with watchman if initialization succeeded
    if [ "$WATCHMAN_FAILED" = false ]; then
        # Set up optimized subscription for CSS files
        # Settle time of 20ms for near-instant response (default is 200ms)
        if ! watchman -j <<-EOF > /dev/null 2>&1
            ["subscribe", "$WATCH_DIR", "css-watch", {
                "expression": ["allof",
                    ["match", "*.css"],
                    ["not", ["match", "*.compiled.css"]],
                    ["not", ["match", "*.map"]]
                ],
                "fields": ["name"],
                "settle": 20
            }]
EOF
        then
            echo -e "${GRAY}Warning: Watchman subscription failed${RESET}"
            echo -e "${GRAY}Falling back to alternative file watcher...${RESET}"
            WATCHMAN_FAILED=true
        fi
    fi

    # Watch for changes using watchman-wait if setup succeeded
    if [ "$WATCHMAN_FAILED" = false ]; then
        while true; do
        watchman-wait "$WATCH_DIR" --max-events=1 --fields name -p '*.css' 2>/dev/null | while read -r file; do
            # Get current time
            current_time=$(date +"%H:%M")
            echo -e "${WHITE}$file${GRAY} changed (${current_time})${RESET}"
            compile_css "$file"
        done
        done
    fi
fi

# Option 2: fswatch (native macOS, good performance)
# Only use if watchman is not available or failed
if (! command -v watchman &>/dev/null || [ "$WATCHMAN_FAILED" = true ]) && command -v fswatch &>/dev/null; then
    echo -e "${GRAY}• Using fswatch for file watching${RESET}"
    echo -e "${GRAY}• Press Ctrl+C to stop watching${RESET}"
    echo ""

    # Watch CSS files, batch changes, exclude compiled files
    fswatch \
        --exclude '\.compiled\.css$' \
        --exclude '\.map$' \
        "$WATCH_DIR" 2>/dev/null | \
    while read -r path; do
        if [[ "$path" == *.css ]]; then
            # Get current time
            current_time=$(date +"%H:%M")
            echo -e "${WHITE}$(basename "$path")${GRAY} changed (${current_time})${RESET}"
            compile_css "$path"
        fi
    done

# Option 3: inotifywait (Linux, good performance)
# Only use if watchman and fswatch are not available or failed
elif (! command -v watchman &>/dev/null || [ "$WATCHMAN_FAILED" = true ]) && command -v inotifywait &>/dev/null; then
    echo -e "${GRAY}• Using inotifywait for file watching${RESET}"
    echo -e "${GRAY}• Press Ctrl+C to stop watching${RESET}"
    echo ""

    while true; do
        # Wait for CSS file changes
        file=$(inotifywait -q -e modify,create,delete,move \
            --exclude '.*\.compiled\.css$|.*\.map$' \
            --format '%f' \
            "$WATCH_DIR" 2>/dev/null)

        if [[ "$file" == *.css ]]; then
            # Get current time
            current_time=$(date +"%H:%M")
            echo -e "${WHITE}$file${GRAY} changed (${current_time})${RESET}"
            compile_css "$file"
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

    # Track file modification times
    declare -A file_times

    # Get initial state
    for file in "$WATCH_DIR"/*.css "$WATCH_DIR"/_*.css; do
        [ -f "$file" ] || continue

        # Skip compiled files
        [[ "$file" =~ \.compiled\.css$ ]] && continue

        # Store modification time (portable across macOS and Linux)
        if [[ "$OSTYPE" == "darwin"* ]]; then
            file_times["$file"]=$(stat -f "%m" "$file" 2>/dev/null)
        else
            file_times["$file"]=$(stat -c "%Y" "$file" 2>/dev/null)
        fi
    done

    # Poll for changes every second
    while true; do
        for file in "$WATCH_DIR"/*.css "$WATCH_DIR"/_*.css; do
            [ -f "$file" ] || continue

            # Skip compiled files
            [[ "$file" =~ \.compiled\.css$ ]] && continue

            # Get current modification time
            current_time=""
            if [[ "$OSTYPE" == "darwin"* ]]; then
                current_time=$(stat -f "%m" "$file" 2>/dev/null)
            else
                current_time=$(stat -c "%Y" "$file" 2>/dev/null)
            fi

            # Check if file changed
            if [ "${file_times[$file]}" != "$current_time" ]; then
                file_times["$file"]=$current_time
                # Get current time
                time_now=$(date +"%H:%M")
                echo -e "${WHITE}$(basename "$file")${GRAY} changed (${time_now})${RESET}"
                # Compile the specific file that changed
                compile_css "$file"
            fi
        done

        # Wait before next check
        sleep 1
    done
fi
