# Working on fx

Handoff notes for whoever picks this up next, human or agent.

**Keep this file current.** Before ending a session that changed the code,
update "Where things stand" and "Next" below, and add anything to "Things
that will bite you" that cost you time. Remove entries that are no longer
true. Design decisions and their reasons belong in `docs/DESIGN.md`, user-facing
behaviour in `README.md`; this file is only what you need to resume work.

## What this is

A norns mod: a rack of SuperCollider effects (serial inserts and two send
chains) that works with any script. This is v2, a rewrite, on branch `v2`.
It targets norns 3.x only and replaces v1 in `dust/code/fx`.

Read `docs/DESIGN.md` first. It has the signal model, the node tree, the Lua
model and the precedence rules for restoring values.

## Where things stand

Done and tested (Lua test, click test, and on the shield):

1. SC core: in-place chains, wrapper with fades/tails/NaN guard, bundled graph
   changes, v1 plugin compatibility (`lib/FxRack.sc`, `FxUnit.sc`, `FxLegacy.sc`).
2. Lua core: registry, rack model, params, PSET restore, persist across
   scripts, settings page (`lib/core.lua`, `fx.lua`, `mod.lua`).
3. Presets: per-effect presets, rack scenes, defaults (`lib/presets.lua`).
4. Menu UX: rack rows and effect slot rows are scroll-with-E3, apply-with-K3
   (`lib/chooser.lua`).
5. Routing: audio inputs as a source (`fx_input_*`), send-to-send
   (`fx_send_a_to_b`, `fx_send_b_to_a`), feedback routing through the send
   inlets (`FxSend`, `\fxInlet`). On the shield: node tree, SC state, CPU
   (about 17% under awake with two v1 effects) and xruns were checked, and
   the user confirmed the feedback routing by ear (2026-11-15).

Not verified: the audio input (`fx_input_*`) with a real source on the
device; the "save as..." name
entry and the mod settings page on screen; start-up restore from a script's
own PSET on the device (covered in the Lua test only).

Nothing is pushed. `git stash` on `feature/pre-post-insert-sends` holds the
user's older WIP ("WIP engine-driven sends"); leave it alone.

## Next

In the order agreed with the user:

- **Step 5, rack page in the mod menu:** slots, order, bypass, meters, CPU.
  This is the next thing to do. Starting points:
  - The page is the `menu` table in `lib/mod.lua` (`mods.menu.register`),
    today two settings rows. Keep those reachable.
  - Change the rack through `Core.set_row` / `Core.place` and the bypass and
    mix params, so the params menu, PSETs and the live state stay in step.
    The page also has to work with no script loaded (`Core.active` false: no
    params exist, the model and SC still do).
  - Order: `Core.place(name, chain, index)` swaps with the occupant. On the
    SC side a move is release + start, so it crossfades.
  - v1 units have no bypass param yet (see below); the page needs one for
    every unit, so do that first.
  - Meters and CPU need data from SC that does not exist yet. Crone's own
    polls (`amp_out_l/r`, `cpu_avg`, `cpu_peak`) are script-owned and reset
    at script change; a mod-owned path is an `OSCFunc`-side `SendReply` or a
    routine in `FxRack` sending to matron (port 10111) and an `osc.event`
    handler, which must chain any handler the script sets. Decide and
    record it in `docs/DESIGN.md`.
  - Redraw only while the page is open (`menu.init` / `menu.deinit`), at a
    fixed rate, and stop the meter traffic when it closes.
  - Agree the layout with the user before building much; screenshots from
    the device (see "On the device") are the quickest way to show it.
- **Step 6:** softcut as a source (needs more SC input channels and JACK
  routes via `audio.port_connect` and the
  `audio_post_restore_default_routing` hook; whether a mod can raise
  `numInputBusChannels` before Crone boots the server is unverified),
  sidechain and modulation control buses, tempo sync, single-file plugins
  with params from SynthDef metadata, multiple instances per unit, a script
  API to request a rack.

Smaller open items:

- Scenes saved before step 4 do not mention the input and send-to-send
  params, so loading one leaves those as they are.
- v1 plugins have no bypass param (their group sizes are fixed). It could go
  in the fx rack group.
- Params a v1 plugin sets up without the helper API (e.g. `fx_resonator`'s
  note and model) are not in presets or the live state.
- Factory preset lookup fails if a plugin writes `return fx.register{...}` as
  a tail call; `plugin_dir` can be passed explicitly.

## Testing

```
lua5.3 test/run.lua [path/to/norns/lua]   # Lua core against the real paramset
test/run_sc.sh                            # audio click test, local scsynth
```

Both must pass before committing. `run.lua` defaults to `~/git/norns/lua`.
`run_sc.sh` needs sclang, scsynth and JACK (pipewire-jack works); it does not
connect to the speakers.

### On the device

The user's shield is a 3.x beta with a custom core. Ask for its address;
it was `10.0.0.138`. SSH as `we` with key auth.

```
rsync -a --delete --exclude .git ./ we@<ip>:dust/code/fx/
test/repl.py --host <ip> '_norns.reset()'                      # restart matron + sclang
test/repl.py --host <ip> --wait 14 'norns.script.load("code/awake/awake.lua")'
test/repl.py --host <ip> 'print(require("fx/lib/core").rack.insert[1])'
test/repl.py --host <ip> --sc 'Crone.server.queryAllNodes;'
ssh we@<ip> 'journalctl -u norns-main -n 80 --no-pager'        # also norns-sclang, norns-jack
```

- A restart is needed after any change: `.sc` classes are compiled at boot,
  and the Lua modules are cached by `require` and shared with the plugin mods.
- Menus can be driven with `_menu.set_page("PARAMS")`, `_menu.set_mode(true)`,
  `_menu.enc(n, d)`, `_menu.key(n, z)`, and captured with
  `_norns.screen_export_screenshot("/tmp/x.png")`.
- For multi-line code, copy a file to `/tmp` and `dofile` / `.load` it.
- The click test can run inside the device's sclang: take
  `test/click_test.scd`, remove the server boot/quit/exit lines, and load it.
  It plays a test tone on the outputs; free `testSrc` and any `testHard`
  node afterwards.
- Tell the user before restarting or making sound on their device. Leave
  the rack empty and the fx params neutral when done, above all the send
  levels of any feedback patch.
- `repl.py` needs `websocket-client`: `python3 -m venv <dir outside the repo>`
  and `pip install websocket-client`, then run it with that venv's python.
- v1 is backed up on the shield at `~/fx-v1-backup`, the old mod list at
  `~/system.mods.pre-fx2`.

## Conventions

- Commit messages: no AI attribution or tool-specific trailers.
- The repo uses the `vehka` GitHub identity (`github-vehka` SSH alias). Run
  `gh auth switch --user vehka` before any `gh` command.
- Commit when a step is done and tested; do not push unless asked.
- The user wants norns core left unpatched: use the param and mod contracts.

## Things that will bite you

- **Two definitions of `FxBase`/`FxSetup` stop sclang compiling**, which means
  no audio at all. Never leave a second copy of fx, or a `.sc` test class,
  under `dust/`. The test plugin is `test/FxTestLegacy.sc.txt` for this reason.
- **v1 plugins are not uniform.** Some add their own params from
  `script_post_init`, some use separators instead of groups, some send OSC to
  their own `<subpath>/set`, and `fx_resonator` overrides `listenOSC` and
  touches `syn` directly. `add_slot` must add exactly two params or v1 group
  sizes break. Check a change against the plugins on the device, not only
  the test plugin.
- **Param actions only fire on change.** Anything restored from a PSET must
  give the same result whatever the line order and whatever was loaded
  before; that is why slot/position params move occupants instead of
  dropping them, while rack rows (applied by hand) replace.
- **The stock params menu applies option params on every encoder step.** Use
  `Chooser` for anything that loads or moves an effect.
- **Rack row option lists depend on what is installed**, so rack rows are
  never saved; the per-unit slot and position are.
- **A send's chain is fed through `InFeedback` from `inBus`**, not from the
  tap directly. Anything new that feeds a send writes to `inBus`; only
  cooperating engines write to the chain bus.
- **A PSET with a post tap and a pre return was a plain post return before
  step 4** and is now a feedback loop.
- **Pre tap with pre return is not a loop**: the return lands after the tap
  point. Feedback needs a post tap with a pre return, or both send-to-send
  levels with an effect on each send.
- **SC dictionary `put` returns the dictionary**, so
  `x = d[k] ?? { d[k] = v }` does not give you `v`.
- **Mod load order is not alphabetical**, and `system_post_startup` can run
  before sclang listens; `/fx/ensure` is sent again at every `script_pre_init`.
- **xruns at restart and script load are normal on this shield.** Judge a
  change by the per-minute count in `journalctl -u norns-jack` while idle and
  while exercising the rack.
