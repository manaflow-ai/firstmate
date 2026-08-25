#!/usr/bin/env bash
# bin/backends/cmux-tui.sh - the cmux-tui session-provider adapter
# (EXPERIMENTAL). cmux-tui is the Rust terminal multiplexer in
# manaflow-ai/cmux `cmux-tui/`, NOT the macOS GUI app that
# bin/backends/cmux.sh drives; the two adapters are independent.
#
# Function prefix: fm_backend_cmuxtui_* (the backend NAME is "cmux-tui",
# but shell function names cannot carry the hyphen portably, so the
# dispatcher's cmux-tui case arms call the cmuxtui-prefixed family).
#
# cmux-tui is a session provider ONLY, exactly like tmux/herdr/zellij: the
# worktree provider stays treehouse. Sourced only through bin/fm-backend.sh's
# fm_backend_source in normal operation; the unit tests source it directly.
#
# Container shape: cmux-tui HAS a real session layer (unlike the GUI app).
# ONE dedicated headless cmux-tui session per firstmate home, named
# "fm-<hometag>" (bin/fm-backend-hometag-lib.sh), started with
# `server start --session <name> --headless --state <dir>` against an
# adapter-owned state dir. ONE workspace per task with exactly one terminal
# tab inside it. Because the session itself is home-scoped, workspace names
# are the PLAIN caller-facing "fm-<id>" labels - no title tag is needed for
# cross-home isolation (the tag lives in the session name instead).
#
# Target string shape: "<workspace_id>:<terminal_id>" - typed opaque ids
# ("ws_<hex>", "term_<hex>") with no embedded colon, so splitting on the
# FIRST colon is trivially correct (herdr/zellij/cmux convention).
#
# Empirical findings (real cmux-tui 0.1.0 @ 4471965b12, macOS aarch64,
# 2026-08-24; docs/verification/runtime-backends.md "cmux-tui" has the
# evidence log) that shaped this adapter:
#
#   1. IDs are DURABLE across server restarts: after `server stop` +
#      `server start --state <same dir>`, `workspace list` and
#      `terminal <id> show` return the SAME ws_/term_ ids (verified live).
#      IDs are therefore the recovery authority; workspace names are display
#      labels only, adopted only through the standard exactly-one duplicate
#      guard when a recorded id has genuinely disappeared.
#   2. `terminal <id> write --text` does NOT auto-submit; `keys enter` is a
#      separate call - the fleet-wide literal-then-Enter contract, verified.
#   3. `screen read` works on a genuinely FRESH terminal (no GUI-cmux
#      fresh-surface internal_error) and returns cursor_row/cursor_col plus
#      cursor_visible, giving this adapter a cursor primitive the GUI app
#      lacks (composer capability cursor=1).
#   4. Closing the LAST workspace of a session works; the session server
#      keeps running with an empty tree (no GUI-cmux last-in-window sibling
#      dance, no zellij ghost tab).
#   5. `process show --json` reports the top-level shell's cwd as a
#      file://<host>/path URL (strip scheme+host) and its child pids. The
#      structured cwd follows a `cd` typed into an OSC7-integrated shell but
#      stays FROZEN when a foreground subshell without shell integration
#      (exactly what `treehouse get` opens) does its own cd - verified with
#      `env -i bash --norc`. The live answer for that case is the child
#      pid's OS-level cwd: `lsof -a -p <pid> -d cwd -Fn` on macOS,
#      /proc/<pid>/cwd on Linux. No screen-scraped pwd-marker probe needed.
#   6. NO workspace-name uniqueness enforcement (two workspaces created with
#      one name, verified). The duplicate refusal below is ours, mirroring
#      every other adapter.
#   7. Mutations accept --correlation-key: replaying the same key returns
#      the ORIGINAL result with replayed:true - even after the created
#      workspace was closed (verified), so keys must be per-attempt nonces
#      used only to retry the SAME indeterminate attempt, never derived from
#      stable labels.
#   8. Typed JSON errors ({code, message, retryable, details}), e.g.
#      selector.not_found, validation.invalid, mutation.indeterminate. The
#      mutate wrapper retries once on a retryable/indeterminate error with
#      the SAME correlation key (act-then-handle, not check-then-act).
#   9. Native per-terminal agent state exists: `agent list --json` rows
#      carry state working|blocked|idle|done|unknown (hook-fed via
#      `agent report`/`agent hook install`), the same vocabulary as herdr's
#      agent_status, mapped the same way for fm_backend_busy_state.
#  10. The per-uid socket dir is 0700 and same-user; there is no
#      socketControlMode matrix and no password handshake (the GUI app's
#      whole auth section does not exist here).
#
# Config isolation is load-bearing: the operator's own ~/.config/cmux/
# cmux-tui.json may configure a machine provider that refuses
# --session/--headless startup, so EVERY invocation exports CMUX_TUI_CONFIG
# pointing at an adapter-owned config file (fm_backend_cmuxtui_config).
#
# Requires: cmux-tui (CLI; override with FM_CMUXTUI_BIN), jq (JSON parsing).
# Bootstrap detects these through fm_backend_required_tools only when
# cmux-tui is the resolved backend; this adapter also gates them again
# before spawning.

# FM_HOME fallback: every real caller already sets FM_HOME as a global before
# sourcing fm-backend.sh (which sources this file); this exists only so this
# file's own unit tests, which source it directly, resolve sanely. Mirrors
# bin/backends/zellij.sh's identical fallback.
FM_BACKEND_CMUXTUI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_CMUXTUI_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$FM_BACKEND_CMUXTUI_ROOT/bin/fm-backend-hometag-lib.sh"

# Shared composer classification (the fleet-wide shape catalogue and verdict
# owner; this adapter contributes only capture and capability facts).
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_CMUXTUI_ROOT/bin/fm-composer-lib.sh"

# Verified minimum: the version the live pass ran against
# (docs/verification/runtime-backends.md "cmux-tui").
FM_BACKEND_CMUXTUI_MIN_MAJOR=0
FM_BACKEND_CMUXTUI_MIN_MINOR=1

# fm_backend_cmuxtui_bin: resolve the cmux-tui CLI binary. FM_CMUXTUI_BIN
# overrides (test isolation and non-PATH installs); otherwise PATH.
fm_backend_cmuxtui_bin() {
  if [ -n "${FM_CMUXTUI_BIN:-}" ]; then
    printf '%s' "$FM_CMUXTUI_BIN"
    return 0
  fi
  command -v cmux-tui 2>/dev/null && return 0
  return 1
}

fm_backend_cmuxtui_tool_check() {
  fm_backend_cmuxtui_bin >/dev/null 2>&1 || { echo "error: backend=cmux-tui selected but the 'cmux-tui' CLI was not found on PATH (set FM_CMUXTUI_BIN or install it from https://github.com/manaflow-ai/cmux)" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=cmux-tui selected but 'jq' is not installed (required to parse cmux-tui's JSON output)" >&2; return 1; }
  return 0
}

# fm_backend_cmuxtui_session: the home-scoped session name. One dedicated
# headless session per firstmate home ("fm-<hometag>"), so crews are isolated
# per home AND from the operator's own interactive cmux-tui sessions
# (including the default "main" session, which this adapter never touches).
# FM_CMUXTUI_SESSION overrides for test isolation, mirroring FM_ZELLIJ_SESSION.
fm_backend_cmuxtui_session() {
  if [ -n "${FM_CMUXTUI_SESSION:-}" ]; then
    printf '%s' "$FM_CMUXTUI_SESSION"
    return 0
  fi
  printf 'fm-%s' "$(fm_backend_hometag)"
}

# fm_backend_cmuxtui_state_dir: the adapter-owned durable state dir handed to
# `server start --state`. Durable ids (finding #1) live here, so it must be a
# per-home stable path: <state>/cmux-tui under the home's own state root.
# FM_CMUXTUI_STATE overrides for test isolation.
fm_backend_cmuxtui_state_dir() {
  if [ -n "${FM_CMUXTUI_STATE:-}" ]; then
    printf '%s' "$FM_CMUXTUI_STATE"
    return 0
  fi
  printf '%s/cmux-tui' "${FM_STATE_OVERRIDE:-$FM_HOME/state}"
}

# fm_backend_cmuxtui_config: the adapter-owned CMUX_TUI_CONFIG file, created
# as an empty JSON object on first use. Never the operator's own
# ~/.config/cmux/cmux-tui.json: a machine_provider configured there makes
# --session/--headless startup fail outright (see file header).
# FM_CMUXTUI_CONFIG overrides for test isolation.
fm_backend_cmuxtui_config() {
  local cfg dir
  cfg="${FM_CMUXTUI_CONFIG:-$(fm_backend_cmuxtui_state_dir)/cmux-tui.json}"
  if [ ! -f "$cfg" ]; then
    dir=$(dirname "$cfg")
    mkdir -p "$dir" 2>/dev/null || true
    printf '{}\n' > "$cfg" 2>/dev/null || true
  fi
  printf '%s' "$cfg"
}

# fm_backend_cmuxtui_cli: run `cmux-tui --session <home-session> <args...>`
# with the adapter-owned config exported. The global --session flag routes
# every scope/action through the home's dedicated session socket, so no call
# can ever reach the operator's default "main" session.
fm_backend_cmuxtui_cli() {  # <cmux-tui-scope-action-and-args...>
  local bin
  bin=$(fm_backend_cmuxtui_bin) || return 1
  CMUX_TUI_CONFIG="$(fm_backend_cmuxtui_config)" \
    "$bin" --session "$(fm_backend_cmuxtui_session)" "$@"
}

# fm_backend_cmuxtui_version_check: refuse loudly on a missing/incompatible
# cmux-tui client. `cmux-tui --version` needs no socket (verified: prints
# "cmux <semver> (<sha>; ghostty <sha>)" with no server running).
fm_backend_cmuxtui_version_check() {
  fm_backend_cmuxtui_tool_check || return 1
  local bin raw ver major rest minor
  bin=$(fm_backend_cmuxtui_bin) || return 1
  raw=$("$bin" --version 2>/dev/null) || { echo "error: 'cmux-tui --version' failed; is cmux-tui installed correctly?" >&2; return 1; }
  ver=$(printf '%s' "$raw" | awk '{print $2}')
  case "$ver" in
    ''|*[!0-9.]*)
      echo "error: could not parse a cmux-tui version from '$raw'; refusing to use an unverified cmux-tui build" >&2
      return 1
      ;;
  esac
  major=${ver%%.*}
  rest=${ver#*.}
  minor=${rest%%.*}
  case "$major" in ''|*[!0-9]*) major=0 ;; esac
  case "$minor" in ''|*[!0-9]*) minor=0 ;; esac
  if [ "$major" -lt "$FM_BACKEND_CMUXTUI_MIN_MAJOR" ] || { [ "$major" -eq "$FM_BACKEND_CMUXTUI_MIN_MAJOR" ] && [ "$minor" -lt "$FM_BACKEND_CMUXTUI_MIN_MINOR" ]; }; then
    echo "error: cmux-tui $ver is older than the verified minimum $FM_BACKEND_CMUXTUI_MIN_MAJOR.$FM_BACKEND_CMUXTUI_MIN_MINOR; update cmux-tui before using backend=cmux-tui" >&2
    return 1
  fi
  return 0
}

# fm_backend_cmuxtui_server_running: passive, READ-ONLY liveness check for the
# home's session server. `server status --session <name>` exits 0 only when
# that named session's socket answers; it never starts anything.
fm_backend_cmuxtui_server_running() {
  local bin
  bin=$(fm_backend_cmuxtui_bin) || return 1
  CMUX_TUI_CONFIG="$(fm_backend_cmuxtui_config)" \
    "$bin" server status --session "$(fm_backend_cmuxtui_session)" >/dev/null 2>&1
}

# fm_backend_cmuxtui_server_ensure: start the home's dedicated headless
# session if it is not already running - mirrors tmux's
# `has-session || new-session -d` and zellij's server_ensure. `server start`
# runs foreground, so it is daemonized explicitly (nohup, detached, output to
# a log inside the adapter state dir) and readiness is polled via
# `server status`.
fm_backend_cmuxtui_server_ensure() {
  fm_backend_cmuxtui_server_running && return 0
  local bin state session log i
  bin=$(fm_backend_cmuxtui_bin) || return 1
  state=$(fm_backend_cmuxtui_state_dir)
  session=$(fm_backend_cmuxtui_session)
  mkdir -p "$state" || { echo "error: cannot create cmux-tui state dir $state" >&2; return 1; }
  log="$state/server.log"
  ( CMUX_TUI_CONFIG="$(fm_backend_cmuxtui_config)" \
      nohup "$bin" server start --session "$session" --headless --state "$state" \
      </dev/null >>"$log" 2>&1 & ) || return 1
  for i in $(seq 1 40); do
    fm_backend_cmuxtui_server_running && return 0
    sleep 0.25
  done
  echo "error: cmux-tui session '$session' did not come up within 10s (see $log)" >&2
  return 1
}

# fm_backend_cmuxtui_container_ensure: the full spawn-time container-ensure
# sequence (version gate, headless session). Echoes the session name,
# mirroring zellij's container_ensure.
fm_backend_cmuxtui_container_ensure() {
  local session
  fm_backend_cmuxtui_version_check || return 1
  fm_backend_cmuxtui_server_ensure || return 1
  session=$(fm_backend_cmuxtui_session)
  printf '%s' "$session"
}

# fm_backend_cmuxtui_mutate: run one mutating CLI action with a fresh
# per-attempt --correlation-key nonce, retrying ONCE with the SAME key when
# the typed error says the attempt was retryable or indeterminate
# (mutation.indeterminate) - act-then-handle-typed-error, never a pre-check.
# The key is a nonce, never label-derived: a replayed key returns the
# ORIGINAL attempt's result even after that workspace was closed (verified,
# finding #7), so a stable key would resurrect stale ids on a later task
# reusing the same label. Echoes the (successful or failed) JSON response.
fm_backend_cmuxtui_mutate() {  # <scope-action-and-args...>
  local key out rc
  key="fm-$$-$(date +%s)-$RANDOM$RANDOM"
  out=$(fm_backend_cmuxtui_cli "$@" --correlation-key "$key" --json 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | jq -e '(.retryable == true) or (.code == "mutation.indeterminate")' >/dev/null 2>&1; then
    out=$(fm_backend_cmuxtui_cli "$@" --correlation-key "$key" --json 2>&1)
    rc=$?
  fi
  printf '%s' "$out"
  return "$rc"
}

# fm_backend_cmuxtui_workspace_id_for_label: the live workspace id whose name
# equals <label>, adopted ONLY when exactly one live workspace carries it -
# the standard duplicate guard (cmux-tui enforces no name uniqueness itself,
# finding #6). Ambiguity prints nothing and fails.
fm_backend_cmuxtui_workspace_id_for_label() {  # <label>
  local label=$1 rows count
  rows=$(fm_backend_cmuxtui_cli workspace list --json 2>/dev/null) || return 1
  count=$(printf '%s' "$rows" | jq -r --arg want "$label" '[.[]? | select(.name == $want)] | length' 2>/dev/null)
  [ "$count" = "1" ] || return 1
  printf '%s' "$rows" | jq -r --arg want "$label" '.[]? | select(.name == $want) | .id' 2>/dev/null | head -1
}

# fm_backend_cmuxtui_terminal_for_workspace: the first terminal id inside
# <workspace_id>, resolved through one `session current snapshot` read
# (workspace -> screens.workspace_id -> layout tab_ids -> tabs.content_id
# where content_kind == "terminal"; chain verified live).
fm_backend_cmuxtui_terminal_for_workspace() {  # <workspace_id>
  local wsid=$1 snap
  snap=$(fm_backend_cmuxtui_cli session current snapshot --json 2>/dev/null) || return 1
  printf '%s' "$snap" | jq -r --arg ws "$wsid" '
    [.screens[]? | select(.workspace_id == $ws) | .layout | .. | .tab_ids? // empty | .[]] as $tabs
    | [.tabs[]? | select((.id as $t | $tabs | index($t)) and .content_kind == "terminal") | .content_id]
    | first // empty
  ' 2>/dev/null
}

# fm_backend_cmuxtui_create_task: create the task's workspace (one terminal
# tab) in the home session, refusing an existing live <label> (finding #6:
# cmux-tui enforces no uniqueness itself; the TOCTOU between this check and
# the create is inherent and documented). Echoes
# "<workspace_id> <terminal_id>" on success.
fm_backend_cmuxtui_create_task() {  # <label> <cwd>
  local label=$1 cwd=$2 dup out wsid termid
  dup=$(fm_backend_cmuxtui_cli workspace list --json 2>/dev/null \
    | jq -r --arg want "$label" '.[]? | select(.name == $want) | .id' 2>/dev/null | head -1)
  if [ -n "$dup" ]; then
    echo "error: cmux-tui workspace '$label' already exists in session '$(fm_backend_cmuxtui_session)'" >&2
    return 1
  fi
  out=$(fm_backend_cmuxtui_mutate workspace create --name "$label" --empty) || {
    echo "error: cmux-tui workspace create failed for '$label': $out" >&2
    return 1
  }
  wsid=$(printf '%s' "$out" | jq -r '.value.workspace_id // empty' 2>/dev/null)
  [ -n "$wsid" ] || { echo "error: could not parse a cmux-tui workspace id for '$label' from: $out" >&2; return 1; }
  out=$(fm_backend_cmuxtui_mutate tab create terminal --workspace "$wsid" --cwd "$cwd") || {
    echo "error: cmux-tui tab create terminal failed for '$label' ($wsid): $out" >&2
    fm_backend_cmuxtui_cli workspace "$wsid" close >/dev/null 2>&1 || true
    return 1
  }
  termid=$(printf '%s' "$out" | jq -r '.value.terminal_id // empty' 2>/dev/null)
  [ -n "$termid" ] || { echo "error: could not parse a cmux-tui terminal id for '$label' ($wsid) from: $out" >&2; return 1; }
  printf '%s %s' "$wsid" "$termid"
}

# fm_backend_cmuxtui_parse_target: split "<workspace_id>:<terminal_id>" on the
# FIRST colon (neither typed id contains a colon, so this is unambiguous).
# Sets FM_BACKEND_CMUXTUI_WORKSPACE and FM_BACKEND_CMUXTUI_TERMINAL.
fm_backend_cmuxtui_parse_target() {  # <target>
  local target=$1
  FM_BACKEND_CMUXTUI_WORKSPACE=${target%%:*}
  FM_BACKEND_CMUXTUI_TERMINAL=${target#*:}
  [ -n "$FM_BACKEND_CMUXTUI_WORKSPACE" ] && [ -n "$FM_BACKEND_CMUXTUI_TERMINAL" ] && [ "$FM_BACKEND_CMUXTUI_TERMINAL" != "$target" ]
}

fm_backend_cmuxtui_terminal_exists() {  # <terminal_id>
  fm_backend_cmuxtui_cli terminal "$1" show --json >/dev/null 2>&1
}

fm_backend_cmuxtui_workspace_name_of_id() {  # <workspace_id>
  fm_backend_cmuxtui_cli workspace "$1" show --json 2>/dev/null \
    | jq -r '.name // empty' 2>/dev/null
}

# fm_backend_cmuxtui_target_ready: parse the target and verify it is live.
# Durable ids are the recovery authority (finding #1): the recorded pair is
# trusted while the terminal answers `terminal <id> show`. With an
# expected-label, the workspace name is verified against that plain label,
# and two narrow refresh paths run when a component has genuinely died:
#   - workspace alive but its terminal gone (the shell exited, which closes
#     the terminal id): re-resolve the workspace's current terminal.
#   - workspace id gone entirely: adopt by name ONLY through the standard
#     exactly-one duplicate guard (names are display labels, never blind
#     recovery authority), then resolve that workspace's terminal.
fm_backend_cmuxtui_target_ready() {  # <target> [expected-label]
  local expected_label=${2:-} name wsid termid
  fm_backend_cmuxtui_parse_target "$1" || return 1
  if [ -n "$expected_label" ]; then
    name=$(fm_backend_cmuxtui_workspace_name_of_id "$FM_BACKEND_CMUXTUI_WORKSPACE")
    if [ "$name" = "$expected_label" ]; then
      fm_backend_cmuxtui_terminal_exists "$FM_BACKEND_CMUXTUI_TERMINAL" && return 0
      wsid=$FM_BACKEND_CMUXTUI_WORKSPACE
    elif [ -n "$name" ]; then
      return 1
    else
      wsid=$(fm_backend_cmuxtui_workspace_id_for_label "$expected_label")
      [ -n "$wsid" ] || return 1
    fi
    termid=$(fm_backend_cmuxtui_terminal_for_workspace "$wsid")
    [ -n "$termid" ] || return 1
    FM_BACKEND_CMUXTUI_WORKSPACE=$wsid
    FM_BACKEND_CMUXTUI_TERMINAL=$termid
    return 0
  fi
  fm_backend_cmuxtui_terminal_exists "$FM_BACKEND_CMUXTUI_TERMINAL"
}

# fm_backend_cmuxtui_screen_json: one `screen read` on the CURRENT parsed
# terminal (caller has already run parse_target/target_ready), echoing the
# raw JSON ({text, cursor_row, cursor_col, cursor_visible, rows, cols}).
fm_backend_cmuxtui_screen_json() {
  fm_backend_cmuxtui_cli terminal "$FM_BACKEND_CMUXTUI_TERMINAL" screen read --json 2>/dev/null
}

# fm_backend_cmuxtui_history_text: the terminal's retained scrollback (rows
# scrolled out above the viewport) as plain text, styled runs joined and
# right-trimmed. Verified contiguous with the visible screen (the last
# history row immediately precedes the screen's first row) with next=null
# even at ~900 retained rows, so history+screen is a seamless tail.
fm_backend_cmuxtui_history_text() {
  fm_backend_cmuxtui_cli terminal "$FM_BACKEND_CMUXTUI_TERMINAL" history read --json 2>/dev/null \
    | jq -r '.rows[]? | [.runs[]?.text] | join("")' 2>/dev/null \
    | sed 's/[[:space:]]*$//'
}

# fm_backend_cmuxtui_capture: bounded plain-text capture. `screen read` is
# clamped to the live viewport, so a request larger than the visible screen
# also fetches the retained scrollback via history read and trims locally
# (the fleet's "fetch generous, trim locally" posture).
fm_backend_cmuxtui_capture() {  # <target> <lines> [expected-label]
  fm_backend_cmuxtui_target_ready "$1" "${3:-}" || return 1
  local lines=${2:-40} screen visible
  case "$lines" in ''|*[!0-9]*) lines=40 ;; esac
  screen=$(fm_backend_cmuxtui_screen_json) || return 1
  visible=$(printf '%s' "$screen" | jq -r '.text // empty' 2>/dev/null) || return 1
  if [ "$(printf '%s\n' "$visible" | wc -l | tr -d '[:space:]')" -lt "$lines" ]; then
    { fm_backend_cmuxtui_history_text; printf '%s\n' "$visible"; } | tail -n "$lines"
    return 0
  fi
  printf '%s' "$visible" | tail -n "$lines"
}

# fm_backend_cmuxtui_send_literal: send TEXT as literal, UNSUBMITTED input -
# the caller sends Enter separately. Verified (finding #2): `write --text`
# does NOT auto-submit, matching every other backend's contract exactly.
fm_backend_cmuxtui_send_literal() {  # <target> <text> [expected-label]
  fm_backend_cmuxtui_target_ready "$1" "${3:-}" || return 1
  fm_backend_cmuxtui_cli terminal "$FM_BACKEND_CMUXTUI_TERMINAL" write --text "$2" >/dev/null 2>&1
}

# fm_backend_cmuxtui_normalize_key: map firstmate's key vocabulary onto
# cmux-tui's verified lowercase `keys` chords. Verified accepted live: enter,
# escape, ctrl+c, ctrl+d, ctrl+u, tab, up, down (an invalid chord returns the
# typed validation.invalid error).
fm_backend_cmuxtui_normalize_key() {  # <key>
  case "$1" in
    Enter|enter) printf 'enter' ;;
    Escape|escape|Esc|esc) printf 'escape' ;;
    C-c|c-c|ctrl+c|Ctrl+c|Ctrl+C|ctrl-c) printf 'ctrl+c' ;;
    C-d|c-d|ctrl+d|Ctrl+d|Ctrl+D|ctrl-d) printf 'ctrl+d' ;;
    # C-u clears a composer line. fm-send.sh's muse interrupt path needs it to
    # drop the prompt muse restores into the composer after Escape.
    C-u|c-u|ctrl+u|Ctrl+u|Ctrl+U|ctrl-u) printf 'ctrl+u' ;;
    Tab) printf 'tab' ;;
    Up|up) printf 'up' ;;
    Down|down) printf 'down' ;;
    *) printf '%s' "$1" ;;
  esac
}

# fm_backend_cmuxtui_send_key: one named special key.
fm_backend_cmuxtui_send_key() {  # <target> <key> [expected-label]
  fm_backend_cmuxtui_target_ready "$1" "${3:-}" || return 1
  local key
  key=$(fm_backend_cmuxtui_normalize_key "$2")
  fm_backend_cmuxtui_cli terminal "$FM_BACKEND_CMUXTUI_TERMINAL" keys "$key" >/dev/null 2>&1
}

# fm_backend_cmuxtui_send_text_line: send one line of TEXT then submit.
# Mirrors bin/backends/cmux.sh's contract: a failed Enter clears the partial
# input with Ctrl-C and returns 1; a failed cleanup returns 2 (unsafe input).
fm_backend_cmuxtui_send_text_line() {  # <target> <text> [expected-label]
  fm_backend_cmuxtui_send_literal "$1" "$2" "${3:-}" || return 1
  fm_backend_cmuxtui_send_key "$1" Enter "${3:-}" && return 0
  fm_backend_cmuxtui_send_key "$1" C-c "${3:-}" >/dev/null 2>&1 && return 1
  return 2
}

# --- composer capture and capability primitives ------------------------------
#
# `screen read` returns the visible screen as plain text PLUS the live cursor
# position (cursor_row/cursor_col/cursor_visible), so this adapter declares
# cursor=1: the shared classifier anchors shape selection on the row the
# cursor actually occupies (tmux's own anchoring), instead of guessing the
# bottom-most shape. The capture is plain text (styled=0), so ghost text is
# unreadable and a bare glyph row carrying trailing text still degrades to
# `unknown` - the cursor primitive improves shape selection, not content
# confidence. A hidden cursor (cursor_visible=false, e.g. mid-redraw) drops
# the cursor fact for that read rather than anchoring on a stale row.

# fm_backend_cmuxtui_composer_state: thin adapter - capture plus capability
# facts in, shared verdict out (bin/fm-composer-lib.sh owns every shape).
fm_backend_cmuxtui_composer_state() {  # <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local screen text cy visible rows caps verdict
  fm_backend_cmuxtui_target_ready "$1" "${2:-}" || { printf 'unknown'; return 0; }
  screen=$(fm_backend_cmuxtui_screen_json) || { printf 'unknown'; return 0; }
  text=$(printf '%s' "$screen" | jq -r '.text // empty' 2>/dev/null)
  [ -n "$text" ] || { printf 'unknown'; return 0; }
  visible=$(printf '%s' "$screen" | jq -r '.cursor_visible' 2>/dev/null)
  cy=$(printf '%s' "$screen" | jq -r '.cursor_row // empty' 2>/dev/null)
  rows=$(printf '%s' "$screen" | jq -r '.rows // empty' 2>/dev/null)
  case "$rows" in ''|*[!0-9]*) rows=$FM_COMPOSER_CAPTURE_LINES ;; esac
  if [ "$visible" = true ] && [ -n "$cy" ]; then
    caps=$(printf 'styled=0\ncursor=1\nidentity=0\nrows=%s' "$rows")
    verdict=$(fm_composer_classify_screen "$caps" "$text" "$cy")
  else
    caps=$(printf 'styled=0\ncursor=0\nidentity=0\nrows=%s' "$rows")
    verdict=$(fm_composer_classify_screen "$caps" "$text")
  fi
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

# fm_backend_cmuxtui_send_text_submit: type <text> into <target> once (raw,
# unsubmitted, via send_literal), then drive the shared verify-and-retry-Enter
# loop (bin/fm-composer-lib.sh: fm_composer_submit_retry_core) against the
# shared composer verdict. Echoes empty|pending|unknown|send-failed, a subset
# of the proof-carrying submit vocabulary; Enter alone is retried, text is
# never retyped.
fm_backend_cmuxtui_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected_label=${6:-}
  fm_backend_cmuxtui_parse_target "$target" || { printf 'unknown'; return 0; }
  fm_backend_cmuxtui_send_literal "$target" "$text" "$expected_label" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_cmuxtui_send_key fm_backend_cmuxtui_composer_state \
    "$target" "$retries" "$sleep_s" "$expected_label"
}

# fm_backend_cmuxtui_pid_cwd: one process's live OS-level cwd -
# /proc/<pid>/cwd on Linux, `lsof -a -p <pid> -d cwd -Fn` on macOS. Empty on
# any failure (a raced-away pid is normal here).
fm_backend_cmuxtui_pid_cwd() {  # <pid>
  local pid=$1 out
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -e "/proc/$pid/cwd" ]; then
    readlink "/proc/$pid/cwd" 2>/dev/null
    return $?
  fi
  out=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | awk '/^n/ { print substr($0, 2); exit }')
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# fm_backend_cmuxtui_current_path: the live foreground cwd, or empty on any
# error (mirrors every adapter's tolerant contract for fm-spawn.sh's
# worktree-discovery poll). Structured, never screen-scraped, three sources
# in preference order:
#   1. `process show --json`'s foreground_cwd - the PTY's foreground process
#      group's live cwd, shipped in cmux-tui 0.12.0 (manaflow-ai/cmux#10704;
#      macOS proc_pidvnodepathinfo, Linux /proc/<pid>/cwd). Used whenever the
#      key is present with a non-null value; null means that daemon's own
#      lookup failed, and an ABSENT key means a pre-0.12.0 daemon - both fall
#      through to the probes below.
#   2. The child pids' OS-level cwd (fm_backend_cmuxtui_pid_cwd), newest
#      first - the pre-0.12.0 answer for a foreground subshell, because the
#      structured top-level cwd stays FROZEN when an integration-free
#      foreground subshell (the `treehouse get` case, finding #5) does its
#      own cd.
#   3. The top-level cwd field, for a childless plain shell.
# Both cwd fields are file://<host>/path URLs; scheme and host are stripped
# identically.
fm_backend_cmuxtui_current_path() {  # <target> [expected-label]
  local target=$1 expected_label=${2:-} proc fg pid p raw
  fm_backend_cmuxtui_target_ready "$target" "$expected_label" || return 0
  proc=$(fm_backend_cmuxtui_cli terminal "$FM_BACKEND_CMUXTUI_TERMINAL" process show --json 2>/dev/null) || return 0
  fg=$(printf '%s' "$proc" | jq -r 'if has("foreground_cwd") and (.foreground_cwd != null) then .foreground_cwd else empty end' 2>/dev/null)
  if [ -n "$fg" ]; then
    printf '%s' "$fg" | sed -E 's|^file://[^/]*||'
    return 0
  fi
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    p=$(fm_backend_cmuxtui_pid_cwd "$pid") || continue
    if [ -n "$p" ]; then
      printf '%s' "$p"
      return 0
    fi
  done < <(printf '%s' "$proc" | jq -r '.children // [] | reverse | .[]' 2>/dev/null)
  raw=$(printf '%s' "$proc" | jq -r '.cwd // empty' 2>/dev/null)
  [ -n "$raw" ] || return 0
  printf '%s' "$raw" | sed -E 's|^file://[^/]*||'
}

# fm_backend_cmuxtui_busy_state: semantic busy state from cmux-tui's native
# per-terminal agent record (`agent list --json`, hook-fed via
# `agent report`/`agent hook install`; finding #9). The state vocabulary is
# identical to herdr's agent_status and is mapped identically: working ->
# busy; idle/done -> idle; blocked -> idle (stuck waiting on the human, which
# the watcher should surface, not suppress as busy); no row or anything
# else -> unknown, the caller's cue to fall back to pane-regex detection.
# The newest row wins when a terminal carries more than one report.
fm_backend_cmuxtui_busy_state() {  # <target>
  local raw
  fm_backend_cmuxtui_parse_target "$1" || { printf 'unknown'; return 0; }
  raw=$(fm_backend_cmuxtui_cli agent list --json 2>/dev/null \
    | jq -r --arg t "$FM_BACKEND_CMUXTUI_TERMINAL" '
        [.[]? | select(.terminal_id == $t)]
        | sort_by(.updated_at_ms | tonumber? // 0)
        | last | .state // empty
      ' 2>/dev/null)
  case "$raw" in
    working) printf 'busy' ;;
    idle|done) printf 'idle' ;;
    blocked) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_cmuxtui_kill: close the task's whole workspace, best-effort
# (mirrors every other backend's `|| true` contract). Closing the LAST
# workspace of the session works natively (finding #4) - the session server
# keeps running with an empty tree - so there is no GUI-cmux sibling dance
# and no zellij ghost-tab sweep. With an expected label, stale ids are
# refreshed through target_ready's guarded recovery first, so the close can
# never hit a workspace id that now belongs to nothing or to a different
# live task name.
fm_backend_cmuxtui_kill() {  # <target> [unused] [expected-label]
  local expected_label=${3:-}
  if [ -n "$expected_label" ]; then
    fm_backend_cmuxtui_target_ready "$1" "$expected_label" || return 0
  else
    fm_backend_cmuxtui_parse_target "$1" || return 0
  fi
  fm_backend_cmuxtui_cli workspace "$FM_BACKEND_CMUXTUI_WORKSPACE" close >/dev/null 2>&1 || true
}

# fm_backend_cmuxtui_list_live: recovery/orphan discovery. Lists every
# workspace in the home's own session whose name carries the fm- task
# prefix, resolving each workspace's terminal through ONE snapshot read.
# The session is home-scoped, so no cross-home filtering is needed and the
# printed label is the plain workspace name. One
# "<workspace_id>:<terminal_id>\t<fm-id>" line per live task workspace.
# Read-only: an unreachable session simply lists nothing.
fm_backend_cmuxtui_list_live() {
  local snap
  snap=$(fm_backend_cmuxtui_cli session current snapshot --json 2>/dev/null) || return 0
  printf '%s' "$snap" | jq -r '
    . as $s
    | ($s.workspaces // []) | .[]
    | select((.name // "") | startswith("fm-"))
    | . as $ws
    | ([$s.screens[]? | select(.workspace_id == $ws.id) | .layout | .. | .tab_ids? // empty | .[]]) as $tabs
    | ([$s.tabs[]? | select((.id as $t | $tabs | index($t)) and .content_kind == "terminal") | .content_id] | first // empty) as $term
    | select($term != "")
    | "\($ws.id):\($term)\t\($ws.name)"
  ' 2>/dev/null
}
