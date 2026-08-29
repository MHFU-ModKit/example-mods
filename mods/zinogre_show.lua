-- zinogre_show.lua — the same port as zinogre_test.lua, brought into shot ONCE.
--
-- The passive test proves the engine builds the monster from our rig. It cannot
-- prove the monster LOOKS right, because it roams and arriving is its decision:
-- two 90 s and 420 s watches filmed empty snowfield while the Zinogre sat ~7000
-- units away.
--
-- ⚠️ SO THIS ONE INTERVENES — but exactly ONCE, and that distinction is the whole
-- point. The rule that matters (CLAUDE.md §8) is "never maintain a big monster
-- PER TICK": re-forcing position, section, size and the freeze gate every frame
-- is what made swapped monsters look combat-broken for two months. A single
-- teleport_near, after which the engine is left alone with the monster, is a
-- different thing — it changes where the fight starts, not how the monster runs.
--
-- It also does NOT shrink him (tigrex_hunt.lua sets size 0.3, which would make
-- the mesh useless to look at) and does not force aggro.

mhfu.port = mhfu.port or { _queue = {} }
mhfu.port.mod = mhfu.port.mod or function(n, f) mhfu.port._queue[n] = f end

mhfu.port.mod("zinogre_show", function(P)
  local log = P.log

  local zin = P.define{
    name    = "zinogre",
    species = mhfu.MON_TIGREX,
    replace = { mhfu.MON_GIADROME },
    pac     = "zinogre_v1.bin",
    orig    = "file_06185.bin.orig",
    fid     = 6186,
    clips   = {}, moves = {},
  }

  local NEAR   = 900.0   -- park him this far along +X from the hunter
  -- 🔴 GATE THE PULL ON A SETTLED AREA, NOT ON A TICK COUNT. The first version
  -- fired 4 s after the port adopted the entity — which is at quest start, while
  -- the driver was still walking base camp -> section 1. It teleported the monster
  -- to a spot the hunter then walked away from, and filmed nothing. The player's
  -- area index changes on every section transition, so "unchanged for SETTLE
  -- ticks" is the signal that the hunter has arrived somewhere and stopped.
  local SETTLE = 20      -- ticks @ 2 Hz = 10 s of a stable area index
  local announced, pulled, area, held = false, false, nil, 0

  zin:brain(function(s)
    local e = s.ent or 0
    if e == 0 then return end
    if not announced then
      announced = true
      log("[zinogre] alive ent=0x%08X joints=%d animbase=0x%08X hp=%d",
          e, mhfu.read_u16(e + 0x1A4), mhfu.read_u32(e + 0x1AC), s.hp or 0)
    end
    if pulled then return end
    local a = s.area
    if a ~= area then area, held = a, 0; return end
    held = held + 1
    if held < SETTLE then return end
    pulled = true
    local ent = mhfu.entity_wrap(e)
    local px, py, pz = mhfu.player_pos()
    ent:teleport_near({px, py, pz}, NEAR)
    log("[zinogre] pulled into shot once at +%.0fX in area %d (settled %d ticks); "
        .. "the engine has him back now", NEAR, a or -1, held)
  end)
end)
