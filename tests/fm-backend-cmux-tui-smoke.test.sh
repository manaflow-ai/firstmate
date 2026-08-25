#!/usr/bin/env bash
# tests/fm-backend-cmux-tui-smoke.test.sh - real cmux-tui smoke test for the
# cmux-tui session-provider adapter (bin/backends/cmux-tui.sh), verified
# against the real 0.1.0 binary (docs/verification/runtime-backends.md
# "cmux-tui"). Mirrors tests/fm-backend-cmux-smoke.test.sh's structure: the
# unit suite fakes the CLI, this one talks to the REAL binary.
#
# Isolation posture (the tests/cmux-test-safety.sh discipline, made stronger
# by cmux-tui's real session layer): everything runs inside ONE throwaway
# per-run session (FM_CMUXTUI_SESSION=fm-tui-test-<nonce>) with its own
# scratch --state dir and adapter-owned CMUX_TUI_CONFIG, so no call can ever
# reach an operator session (including the default "main" session). Task
# labels are fm-test- prefixed, cleanup closes only what this test created,
# and teardown stops the throwaway session it started and removes its
# scratch state. Nothing here enumerates-and-closes a shared namespace.
#
# Skips cleanly when cmux-tui (or jq) is not installed, so CI/dev machines
# without the binary are unaffected.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the cmux-tui adapter)"; exit 0; }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-cmux-tui-smoke.XXXXXX")
export FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME"
export FM_CMUXTUI_SESSION="fm-tui-test-$$-$RANDOM"
export FM_CMUXTUI_STATE="$TMP_ROOT/tui-state"
export FM_CMUXTUI_CONFIG="$TMP_ROOT/cmux-tui.json"
unset FM_CMUXTUI_BIN

SESSION_STARTED=0
cleanup_all() {
  if [ "$SESSION_STARTED" -eq 1 ]; then
    fm_backend_cmuxtui_cli server stop --session "$FM_CMUXTUI_SESSION" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT"
}
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
trap cleanup_all EXIT

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source cmux-tui || { echo "skip: could not source the cmux-tui adapter"; exit 0; }

fm_backend_cmuxtui_tool_check >/dev/null 2>&1 || { echo "skip: cmux-tui CLI not found on PATH"; exit 0; }
fm_backend_cmuxtui_version_check >/dev/null 2>&1 || { echo "skip: installed cmux-tui is older than the verified minimum"; exit 0; }

# --- container_ensure: dedicated headless throwaway session -------------------

SES=$(fm_backend_cmuxtui_container_ensure) || fail "container_ensure failed"
SESSION_STARTED=1
[ "$SES" = "$FM_CMUXTUI_SESSION" ] || fail "container_ensure should echo the session name, got '$SES'"
fm_backend_cmuxtui_server_running || fail "the throwaway session should be running after container_ensure"
fm_backend_cmuxtui_container_ensure >/dev/null || fail "container_ensure must be idempotent on a running session"
pass "real cmux-tui: container_ensure starts (and idempotently reuses) the isolated headless session"

# --- create_task + duplicate refusal -------------------------------------------

LABEL="fm-test-smoke1"
TASK_IDS=$(fm_backend_cmuxtui_create_task "$LABEL" /tmp) || fail "create_task failed"
read -r WS1 TERM1 <<EOF
$TASK_IDS
EOF
if [ -z "$WS1" ] || [ -z "$TERM1" ]; then
  fail "create_task did not return workspace/terminal ids"
fi
case "$WS1" in ws_*) : ;; *) fail "workspace id should be a typed ws_ id, got '$WS1'" ;; esac
case "$TERM1" in term_*) : ;; *) fail "terminal id should be a typed term_ id, got '$TERM1'" ;; esac
TARGET="$WS1:$TERM1"

if fm_backend_cmuxtui_create_task "$LABEL" /tmp >/dev/null 2>&1; then
  fail "create_task should refuse a duplicate workspace name (cmux-tui itself does not enforce uniqueness)"
fi
pass "real cmux-tui: create_task creates a workspace/terminal and refuses a duplicate label"

# --- expected-label verification ------------------------------------------------

fm_backend_cmuxtui_send_key "$TARGET" Escape "$LABEL" \
  || fail "send_key with a matching expected task label should succeed"
if fm_backend_cmuxtui_send_key "$TARGET" Escape "fm-test-not-$LABEL" >/dev/null 2>&1; then
  fail "send_key with a mismatched expected task label should fail"
fi
pass "real cmux-tui: expected-label verification accepts the matching workspace and rejects a mismatch"

# --- send_literal + send_key(Enter), the two-step submit form ------------------

sleep 0.5
fm_backend_cmuxtui_send_literal "$TARGET" 'echo literal-then-key-captain' \
  || fail "send_literal failed"
sleep 0.3
fm_backend_cmuxtui_send_key "$TARGET" Enter || fail "send_key Enter failed"
sleep 0.7
out=$(fm_backend_cmuxtui_capture "$TARGET" 20) || fail "capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real cmux-tui: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real cmux-tui: send_literal (unsubmitted) + send_key Enter submit as two steps and the output is capturable"

# --- send_text_line (the composed form) -----------------------------------------

fm_backend_cmuxtui_send_text_line "$TARGET" "echo captain-on-deck-line" \
  || fail "send_text_line failed"
sleep 0.7
out=$(fm_backend_cmuxtui_capture "$TARGET" 20) || fail "capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real cmux-tui: send_text_line did not run and echo the line"$'\n'"$out" ;;
esac
pass "real cmux-tui: send_text_line composes write+Enter and its output is capturable"

# --- capture beyond the viewport pulls contiguous scrollback --------------------

# shellcheck disable=SC2016 # The $(seq) must reach the terminal literally for ITS shell to expand.
fm_backend_cmuxtui_send_text_line "$TARGET" 'for i in $(seq 1 60); do echo smoke-scroll-$i; done'
sleep 1
out=$(fm_backend_cmuxtui_capture "$TARGET" 80) || fail "large capture failed"
case "$out" in
  *smoke-scroll-2*) : ;;
  *) fail "real cmux-tui: a larger-than-viewport capture did not include scrolled-out history"$'\n'"$out" ;;
esac
case "$out" in
  *smoke-scroll-60*) : ;;
  *) fail "real cmux-tui: the large capture lost the newest visible rows"$'\n'"$out" ;;
esac
pass "real cmux-tui: capture beyond the viewport includes contiguous scrollback plus the live screen"

# --- current_path: structured live cwd, frozen-subshell counterexample ---------

fm_backend_cmuxtui_send_text_line "$TARGET" "cd /tmp"
sleep 0.5
p=$(fm_backend_cmuxtui_current_path "$TARGET") || fail "current_path failed"
case "$p" in
  */tmp) : ;;
  *) fail "real cmux-tui: current_path did not report the shell's cwd after a direct cd, got '$p'" ;;
esac
pass "real cmux-tui: current_path reads the live cwd after a direct cd"

# The load-bearing case: an integration-free foreground SUBSHELL's own cd
# (exactly what `treehouse get` opens). The structured cwd field stays frozen
# at the launch dir; the child pid's OS-level cwd is the live answer.
fm_backend_cmuxtui_send_text_line "$TARGET" 'env -i /bin/bash --norc'
sleep 0.8
fm_backend_cmuxtui_send_text_line "$TARGET" "cd /usr/local"
sleep 0.5
p2=$(fm_backend_cmuxtui_current_path "$TARGET") || fail "current_path failed inside a nested subshell"
case "$p2" in
  /usr/local) : ;;
  *) fail "real cmux-tui: current_path did not track an integration-free subshell's own cd (the treehouse-get-shaped case), got '$p2'" ;;
esac
pass "real cmux-tui: current_path tracks a foreground subshell's cd through the child pid (structured cwd stays frozen)"
fm_backend_cmuxtui_send_text_line "$TARGET" 'exit'
sleep 0.5

# --- composer_state: a plain shell prompt is never a safe injection target -----

cs=$(fm_backend_cmuxtui_composer_state "$TARGET")
[ "$cs" = unknown ] || fail "a plain shell prompt should classify unknown (no agent composer), got '$cs'"
pass "real cmux-tui: composer_state reads a plain shell prompt as unknown, never a false empty"

# --- busy_state: native hook-fed agent record -----------------------------------

bs=$(fm_backend_busy_state cmux-tui "$TARGET")
[ "$bs" = unknown ] || fail "busy_state should report unknown with no agent row, got '$bs'"
fm_backend_cmuxtui_cli agent report --terminal "$TERM1" --state working --source hook >/dev/null 2>&1 \
  || fail "agent report (working) failed"
bs=$(fm_backend_busy_state cmux-tui "$TARGET")
[ "$bs" = busy ] || fail "busy_state should report busy after a working agent report, got '$bs'"
fm_backend_cmuxtui_cli agent report --terminal "$TERM1" --state idle --source hook >/dev/null 2>&1 \
  || fail "agent report (idle) failed"
bs=$(fm_backend_busy_state cmux-tui "$TARGET")
[ "$bs" = idle ] || fail "busy_state should report idle after an idle agent report, got '$bs'"
pass "real cmux-tui: fm_backend_busy_state reads the native hook-fed agent state (unknown -> busy -> idle)"

# --- list_live (id-first recovery discovery) ------------------------------------

live=$(fm_backend_cmuxtui_list_live)
case "$live" in
  *"$WS1:$TERM1"*"$LABEL"*) : ;;
  *) fail "list_live did not report the live task workspace with its ids and label"$'\n'"--- got ---"$'\n'"$live" ;;
esac
pass "real cmux-tui: list_live discovers the live task workspace with durable ids and its label"

# --- durable ids across a server restart ----------------------------------------

fm_backend_cmuxtui_cli server stop --session "$FM_CMUXTUI_SESSION" >/dev/null 2>&1 \
  || fail "server stop failed"
sleep 1
if fm_backend_cmuxtui_server_running; then
  fail "the session should be down after server stop"
fi
fm_backend_cmuxtui_container_ensure >/dev/null || fail "container_ensure failed to restart from durable state"
fm_backend_cmuxtui_target_ready "$TARGET" "$LABEL" \
  || fail "the recorded workspace:terminal target should survive a server restart (durable ids)"
out=$(fm_backend_cmuxtui_capture "$TARGET" 5) || fail "capture failed on the restored terminal"
[ -n "$out" ] || fail "the restored terminal should produce a readable screen"
pass "real cmux-tui: the recorded target survives a server restart - durable ids are the recovery authority"

# --- kill: whole-workspace close, last workspace included ------------------------

fm_backend_cmuxtui_kill "$TARGET" "" "$LABEL"
sleep 0.5
STILL_LIVE=$(fm_backend_cmuxtui_cli workspace list --json 2>/dev/null | jq -r --arg id "$WS1" '.[]? | select(.id == $id) | .id')
[ -z "$STILL_LIVE" ] || fail "kill did not remove the task workspace"
fm_backend_cmuxtui_server_running || fail "the session server should keep running after closing its last workspace"
fm_backend_cmuxtui_kill "$TARGET" || fail "kill on an already-dead target must stay best-effort (never fail)"
pass "real cmux-tui: kill removes the whole workspace (last one included), stays idempotent, and the session survives"

# --- teardown: stop the throwaway session ----------------------------------------

fm_backend_cmuxtui_cli server stop --session "$FM_CMUXTUI_SESSION" >/dev/null 2>&1 \
  || fail "final server stop failed"
SESSION_STARTED=0
sleep 0.5
if fm_backend_cmuxtui_server_running; then
  fail "the throwaway session should be stopped at teardown"
fi
pass "real cmux-tui: the throwaway session is stopped and its scratch state removed"

cleanup_all
trap - EXIT
