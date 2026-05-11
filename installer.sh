#!/usr/bin/env bash
#
# installer.sh — install the noctalia usbguard plugin.
#
# Idempotent: safe to re-run. Performs:
#   1. Copy plugin files to ~/.config/noctalia/plugins/usbguard/
#   2. Enable the plugin in ~/.config/noctalia/plugins.json (states.usbguard.enabled = true)
#   3. Add { "id": "usbguard" } to bar.widgets.<section> in settings.json if missing
#   4. Verify usbguard IPC is reachable as the current user
#
# Existing JSON files are backed up to <file>.bak.<timestamp> before edits.
#
# Usage:
#   ./installer.sh               # install to the 'right' bar section
#   ./installer.sh -s left       # install to 'left'
#   ./installer.sh -s center     # install to 'center'
#   ./installer.sh -n            # don't touch settings.json (just install + enable)
#   ./installer.sh -u            # uninstall

set -euo pipefail

# --- Config ------------------------------------------------------------------

PLUGIN_ID="usbguard"
PLUGIN_FILES=(manifest.json Main.qml BarWidget.qml Panel.qml Settings.qml README.md)

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/noctalia"
PLUGINS_DIR="$CONFIG_DIR/plugins"
TARGET_DIR="$PLUGINS_DIR/$PLUGIN_ID"
PLUGINS_JSON="$CONFIG_DIR/plugins.json"
SETTINGS_JSON="$CONFIG_DIR/settings.json"

BAR_SECTION="right"
SKIP_BAR_EDIT=0
UNINSTALL=0

# --- Pretty output -----------------------------------------------------------

# Disable colors if stdout isn't a terminal.
if [ -t 1 ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_OK=$'\033[32m'
    C_WARN=$'\033[33m'
    C_ERR=$'\033[31m'
    C_INFO=$'\033[36m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''; C_OK=''; C_WARN=''; C_ERR=''; C_INFO=''
fi

say()  { printf '%s%s%s\n'   "$C_INFO" "$*" "$C_RESET"; }
ok()   { printf '%s✓%s %s\n'  "$C_OK"   "$C_RESET" "$*"; }
warn() { printf '%s!%s %s\n'  "$C_WARN" "$C_RESET" "$*" >&2; }
die()  { printf '%s✗%s %s\n'  "$C_ERR"  "$C_RESET" "$*" >&2; exit 1; }
step() { printf '\n%s==>%s %s%s%s\n' "$C_INFO" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }

# --- Argument parsing --------------------------------------------------------

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  -s SECTION   Bar section to add the widget to: left | center | right (default: right)
  -n           Don't edit settings.json (just install files + enable plugin)
  -u           Uninstall: remove plugin files and clear references from JSON
  -h           Show this help
EOF
}

while getopts ":s:nuh" opt; do
    case "$opt" in
        s) BAR_SECTION="$OPTARG" ;;
        n) SKIP_BAR_EDIT=1 ;;
        u) UNINSTALL=1 ;;
        h) usage; exit 0 ;;
        \?) die "Unknown option: -$OPTARG (use -h)" ;;
        :)  die "Option -$OPTARG requires an argument" ;;
    esac
done

case "$BAR_SECTION" in
    left|center|right) ;;
    *) die "Invalid section '$BAR_SECTION' — must be left, center, or right" ;;
esac

# --- Preflight ---------------------------------------------------------------

step "Preflight"

command -v python3 >/dev/null 2>&1 || die "python3 is required for JSON editing"
ok "python3 found"

# Locate plugin source files. We accept either:
#   - script is run from the plugin directory (manifest.json next to script)
#   - script is run from the parent of a 'usbguard/' subdir
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/manifest.json" ]; then
    SRC_DIR="$SCRIPT_DIR"
elif [ -f "$SCRIPT_DIR/usbguard/manifest.json" ]; then
    SRC_DIR="$SCRIPT_DIR/usbguard"
else
    die "Can't find plugin source files. Run this script from inside the unpacked plugin directory (the one containing manifest.json)."
fi
ok "plugin source: $SRC_DIR"

# Verify all expected files are present in the source (skip during uninstall).
if [ "$UNINSTALL" -eq 0 ]; then
    missing=()
    for f in "${PLUGIN_FILES[@]}"; do
        [ -f "$SRC_DIR/$f" ] || missing+=("$f")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing files in $SRC_DIR: ${missing[*]}"
    fi
    ok "all source files present"
fi

# --- Helpers -----------------------------------------------------------------

backup_if_exists() {
    local file="$1"
    [ -f "$file" ] || return 0
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    cp "$file" "$file.bak.$stamp"
    printf '%s    backup: %s%s\n' "$C_DIM" "$file.bak.$stamp" "$C_RESET"
}

# Run a Python snippet that operates on a JSON file. Reads the file (or starts
# from {}), passes its contents to the snippet via stdin variable `data`, and
# writes the snippet's output back atomically.
edit_json() {
    local file="$1" snippet="$2"
    mkdir -p "$(dirname "$file")"
    backup_if_exists "$file"
    python3 - "$file" <<PYEOF
import json, os, sys, tempfile

path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
except json.JSONDecodeError as e:
    print(f"ERROR: {path} is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)

$snippet

# Atomic write: temp file in the same dir, then rename.
d = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix=".json.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
except Exception:
    os.unlink(tmp)
    raise
PYEOF
}

# --- Uninstall path ----------------------------------------------------------

if [ "$UNINSTALL" -eq 1 ]; then
    step "Uninstalling $PLUGIN_ID"

    if [ -d "$TARGET_DIR" ]; then
        rm -rf "$TARGET_DIR"
        ok "removed $TARGET_DIR"
    else
        warn "nothing to remove at $TARGET_DIR"
    fi

    if [ -f "$PLUGINS_JSON" ]; then
        edit_json "$PLUGINS_JSON" "
states = data.get('states', {})
if '$PLUGIN_ID' in states:
    del states['$PLUGIN_ID']
# Clean up the legacy top-level key the earlier installer attempt may have left.
data.pop('$PLUGIN_ID', None)
"
        ok "cleared $PLUGIN_ID from plugins.json"
    fi

    if [ -f "$SETTINGS_JSON" ]; then
        edit_json "$SETTINGS_JSON" "
bar = data.get('bar', {})
widgets = bar.get('widgets', {})
removed = 0
for section, items in list(widgets.items()):
    if not isinstance(items, list):
        continue
    before = len(items)
    items[:] = [w for w in items if not (isinstance(w, dict) and w.get('id') == '$PLUGIN_ID')]
    removed += before - len(items)
print(f'    removed {removed} widget reference(s)')
"
        ok "cleared widget references from settings.json"
    fi

    echo
    say "Uninstall complete. Restart noctalia to apply: pkill -f 'qs -c noctalia-shell'"
    exit 0
fi

# --- Install: copy files -----------------------------------------------------

step "Installing files"

mkdir -p "$TARGET_DIR"
for f in "${PLUGIN_FILES[@]}"; do
    install -m 0644 "$SRC_DIR/$f" "$TARGET_DIR/$f"
done
ok "copied to $TARGET_DIR"

# Validate the manifest just dropped in place.
python3 -c "
import json, sys
m = json.load(open('$TARGET_DIR/manifest.json'))
if m.get('id') != '$PLUGIN_ID':
    sys.exit(f\"manifest id mismatch: got {m.get('id')!r}\")
" || die "manifest.json failed validation"
ok "manifest.json valid"

# --- Install: enable in plugins.json -----------------------------------------

step "Enabling plugin in plugins.json"

edit_json "$PLUGINS_JSON" "
# Defensive: remove any legacy top-level key from earlier botched edits.
data.pop('$PLUGIN_ID', None)

states = data.setdefault('states', {})
entry = states.setdefault('$PLUGIN_ID', {})
was_enabled = entry.get('enabled', False)
entry['enabled'] = True
print('    states.$PLUGIN_ID.enabled =', entry['enabled'],
      '(was', was_enabled, ')')
"
ok "plugin enabled"

# --- Install: add bar widget -------------------------------------------------

if [ "$SKIP_BAR_EDIT" -eq 1 ]; then
    warn "skipping settings.json edit (-n given); add { \"id\": \"$PLUGIN_ID\" } to bar.widgets.<section> manually"
else
    step "Adding bar widget to bar.widgets.$BAR_SECTION"

    edit_json "$SETTINGS_JSON" "
bar = data.setdefault('bar', {})
widgets = bar.setdefault('widgets', {})
section = widgets.setdefault('$BAR_SECTION', [])

# Already present?
if any(isinstance(w, dict) and w.get('id') == '$PLUGIN_ID' for w in section):
    print('    already present in $BAR_SECTION — leaving as-is')
else:
    # If the user previously had it in a different section, leave that alone
    # too; multiple instances are valid.
    section.append({'id': '$PLUGIN_ID'})
    print('    appended { \"id\": \"$PLUGIN_ID\" } to $BAR_SECTION')
print('    $BAR_SECTION widgets:',
      [w.get('id') if isinstance(w, dict) else w for w in section])
"
    ok "bar widget configured"
fi

# --- Sanity check: usbguard IPC ---------------------------------------------

step "Checking usbguard reachability"

if ! command -v usbguard >/dev/null 2>&1; then
    warn "'usbguard' binary not on PATH — install the usbguard package"
elif usbguard list-devices >/dev/null 2>&1; then
    ok "usbguard list-devices works as $USER (no sudo needed)"
else
    warn "usbguard list-devices failed as $USER"
    warn "you probably need to grant IPC access. As root:"
    warn "    usbguard add-user \"$USER\" --devices=listen,modify --policy=list,modify --exceptions=listen"
    warn "    systemctl restart usbguard"
fi

# --- Done --------------------------------------------------------------------

echo
say "$(printf '%sInstall complete.%s' "$C_BOLD" "$C_RESET")"
cat <<EOF

Next step: restart noctalia to load the plugin.

    pkill -f "qs -c noctalia-shell"
    qs -c noctalia-shell &

Or, if you have hot-reload on (NOCTALIA_DEBUG=1 or 8 clicks on the logo in
Settings → About), noctalia should pick it up automatically.

Verify it loaded:

    pgrep -fa noctalia
    # then check Settings → Bar for the USBGuard widget
EOF
