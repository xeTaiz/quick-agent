#!/bin/bash
set -euo pipefail

readonly PLUGIN_ID="xetaiz.quick-agent"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
readonly DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
readonly LOCAL_BIN="$HOME/.local/bin"
readonly PLUGINS_DIR="$CONFIG_HOME/omarchy/plugins"
readonly PLUGIN_LINK="$PLUGINS_DIR/$PLUGIN_ID"
readonly SANDBOX_SOURCE="${QUICK_AGENT_SANDBOX_DOTFILES:-$HOME/dotfiles/agent-sandbox}"
readonly SHELL_CONFIG="$CONFIG_HOME/omarchy/shell.json"

info() {
  printf 'quick-agent: %s\n' "$*"
}

warn() {
  printf 'quick-agent: warning: %s\n' "$*" >&2
}

fail() {
  printf 'quick-agent: error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

same_target() {
  local source="$1"
  local destination="$2"
  [[ -e $destination || -L $destination ]] || return 1
  [[ "$(realpath -m -- "$source")" == "$(realpath -m -- "$destination")" ]]
}

link_required() {
  local source="$1"
  local destination="$2"
  local label="$3"

  [[ -e $source || -L $source ]] || fail "$label source not found: $source"
  mkdir -p -- "$(dirname -- "$destination")"

  if same_target "$source" "$destination"; then
    info "$label already linked: $destination"
  elif [[ -e $destination || -L $destination ]]; then
    fail "$label already exists at $destination; refusing to replace it"
  else
    ln -s -- "$source" "$destination"
    info "linked $label: $destination -> $source"
  fi
}

link_if_absent() {
  local source="$1"
  local destination="$2"
  local label="$3"

  mkdir -p -- "$(dirname -- "$destination")"

  if [[ -e $destination || -L $destination ]]; then
    if [[ -e $source || -L $source ]] && same_target "$source" "$destination"; then
      info "$label already linked: $destination"
    else
      warn "$label already exists at $destination; leaving the user's file unchanged"
    fi
    return
  fi

  [[ -e $source || -L $source ]] || fail "$label source not found: $source"
  ln -s -- "$source" "$destination"
  info "linked $label: $destination -> $source"
}

require_source_if_absent() {
  local source="$1"
  local destination="$2"
  local label="$3"
  if [[ ! -e $destination && ! -L $destination && ! -e $source && ! -L $source ]]; then
    fail "$label is absent and its dotfiles source was not found: $source"
  fi
}

enable_for_next_start() {
  local config_dir config_file default_config tmp
  config_dir="$(dirname -- "$SHELL_CONFIG")"
  default_config="${OMARCHY_PATH:-/usr/share/omarchy}/config/omarchy/shell.json"
  mkdir -p -- "$config_dir"
  [[ ! -L $SHELL_CONFIG || -e $SHELL_CONFIG ]] || fail "shell config is a broken symlink; refusing to replace it: $SHELL_CONFIG"


  if [[ ! -e $SHELL_CONFIG ]]; then
    [[ -r $default_config ]] || fail "cannot initialize $SHELL_CONFIG; default not readable: $default_config"
    tmp="$(mktemp --tmpdir="$config_dir" .shell.json.XXXXXX)"
    cp -- "$default_config" "$tmp"
    chmod 600 "$tmp"
    mv -- "$tmp" "$SHELL_CONFIG"
    info "initialized Omarchy shell config from $default_config"
  fi
  config_file="$(realpath -e -- "$SHELL_CONFIG")" || fail "cannot resolve shell config: $SHELL_CONFIG"
  config_dir="$(dirname -- "$config_file")"

  [[ -f $config_file && -w $config_file ]] || fail "shell config is not a writable regular file: $config_file"
  jq -e '
    type == "object"
    and .version == 1
    and ((.plugins // []) | type == "array")
  ' "$config_file" >/dev/null || fail "unsupported shell config shape in $config_file; expected version 1 with plugins as an array"

  tmp="$(mktemp --tmpdir="$config_dir" .shell.json.XXXXXX)"
  if ! jq --arg id "$PLUGIN_ID" '
    if any((.plugins // [])[]; ((.id // "") == $id)) then
      .
    else
      .plugins = ((.plugins // []) + [{id: $id}])
    end
  ' "$config_file" >"$tmp"; then
    rm -f -- "$tmp"
    fail "could not update $SHELL_CONFIG"
  fi
  chmod --reference="$config_file" "$tmp"
  mv -- "$tmp" "$config_file"
  info "enabled $PLUGIN_ID persistently in $SHELL_CONFIG"
}

for command in bun jq mise bwrap omarchy-shell omarchy-plugin-enable omarchy-plugin-list omarchy-plugin-validate; do
  require_command "$command"
done

[[ -f $SCRIPT_DIR/manifest.json ]] || fail "manifest.json is missing from $SCRIPT_DIR"
[[ -f $SCRIPT_DIR/Main.qml ]] || fail "Main.qml is missing from $SCRIPT_DIR"
[[ -f $SCRIPT_DIR/bridge.ts ]] || fail "bridge.ts is missing from $SCRIPT_DIR"
[[ -x $SCRIPT_DIR/quick-agent ]] || fail "launcher is not executable: $SCRIPT_DIR/quick-agent"

manifest_id="$(jq -r '.id // empty' "$SCRIPT_DIR/manifest.json")"
[[ $manifest_id == "$PLUGIN_ID" ]] || fail "manifest id is '$manifest_id', expected '$PLUGIN_ID'"
jq -e '.schemaVersion == 1 and (.kinds | index("overlay") != null) and .entryPoints.overlay == "Main.qml"' \
  "$SCRIPT_DIR/manifest.json" >/dev/null || fail "manifest must declare schema 1 overlay entry point Main.qml"
omarchy-plugin-validate "$SCRIPT_DIR"

if ! mise which omp --tool github:can1357/oh-my-pi@latest >/dev/null 2>&1; then
  fail "OMP is not installed in mise for github:can1357/oh-my-pi@latest (required by the sandbox launcher)"
fi
if ! bwrap --die-with-parent --new-session --unshare-all --share-net \
  --ro-bind / / --dev /dev --proc /proc -- /usr/bin/true; then
  fail "bubblewrap cannot create the sandbox required by OMP"
fi
require_source_if_absent "$SANDBOX_SOURCE/.local/bin/o" "$LOCAL_BIN/o" "OMP sandbox launcher"
require_source_if_absent "$SANDBOX_SOURCE/.local/bin/agent-sandbox" "$LOCAL_BIN/agent-sandbox" "sandbox wrapper"
require_source_if_absent "$SANDBOX_SOURCE/.config/agent-sandbox/paths" "$CONFIG_HOME/agent-sandbox/paths" "sandbox path config"



link_required "$SCRIPT_DIR" "$PLUGIN_LINK" "Omarchy plugin"
link_if_absent "$SCRIPT_DIR/quick-agent" "$LOCAL_BIN/quick-agent" "launcher"
link_if_absent "$SCRIPT_DIR/quick-agent.desktop" "$DATA_HOME/applications/quick-agent.desktop" "desktop launcher"

link_if_absent "$SANDBOX_SOURCE/.local/bin/o" "$LOCAL_BIN/o" "OMP sandbox launcher"
link_if_absent "$SANDBOX_SOURCE/.local/bin/agent-sandbox" "$LOCAL_BIN/agent-sandbox" "sandbox wrapper"
link_if_absent "$SANDBOX_SOURCE/.config/agent-sandbox/paths" "$CONFIG_HOME/agent-sandbox/paths" "sandbox path config"

[[ -x $LOCAL_BIN/o ]] || fail "OMP launcher is not executable: $LOCAL_BIN/o"
[[ -x $LOCAL_BIN/agent-sandbox ]] || fail "sandbox wrapper is not executable: $LOCAL_BIN/agent-sandbox"
[[ -r $CONFIG_HOME/agent-sandbox/paths ]] || fail "sandbox path config is not readable: $CONFIG_HOME/agent-sandbox/paths"

live_enabled=false
if omarchy-shell shell ping >/dev/null 2>&1; then
  info "running Omarchy shell detected; rescanning plugins"
  if omarchy-shell shell rescanPlugins >/dev/null 2>&1; then
    discovered=false
    for (( attempt = 0; attempt < 40; attempt++ )); do
      if omarchy-plugin-list --json 2>/dev/null | jq -e --arg id "$PLUGIN_ID" 'any(.[]; .id == $id)' >/dev/null; then
        discovered=true
        break
      fi
      sleep 0.05
    done

    if [[ $discovered == true ]] && omarchy-plugin-enable "$PLUGIN_ID" >/dev/null; then
      live_enabled=true
      info "enabled $PLUGIN_ID in the running Omarchy shell"
    else
      warn "the running shell did not discover or enable $PLUGIN_ID; configuring it for the next shell start"
    fi
  else
    warn "plugin rescan failed; configuring $PLUGIN_ID for the next shell start"
  fi
else
  info "no running Omarchy shell detected; skipping live IPC"
fi

if [[ $live_enabled != true ]]; then
  enable_for_next_start
  info "pending: start or restart the real Omarchy shell before using Quick Agent"
fi

info "launcher command: quick-agent"
info "direct command: omarchy-shell shell toggle $PLUGIN_ID '{}'"
info "runtime prerequisites ready: bun, mise OMP, bubblewrap, sandbox wrapper, and sandbox path config"
