-- megatigrex.lua — MEGA TIGREX SWARM
--
-- On any quest that has EXACTLY ONE big-monster target, on the snowy mountains
-- map, spawn a swarm of 10 mini-Tigrex (random size 0.2..0.4) in section 1 and
-- paint them all on the minimap.
--
-- HOW IT BUILDS ON WHAT WE LEARNED
--   * One Tigrex must be RESIDENT to clone from. If the quest already has a
--     Tigrex we use it; otherwise we ADD a Tigrex alongside the native monster
--     (mhfu.quest_add_monster — §48 group split + forge) so e.g. a Giadrome
--     quest becomes "1 Giadrome + 10 Tigrex". (If your build can't load a 2nd
--     DIFFERENT family yet, flip KEEP_NATIVE=false to REPLACE the native
--     monster with Tigrex instead — that always works.)
--   * The swarm itself is CHEAP: all 10 Tigrex share the one resident model /
--     overlay / species block — only the ~31 KB entity struct is duplicated.
--     mhfu.entity_clone() does the deep-copy + self-ptr rebase + splices the
--     copy into the engine update chain + registry (memory tigrex-clone-recipe).
--   * Forced into snow section 1 + made visible via the +0x29A section-tracker
--     fix (memory giadrome-tigrex-render-bug).
--
-- DEPLOY: drop this file at
--   ms0:/PSP/PLUGINS/mhfu_framework/mods/megatigrex.lua
-- and cold-boot (the entity_clone C binding ships in the PRX). Hot-reload works
-- for tweaks once it's loaded. Only ONE mhfu_tick can be active — keep the
-- other tigrex_*.lua scripts out of the mods dir.

------------------------------------------------------------------------ CONFIG
local CFG = {
  COUNT       = 10,        -- total Tigrex in the swarm
  SIZE_MIN    = 0.2,
  SIZE_MAX    = 0.4,
  SPREAD      = 1400.0,    -- world-unit radius of the ring we scatter them on
  KEEP_NATIVE = true,      -- true  = ADD Tigrex, keep the quest's own monster
                           -- false = REPLACE the native monster with Tigrex
  AGGRO       = false,     -- true  = the whole swarm hunts you immediately
                           --         (freeze HP at 0x090B3724 or you WILL die)
}
--------------------------------------------------------------------------------

local TIGREX = mhfu.MON.TIGREX
local SNOW_S1 = mhfu.AREA.SNOW_S1   -- 99
local IN_AREA = 17                   -- screen_state when fully in a field section

local armed   = false   -- this quest qualified (single big monster, ensured Tigrex)
local spawned = false   -- swarm already built this run

-------------------------------------------------------- gate + ensure resident
mhfu.on_quest_targets_building(function(quest)
  armed, spawned = false, false
  if quest == 0 then return end

  local n = mhfu.quest_monster_count(quest)
  if n ~= 1 then
    mhfu.log(string.format("[megatigrex] skip: quest has %d big monsters (need exactly 1)", n))
    return
  end

  if mhfu.quest_has(quest, TIGREX) then
    mhfu.log("[megatigrex] native Tigrex present — will clone it")
    armed = true
  elseif CFG.KEEP_NATIVE then
    if mhfu.quest_add_monster(quest, TIGREX, 0, 0) then
      mhfu.log("[megatigrex] added a Tigrex alongside the native monster")
      armed = true
    else
      mhfu.log("[megatigrex] quest_add_monster failed — flip KEEP_NATIVE=false to replace instead")
    end
  else
    local from = mhfu.quest_first_monster(quest)
    if from >= 0 and mhfu.quest_replace_monster(quest, from, TIGREX) then
      mhfu.log(string.format("[megatigrex] replaced native 0x%02X with Tigrex", from))
      armed = true
    else
      mhfu.log("[megatigrex] could not retag the native monster")
    end
  end
end)

-- neutralise any stale action-force closure from a previous hot-reload
mhfu.on_bigmonster_action(function(ctx) return ctx.action_id end, 100)

------------------------------------------------------------------- swarm build
-- Scatter `ent` onto the ring at slot `i` of `total`, give it a random mini
-- size, drop it into section 1 and make it visible.
local function place(ent, i, total, px, py, pz)
  local a  = (i / total) * (2.0 * math.pi)
  local x  = px + CFG.SPREAD * math.cos(a)
  local z  = pz + CFG.SPREAD * math.sin(a)
  local sz = CFG.SIZE_MIN + math.random() * (CFG.SIZE_MAX - CFG.SIZE_MIN)
  ent:set_pos(x, py, z):set_size(sz):make_visible(SNOW_S1)
  if CFG.AGGRO then ent:force_aggro(mhfu.world.player()) end
  return sz
end

local function build_swarm()
  local src = mhfu.world.first(TIGREX)
  if not src then return false end           -- Tigrex not resident yet

  local px, py, pz = mhfu.player_pos()
  math.randomseed((mhfu.get_quest_timer() or 0) + 1)

  -- the resident Tigrex becomes swarm member #1
  local sz1 = place(src, 0, CFG.COUNT, px, py, pz)
  mhfu.log(string.format("[megatigrex] member 1/%d (native) size=%.2f", CFG.COUNT, sz1))

  -- clone the rest, all sharing its model/overlay
  for i = 1, CFG.COUNT - 1 do
    local c = src:clone()
    if not c then
      mhfu.log(string.format("[megatigrex] clone %d failed (pool/registry full) — stopping", i + 1))
      break
    end
    local sz = place(c, i, CFG.COUNT, px, py, pz)
    mhfu.log(string.format("[megatigrex] member %d/%d clone=0x%08X size=%.2f",
      i + 1, CFG.COUNT, c.ptr, sz))
  end
  return true
end

----------------------------------------------------------------------- tick
function mhfu_tick()
  mhfu.paint_map()                              -- keep the swarm on the minimap
  if not armed or spawned then return end
  if mhfu.get_screen_state() ~= IN_AREA then return end
  if mhfu.get_area_index() ~= SNOW_S1 then return end   -- snow section 1 only

  if build_swarm() then
    spawned = true
    mhfu.log("[megatigrex] swarm deployed in snow section 1")
  end
end

mhfu.log("[megatigrex] registered — single-big-monster snow quests get 10 mini-Tigrex")
