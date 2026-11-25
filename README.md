# smudgenix

Bootstraps and keeps a system up to date. Host-specific config lives in a
small, uncommitted per-host flake; user-level (sudo-free) home-manager config
lives in a small, uncommitted per-home flake. Both build on this repo.

```
github:smudge/smudgenix ─┬─► /etc/nixos/flake.nix              (per-host)  → smx os config apply
                         └─► ~/.config/home-manager/flake.nix  (per-home)  → smx config apply
```

## NixOS

Generate the per-host flake next to your `hardware-configuration.nix`, then
fill it in (hostname, `system.stateVersion`, `smudgenix.*` options, hardware
module, overrides):

```bash
cd /etc/nixos
sudo nix --extra-experimental-features 'nix-command flakes' flake init -t github:smudge/smudgenix
sudoedit /etc/nixos/flake.nix
sudo nixos-rebuild switch
```

On each user's first login, a user service generates
`~/.config/home-manager/flake.nix` from the `smudgenix.user.homeTemplate`
template (default: `github:smudge/smudgenix#home`) and applies it, so every
user manages their own home without sudo. It never clones or overwrites
anything; edit that file for per-home overrides. The primary user's git
identity is pre-filled from `smudgenix.user.git` if set; otherwise you are
notified to fill it in, and it is applied on the next update. The generated
flake follows the system's smudgenix (via `/etc/nixos/flake.lock`), so home
and system share one smudgenix and nixpkgs, and update in lockstep.


Systems are flake-only: channels are disabled, and `<nixpkgs>` (e.g. for
`nix-shell -p`) resolves to the system's flake-pinned nixpkgs.

The desktop is niri with the Noctalia shell. Its bar hides when windows need
the space, and shows whenever something drops from it. Super is the leader
key: tap it alone for the Control Center, hold it and the bar peeks out, keep
holding and niri's shortcuts show (`smudgenix.desktop.leader`).

## Userland only (any Nix-enabled home)

On macOS, another distro, or anywhere without sudo, use just the home-manager
half. Fill in the `@placeholders@`, including your git identity (required), and
`stateVersion` (the current home-manager release, e.g. from
`home-manager --version`), then apply:

```bash
mkdir -p ~/.config/home-manager && cd ~/.config/home-manager
nix flake init -t github:smudge/smudgenix#home
$EDITOR flake.nix
nix run home-manager -- switch
```

## Updates

Updates are driven by what is pushed upstream:

- `nixos-upgrade.timer` refreshes `/etc/nixos/flake.lock` and rebuilds daily, at
  `smudgenix.autoUpdate.time` (default `"04:00"`) in `time.timeZone`, or at any
  systemd calendar spec given as `smudgenix.autoUpdate.dates`.
  It never reboots unless `smudgenix.autoUpdate.reboot = true`; instead, the
  primary user gets a desktop notification when an update needs a reboot.
- `home-manager-auto-update` (user) refreshes
  `~/.config/home-manager/flake.lock` and re-applies right after each system
  switch (picking up the system's new smudgenix), and daily.

## Agents

OpenCode's server runs as each user's `opencode` service, from login (and
`opencode` starts it, if it's stopped, and uses it), and agents' commands run without the desktop's
environment, even the one a client passes on
(`smudgenix.ai.server.unsetEnvironment`), so nothing they run finds niri or
your windows by accident. Nor can they reach its sockets (only the session
bus, the SSH agent and GnuPG's, of `$XDG_RUNTIME_DIR`:
`smudgenix.ai.server.runtimeDir`), change what runs at login (user units,
autostart: `server.readOnly`), or gain privileges.
`opencode service start|stop|restart` goes through the service, and
`smx ai doctor` checks all of it.

And each command runs in its own sandbox (`smudgenix.ai.sandbox`, through
smudgenix's OpenCode plugin): everything read-only but its project, tools'
caches and `/tmp`; none of OpenCode's own files (its password, its saved
permissions), keyrings, private keys or browsers' profiles; its own
processes (not the server's); and of the session bus, only the keyring. So
an agent can't answer its own requests, or start something outside the
sandbox (`systemd-run --user`).

What it can still do: read the rest of your home, use the network, sign with
the SSH agent, and ask the keyring for any secret (git's and `gh`'s
credentials need it), so take care what you let agents read. Edits and
writes that go through OpenCode's own tools, not a shell, aren't sandboxed:
its permission rules govern those.

On the desktop, the bar's agents capsule is grey unless something needs you,
waits for review, or is at work, and you're only interrupted (a notification)
when an agent needs you or fails. Mod+A (or a click on it) shows your
threads of work in the project you're in (Tab for others, or all), by whose
turn it is: yours (it needs you, or it's back: work to review, an answer),
away (an agent's at it), or parked. A thread stays until you close it (`c`);
`n` starts one (Enter: in the background, to come back when it's done;
Shift+Enter: in a TUI), `r` tells one more, `z` parks one. `smx ai new`,
`reply`, `park`, `close`, `status`, `watch` and `open` do the same from a
terminal. Closing a thread archives its session (nothing's deleted), and
`smx ai history` shows your threads day by day, closed ones too: when, in
which project, how they ended (their review's outcome) and what they cost,
subagents included (`--days`, `--since`, `--project`, `--json`).

What you decide goes in a decision log: one line each, like a changelog, kept
privately in `~/.local/share/smudgenix/decisions.jsonl`. A line is a
direction (where the work is going), a constraint (a must), a decision, or
something left open on purpose; it's yours (all your projects), a project's,
or a thread's. `smx ai decide "<line>" [--why "<why>"]` adds one, for the
project you're in by default. Nothing's ever edited: `--supersedes <id>`,
`smx ai reopen`, `confirm` and `withdraw` add lines too, and `smx ai log`
shows it all, newest first (`--current`: only what stands now). Every agent
gets what stands in its project and thread, and is told to work within it.
When a choice is a judgment call, it asks you instead of guessing, with
options and its pick, and waits. A small, reversible call it makes and
records as provisional, for you to confirm or overturn. Both wait in Mod+A,
under To decide, with what already stands there. You answer with a line of
your own (an option's, edited, or yours) and why, and the agent carries on
from it.

When an agent asks permission, its notification opens Mod+A on it (so one
appearing as you type can't answer anything, and one you missed is a Mod+A
away), which shows the request as it is (the command, or the files, and
where), to allow or deny; or `smx ai allow|deny <request>`. `--always` allows the like in that project from
now on (OpenCode keeps these); `smx ai allowed` lists them, and
`smx ai allowed revoke <id>` takes one back.

A thread you start in a repository (`smx ai new`, or `n` in Mod+A) works in
a workspace of its own, in smudgenix's store (a jj workspace, and a git
worktree, of your repository), never in your checkout. Its work is a stack of
layers: one change each, with its purpose as its commit title, each safe to
land on its own, the least controversial first. Agents commit and revise
layers only through smudgenix's OpenCode plugin: their own commands can't
change history. Mod+A shows a thread with layers as "to review". Enter opens
its stack, bottom first: each layer's purpose and size, and the selected
one's hotspots and diff, right there (Shift+J/K scrolls it; Enter opens it
all in a terminal). `a` lands it and every layer below it on your trunk (a
fast-forward, in your checkout if it's on it: your uncommitted work stays).
`r` tells the agent what to change in it; the layers above restack on the
change. A layer with an agent's call still provisional in it can't land until
you settle the call. `smx ai stack <session>`, `stack diff <session> <layer>`
and `land <session> <layer>` do the same from a terminal. Closing a thread
lands its layers (`--accept`) or sets them aside (`--discard`: still in jj's
history, never reverted), and removes its workspace.

A session started some other way (in your checkout, say) is reviewed whole
instead: when it finishes having changed its repository, its work goes to review by itself
(`smx ai review <session>`, or `p` on it in Mod+A, does it any time): the
change, frozen as a commit of the working tree (untracked files too; your
branch and files untouched), from where it started (or its last accepted
review ended); the places worth a closer look (dependencies, deleted or
skipped tests, migrations, CI, security-sensitive files and lines, large
changes); and what the agent says it did, marked as its claim. `smx ai diff <task>` shows it; `accept`,
`revise <task> "<what to change>"` (back to its session) or `defer` decide.
A review that's changed since it was frozen is stale, and can't be accepted
until you review it again. Tasks live in `~/.local/share/smudgenix/tasks`,
which agents' commands can't change.

`smx ai verify <task>` (`v` in a review) adds evidence, rather than the
agent's word: it runs the project's check on exactly the frozen revision, in
a fresh copy and agents' sandbox (it's their code), and records whether it
passed, with its log (`e`). The check is guessed from the project's files
(`nix flake check`, `npm test`, `cargo test`, `go test ./...`, `make check`,
`pytest`…), or the one you last gave it with `--command "<check>"`.

## smx

`smx`, installed for every user, works on your home, and never needs sudo.
`smx os` works on the OS, shared by every user, and asks for sudo only to
change it. `smx help` and `smx os help` list everything.

```bash
smx update          # get the latest (the OS's smudgenix) for your home, and apply it
smx config          # browse your settings, and change them
smx config set dev.enable false
smx config diff     # what applying would change
smx config apply    # apply your changes
smx history         # your home's generations
smx revert [<gen>]  # back to the previous generation, or to <gen>

smx os update       # regenerate /etc/nixos/flake.lock, and apply it
smx os config set hiDPI true
smx os config apply
smx os revert [<gen>]

smx shell ripgrep jq # a shell with these packages, from the OS's nixpkgs
smx run cowsay hi    # run one, without installing it
smx search pdf       # find packages
smx clean [30d]      # delete your generations older than that (14d), and what nothing uses
smx os clean [30d]
```

The OS commands take `--try` (only until the next reboot) or `--on-reboot`
(from the next reboot). After a revert, automatic updates wait until the next
`update` or `config apply`.

The OS sets everyone's defaults, and each home can change the desktop's
for itself: `smx config set desktop.touchpad.tapToClick true`, or keyboard
repeat, keybinds (`desktop.binds`) and Noctalia's settings
(`desktop.noctalia.settings`). Unset, they're the OS's.

`config set` writes `smudgenix.toml`, next to the flake (which reads it with
`settings = ./smudgenix.toml;`). Its keys are `smudgenix.*` options, checked
against their types, and they win over the same options set in `flake.nix`.
For anything else, `config edit --nix` edits `flake.nix` itself, and checks
it before applying. `config reset` puts both back as they were last applied.

In a terminal, smx shows each step on one line (and builds with
nix-output-monitor), keeping Nix's own output in
`~/.local/state/smudgenix/logs/` unless it warns or fails; `--verbose`
shows all of it. After applying, it lists the packages that changed.

Updates use your `gh` login, if any, to avoid GitHub rate limits.

For local iteration, `config apply --local <checkout>` uses a smudgenix
checkout instead of the locked one. To work on smudgenix's Noctalia plugins
(`noctalia/plugins/`), `smx config set desktop.noctalia.pluginsFrom
<checkout>` uses the checkout's, and Noctalia reloads them as you edit them.
