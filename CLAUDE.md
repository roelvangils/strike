# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains `strike.sh` (referred to as "swatch" in the script), a modern CSS build tool that uses Lightning CSS for fast compilation, bundling, and minification of CSS files.

## Key Commands

### Running the Tool
```bash
# Default mode: watch + minify, no source maps
./strike.sh

# Compile once and exit
./strike.sh --no-watch

# Include source maps for debugging
./strike.sh -s

# Debug mode: readable + source maps
./strike.sh --no-minify -s

# Show help
./strike.sh --help
```

## Architecture

The script implements a CSS build pipeline with:

1. **Lightning CSS Integration**: Uses Lightning CSS (Rust-based) for fast compilation
2. **File Watching**: Supports multiple watchers in order of preference:
   - Watchman (fastest, most efficient)
   - fswatch (native macOS)
   - inotifywait (Linux)
   - Polling fallback (universal but less efficient)
3. **Smart File Detection**: 
   - Automatically finds main CSS file (non-partial)
   - Skips partials (files starting with `_`)
   - Avoids recompiling `.compiled.css` files
4. **Output Management**: Supports directory selection for compiled CSS output

## Development Notes

- The script requires Lightning CSS CLI (`lightningcss`) to be installed
- Optional dependency: `gum` for interactive directory selection
- Partials (files starting with `_`) are imported but not compiled directly
- Output files are named `[filename].compiled.css`
- Default browser target: browsers with >0.25% market share
- Watchman settle time is optimized to 20ms for near-instant response