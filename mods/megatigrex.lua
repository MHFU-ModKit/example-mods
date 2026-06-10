-- megatigrex.lua — MEGA TIGREX SWARM
--
-- On any quest that has EXACTLY ONE big-monster target, spawn a swarm of 10
-- mini-Tigrex (random size 0.2..0.4) and paint them on the minimap.
--
-- HOW IT BUILDS ON WHAT WE LEARNED
--   * One Tigrex must be RESIDENT to clone from. If the quest already has a
--     Tigrex we use it; otherwise we ADD a Tigrex alongside the native monster
--     (mhfu.quest_add_monster — §48), so e.g. a Giadrome quest becomes
--     "1 Giadrome + 10 Tigrex". (Flip KEEP_NATIVE=false to REPLACE instead.)
--   * The swarm is CHEAP: all 10 share the one resident model/overlay/species
--     block — only the ~31 KB entity struct is duplicated. mhfu.entity_clone()
--     deep-copies + rebases self-ptrs + splices into the engine update chain +
--     registry (memory tigrex-clone-recipe). Clones live in the memory=64 extra
--     RAM (0x0A800000+), so the tiny managed partition isn't starved.
--   * A cloned big monster has NO engine manager driving it, and section
--     transitions rebuild the update chain and ORPHAN the clones (they freeze).
--     So we SHEPHERD them every tick: re-splice any orphan onto the live native
--     Tigrex's +0x1C4 chain + sync its +0x29A section (visibility + ticking).
--     Verified live: re-attaching an orphan flips it from frozen to ticking.
--
-- DEPLOY: ms0:/PSP/PLUGINS/mhfu_framework/mods/megatigrex.lua  (+ cold boot once
-- for the entity_clone C binding). Hot-reload works for tweaks after that.

------------------------------------------------------------------------ CONFIG
local CFG = {
  COUNT       = 10,        -- total Tigrex in the swarm
  SIZE_MIN    = 0.2,
  SIZE_MAX    = 0.4,
  SPREAD      = 1400.0,    -- ring radius we home the swarm on (around the native)
  COLOC       = 9000.0,    -- deploy once you're within this of the native Tigrex
  KEEP_NATIVE = true,      -- true = ADD Tigrex (keep native); false = REPLACE
  AGGRO       = false,     -- true = the swarm hunts you (HP freeze recommended)
  FREEZE_HP   = true,      -- pin player HP to max each tick (one-shot insurance)
}
--------------------------------------------------------------------------------

-- entity offsets
local NEXTOBJ, PREVOBJ, SECTION, AISTATE = 0x1C4, 0x1C8, 0x29A, 0x334
local HP_CUR, HP_MAX = 0x090B3724, 0x090B385E
local LO_END  = 0x0A000000          -- native is below this; clones are above
local RAM_END = 0x0C000000
local TIGREX  = mhfu.MON.TIGREX
local IN_AREA = 17

-- State in a GLOBAL table so a hot-reload (re-execs this chunk) keeps the
-- swarm we already built + the quest's `armed` decision. Backfill each field so
-- a global persisted under an older schema can't leave a nil (nil-index crash).
megatigrex_state = megatigrex_state or {}
local S = megatigrex_state
if S.armed    == nil then S.armed    = false end
if S.deployed == nil then S.deployed = false end
S.clones = S.clones or {}
S.homed  = S.homed  or {}

local detach_all   -- forward decl (defined below; referenced by the death hook)

-- Hot-reload / savestate bootstrap: the quest event runs once at quest begin
-- and won't re-fire, and a previous build may have cloned without recording the
-- pointers. So whenever our clone list is empty but Tigrex already live up in
-- extra RAM, recover them from the world (regardless of `armed`) so shepherd()
-- can adopt the existing swarm after a hot-reload.
if #S.clones == 0 then
  for _, p in ipairs(mhfu.entities_of_type(TIGREX)) do
    if p >= LO_END then S.clones[#S.clones + 1] = p end   -- clones = extra-RAM ones
  end
  if #S.clones > 0 then
    S.armed, S.deployed, S.homed = true, true, {}
    mhfu.log(string.format("[megatigrex] recovered %d existing clones from the world", #S.clones))
  end
end

-------------------------------------------------------- gate + ensure resident
mhfu.on_quest_targets_building(function(quest)
  S.armed, S.deployed, S.clones, S.homed = false, false, {}, {}
  if quest == 0 then return end

  local n = mhfu.quest_monster_count(quest)
  if n ~= 1 then
    mhfu.log(string.format("[megatigrex] skip: quest has %d big monsters (need exactly 1)", n))
    return
  end

  if mhfu.quest_has(quest, TIGREX) then
    mhfu.log("[megatigrex] native Tigrex present — will clone it"); S.armed = true
  elseif CFG.KEEP_NATIVE then
    if mhfu.quest_add_monster(quest, TIGREX, 0, 0) then
      mhfu.log("[megatigrex] added a Tigrex alongside the native monster"); S.armed = true
    else
      mhfu.log("[megatigrex] quest_add_monster failed — set KEEP_NATIVE=false to replace")
    end
  else
    local from = mhfu.quest_first_monster(quest)
    if from >= 0 and mhfu.quest_replace_monster(quest, from, TIGREX) then
      mhfu.log(string.format("[megatigrex] replaced native 0x%02X with Tigrex", from)); S.armed = true
    else
      mhfu.log("[megatigrex] could not retag the native monster")
    end
  end
end)

-- neutralise any stale action-force closure from a previous hot-reload
mhfu.on_bigmonster_action(function(ctx) return ctx.action_id end, 100)

-- Detach the swarm the instant a big monster dies (fires on the poll thread,
-- before the quest-end teardown walks the chain). Belt-and-suspenders with the
-- area-exit guard in mhfu_tick — whichever sees it first unlinks the clones.
mhfu.on_bigmonster_death(function(ent)
  -- only the native (low RAM) dying ends the quest; clones are extra-RAM
  if ent and ent < LO_END and S.deployed and detach_all then detach_all() end
end)

------------------------------------------------------------- find the native
-- The native Tigrex is the engine-driven one (lives in low RAM; clones are the
-- ones we put up in extra RAM).
local function native_tigrex()
  for _, p in ipairs(mhfu.entities_of_type(TIGREX)) do
    if p < LO_END then return p end
  end
  return nil
end

------------------------------------------------------------------- swarm build
local function build_swarm(src)
  math.randomseed((mhfu.get_quest_timer() or 0) + 1)
  -- the native becomes member #1 (just mini-sized; the engine already drives it)
  local sz1 = CFG.SIZE_MIN + math.random() * (CFG.SIZE_MAX - CFG.SIZE_MIN)
  mhfu.entity_set_size(src, sz1)
  mhfu.log(string.format("[megatigrex] member 1/%d (native) size=%.2f", CFG.COUNT, sz1))
  -- clone the rest into extra RAM; shepherd() homes + wakes them
  for i = 1, CFG.COUNT - 1 do
    local c = mhfu.entity_clone(src)
    if not c or c == 0 then
      mhfu.log(string.format("[megatigrex] clone %d failed (RAM/registry full) — stopping", i + 1))
      break
    end
    mhfu.entity_set_size(c, CFG.SIZE_MIN + math.random() * (CFG.SIZE_MAX - CFG.SIZE_MIN))
    S.clones[#S.clones + 1] = c
  end
  mhfu.log(string.format("[megatigrex] cloned %d (total %d Tigrex)", #S.clones, #S.clones + 1))
end

----------------------------------------------------- shepherd (keep them live)
-- Walk the native's update chain; return a membership set + the tail.
local function chain_set_tail(head)
  local set, n = {}, head
  for _ = 1, 80 do
    set[n] = true
    local nx = mhfu.read_u32(n + NEXTOBJ)
    if nx == 0 or nx < 0x08000000 or nx >= RAM_END then return set, n end
    n = nx
  end
  return set, n
end

local function shepherd(nat)
  local natsec = mhfu.read_u16(nat + SECTION)
  local natai  = mhfu.read_u8(nat + AISTATE)
  local nx, ny, nz = mhfu.entity_pos(nat)
  local members, tail = chain_set_tail(nat)
  for i, cp in ipairs(S.clones) do
    if cp and cp ~= 0 then
      mhfu.write_u16(cp + SECTION, natsec)            -- keep in the native's section
      if not members[cp] then                          -- orphaned -> re-attach + wake
        mhfu.write_u32(cp + NEXTOBJ, 0)
        mhfu.write_u32(cp + PREVOBJ, tail)
        mhfu.write_u32(tail + NEXTOBJ, cp)
        mhfu.write_u8(cp + AISTATE, natai)
        tail = cp; members[cp] = true
        if not S.homed[cp] then                        -- first attach: gather near native
          local a = (i / CFG.COUNT) * (2.0 * math.pi)
          mhfu.entity_set_pos(cp, nx + CFG.SPREAD * math.cos(a), ny, nz + CFG.SPREAD * math.sin(a))
          mhfu.entity_make_visible(cp, natsec)
          if CFG.AGGRO then mhfu.entity_force_aggro(cp, mhfu.player_pos()) end
          S.homed[cp] = true
        end
      end
    end
  end
end

--------------------------------------------------------------- teardown safety
-- Splice the clones OUT of the engine update chain + clear their registry slots.
-- The clones are foreign objects we injected; if we leave them in when the quest
-- tears down (native killed / area unload), the engine walks a now-dangling chain
-- and crashes (Read Word at garbage ptr in the manager-drive path). So detach
-- them the moment we're leaving the field or the native is gone. The clone
-- structs live in persistent extra RAM, so this just unlinks — no double-free.
detach_all = function()
  for _, cp in ipairs(S.clones) do
    if cp and cp ~= 0 then
      for s = 1, 20 do
        if mhfu.read_u32(0x09C1213C + s * 4) == cp then mhfu.write_u32(0x09C1213C + s * 4, 0) end
      end
      local prev = mhfu.read_u32(cp + PREVOBJ)
      local nxt  = mhfu.read_u32(cp + NEXTOBJ)
      if prev >= 0x08000000 and prev < RAM_END then mhfu.write_u32(prev + NEXTOBJ, nxt) end
      if nxt  >= 0x08000000 and nxt  < RAM_END then mhfu.write_u32(nxt  + PREVOBJ, prev) end
      mhfu.write_u32(cp + NEXTOBJ, 0)
      mhfu.write_u32(cp + PREVOBJ, 0)
    end
  end
  S.clones, S.homed, S.deployed = {}, {}, false
end

----------------------------------------------------------------------- tick
function mhfu_tick()
  mhfu.paint_map()
  if CFG.FREEZE_HP then
    local mx = mhfu.read_u16(HP_MAX)
    if mx > 0 and mx < 10000 then mhfu.write_u16(HP_CUR, mx) end
  end

  -- teardown safety FIRST: if we've deployed but are leaving the field or the
  -- native is gone, unlink the swarm before the engine tears the quest down.
  if S.deployed and #S.clones > 0 then
    if mhfu.get_screen_state() ~= IN_AREA or not native_tigrex() then
      detach_all()
      mhfu.log("[megatigrex] swarm detached (area exit / native gone) — teardown safe")
      return
    end
  end

  if not S.armed then return end
  if mhfu.get_screen_state() ~= IN_AREA then return end

  local nat = native_tigrex()
  if not nat then return end

  if not S.deployed then
    -- deploy once you've reached the native Tigrex's section (co-located)
    local px, py, pz = mhfu.player_pos()
    local mx, _, mz  = mhfu.entity_pos(nat)
    local dx, dz = px - mx, pz - mz
    if dx * dx + dz * dz > CFG.COLOC * CFG.COLOC then return end
    build_swarm(nat)
    S.deployed = true
    mhfu.log("[megatigrex] swarm deployed")
  end

  shepherd(nat)   -- every tick: keep the clones attached + alive
end

mhfu.log("[megatigrex] registered — single-big-monster quests get 10 mini-Tigrex")
