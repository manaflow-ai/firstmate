# cmux-tui runtime backend

cmux-tui is an experimental headless terminal-multiplexer backend, the Rust `cmux-tui` binary from [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux).
It is a different product from the macOS GUI app that the [`cmux` backend](cmux-backend.md) drives, and the two backends are independent.
It provides task workspaces and terminals while Treehouse continues to provide git worktrees.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.

## Setup

Pick cmux-tui when crews should run headless with no GUI app, including on Linux and over SSH.

Prerequisites:

- The `cmux-tui` binary (0.1 or newer) on `PATH`, or `FM_CMUXTUI_BIN` pointing at it.
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

There is no socket-access matrix and no password: the session socket lives in a 0700 per-uid directory and admits the same user by default.

Select cmux-tui with local `config/backend` containing `cmux-tui`, `FM_BACKEND=cmux-tui` for one launch, or an explicit request to Firstmate.
It is also runtime auto-detected when Firstmate itself runs inside a cmux-tui terminal, from the injected `CMUX_TUI_SOCKET` marker (or its legacy `CMUX_MUX_SOCKET` alias).
Detection checks tmux first, then Herdr, then cmux-tui, then the cmux GUI app: an inner multiplexer always wins, and a cmux-tui session started inside a cmux GUI tab still resolves to cmux-tui because the GUI marker is inherited from outside.
A spawn stops with an actionable setup message when the binary, minimum version, or `jq` is unavailable.

Every adapter invocation exports `CMUX_TUI_CONFIG` pointing at an adapter-owned config file (default `state/cmux-tui/cmux-tui.json`, created as `{}`).
This is load-bearing: an operator's own `~/.config/cmux/cmux-tui.json` may configure a machine provider that refuses `--session`/`--headless` startup outright.
`FM_CMUXTUI_CONFIG` overrides the file for test isolation.

## Task shape and metadata

Each firstmate home owns one dedicated headless session named `fm-<home-label>` (`FM_CMUXTUI_SESSION` overrides for tests), started with `server start --session <name> --headless --state <dir>` against the adapter-owned state dir `state/cmux-tui` (`FM_CMUXTUI_STATE` overrides).
The adapter never touches the operator's own sessions, including the default `main` session, because every CLI call carries the home session's explicit `--session` flag.
Each task owns one workspace with one terminal tab inside that session.
Because the session itself is home-scoped, workspace names are the plain caller-facing `fm-<id>` labels with no home tag.
cmux-tui does not enforce workspace-name uniqueness, so the create path refuses a live duplicate label itself, and that check-then-create window is an inherent TOCTOU.

```text
backend=cmux-tui
window=<workspace-id>:<terminal-id>
cmuxtui_session=<session-name>
cmuxtui_workspace_id=<workspace-id>
cmuxtui_terminal_id=<terminal-id>
```

Workspace and terminal ids are durable across server restarts (verified live: the same `ws_`/`term_` ids come back from the same `--state` dir).
The recorded id pair is therefore the recovery authority.
Names are display labels only: a stale id is re-resolved by label solely through the standard exactly-one duplicate guard, and an ambiguous name refuses rather than guessing.

## Current operation and safety

Literal send and Enter are separate calls: `terminal <id> write --text` never auto-submits, and `terminal <id> keys <chord>` delivers Enter, Escape, Ctrl-C, Ctrl-D, Ctrl-U, Tab, Up, and Down (lowercase chords, invalid chords return a typed error).
`screen read` works on a genuinely fresh terminal and returns the live cursor position, so the composer verifier hands the shared classifier in `bin/fm-composer-lib.sh` a cursor-anchored capture (`cursor=1`).
The capture is plain text (`styled=0`), so ghost text stays unreadable and a bare glyph row carrying trailing text still degrades to `unknown` rather than a false `pending`.
A hidden cursor drops the cursor fact for that read instead of anchoring on a stale row.
Captures larger than the viewport append the terminal's retained scrollback from `history read`, which is contiguous with the visible screen.

Worktree-path discovery is structured, never screen-scraped: `process show --json` reports the top-level shell's live cwd (a `file://<host>/path` URL, scheme and host stripped) plus child pids.
On cmux-tui 0.12.0 or newer the same response carries `foreground_cwd`, the PTY's foreground process group's live cwd ([manaflow-ai/cmux#10704](https://github.com/manaflow-ai/cmux/pull/10704)), and the adapter uses it whenever the key is present and non-null, stripped of scheme and host the same way.
A null `foreground_cwd` (that daemon's own lookup failed) or an absent key (a pre-0.12.0 daemon) falls back to the child-pid probe: the structured top-level cwd freezes when an integration-free foreground subshell (the `treehouse get` case) changes directory, so child pids are consulted through their OS-level cwd (`lsof -a -p <pid> -d cwd -Fn` on macOS, `/proc/<pid>/cwd` on Linux).
`terminal <id> screen wait --pattern <regex> --timeout-ms <n>` exists as an event-driven output wait for future use.

Mutations go through a wrapper that attaches a per-attempt `--correlation-key` nonce and retries once with the same key on a retryable or `mutation.indeterminate` typed error.
Keys are never derived from stable labels: a replayed key returns the original attempt's result even after that workspace was closed (verified live), so a label-derived key would resurrect stale ids.

Native per-terminal agent state exists: `agent list --json` rows carry `working|blocked|idle|done|unknown`, hook-fed via `agent report` and `agent hook install`.
`fm_backend_busy_state` maps them exactly as Herdr's agent status is mapped: `working` is busy, `idle`/`done`/`blocked` are idle, and no row is unknown, the watcher's cue to fall back to pane-regex detection.

Cleanup closes the task's whole workspace.
Closing the last workspace of the session works natively, and the session server keeps running with an empty tree, so there is no sibling-workspace dance and no ghost tab.
Real tests spin up their own isolated throwaway session (`FM_CMUXTUI_SESSION=fm-tui-test-*`) with `fm-test-` labels and a scratch `--state` dir, stop that session afterward, and never enumerate-and-close anything in a shared namespace.

## Active limits

- cmux-tui is experimental, and secondmate spawns are unsupported until a per-home lifecycle design is verified.
- Workspace-name uniqueness is not enforced natively, so the duplicate refusal is the adapter's own and its check-then-create window is inherent.
- Env markers are ordinary environment variables a wrapper can scrub, like every other backend's markers.
- A target can disappear between a structural readiness read and the operation.
- A foreground subshell's cwd needs the child-pid lookup on daemons older than cmux-tui 0.12.0, and remains the fallback when 0.12.0's native `foreground_cwd` is null.
- Agent state is hook-fed, so a harness without installed hooks reports no row and supervision falls back to screen polling.
- There is no native push-event wait wired into the watcher yet; `screen wait` exists but `fm_backend_has_push` still reports false.

## Regression entry points

```sh
tests/fm-backend-cmux-tui.test.sh
tests/fm-backend-cmux-tui-smoke.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#cmux-tui) records the active live evidence, including durable-id restart proof and the frozen-subshell cwd counterexample.
