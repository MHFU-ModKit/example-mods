<p align="center">
  <img src="misc/banner.svg" width="720" alt="EXAMPLE-MODS">
</p>

# MHFU ModKit — example mods

Lua mods for the [MHFU framework](https://github.com/MHFU-ModKit/framework), and the port
manifests behind the ported monsters. Each `.lua` in `mods/` goes on the memory stick as is:

```
<memstick>/PSP/PLUGINS/mhfu_framework/mods/<name>.lua
```

and is hot-reloaded while the game runs — edit, save, it applies. Everything here was run in-game.

## The mods

| File | What it shows |
|---|---|
| `mods/tigrex_aggro.lua`, `tigrex_hunt.lua`, `tigrex_ontop.lua`, `tigrex_section1.lua`, `tigrex_invest.lua` | the entity API on a native Tigrex: aggro, following the hunter, teleporting into his section, reading his state |
| `mods/megatigrex.lua` | ten Tigrex at once — entity cloning, the ~2 damaging-monster cap in practice |
| `mods/dup_test.lua` | a second *fighting* big monster through the quest-target path (`quest_add_monster`) |
| `mods/brute_tigrex.lua`, `brute_showcase.lua`, `brute_dmg.lua` | a fully ported Brute Tigrex: model injection, its own moveset, damage on the ported rig |
| `mods/zinogre_lunge.lua` | a ported Zinogre's first declared move — the port library, native seams, distance rules, the run budget |
| `mods/zinogre_fx.lua`, `zinogre_clips.lua`, `zinogre_show.lua`, `zinogre_test.lua` | effects on the ported rig, clip playback, a showcase loop, the test bench |
| `mods/zinogre_hit.lua` | **generated** by the monster editor from `ports/zinogre.toml` — the hurtboxes and attack volumes as the runtime eats them |
| `mods/clip_probe.lua`, `relocate_test.lua` | reading the clip-state block; the relocate-source injection path |

The port library they build on (`mhfu_port.lua`) ships embedded in the framework; its API is
[`docs/MOD_PORTED_MONSTER.md`](docs/MOD_PORTED_MONSTER.md).

## The ports

`ports/<name>.toml` is a ported monster as data: source model, clip labels, moves with their
host `(main, sub)` pairs, claims and rules, hurtboxes, parts and attack volumes. They are
authored in the [`monster-editor`](https://github.com/MHFU-ModKit/monster-editor) and deployed
by it; the PAC each one builds is produced from your own game files with the
[`formats`](https://github.com/MHFU-ModKit/formats) tools.

## No game data is included

This repository contains **no game files, no extracted assets, no artwork** — not the ISO, not
decrypted archives, not models or textures, not dumped tables. All of it is gitignored and is
reproduced from your own legally obtained copy of the game (see the `formats` repo's
`docs/ASSETS.md`). Everything targets **MHFU EU (ULES01213)**; addresses will not line up with a
JP or NA build.

## About this repository

`example-mods` is one of the [MHFU-ModKit](https://github.com/MHFU-ModKit) repositories. They are cut
from one upstream research repository and re-published from it, so they move in lockstep — a
file that appears in two of them is the same file at the same commit. Pull requests are welcome
here; an accepted one is applied upstream and comes back in the next export, which is why
`main` only takes changes through PRs. Issues are welcome for bugs, questions and findings alike.

The siblings:

- [`framework`](https://github.com/MHFU-ModKit/framework) — the runtime mod framework: one PRX, many mods, hot-reloaded Lua
- [`monster-editor`](https://github.com/MHFU-ModKit/monster-editor) — the desktop editor for ported monsters
- [`hud`](https://github.com/MHFU-ModKit/hud) — a live read-only HUD and AI editor over the PPSSPP debugger
- [`blender-addon`](https://github.com/MHFU-ModKit/blender-addon) — import, edit and export big monsters in Blender
- [`formats`](https://github.com/MHFU-ModKit/formats) — the file-format library, ISO extraction and the MHP3rd→MHFU porter

## License

[MIT](LICENSE). Not affiliated with or endorsed by Capcom. Monster Hunter is a trademark of
Capcom Co., Ltd.
