-- tigrex_aggro.lua — TEST RIG: decoded-aggro recipe (Section 33c, 2026-06-05).
--
-- Goal: make a big monster AUTONOMOUSLY aggro + pursue the player in a section he
-- normally won't fight in (esp. BASECAMP), by satisfying the engine's own
-- aggro-eval gates directly instead of scripting pursuit.
--
-- Aggro-eval fn 0x09A66098(monster,a1) runs per-tick and ACQUIRES (sets
-- monster+0x2A4=1 -> engage + native pursuit) only if ALL hold:
--   A) monster+0x29A (u16 section)  == player.area_index   (== get_area_index())
--   B) monster+0x1E6 (u16)          == [player]+0x28 (player section byte)
--   C) combat-enable: [0x09A44C5C]->obj ; obj+0x5C (u8) != 0
--   D) range/target check 0x09A631A8 -> needs [player]+0x6AF14 & 1, a valid target
--      from z_un_088dcebc([0x09A4F0C4]), target HP>0, then dist(monster,target+0x200)
-- player master singleton = 0x089CC438. See memory big-monster-aggro-target.
--
-- This rig FORCES A,B,C,(+0x6AF14 bit for D) every tick and LOGS each gate + the
-- acquire/engage/ai_state so we can see exactly which gate (likely D, the target
-- resolver) still blocks in basecamp. HP is frozen so we survive the test.
--
-- COLD BOOT ONLY (savestate bypasses the PRX/lua framework). Keep this the ONLY
-- .lua in the mods dir (one mhfu_tick); tigrex_section1.lua renamed to .bak.

------------------------------------------------------------------------ CONFIG
local TIGREX_SIZE = 0.3
local TP_OFFSET   = 600.0
local COLOC       = 6000.0
local HEARTBEAT   = 6           -- ~3 s

-- globals
local PLAYER_SINGLETON     = 0x089CC438   -- -> player object
local COMBAT_GATE_GLOBAL   = 0x09A44C5C   -- -> obj ; obj+0x5C = combat-enable u8
local PLAYER_POS           = 0x09998D50   -- player world pos (vec3 f32)
-- player-object offsets
local PL_SEC_BYTE          = 0x28         -- u8 section
local PL_AREA              = 0x6AF0E       -- u16 area_index (== get_area_index())
local PL_TGT_ENABLE        = 0x6AF14       -- u32, bit 0x1 = targeting enable (gate D)
-- monster offsets
local OFF_POS      = 0x200
local OFF_SEC_A    = 0x29A   -- u16 section (gate A + visibility)
local OFF_SEC_B    = 0x1E6   -- u16 (gate B)
local OFF_FLAGS638 = 0x638   -- bit 0x8000 = visibility cond B
local OFF_ACQUIRE  = 0x2A4   -- engine sets =1 on target-acquire
local OFF_ENGAGE   = 0x05DC  -- f32 engage (1.0 when aggro)
local OFF_AISTATE  = 0x334   -- u16/u8 ai_state (2 = engaged)
local OFF_FRAME    = 0x092   -- frame counter
-- player HP (freeze so the test run survives)
local HP_CUR = 0x090B3724
local HP_MAX = 0x090B385E
--------------------------------------------------------------------------------

local MON_GIADROME = mhfu.MON_GIADROME
local MON_TIGREX   = mhfu.MON_TIGREX

local function valid(a) return a ~= 0 and mhfu.mem_valid(a) end

local function u32_to_float(u)
  if u == 0 then return 0.0 end
  local sign = (u >> 31) == 1 and -1.0 or 1.0
  local exp  = (u >> 23) & 0xFF
  local mant = u & 0x7FFFFF
  if exp == 0   then return sign * mant * (2.0 ^ -149) end
  if exp == 255 then return sign * math.huge end
  return sign * (1.0 + mant * (2.0 ^ -23)) * (2.0 ^ (exp - 127))
end
local function float_to_u32(f)
  if f ~= f then return 0x7FC00000 end
  if f == 0.0 then return 0 end
  local sign = 0
  if f < 0.0 then sign = 0x80000000; f = -f end
  local exp = math.floor(math.log(f, 2.0))
  local mant = f / (2.0 ^ exp)
  while mant >= 2.0 do mant = mant / 2.0; exp = exp + 1 end
  while mant <  1.0 do mant = mant * 2.0; exp = exp - 1 end
  local E = exp + 127
  if E >= 255 then return sign | 0x7F800000 end
  if E <= 0   then return sign end
  local m = math.floor((mant - 1.0) * 8388608.0 + 0.5)
  if m >= 8388608 then m = m - 8388608; E = E + 1; if E >= 255 then return sign | 0x7F800000 end end
  return (sign | (E << 23) | (m & 0x7FFFFF)) & 0xFFFFFFFF
end
local function read_f(a)  return u32_to_float(mhfu.read_u32(a)) end
local function write_f(a, f) mhfu.write_u32(a, float_to_u32(f)) end

-- Swap Giadrome -> Tigrex at native coords (full provisioning).
mhfu.on_quest_targets_building(function(quest)
  if quest == 0 then return end
  if mhfu.quest_has(quest, MON_GIADROME)
     and mhfu.quest_replace_monster(quest, MON_GIADROME, MON_TIGREX) then
    mhfu.log("[tigaggro] giadrome -> tigrex")
  end
end)

mhfu.on_bigmonster_spawn(function(ent, mtype, slot, hp)
  if mtype ~= MON_TIGREX then return end
  mhfu.entity_set_size(ent, TIGREX_SIZE)
  mhfu.log(string.format("[tigaggro] spawn ent=0x%08X hp=%d", ent, hp))
end)

-- neutralise any stale action-force closure from a previous hot-reload
mhfu.on_bigmonster_action(function(ctx) return ctx.action_id end, 100)

local tk = 0
local last_tp_area = -1

function mhfu_tick()
  mhfu.write_u8(0x090B3A6A, 0xFF)   -- paintball minimap

  -- HP freeze (survive the test)
  local hpmax = mhfu.read_u16(HP_MAX)
  if hpmax > 0 then mhfu.write_u16(HP_CUR, hpmax) end

  tk = tk + 1
  local list = mhfu.entities_of_type(MON_TIGREX)
  local ent  = list and list[1]
  if not ent or ent == 0 then return end

  local parea = mhfu.get_area_index()
  local pp = mhfu.read_u32(PLAYER_SINGLETON)
  local psec = (valid(pp + PL_SEC_BYTE)) and mhfu.read_u8(pp + PL_SEC_BYTE) or 0

  -- bring the Tigrex to the player's section on entry (edge-trigger)
  if parea ~= last_tp_area and parea ~= 0 then
    local px, py, pz = read_f(PLAYER_POS), read_f(PLAYER_POS + 4), read_f(PLAYER_POS + 8)
    write_f(ent + OFF_POS,     px + TP_OFFSET)
    write_f(ent + OFF_POS + 4, py)
    write_f(ent + OFF_POS + 8, pz)
    last_tp_area = parea
    mhfu.log(string.format("[tigaggro] tp Tigrex to section %d", parea))
  end

  -- ===== FORCE the aggro-eval gates =====
  mhfu.write_u16(ent + OFF_SEC_A, parea)           -- gate A (+ visibility A)
  mhfu.write_u16(ent + OFF_SEC_B, psec)            -- gate B
  local fl = mhfu.read_u32(ent + OFF_FLAGS638)
  if (fl & 0x8000) == 0 then mhfu.write_u32(ent + OFF_FLAGS638, fl | 0x8000) end  -- visibility B
  -- gate C: combat-enable
  local cg = mhfu.read_u32(COMBAT_GATE_GLOBAL)
  if valid(cg + 0x5C) then mhfu.write_u8(cg + 0x5C, 1) end
  -- gate D: helper 0x09A631A8 BAILS (returns 0, no target) when [player]+0x6AF14
  -- bit0 is SET — it's a "no-target / safe-zone" flag (basecamp sets it; also
  -- locks player control/camera). CLEAR it so the target resolver runs.
  if valid(pp + PL_TGT_ENABLE) then
    local te = mhfu.read_u32(pp + PL_TGT_ENABLE)
    if (te & 1) == 1 then mhfu.write_u32(pp + PL_TGT_ENABLE, te & 0xFFFFFFFE) end
  end

  -- heartbeat: did the engine ACQUIRE? + which gates currently hold
  if tk % HEARTBEAT == 0 then
    local acq = mhfu.read_u8(ent + OFF_ACQUIRE)
    local eng = mhfu.read_u32(ent + OFF_ENGAGE)
    local ai  = mhfu.read_u8(ent + OFF_AISTATE)
    local fr  = mhfu.read_u8(ent + OFF_FRAME)
    local cgv = valid(cg + 0x5C) and mhfu.read_u8(cg + 0x5C) or -1
    local pa  = valid(pp + PL_AREA) and mhfu.read_u16(pp + PL_AREA) or -1
    local te  = valid(pp + PL_TGT_ENABLE) and (mhfu.read_u32(pp + PL_TGT_ENABLE) & 1) or -1
    mhfu.log(string.format(
      "[tigaggro] hb area=%d psec=%d | secA=%d secB=%d combat=%d tgtEn=%d plArea=%d | ACQUIRE=%d engage=0x%08X ai=%d fr=%d",
      parea, psec,
      mhfu.read_u16(ent + OFF_SEC_A), mhfu.read_u16(ent + OFF_SEC_B), cgv, te, pa,
      acq, eng, ai, fr))
  end
end

mhfu.log("[tigaggro] registered — autonomous-aggro recipe test (Section 33c)")
