# Strike ⚡

A simple (but lightning-fast) build script that combines [Watchman](https://facebook.github.io/watchman/) and [Lightning CSS](https://lightningcss.dev/) into a simple, elegant command-line interface.

## Why Strike?

Strike combines two best-in-class tools:

-   **[Watchman](https://facebook.github.io/watchman/)** - Facebook's file watching service that provides the fastest, most efficient file system monitoring available
-   **[Lightning CSS](https://lightningcss.dev/)** - An extremely fast CSS parser, transformer, bundler, and minifier written in Rust

While these tools are powerful on their own, they require configuration and setup. Strike wraps them in a zero-config script.

## Features

### 🚀 Blazing Fast Performance

-   Near-instant compilation (typically 7-20ms)
-   Watchman's superior file watching eliminates polling overhead
-   Lightning CSS's Rust-based engine provides unmatched processing speed

### 🎯 Smart Defaults

-   Automatically detects your main CSS file
-   Skips partial files (those starting with `_`)
-   Handles `@import` statements intelligently
-   Outputs to `[filename].compiled.css` to avoid conflicts

## Installation

1. Install the required tools:

```bash
# macOS
brew install watchman
npm install -g lightningcss-cli

# Linux
apt-get install watchman  # or your package manager
npm install -g lightningcss-cli
```

2. Download the script:

```bash
curl -O https://raw.githubusercontent.com/yourusername/strike/main/strike.sh
chmod +x strike.sh
```

## Usage

### Basic Usage

```bash
# Watch and compile with minification (default)
./strike.sh

# Compile once and exit
./strike.sh --no-watch

# Include source maps for debugging
./strike.sh -s

# Development mode (no minification + source maps)
./strike.sh --no-minify -s
```

### Command Options

| Option            | Description                          |
| ----------------- | ------------------------------------ |
| `-h, --help`      | Show help message                    |
| `-w, --watch`     | Watch for file changes (default: on) |
| `--no-watch`      | Compile once and exit                |
| `-s, --sourcemap` | Include inline source maps           |
| `-m, --minify`    | Minify the output (default: on)      |
| `--no-minify`     | Keep output readable                 |

## Fallback Support

Strike gracefully degrades when Watchman isn't available, falling back to:

1. `fswatch` (macOS native)
2. `inotifywait` (Linux)
3. Polling (universal but less efficient)

However, for the best experience, I strongly recommend installing Watchman.

## Performance

In typical usage, Strike provides:

-   **File change detection**: < 20ms with Watchman
-   **CSS compilation**: 5-30ms for most projects
-   **Total response time**: Usually under 50ms from save to compiled output

This means you can save your CSS and see the compiled result faster than your browser can refresh.
