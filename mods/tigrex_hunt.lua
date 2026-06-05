-- tigrex_hunt.lua — "the hunter comes to YOU" (a fun one, hehe).
--
-- * Swaps the Giadrome for a Tigrex and shrinks him to 0.3.
-- * Roams him to whatever section the player is in, parks him near the player,
--   and lets him fly in / land / aggro naturally if the zone allows.
-- * If after 30 s he still hasn't engaged on his own, FORCES the aggro at you.
--
-- All the raw memory work (float packing, entity offsets, the engage signature,
-- the visibility gate, the player position, the minimap cheat) now lives in the
-- framework — see mhfu.world / mhfu.entity / Entity:force_aggro (_prelude.lua).
--
-- Cold boot only (savestate bypasses the PRX/lua). Keep this the ONLY active .lua.

------------------------------------------------------------------------ CONFIG
local TIGREX_SIZE = 0.3
local NEAR_OFFSET = 500.0     -- park him this far (+X) from the player
local COLOC       = 6000.0    -- "same area" radius
local FAR_RECALL  = 7000.0    -- re-park him if he wanders past this
local AGGRO_DELAY = 900       -- 30 s @ 30 Hz (quest timer ticks)
local MELEE_KEEP  = 900.0     -- after forcing, keep him within this so he can attack
local HEARTBEAT   = 30
--------------------------------------------------------------------------------

-- Swap Giadrome -> Tigrex at native coords (full provisioning).
mhfu.on_quest_targets_building(function(quest)
  if quest == 0 then return end
  if mhfu.quest_has(quest, mhfu.MON_GIADROME)
     and mhfu.quest_replace_monster(quest, mhfu.MON_GIADROME, mhfu.MON_TIGREX) then
    mhfu.log("[tighunt] giadrome -> tigrex")
  end
end)

mhfu.on_bigmonster_spawn(function(ent, mtype, slot, hp)
  if mtype ~= mhfu.MON_TIGREX then return end
  mhfu.entity_wrap(ent):set_size(TIGREX_SIZE)
  mhfu.log(string.format("[tighunt] spawn ent=0x%08X hp=%d", ent, hp))
end)

-- neutralise any stale action-force closure from a previous hot-reload
mhfu.on_bigmonster_action(function(ctx) return ctx.action_id end, 100)

local tk        = 0
local last_area = -1
local aggro_qt0 = nil   -- quest timer when he reached the player's section
local forced    = false

function mhfu_tick()
  mhfu.world.paint_map()          -- paintball the boss on the minimap
  tk = tk + 1

  if not mhfu.world.in_area() then last_area = -1; return end

  local tig    = mhfu.world.first(mhfu.MON_TIGREX)
  if not tig then return end
  local player = mhfu.world.player()
  local parea  = mhfu.world.area()
  local d      = tig:dist_to(player)

  -- On entering a new section: bring him here, park near the player, restart clock.
  if parea ~= last_area then
    last_area = parea
    tig:teleport_near(player, NEAR_OFFSET)
    aggro_qt0 = mhfu.world.quest_timer()
    forced = false
    mhfu.log(string.format("[tighunt] roamed to section %d, parked near you; 30s clock", parea))
  end

  -- Keep him visible while co-located; recall him if he wanders off.
  if d < COLOC then tig:make_visible() end
  if d > FAR_RECALL then tig:teleport_near(player, NEAR_OFFSET) end

  -- 30 s elapsed and still not engaged on his own -> FORCE the hunt at you.
  if (not tig:engaged()) and aggro_qt0 then
    local elapsed = aggro_qt0 - mhfu.world.quest_timer()   -- timer decrements
    if elapsed >= AGGRO_DELAY then
      if not forced then mhfu.log("[tighunt] 30s up -> FORCING the hunt!"); forced = true end
      tig:force_aggro(player)
      if d > MELEE_KEEP then tig:teleport_near(player, MELEE_KEEP * 0.6) end
    end
  end

  if tk % HEARTBEAT == 0 then
    mhfu.log(string.format("[tighunt] hb area=%d dist=%.0f engaged=%s ai=%d forced=%s",
      parea, d, tostring(tig:engaged()), tig:ai_state(), tostring(forced)))
  end
end

mhfu.log("[tighunt] registered — Tigrex hunts you in your section; forces aggro after 30s")
