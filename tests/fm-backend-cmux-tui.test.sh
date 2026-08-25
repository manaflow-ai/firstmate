#!/usr/bin/env bash
# tests/fm-backend-cmux-tui.test.sh - fake-cmux-tui-CLI unit tests for the
# cmux-tui session-provider adapter (bin/backends/cmux-tui.sh), verified
# against the real cmux-tui 0.1.0 binary
# (docs/verification/runtime-backends.md "cmux-tui"). Mirrors
# tests/fm-backend-cmux.test.sh's fakebin/command-log convention: a small,
# LOG-based, canned-response fake `cmux-tui` + real `jq` (jq is a real
# required tool for this backend, not faked). The real-binary smoke test
# lives in tests/fm-backend-cmux-tui-smoke.test.sh, gated on the cmux-tui
# binary actually being installed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the cmux-tui adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-cmux-tui-tests)

# The adapter's own env knobs must not leak in from the environment this
# suite happens to run inside (e.g. a developer shell inside cmux-tui).
unset FM_CMUXTUI_BIN FM_CMUXTUI_SESSION FM_CMUXTUI_CONFIG FM_CMUXTUI_STATE

# make_cmuxtui_fakebin: a `cmux-tui` stub that logs every invocation (one
# line, unit-separated args, prefixed with the exported CMUX_TUI_CONFIG, to
# $FM_CMUXTUI_LOG) and returns the canned response for that call read from
# $FM_CMUXTUI_RESPONSES/<n>.out, consumed IN ORDER. A missing response file
# means "succeed with empty stdout". `--version` and `server status` are
# handled specially (not call-counted, not consuming the ordered queue),
# mirroring the cmux fake's version/ping special-casing. An <n>.exit file
# sets that call's exit code, with any <n>.out still printed first (the real
# CLI prints its typed error JSON alongside a nonzero exit).
make_cmuxtui_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/cmux-tui" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_CMUXTUI_LOG:?}"
RESP="${FM_CMUXTUI_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
{
  printf 'CMUX_TUI_CONFIG=%s' "${CMUX_TUI_CONFIG:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

if [ "${1:-}" = --version ]; then
  printf 'cmux %s (4471965b12d19914793f46f96322fff5815da010; ghostty f76c132e)\n' "${FM_CMUXTUI_FAKE_VERSION:-0.1.0}"
  exit 0
fi
if [ "${1:-}" = server ] && [ "${2:-}" = status ]; then
  exit "${FM_CMUXTUI_FAKE_STATUS_EXIT:-0}"
fi

next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$next" > "$COUNT_FILE"
[ -f "$RESP/$next.out" ] && cat "$RESP/$next.out"
if [ -f "$RESP/$next.exit" ]; then
  exit "$(cat "$RESP/$next.exit")"
fi
exit 0
SH
  chmod +x "$fb/cmux-tui"
  printf '%s\n' "$fb"
}

# The typed opaque ids the real CLI returns (docs/verification "cmux-tui").
WS_A=ws_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
WS_B=ws_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
TERM_A=term_11111111111111111111111111111111
TERM_B=term_22222222222222222222222222222222
TARGET_A="$WS_A:$TERM_A"

cmuxtui_workspace_list_response() {  # <dir> <n> [<id> <name>]...
  local dir=$1 n=$2 json first=1
  shift 2
  json='['
  while [ $# -ge 2 ]; do
    [ "$first" -eq 1 ] || json="$json,"
    json="$json{\"id\":\"$1\",\"name\":\"$2\",\"focused\":false,\"index\":0}"
    first=0
    shift 2
  done
  json="$json]"
  printf '%s' "$json" > "$dir/responses/$n.out"
}

cmuxtui_workspace_show_response() {  # <dir> <n> <id> <name>
  printf '{"id":"%s","name":"%s","focused":true,"index":0}' "$3" "$4" > "$1/responses/$2.out"
}

cmuxtui_terminal_show_response() {  # <dir> <n> <term_id>
  printf '{"id":"%s","lifecycle":"running","running":true,"rows":24,"cols":80}' "$3" > "$1/responses/$2.out"
}

cmuxtui_screen_read_response() {  # <dir> <n> <text> [cursor_row] [cursor_visible]
  jq -n --arg t "$3" --argjson cy "${4:-0}" --argjson vis "${5:-true}" \
    '{text:$t, cursor_row:$cy, cursor_col:2, cursor_visible:$vis, rows:24, cols:80}' \
    > "$1/responses/$2.out"
}

cmuxtui_create_response() {  # <dir> <n> <kind> <id>
  printf '{"generation":"g1","replayed":false,"revision":"1","value":{"kind":"%s","%s_id":"%s"}}' \
    "$3" "$3" "$4" > "$1/responses/$2.out"
}

cmuxtui_snapshot_response() {  # <dir> <n> <ws_id> <ws_name> <tab_id> <term_id>
  jq -n --arg ws "$3" --arg name "$4" --arg tab "$5" --arg term "$6" '{
    workspaces: [{id:$ws, name:$name, focused:true, index:0}],
    screens: [{id:"screen_1", workspace_id:$ws, layout:{root:{kind:"leaf", tab_ids:[$tab]}}}],
    tabs: [{id:$tab, content_kind:"terminal", content_id:$term}]
  }' > "$1/responses/$2.out"
}

cmuxtui_agent_list_response() {  # <dir> <n> <term_id> <state> <updated_at_ms>
  jq -n --arg t "$3" --arg s "$4" --arg u "$5" \
    '[{id:"agent_1", terminal_id:$t, state:$s, source:"hook", updated_at_ms:$u}]' \
    > "$1/responses/$2.out"
}

cmuxtui_typed_error_response() {  # <dir> <n> <code> <retryable> <exit>
  printf '{"code":"%s","details":{},"message":"fixture error","retryable":%s}' "$3" "$4" > "$1/responses/$2.out"
  printf '%s' "$5" > "$1/responses/$2.exit"
}

# run_adapter <dir> <fakebin> <script...>: source the adapter in an isolated
# home with the fake CLI first on PATH and a pinned test session name.
run_adapter() {  # <dir> <fb> <bash -c body>
  local dir=$1 fb=$2 body=$3
  PATH="$fb:$PATH" FM_HOME="$dir" FM_CMUXTUI_SESSION=fm-tui-test-unit \
    FM_CMUXTUI_CONFIG="$dir/cmux-tui.json" FM_CMUXTUI_STATE="$dir/tui-state" \
    FM_CMUXTUI_LOG="$dir/log" FM_CMUXTUI_RESPONSES="$dir/responses" \
    bash -c ". \"\$0/bin/backends/cmux-tui.sh\"; $body" "$ROOT"
}

# --- version_check / tool_check ----------------------------------------------

test_version_check_accepts_current_version() {
  local dir fb
  dir="$TMP_ROOT/version-ok"; mkdir -p "$dir/responses"
  fb=$(make_cmuxtui_fakebin "$dir")
  FM_CMUXTUI_FAKE_VERSION=0.1.0 run_adapter "$dir" "$fb" 'fm_backend_cmuxtui_version_check' \
    || fail "version_check should accept 0.1.0 (the verified minimum)"
  pass "fm_backend_cmuxtui_version_check: accepts the verified minimum (0.1.0)"
}

test_version_check_accepts_newer_version() {
  local dir fb
  dir="$TMP_ROOT/version-newer"; mkdir -p "$dir/responses"
  fb=$(make_cmuxtui_fakebin "$dir")
  FM_CMUXTUI_FAKE_VERSION=1.3.0 run_adapter "$dir" "$fb" 'fm_backend_cmuxtui_version_check' \
    || fail "version_check should accept a newer version (1.3.0)"
  pass "fm_backend_cmuxtui_version_check: accepts a newer version (1.3.0)"
}

test_version_check_refuses_old_version() {
  local dir fb out status
  dir="$TMP_ROOT/version-old"; mkdir -p "$dir/responses"
  fb=$(make_cmuxtui_fakebin "$dir")
  out=$(FM_CMUXTUI_FAKE_VERSION=0.0.9 run_adapter "$dir" "$fb" 'fm_backend_cmuxtui_version_check' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "version_check should refuse 0.0.9 (below the 0.1 minimum)"
  assert_contains "$out" "0.0.9" "version_check error did not name the rejected version"
  pass "fm_backend_cmuxtui_version_check: refuses an old version loudly"
}

test_version_check_refuses_missing_binary() {
  local dir out status
  dir="$TMP_ROOT/version-missing"; mkdir -p "$dir/empty-fakebin"
  out=$( PATH="$dir/empty-fakebin:/usr/bin:/bin" FM_HOME="$dir" \
    bash -c '. "$0/bin/backends/cmux-tui.sh"; fm_backend_cmuxtui_version_check' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "version_check should refuse when cmux-tui is not installed"
  assert_contains "$out" "not found" "version_check did not report cmux-tui as missing"
  pass "fm_backend_cmuxtui_version_check: refuses loudly when cmux-tui is not on PATH"
}

test_bin_honors_override() {
  local dir out
  dir="$TMP_ROOT/bin-override"; mkdir -p "$dir"
  out=$( FM_CMUXTUI_BIN=/opt/custom/cmux-tui FM_HOME="$dir" \
    bash -c '. "$0/bin/backends/cmux-tui.sh"; fm_backend_cmuxtui_bin' "$ROOT" )
  [ "$out" = /opt/custom/cmux-tui ] || fail "fm_backend_cmuxtui_bin should honor FM_CMUXTUI_BIN, got '$out'"
  pass "fm_backend_cmuxtui_bin: FM_CMUXTUI_BIN overrides PATH resolution"
}

# --- session naming, config isolation ----------------------------------------

test_session_name_is_home_scoped() {
  local dir out expected
  dir="$TMP_ROOT/session-name"; mkdir -p "$dir"
  expected="fm-$(FM_HOME="$dir" FM_ROOT="$dir" bash -c '. "$0/bin/fm-backend-hometag-lib.sh"; fm_backend_hometag' "$ROOT")"
  out=$( FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
    bash -c '. "$0/bin/backends/cmux-tui.sh"; fm_backend_cmuxtui_session' "$ROOT" )
  [ "$out" = "$expected" ] || fail "default session should be $expected, got '$out'"
  case "$out" in fm-firstmate-*) : ;; *) fail "primary session should carry the firstmate hometag, got '$out'" ;; esac
  pass "fm_backend_cmuxtui_session: defaults to the home-scoped fm-<hometag> session"
}

test_session_name_override() {
  local dir out
  dir="$TMP_ROOT/session-override"; mkdir -p "$dir"
  out=$( FM_HOME="$dir" FM_CMUXTUI_SESSION=fm-tui-test-x \
    bash -c '. "$0/bin/backends/cmux-tui.sh"; fm_backend_cmuxtui_session' "$ROOT" )
  [ "$out" = fm-tui-test-x ] || fail "FM_CMUXTUI_SESSION should override the session name, got '$out'"
  pass "fm_backend_cmuxtui_session: FM_CMUXTUI_SESSION overrides for test isolation"
}

test_cli_exports_adapter_owned_config() {
  local dir fb
  dir="$TMP_ROOT/config-isolation"; mkdir -p "$dir/responses"
  fb=$(make_cmuxtui_fakebin "$dir")
  cmuxtui_workspace_list_response "$dir" 1
  run_adapter "$dir" "$fb" 'fm_backend_cmuxtui_cli workspace list --json' >/dev/null
  assert_contains "$(cat "$dir/log")" "CMUX_TUI_CONFIG=$dir/cmux-tui.json" \
    "fm_backend_cmuxtui_cli did not export the adapter-owned CMUX_TUI_CONFIG"
  [ -f "$dir/cmux-tui.json" ] || fail "the adapter-owned config file was not created"
  [ "$(cat "$dir/cmux-tui.json")" = "{}" ] || fail "the adapter-owned config should be an empty JSON object"
  assert_contains "$(cat "$dir/log")" $'\x1f''--session'$'\x1f''fm-tui-test-unit' \
    "fm_backend_cmuxtui_cli did not route through the explicit home session"
  pass "fm_backend_cmuxtui_cli: exports the adapter-owned config and the explicit --session route"
}

# --- target parsing, key normalization ----------------------------------------

test_parse_target() {
  ( . "$ROOT/bin/backends/cmux-tui.sh"
    fm_backend_cmuxtui_parse_target "$TARGET_A" || exit 1
    [ "$FM_BACKEND_CMUXTUI_WORKSPACE" = "$WS_A" ] || { echo "workspace mismatch: $FM_BACKEND_CMUXTUI_WORKSPACE" >&2; exit 1; }
    [ "$FM_BACKEND_CMUXTUI_TERMINAL" = "$TERM_A" ] || { echo "terminal mismatch: $FM_BACKEND_CMUXTUI_TERMINAL" >&2; exit 1; }
    fm_backend_cmuxtui_parse_target "no-colon-here" && exit 1
    exit 0
  ) || fail "fm_backend_cmuxtui_parse_target did not split workspace:terminal correctly"
  pass "fm_backend_cmuxtui_parse_target: splits '<workspace_id>:<terminal_id>' on the first colon"
}

test_normalize_key() {
  ( . "$ROOT/bin/backends/cmux-tui.sh"
    [ "$(fm_backend_cmuxtui_normalize_key Enter)" = enter ] || { echo "Enter failed" >&2; exit 1; }
    [ "$(fm_backend_cmuxtui_normalize_key Escape)" = escape ] || { echo "Escape failed" >&2; exit 1; }
    [ "$(fm_backend_cmuxtui_normalize_key C-c)" = ctrl+c ] || { echo "C-c failed" >&2; exit 1; }
    [ "$(fm_backend_cmuxtui_normalize_key C-d)" = ctrl+d ] || { echo "C-d failed" >&2; exit 1; }
    [ "$(fm_backend_cmuxtui_normalize_key C-u)" = ctrl+u ] || { echo "C-u failed" >&2; exit 1; }
    [ "$(fm_backend_cmuxtui_normalize_key Tab)" = tab ] || { echo "Tab failed" >&2; exit 1; }
    [ "$(fm_backend_cmuxtui_normalize_key Up)" = up ] || { echo "Up failed" >&2; exit 1; }
    [ "$(fm_backend_cmuxtui_normalize_key Down)" = down ] || { echo "Down failed" >&2; exit 1; }
  ) || fail "fm_backend_cmuxtui_normalize_key did not map firstmate's key vocabulary to cmux-tui's verified chords"
  pass "fm_backend_cmuxtui_normalize_key: Enter/Escape/C-c/C-d/C-u/Tab/Up/Down map to verified lowercase chords"
}

# --- dispatch wiring and detection (fm-backend.sh) -----------------------------

test_dispatch_routes_cmuxtui_backend() {
  fm_backend_validate cmux-tui 2>/dev/null || fail "fm_backend_validate should accept cmux-tui"
  fm_backend_validate_spawn cmux-tui 2>/dev/null || fail "fm_backend_validate_spawn should accept cmux-tui"
  [ "$(fm_backend_required_tools cmux-tui)" = "cmux-tui jq treehouse" ] \
    || fail "fm_backend_required_tools should be 'cmux-tui jq treehouse'"
  pass "fm-backend.sh: cmux-tui is known, spawn-capable, and owns its tool delta"
}

test_detect_cmuxtui_socket_marker() {
  local out
  out=$(unset TMUX HERDR_ENV CMUX_MUX_SOCKET; CMUX_TUI_SOCKET=/tmp/fake.sock fm_backend_detect) \
    || fail "fm_backend_detect should succeed when CMUX_TUI_SOCKET is set"
  [ "$out" = cmux-tui ] || fail "fm_backend_detect should report cmux-tui for CMUX_TUI_SOCKET alone, got '$out'"
  pass "fm_backend_detect: CMUX_TUI_SOCKET alone selects cmux-tui"
}

test_detect_cmuxtui_legacy_marker() {
  local out
  out=$(unset TMUX HERDR_ENV CMUX_TUI_SOCKET; CMUX_MUX_SOCKET=/tmp/fake.sock fm_backend_detect) \
    || fail "fm_backend_detect should succeed when legacy CMUX_MUX_SOCKET is set"
  [ "$out" = cmux-tui ] || fail "fm_backend_detect should report cmux-tui for legacy CMUX_MUX_SOCKET, got '$out'"
  pass "fm_backend_detect: the legacy CMUX_MUX_SOCKET alias also selects cmux-tui"
}

test_detect_inner_multiplexers_win_over_cmuxtui() {
  local out
  out=$(unset HERDR_ENV; TMUX='fake,1,0' CMUX_TUI_SOCKET=/tmp/fake.sock fm_backend_detect) \
    || fail "fm_backend_detect should succeed with tmux and cmux-tui markers present"
  [ "$out" = tmux ] || fail "tmux nested inside cmux-tui must win, got '$out'"
  out=$(unset TMUX; HERDR_ENV=1 CMUX_TUI_SOCKET=/tmp/fake.sock fm_backend_detect) \
    || fail "fm_backend_detect should succeed with herdr and cmux-tui markers present"
  [ "$out" = herdr ] || fail "herdr nested inside cmux-tui must win, got '$out'"
  pass "fm_backend_detect: tmux/herdr nested inside cmux-tui resolve innermost-first"
}

test_detect_cmuxtui_wins_over_gui_cmux_marker() {
  # A cmux-tui session started inside a cmux GUI tab inherits the GUI's
  # CMUX_WORKSPACE_ID into its terminals (verified live), so the inner
  # cmux-tui marker must win over the outer GUI app's.
  local out
  out=$(unset TMUX HERDR_ENV; CMUX_TUI_SOCKET=/tmp/fake.sock CMUX_WORKSPACE_ID=fake-uuid fm_backend_detect) \
    || fail "fm_backend_detect should succeed with cmux-tui and cmux GUI markers present"
  [ "$out" = cmux-tui ] || fail "cmux-tui inside the cmux GUI app must resolve to cmux-tui, got '$out'"
  pass "fm_backend_detect: CMUX_TUI_SOCKET wins over the inherited GUI CMUX_WORKSPACE_ID"
}

test_backend_name_notices_autodetected_cmuxtui() {
  local dir out errfile
  dir="$TMP_ROOT/name-notice"; mkdir -p "$dir/config-empty"
  errfile="$dir/stderr"
  out=$(unset TMUX HERDR_ENV; CMUX_TUI_SOCKET=/tmp/fake.sock FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$dir/config-empty" fm_backend_name 2>"$errfile")
  [ "$out" = cmux-tui ] || fail "fm_backend_name should auto-detect cmux-tui, got '$out'"
  assert_contains "$(cat "$errfile")" "EXPERIMENTAL cmux-tui backend" \
    "auto-detected cmux-tui should print the loud experimental notice"
  assert_contains "$(cat "$errfile")" "CMUX_TUI_SOCKET" \
    "the notice should name the winning signal"
  pass "fm_backend_name: auto-detected cmux-tui prints the experimental notice naming the signal"
}

test_dispatch_busy_state_routes_cmuxtui() {
  local dir fb out
  dir="$TMP_ROOT/dispatch-busy"; mkdir -p "$dir/responses"
  fb=$(make_cmuxtui_fakebin "$dir")
  cmuxtui_agent_list_response "$dir" 1 "$TERM_A" working 1000
  out=$( PATH="$fb:$PATH" FM_HOME="$dir" FM_CMUXTUI_SESSION=fm-tui-test-unit \
    FM_CMUXTUI_CONFIG="$dir/cmux-tui.json" FM_CMUXTUI_LOG="$dir/log" FM_CMUXTUI_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_busy_state cmux-tui "$1"' "$ROOT" "$TARGET_A" )
  [ "$out" = busy ] || fail "fm_backend_busy_state should route cmux-tui to its native agent read, got '$out'"
  pass "fm_backend_busy_state: routes cmux-tui to the native agent-state classifier"
}

test_endpoint_validation_accepts_and_refuses() {
  local dir meta
  dir="$TMP_ROOT/endpoint-validation"; mkdir -p "$dir"
  meta="$dir/task1.meta"
  {
    echo "window=$TARGET_A"
    echo "endpoint_task_id=task1"
    echo "worktree=/tmp/wt"
    echo "project=/tmp/proj"
    echo "backend=cmux-tui"
    echo "cmuxtui_session=fm-tui-test-unit"
    echo "cmuxtui_workspace_id=$WS_A"
    echo "cmuxtui_terminal_id=$TERM_A"
  } > "$meta"
  fm_backend_validate_task_endpoint "$meta" task1 2>/dev/null \
    || fail "endpoint validation should accept a well-formed cmux-tui record"
  [ "$FM_BACKEND_VALIDATED_BACKEND" = cmux-tui ] || fail "validated backend should be cmux-tui"
  [ "$FM_BACKEND_VALIDATED_TARGET" = "$TARGET_A" ] || fail "validated target should be the recorded window"
  meta="$dir/task2.meta"
  {
    echo "window=$WS_B:$TERM_B"
    echo "endpoint_task_id=task2"
    echo "worktree=/tmp/wt"
    echo "project=/tmp/proj"
    echo "backend=cmux-tui"
    echo "cmuxtui_session=fm-tui-test-unit"
    echo "cmuxtui_workspace_id=$WS_A"
    echo "cmuxtui_terminal_id=$TERM_A"
  } > "$meta"
  if fm_backend_validate_task_endpoint "$meta" task2 2>/dev/null; then
    fail "endpoint validation should refuse a window that disagrees with the recorded id pair"
  fi
  pass "fm_backend_validate_task_endpoint: accepts a consistent cmux-tui record and refuses a divergent one"
}

# --- create_task: duplicate refusal, id resolution, correlation keys ----------

test_create_task_refuses_duplicate_label() {
  local dir fb out status
  dir="$TMP_ROOT/dup-task"; mkdir -p "$dir/responses"
  cmuxtui_workspace_list_response "$dir" 1 "$WS_A" fm-dup1
  fb=$(make_cmuxtui_fakebin "$dir")
  out=$(run_adapter "$dir" "$fb" 'fm_backend_cmuxtui_create_task fm-dup1 /tmp/proj' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "create_task should refuse an existing workspace name (cmux-tui itself does not enforce uniqueness)"
  assert_contains "$out" "already exists" "create_task did not report the duplicate name"
  pass "fm_backend_cmuxtui_create_task: refuses a duplicate workspace name"
}

test_create_task_creates_and_parses_ids() {
  local dir fb out log
  dir="$TMP_ROOT/create-task"; mkdir -p "$dir/responses"
  cmuxtui_workspace_list_response "$dir" 1
  cmuxtui_create_response "$dir" 2 workspace "$WS_A"
  cmuxtui_create_response "$dir" 3 terminal "$TERM_A"
  fb=$(make_cmuxtui_fakebin "$dir")
  out=$(run_adapter "$dir" "$fb" 'fm_backend_cmuxtui_create_task fm-newtask /tmp/proj')
  [ "$out" = "$WS_A $TERM_A" ] || fail "create_task should echo '<workspace_id> <terminal_id>', got '$out'"
  log=$(cat "$dir/log")
  assert_contains "$log" $'\x1f''workspace'$'\x1f''create'$'\x1f''--name'$'\x1f''fm-newtask'$'\x1f''--empty' \
    "create_task did not create an empty named workspace"
  assert_contains "$log" $'\x1f''tab'$'\x1f''create'$'\x1f''terminal'$'\x1f''--workspace'$'\x1f'"$WS_A"$'\x1f''--cwd'$'\x1f''/tmp/proj' \
    "create_task did not create the terminal tab with the task cwd"
  assert_contains "$log" $'\x1f''--correlation-key'$'\x1f' \
    "create_task's mutations did not carry a correlation key"
  pass "fm_backend_cmuxtui_create_task: creates workspace+terminal and echoes both ids"
}

test_mutate_retries_indeterminate_with_same_key() {
  local dir fb out keys
  dir="$TMP_ROOT/mutate-retry"; mkdir -p "$dir/responses"
  # 1: workspace create -> typed retryable mutation.indeterminate error
  cmuxtui_typed_error_response "$dir" 1 mutation.indeterminate true 1
  # 2: the retry succeeds
  cmuxtui_create_response "$dir" 2 workspace "$WS_A"
  fb=$(make_cmuxtui_fakebin "$dir")
  out=$(run_adapter "$dir" "$fb" 'fm_backend_cmuxtui_mutate workspace create --name fm-x --empty')
  assert_contains "$out" "$WS_A" "mutate should return the retry's successful response"
  keys=$(grep -o -e $'--correlation-key\x1f[^\x1f]*' "$dir/log" | sort -u | wc -l | tr -d '[:space:]')
  [ "$keys" = 1 ] || fail "the retry must reuse the SAME correlation key (found $keys distinct keys)"
  [ "$(grep -c $'\x1f''workspace'$'\x1f''create' "$dir/log")" = 2 ] \
    || fail "mutate should have attempted the create exactly twice"
  pass "fm_backend_cmuxtui_mutate: retries a mutation.indeterminate error once with the same correlation key"
}

test_mutate_does_not_retry_terminal_errors() {
  local dir fb status
  dir="$TMP_ROOT/mutate-no-retry"; mkdir -p "$dir/responses"
  cmuxtui_typed_error_response "$dir" 1 validation.invalid false 1
  fb=$(make_cmuxtui_fakebin "$dir")
  run_adapter "$dir" "$fb" 'fm_backend_cmuxtui_mutate workspace create --name fm-x --empty' >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "mutate should propagate a non-retryable typed error"
  [ "$(grep -c $'\x1f''workspace'$'\x1f''create' "$dir/log")" = 1 ] \
    || fail "a non-retryable error must not be retried"
  pass "fm_backend_cmuxtui_mutate: a non-retryable typed error fails once, with no blind retry"
}

# --- target_ready: durable ids first, guarded label recovery ------------------

test_target_ready_fails_when_terminal_absent() {
  local dir fb status
  dir="$TMP_ROOT/ready-absent"; mkdir -p "$dir/responses"
  cmuxtui_typed_error_response "$dir" 1 selector.not_found false 1
  fb=$(make_cmuxtui_fakebin "$dir")
  run_adapter "$dir" "$fb" "fm_backend_cmuxtui_target_ready $TARGET_A"
  status=$?
  [ "$status" -ne 0 ] || fail "target_ready should fail when terminal show reports selector.not_found"
  pass "fm_backend_cmuxtui_target_ready: fails when the terminal id is gone"
}

test_target_ready_verifies_expected_label() {
  local dir fb
  dir="$TMP_ROOT/ready-label-ok"; mkdir -p "$dir/responses"
  cmuxtui_workspace_show_response "$dir" 1 "$WS_A" fm-label
  cmuxtui_terminal_show_response "$dir" 2 "$TERM_A"
  fb=$(make_cmuxtui_fakebin "$dir")
  run_adapter "$dir" "$fb" "fm_backend_cmuxtui_target_ready $TARGET_A fm-label" \
    || fail "target_ready should succeed when the workspace name matches the expected label"
  pass "fm_backend_cmuxtui_target_ready: verifies the workspace name against the expected label"
}

test_target_ready_rejects_label_mismatch() {
  local dir fb status
  dir="$TMP_ROOT/ready-label-mismatch"; mkdir -p "$dir/responses"
  cmuxtui_workspace_show_response "$dir" 1 "$WS_A" not-the-task
  fb=$(make_cmuxtui_fakebin "$dir")
  run_adapter "$dir" "$fb" "fm_backend_cmuxtui_target_ready $TARGET_A fm-label"
  status=$?
  [ "$status" -ne 0 ] || fail "target_ready should reject a workspace id now carrying a different name"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''terminal'$'\x1f' \
    "target_ready should not touch the terminal after a label mismatch"
  pass "fm_backend_cmuxtui_target_ready: rejects a workspace id reused under a different name"
}

test_target_ready_adopts_unambiguous_label_when_id_gone() {
  local dir fb out
  dir="$TMP_ROOT/ready-adopt"; mkdir -p "$dir/responses"
  # 1: workspace show for the stale id -> typed not-found (empty name)
  cmuxtui_typed_error_response "$dir" 1 selector.not_found false 1
  # 2: workspace list -> exactly one workspace carries the label
  cmuxtui_workspace_list_response "$dir" 2 "$WS_B" fm-label
  # 3: snapshot -> that workspace's terminal
  cmuxtui_snapshot_response "$dir" 3 "$WS_B" fm-label tab_1 "$TERM_B"
  fb=$(make_cmuxtui_fakebin "$dir")
  out=$(run_adapter "$dir" "$fb" "fm_backend_cmuxtui_target_ready $TARGET_A fm-label && printf '%s:%s' \"\$FM_BACKEND_CMUXTUI_WORKSPACE\" \"\$FM_BACKEND_CMUXTUI_TERMINAL\"")
  [ "$out" = "$WS_B:$TERM_B" ] || fail "target_ready should adopt the unambiguous live label's ids, got '$out'"
  pass "fm_backend_cmuxtui_target_ready: adopts by name only when exactly one live workspace carries the label"
}

test_target_ready_refuses_ambiguous_label() {
  local dir fb status
  dir="$TMP_ROOT/ready-ambiguous"; mkdir -p "$dir/responses"
  cmuxtui_typed_error_response "$dir" 1 selector.not_found false 1
  cmuxtui_workspace_list_response "$dir" 2 "$WS_B" fm-label ws_cccccccccccccccccccccccccccccccc fm-label
  fb=$(make_cmuxtui_fakebin "$dir")
  run_adapter "$dir" "$fb" "fm_backend_cmuxtui_target_ready $TARGET_A fm-label"
  status=$?
  [ "$status" -ne 0 ] || fail "target_ready must refuse adoption when two live workspaces share the label"
  pass "fm_backend_cmuxtui_target_ready: refuses label adoption when the name is ambiguous"
}

# --- capture / send primitives -------------------------------------------------

test_capture_trims_screen_locally() {
  local dir fb out
  dir="$TMP_ROOT/capture"; mkdir -p "$dir/responses"
  cmuxtui_terminal_show_response "$dir" 1 "$TERM_A"
  cmuxtui_screen_read_response "$dir" 2 $'line one\nline two\nline three\nline four'
  fb=$(make_cmuxtui_fakebin "$dir")
  out=$(run_adapter "$dir" "$fb" "fm_backend_cmuxtui_capture $TARGET_A 2")
  [ "$out" = $'line three\nline four' ] || fail "capture should trim to the last N lines locally, got '$out'"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''history' \
    "a request smaller than the visible screen should not fetch history"
  pass "fm_backend_cmuxtui_capture: trims the visible screen to N lines locally"
}

test_capture_appends_history_for_large_requests() {
  local dir fb out
  dir="$TMP_ROOT/capture-history"; mkdir -p "$dir/responses"
  cmuxtui_terminal_show_response "$dir" 1 "$TERM_A"
  cmuxtui_screen_read_response "$dir" 2 $'screen one\nscreen two'
  jq -n '{next: null, rows: [
    {row:0, runs:[{attrs:0, text:"hist one   "}]},
    {row:1, runs:[{attrs:0, text:"hist "},{attrs:1, text:"two"}]}
  ]}' > "$dir/responses/3.out"
  fb=$(make_cmuxtui_fakebin "$dir")
  out=$(run_adapter "$dir" "$fb" "fm_backend_cmuxtui_capture $TARGET_A 3")
  [ "$out" = $'hist two\nscreen one\nscreen two' ] \
    || fail "capture should prepend right-trimmed history rows before the screen, got '$out'"
  pass "fm_backend_cmuxtui_capture: appends contiguous scrollback for a larger-than-viewport request"
}

test_capture_fails_when_target_not_ready() {
  local dir fb status
  dir="$TMP_ROOT/capture-not-ready"; mkdir -p "$dir/responses"
  cmuxtui_typed_error_response "$dir" 1 selector.not_found false 1
  fb=$(make_cmuxtui_fakebin "$dir")
  run_adapter "$dir" "$fb" "fm_backend_cmuxtui_capture $TARGET_A 5"
  status=$?
  [ "$status" -ne 0 ] || fail "capture should fail when the target terminal is absent"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''screen'$'\x1f''read' \
    "capture should not read after readiness fails"
  pass "fm_backend_cmuxtui_capture: fails when the target terminal is absent"
}

test_send_literal_does_not_submit() {
  local dir fb log
  dir="$TMP_ROOT/sendliteral"; mkdir -p "$dir/responses"
  cmuxtui_terminal_show_response "$dir" 1 "$TERM_A"
  fb=$(make_cmuxtui_fakebin "$dir")
  run_adapter "$dir" "$fb" "fm_backend_cmuxtui_send_literal $TARGET_A '--help'" \
    || fail "send_literal should succeed"
  log=$(cat "$dir/log")
  assert_contains "$log" $'\x1f''terminal'$'\x1f'"$TERM_A"$'\x1f''write'$'\x1f''--text'$'\x1f''--help' \
    "send_literal did not pass the text through write --text"
  assert_not_contains "$log" $'\x1f''keys' "send_literal must never submit"
  pass "fm_backend_cmuxtui_send_literal: writes unsubmitted text, option-shaped payloads included"
}

test_send_key_normalizes_and_targets() {
  local dir fb
  dir="$TMP_ROOT/sendkey"; mkdir -p "$dir/responses"
  cmuxtui_terminal_show_response "$dir" 1 "$TERM_A"
  fb=$(make_cmuxtui_fakebin "$dir")
  run_adapter "$dir" "$fb" "fm_backend_cmuxtui_send_key $TARGET_A Escape" \
    || fail "send_key should succeed"
  assert_contains "$(cat "$dir/log")" $'\x1f''terminal'$'\x1f'"$TERM_A"$'\x1f''keys'$'\x1f''escape' \
    "send_key did not normalize Escape to escape against the explicit terminal"
  pass "fm_backend_cmuxtui_send_key: normalizes the key and targets the explicit terminal id"
}

test_send_text_line_clears_partial_input_when_enter_fails() {
  local dir fb status log
  dir="$TMP_ROOT/sendline-enter-failure"; mkdir -p "$dir/responses"
  # 1: terminal show (literal), 2: write, 3: terminal show (Enter), 4: keys enter FAILS,
  # 5: terminal show (C-c cleanup), 6: keys ctrl+c
  cmuxtui_terminal_show_response "$dir" 1 "$TERM_A"
  cmuxtui_terminal_show_response "$dir" 3 "$TERM_A"
  cmuxtui_typed_error_response "$dir" 4 mutation.indeterminate false 1
  cmuxtui_terminal_show_response "$dir" 5 "$TERM_A"
  fb=$(make_cmuxtui_fakebin "$dir")
  run_adapter "$dir" "$fb" "fm_backend_cmuxtui_send_text_line $TARGET_A 'export TRACEPARENT=carrier'"
  status=$?
  [ "$status" -ne 0 ] || fail "send_text_line should report a failed Enter"
  log=$(cat "$dir/log")
  assert_contains "$log" $'\x1f''keys'$'\x1f''ctrl+c' \
    "send_text_line did not clear the partial input after Enter failed"
  pass "fm_backend_cmuxtui_send_text_line: clears partial input when Enter fails"
}

test_send_text_line_reports_unsafe_input_when_cleanup_fails() {
  local dir fb status
  dir="$TMP_ROOT/sendline-cleanup-failure"; mkdir -p "$dir/responses"
  cmuxtui_terminal_show_response "$dir" 1 "$TERM_A"
  cmuxtui_terminal_show_response "$dir" 3 "$TERM_A"
  cmuxtui_typed_error_response "$dir" 4 mutation.indeterminate false 1
  cmuxtui_terminal_show_response "$dir" 5 "$TERM_A"
  cmuxtui_typed_error_response "$dir" 6 mutation.indeterminate false 1
  fb=$(make_cmuxtui_fakebin "$dir")
  run_adapter "$dir" "$fb" "fm_backend_cmuxtui_send_text_line $TARGET_A 'export TRACEPARENT=carrier'"
  status=$?
  expect_code 2 "$status" "send_text_line should distinguish uncleared input"
  pass "fm_backend_cmuxtui_send_text_line: reports unsafe input when cleanup also fails"
}

# --- composer_state: cursor-anchored shared classification --------------------

test_composer_state_bare_prompt_is_empty() {
  local dir fb out
  dir="$TMP_ROOT/composer-bare"; mkdir -p "$dir/responses"
  cmuxtui_terminal_show_response "$dir" 1 "$TERM_A"
  cmuxtui_screen_read_response "$dir" 2 $'transcript line\n❯' 1
  fb=$(make_cmuxtui_fakebin "$dir")
  out=$(run_adapter "$dir" "$fb" "fm_backend_cmuxtui_composer_state $TARGET_A")
  [ "$out" = empty ] || fail "a bare '❯' row under the cursor should read empty, got '$out'"
  pass "fm_backend_cmuxtui_composer_state: a bare '❯' row under the cursor reads empty"
}

test_composer_state_bordered_text_is_pending() {
  local dir fb out
  dir="$TMP_ROOT/composer-pending"; mkdir -p "$dir/responses"
  cmuxtui_terminal_show_response "$dir" 1 "$TERM_A"
  cmuxtui_screen_read_response "$dir" 2 $'  ╭────────────────────────╮\n  │ ❯ hello captain        │\n  ╰──────── Composer ──────╯\n\n  Enter:send' 1
  fb=$(make_cmuxtui_fakebin "$dir")
  out=$(run_adapter "$dir" "$fb" "fm_backend_cmuxtui_composer_state $TARGET_A")
  [ "$out" = pending ] || fail "real bordered composer text should read pending, got '$out'"
  pass "fm_backend_cmuxtui_composer_state: cursor-anchored bordered text reads pending"
}

test_composer_state_bare_glyph_text_degrades_unknown() {
  # styled=0: plain capture cannot tell typed input from the harness's own
  # idle suggestion after a bare glyph, so the shared classifier degrades to
  # unknown, never a false pending.
  local dir fb out
  dir="$TMP_ROOT/composer-unknown"; mkdir -p "$dir/responses"
  cmuxtui_terminal_show_response "$dir" 1 "$TERM_A"
  cmuxtui_screen_read_response "$dir" 2 $'transcript line\n❯ retain this message' 1
  fb=$(make_cmuxtui_fakebin "$dir")
  out=$(run_adapter "$dir" "$fb" "fm_backend_cmuxtui_composer_state $TARGET_A")
  [ "$out" = unknown ] || fail "plain-capture text after a bare glyph must degrade to unknown, got '$out'"
  pass "fm_backend_cmuxtui_composer_state: plain-capture bare-glyph text degrades to unknown"
}

test_composer_state_blank_cursor_row_is_unknown() {
  local dir fb out
  dir="$TMP_ROOT/composer-blank-row"; mkdir -p "$dir/responses"
  cmuxtui_terminal_show_response "$dir" 1 "$TERM_A"
  cmuxtui_screen_read_response "$dir" 2 $'transcript line\n\nplain-shell$ output' 1
  fb=$(make_cmuxtui_fakebin "$dir")
  out=$(run_adapter "$dir" "$fb" "fm_backend_cmuxtui_composer_state $TARGET_A")
  [ "$out" = unknown ] || fail "a blank cursor row with no container proof must stay unknown, got '$out'"
  pass "fm_backend_cmuxtui_composer_state: the strict blank-row rule holds under the cursor"
}

test_composer_state_hidden_cursor_falls_back_cursorless() {
  local dir fb out
  dir="$TMP_ROOT/composer-hidden-cursor"; mkdir -p "$dir/responses"
  cmuxtui_terminal_show_response "$dir" 1 "$TERM_A"
  # cursor_visible=false with a stale cursor_row pointing at the transcript;
  # the bottom-most shape (the bare glyph) must still win.
  cmuxtui_screen_read_response "$dir" 2 $'transcript line\n❯' 0 false
  fb=$(make_cmuxtui_fakebin "$dir")
  out=$(run_adapter "$dir" "$fb" "fm_backend_cmuxtui_composer_state $TARGET_A")
  [ "$out" = empty ] || fail "a hidden cursor should fall back to cursorless bottom-most selection, got '$out'"
  pass "fm_backend_cmuxtui_composer_state: a hidden cursor drops the cursor fact instead of anchoring stale"
}

test_composer_state_unknown_on_capture_failure() {
  local dir fb out status
  dir="$TMP_ROOT/composer-capture-fail"; mkdir -p "$dir/responses"
  cmuxtui_typed_error_response "$dir" 1 selector.not_found false 1
  fb=$(make_cmuxtui_fakebin "$dir")
  out=$(run_adapter "$dir" "$fb" "fm_backend_cmuxtui_composer_state $TARGET_A")
  status=$?
  [ "$status" -eq 0 ] || fail "composer_state should not itself fail the caller"
  [ "$out" = unknown ] || fail "an unreadable terminal should read as unknown, got '$out'"
  pass "fm_backend_cmuxtui_composer_state: reports unknown when the terminal cannot be captured"
}

# --- send_text_submit: shared verify-and-retry-Enter --------------------------

test_send_text_submit_detects_landed_send() {
  local dir fb out enter_count
  dir="$TMP_ROOT/submit-ok"; mkdir -p "$dir/responses"
  # 1: terminal show (literal), 2: write, 3: terminal show (Enter), 4: keys enter,
  # 5: terminal show (composer capture), 6: screen read -> empty composer
  cmuxtui_terminal_show_response "$dir" 1 "$TERM_A"
  cmuxtui_terminal_show_response "$dir" 3 "$TERM_A"
  cmuxtui_terminal_show_response "$dir" 5 "$TERM_A"
  cmuxtui_screen_read_response "$dir" 6 $'transcript line\n❯' 1
  fb=$(make_cmuxtui_fakebin "$dir")
  out=$(run_adapter "$dir" "$fb" "fm_backend_cmuxtui_send_text_submit $TARGET_A 'hello captain' 3 0.01 0.01")
  [ "$out" = empty ] || fail "send_text_submit should report empty once the composer clears, got '$out'"
  enter_count=$(grep -c $'\x1f''keys'$'\x1f''enter' "$dir/log")
  [ "$enter_count" -eq 1 ] || fail "a landed plain send needs exactly one Enter, sent $enter_count"
  pass "fm_backend_cmuxtui_send_text_submit: reports 'empty' once the composer reads empty after one Enter"
}

test_send_text_submit_detects_swallowed_enter() {
  local dir fb out
  dir="$TMP_ROOT/submit-swallow"; mkdir -p "$dir/responses"
  cmuxtui_terminal_show_response "$dir" 1 "$TERM_A"
  cmuxtui_terminal_show_response "$dir" 3 "$TERM_A"
  cmuxtui_terminal_show_response "$dir" 5 "$TERM_A"
  cmuxtui_screen_read_response "$dir" 6 $'  ╭───────────────────╮\n  │ ❯ hello captain   │\n  ╰───────────────────╯' 1
  cmuxtui_terminal_show_response "$dir" 7 "$TERM_A"
  cmuxtui_terminal_show_response "$dir" 9 "$TERM_A"
  cmuxtui_screen_read_response "$dir" 10 $'  ╭───────────────────╮\n  │ ❯ hello captain   │\n  ╰───────────────────╯' 1
  fb=$(make_cmuxtui_fakebin "$dir")
  out=$(run_adapter "$dir" "$fb" "fm_backend_cmuxtui_send_text_submit $TARGET_A 'hello captain' 2 0.01 0.01")
  [ "$out" = pending ] || fail "send_text_submit should report pending after exhausted Enter retries, got '$out'"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''write'$'\x1f''--text'$'\x1f''hello captain'$'\x1f''--text' \
    "send_text_submit must never retype"
  [ "$(grep -c $'\x1f''write' "$dir/log")" = 1 ] || fail "the text must be typed exactly once"
  pass "fm_backend_cmuxtui_send_text_submit: reports 'pending' on a swallowed Enter and never retypes"
}

test_send_text_submit_send_failed_when_target_absent() {
  local dir fb out
  dir="$TMP_ROOT/submit-no-target"; mkdir -p "$dir/responses"
  cmuxtui_typed_error_response "$dir" 1 selector.not_found false 1
  fb=$(make_cmuxtui_fakebin "$dir")
  out=$(run_adapter "$dir" "$fb" "fm_backend_cmuxtui_send_text_submit $TARGET_A x 2 0.01 0.01")
  [ "$out" = send-failed ] || fail "send_text_submit should report send-failed when the target is absent, got '$out'"
  pass "fm_backend_cmuxtui_send_text_submit: reports 'send-failed' when the target terminal is absent"
}

# --- current_path: structured cwd, child-pid subshell fallback ----------------

test_current_path_prefers_child_pid_cwd() {
  local dir fb out
  dir="$TMP_ROOT/cwd-child"; mkdir -p "$dir/responses"
  cmuxtui_terminal_show_response "$dir" 1 "$TERM_A"
  printf '{"argv":["/bin/zsh"],"children":[4242],"cwd":"file://somehost/frozen/launch/dir","executable":"/bin/zsh","pid":100}' \
    > "$dir/responses/2.out"
  fb=$(make_cmuxtui_fakebin "$dir")
  # Fake lsof: the macOS child-pid cwd read (this suite runs where /proc is absent).
  cat > "$fb/lsof" <<'SH'
#!/usr/bin/env bash
printf 'p4242\nfcwd\nn/live/subshell/worktree\n'
SH
  chmod +x "$fb/lsof"
  out=$(run_adapter "$dir" "$fb" "fm_backend_cmuxtui_current_path $TARGET_A")
  [ "$out" = /live/subshell/worktree ] \
    || fail "current_path should prefer the foreground child pid's OS-level cwd, got '$out'"
  pass "fm_backend_cmuxtui_current_path: a foreground subshell's cwd comes from the child pid, not the frozen field"
}

test_current_path_falls_back_to_structured_cwd() {
  local dir fb out
  dir="$TMP_ROOT/cwd-top"; mkdir -p "$dir/responses"
  cmuxtui_terminal_show_response "$dir" 1 "$TERM_A"
  printf '{"argv":["/bin/zsh"],"children":[],"cwd":"file://somehost/private/tmp/proj","executable":"/bin/zsh","pid":100}' \
    > "$dir/responses/2.out"
  fb=$(make_cmuxtui_fakebin "$dir")
  out=$(run_adapter "$dir" "$fb" "fm_backend_cmuxtui_current_path $TARGET_A")
  [ "$out" = /private/tmp/proj ] \
    || fail "current_path should strip the file://<host> prefix from the structured cwd, got '$out'"
  pass "fm_backend_cmuxtui_current_path: a childless shell uses the structured cwd with scheme and host stripped"
}

test_current_path_prefers_native_foreground_cwd() {
  # cmux-tui >= 0.12.0 (manaflow-ai/cmux#10704): a present, non-null
  # foreground_cwd is the PTY's foreground process group's live cwd and wins
  # outright - the child-pid probe must not run even when children exist.
  local dir fb out
  dir="$TMP_ROOT/cwd-foreground"; mkdir -p "$dir/responses"
  cmuxtui_terminal_show_response "$dir" 1 "$TERM_A"
  printf '{"argv":["/bin/zsh"],"children":[4242],"cwd":"file://somehost/frozen/launch/dir","foreground_cwd":"file://somehost/native/foreground/worktree","executable":"/bin/zsh","pid":100}' \
    > "$dir/responses/2.out"
  fb=$(make_cmuxtui_fakebin "$dir")
  # A booby-trapped lsof: reaching the child-pid probe despite a usable
  # native field is the regression this case pins against.
  cat > "$fb/lsof" <<'SH'
#!/usr/bin/env bash
printf 'p4242\nfcwd\nn/wrong/probe/answer\n'
SH
  chmod +x "$fb/lsof"
  out=$(run_adapter "$dir" "$fb" "fm_backend_cmuxtui_current_path $TARGET_A")
  [ "$out" = /native/foreground/worktree ] \
    || fail "current_path should prefer a present non-null foreground_cwd, scheme and host stripped, got '$out'"
  pass "fm_backend_cmuxtui_current_path: a present non-null foreground_cwd wins, with the file://<host> prefix stripped"
}

test_current_path_null_foreground_cwd_falls_back() {
  # A present-but-null foreground_cwd means that daemon's own lookup failed;
  # the child-pid probe must still answer.
  local dir fb out
  dir="$TMP_ROOT/cwd-foreground-null"; mkdir -p "$dir/responses"
  cmuxtui_terminal_show_response "$dir" 1 "$TERM_A"
  printf '{"argv":["/bin/zsh"],"children":[4242],"cwd":"file://somehost/frozen/launch/dir","foreground_cwd":null,"executable":"/bin/zsh","pid":100}' \
    > "$dir/responses/2.out"
  fb=$(make_cmuxtui_fakebin "$dir")
  cat > "$fb/lsof" <<'SH'
#!/usr/bin/env bash
printf 'p4242\nfcwd\nn/live/subshell/worktree\n'
SH
  chmod +x "$fb/lsof"
  out=$(run_adapter "$dir" "$fb" "fm_backend_cmuxtui_current_path $TARGET_A")
  [ "$out" = /live/subshell/worktree ] \
    || fail "a null foreground_cwd should fall back to the child-pid probe, got '$out'"
  pass "fm_backend_cmuxtui_current_path: a null foreground_cwd falls back to the child-pid probe"
}

test_current_path_absent_foreground_cwd_falls_back() {
  # An absent key is a pre-0.12.0 daemon; the child-pid probe must answer
  # exactly as before the field existed.
  local dir fb out
  dir="$TMP_ROOT/cwd-foreground-absent"; mkdir -p "$dir/responses"
  cmuxtui_terminal_show_response "$dir" 1 "$TERM_A"
  printf '{"argv":["/bin/zsh"],"children":[4242],"cwd":"file://somehost/frozen/launch/dir","executable":"/bin/zsh","pid":100}' \
    > "$dir/responses/2.out"
  fb=$(make_cmuxtui_fakebin "$dir")
  cat > "$fb/lsof" <<'SH'
#!/usr/bin/env bash
printf 'p4242\nfcwd\nn/live/subshell/worktree\n'
SH
  chmod +x "$fb/lsof"
  out=$(run_adapter "$dir" "$fb" "fm_backend_cmuxtui_current_path $TARGET_A")
  [ "$out" = /live/subshell/worktree ] \
    || fail "an absent foreground_cwd (old daemon) should fall back to the child-pid probe, got '$out'"
  pass "fm_backend_cmuxtui_current_path: an absent foreground_cwd (pre-0.12.0 daemon) falls back to the child-pid probe"
}

test_current_path_empty_when_target_gone() {
  local dir fb out
  dir="$TMP_ROOT/cwd-gone"; mkdir -p "$dir/responses"
  cmuxtui_typed_error_response "$dir" 1 selector.not_found false 1
  fb=$(make_cmuxtui_fakebin "$dir")
  out=$(run_adapter "$dir" "$fb" "fm_backend_cmuxtui_current_path $TARGET_A")
  [ -z "$out" ] || fail "current_path should print nothing for a dead target, got '$out'"
  pass "fm_backend_cmuxtui_current_path: prints nothing (never fails) for a dead target"
}

# --- busy_state: native hook-fed agent record ---------------------------------

test_busy_state_maps_agent_states() {
  local dir fb out state expected
  for state in working idle 'done' blocked; do
    case "$state" in
      working) expected=busy ;;
      *) expected=idle ;;
    esac
    dir="$TMP_ROOT/busy-$state"; mkdir -p "$dir/responses"
    cmuxtui_agent_list_response "$dir" 1 "$TERM_A" "$state" 1000
    fb=$(make_cmuxtui_fakebin "$dir")
    out=$(run_adapter "$dir" "$fb" "fm_backend_cmuxtui_busy_state $TARGET_A")
    [ "$out" = "$expected" ] || fail "agent state '$state' should map to '$expected', got '$out'"
  done
  pass "fm_backend_cmuxtui_busy_state: working->busy, idle/done/blocked->idle (herdr's mapping)"
}

test_busy_state_unknown_without_agent_row() {
  local dir fb out
  dir="$TMP_ROOT/busy-none"; mkdir -p "$dir/responses"
  printf '[]' > "$dir/responses/1.out"
  fb=$(make_cmuxtui_fakebin "$dir")
  out=$(run_adapter "$dir" "$fb" "fm_backend_cmuxtui_busy_state $TARGET_A")
  [ "$out" = unknown ] || fail "no agent row should read unknown, got '$out'"
  pass "fm_backend_cmuxtui_busy_state: no hook-fed row reads unknown (pane-regex fallback cue)"
}

test_busy_state_newest_row_wins() {
  local dir fb out
  dir="$TMP_ROOT/busy-newest"; mkdir -p "$dir/responses"
  jq -n --arg t "$TERM_A" '[
    {id:"agent_1", terminal_id:$t, state:"working", source:"hook", updated_at_ms:"1000"},
    {id:"agent_2", terminal_id:$t, state:"idle", source:"hook", updated_at_ms:"2000"}
  ]' > "$dir/responses/1.out"
  fb=$(make_cmuxtui_fakebin "$dir")
  out=$(run_adapter "$dir" "$fb" "fm_backend_cmuxtui_busy_state $TARGET_A")
  [ "$out" = idle ] || fail "the newest agent row should win, got '$out'"
  pass "fm_backend_cmuxtui_busy_state: the newest updated_at_ms row wins"
}

# --- kill / list_live ----------------------------------------------------------

test_kill_closes_workspace() {
  local dir fb
  dir="$TMP_ROOT/kill"; mkdir -p "$dir/responses"
  fb=$(make_cmuxtui_fakebin "$dir")
  run_adapter "$dir" "$fb" "fm_backend_cmuxtui_kill $TARGET_A" \
    || fail "kill must stay best-effort"
  assert_contains "$(cat "$dir/log")" $'\x1f''workspace'$'\x1f'"$WS_A"$'\x1f''close' \
    "kill did not close the task workspace"
  pass "fm_backend_cmuxtui_kill: closes the task's whole workspace"
}

test_kill_is_best_effort_when_close_fails() {
  local dir fb
  dir="$TMP_ROOT/kill-fail"; mkdir -p "$dir/responses"
  cmuxtui_typed_error_response "$dir" 1 selector.not_found false 1
  fb=$(make_cmuxtui_fakebin "$dir")
  run_adapter "$dir" "$fb" "fm_backend_cmuxtui_kill $TARGET_A" \
    || fail "kill must never fail, even when close-workspace fails"
  pass "fm_backend_cmuxtui_kill: never fails even when the close fails"
}

test_kill_recovers_stale_target_by_label() {
  local dir fb log
  dir="$TMP_ROOT/kill-stale"; mkdir -p "$dir/responses"
  # target_ready label recovery: 1 workspace show (stale id gone), 2 workspace
  # list (unambiguous label), 3 snapshot (terminal), then 4 close on the
  # REFRESHED workspace id.
  cmuxtui_typed_error_response "$dir" 1 selector.not_found false 1
  cmuxtui_workspace_list_response "$dir" 2 "$WS_B" fm-label
  cmuxtui_snapshot_response "$dir" 3 "$WS_B" fm-label tab_1 "$TERM_B"
  fb=$(make_cmuxtui_fakebin "$dir")
  run_adapter "$dir" "$fb" "fm_backend_cmuxtui_kill $TARGET_A '' fm-label" \
    || fail "kill should recover a stale target when the expected label is live"
  log=$(cat "$dir/log")
  assert_contains "$log" $'\x1f''workspace'$'\x1f'"$WS_B"$'\x1f''close' \
    "kill did not close the refreshed workspace id"
  assert_not_contains "$log" $'\x1f''workspace'$'\x1f'"$WS_A"$'\x1f''close' \
    "kill must not close the stale workspace id after label recovery"
  pass "fm_backend_cmuxtui_kill: recovers a stale workspace id through the guarded label path"
}

test_list_live_filters_fm_workspaces() {
  local dir fb out
  dir="$TMP_ROOT/list-live"; mkdir -p "$dir/responses"
  jq -n --arg ws "$WS_A" --arg term "$TERM_A" '{
    workspaces: [
      {id:$ws, name:"fm-task1", focused:false, index:0},
      {id:"ws_dddddddddddddddddddddddddddddddd", name:"scratch", focused:true, index:1}
    ],
    screens: [
      {id:"screen_1", workspace_id:$ws, layout:{root:{kind:"leaf", tab_ids:["tab_1"]}}},
      {id:"screen_2", workspace_id:"ws_dddddddddddddddddddddddddddddddd", layout:{root:{kind:"leaf", tab_ids:["tab_2"]}}}
    ],
    tabs: [
      {id:"tab_1", content_kind:"terminal", content_id:$term},
      {id:"tab_2", content_kind:"terminal", content_id:"term_33333333333333333333333333333333"}
    ]
  }' > "$dir/responses/1.out"
  fb=$(make_cmuxtui_fakebin "$dir")
  out=$(run_adapter "$dir" "$fb" 'fm_backend_cmuxtui_list_live')
  [ "$out" = "$WS_A:$TERM_A"$'\t''fm-task1' ] \
    || fail "list_live should list only fm- task workspaces with their terminal ids, got '$out'"
  pass "fm_backend_cmuxtui_list_live: lists only fm- task workspaces from one snapshot read"
}

# --- fm-spawn.sh: --secondmate refuses backend=cmux-tui -----------------------

test_secondmate_spawn_refuses_cmuxtui_backend() {
  local dir state data config projects out status
  dir="$TMP_ROOT/secondmate-refuse"; state="$dir/state"; data="$dir/data"; config="$dir/config"; projects="$dir/projects"
  mkdir -p "$state" "$data" "$config" "$projects"
  out=$( FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" FM_PROJECTS_OVERRIDE="$projects" \
    "$ROOT/bin/fm-spawn.sh" sm-cmuxtui-test --secondmate --backend cmux-tui 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-spawn.sh should refuse a --secondmate spawn with --backend cmux-tui"
  assert_contains "$out" "does not support --secondmate" "fm-spawn.sh did not report the cmux-tui secondmate refusal"
  pass "fm-spawn.sh: refuses backend=cmux-tui for --secondmate spawns (no secondmate launch design yet)"
}

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

test_version_check_accepts_current_version
test_version_check_accepts_newer_version
test_version_check_refuses_old_version
test_version_check_refuses_missing_binary
test_bin_honors_override
test_session_name_is_home_scoped
test_session_name_override
test_cli_exports_adapter_owned_config
test_parse_target
test_normalize_key
test_dispatch_routes_cmuxtui_backend
test_detect_cmuxtui_socket_marker
test_detect_cmuxtui_legacy_marker
test_detect_inner_multiplexers_win_over_cmuxtui
test_detect_cmuxtui_wins_over_gui_cmux_marker
test_backend_name_notices_autodetected_cmuxtui
test_dispatch_busy_state_routes_cmuxtui
test_endpoint_validation_accepts_and_refuses
test_create_task_refuses_duplicate_label
test_create_task_creates_and_parses_ids
test_mutate_retries_indeterminate_with_same_key
test_mutate_does_not_retry_terminal_errors
test_target_ready_fails_when_terminal_absent
test_target_ready_verifies_expected_label
test_target_ready_rejects_label_mismatch
test_target_ready_adopts_unambiguous_label_when_id_gone
test_target_ready_refuses_ambiguous_label
test_capture_trims_screen_locally
test_capture_appends_history_for_large_requests
test_capture_fails_when_target_not_ready
test_send_literal_does_not_submit
test_send_key_normalizes_and_targets
test_send_text_line_clears_partial_input_when_enter_fails
test_send_text_line_reports_unsafe_input_when_cleanup_fails
test_composer_state_bare_prompt_is_empty
test_composer_state_bordered_text_is_pending
test_composer_state_bare_glyph_text_degrades_unknown
test_composer_state_blank_cursor_row_is_unknown
test_composer_state_hidden_cursor_falls_back_cursorless
test_composer_state_unknown_on_capture_failure
test_send_text_submit_detects_landed_send
test_send_text_submit_detects_swallowed_enter
test_send_text_submit_send_failed_when_target_absent
test_current_path_prefers_child_pid_cwd
test_current_path_falls_back_to_structured_cwd
test_current_path_prefers_native_foreground_cwd
test_current_path_null_foreground_cwd_falls_back
test_current_path_absent_foreground_cwd_falls_back
test_current_path_empty_when_target_gone
test_busy_state_maps_agent_states
test_busy_state_unknown_without_agent_row
test_busy_state_newest_row_wins
test_kill_closes_workspace
test_kill_is_best_effort_when_close_fails
test_kill_recovers_stale_target_by_label
test_list_live_filters_fm_workspaces
test_secondmate_spawn_refuses_cmuxtui_backend
