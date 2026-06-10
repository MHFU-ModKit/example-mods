-- tigrex_ontop.lua — ADD a Tigrex ON TOP of the native Giadrome (2 big monsters).
--
-- Uses the Section-38 cap finding: a quest holds up to TWO big-monster groups
-- (Quest.targets[2]) gated by Quest+0x67C. mhfu.quest_add_monster() appends a
-- Tigrex list-A node (engine loads its model natively, Section 31) and the
-- framework's buildTargets postfix wires it into target[1] + sets Quest+0x67C=2.
--
-- Then: Tigrex sized 0.3, brought to the player's field section (section-1
-- reachable via spawn-native-then-RELOCATE, Section 33), and both bosses
-- painted on the minimap.
--
-- Target quest: 2-star #4 = the native Giadrome hunt (detected by emId, not id).
-- COLD BOOT required (PRX + scripts load on cold boot only).

------------------------------------------------------------------------ CONFIG
local TIGREX_SIZE   = 0.3
local BASECAMP_AREA = 98        -- field section ids are NOT sequential (sec1=99)
local COLOC_DIST    = 6000.0
local TP_OFFSET     = 600.0
local HEARTBEAT     = 8
local PLAYER_POS    = 0x09998D50
local OFF_POS       = 0x200
local OFF_SECTION   = 0x29A
local OFF_FLAGS638  = 0x638
local OFF_DRAWFLAG  = 0x004
local OFF_AISTATE   = 0x334
local OFF_FRAME     = 0x092
--------------------------------------------------------------------------------

local MON_GIADROME = mhfu.MON_GIADROME
local MON_TIGREX   = mhfu.MON_TIGREX

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
  local exp  = math.floor(math.log(f, 2.0))
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

local function make_visible(ent, parea)
  if mhfu.read_u16(ent + OFF_SECTION) ~= parea then
    mhfu.write_u16(ent + OFF_SECTION, parea)
  end
  local fl = mhfu.read_u32(ent + OFF_FLAGS638)
  if (fl & 0x8000) == 0 then mhfu.write_u32(ent + OFF_FLAGS638, fl | 0x8000) end
end

-- ADD Tigrex on top of Giadrome, before the loading-screen model load.
mhfu.on_quest_targets_building(function(quest)
  if quest == 0 then return end
  if mhfu.quest_has(quest, MON_GIADROME) and not mhfu.quest_has(quest, MON_TIGREX) then
    if mhfu.quest_add_monster(quest, MON_TIGREX) then   -- x,z omitted => clone Giadrome's section
      mhfu.log("[tigtop] added Tigrex on top of Giadrome (2 big monsters)")
    else
      mhfu.log("[tigtop] quest_add_monster FAILED")
    end
  end
end)

mhfu.on_bigmonster_spawn(function(ent, mtype, slot, hp)
  if mtype ~= MON_TIGREX then return end
  mhfu.entity_set_size(ent, TIGREX_SIZE)
  mhfu.log(string.format("[tigtop] Tigrex spawned ent=0x%08X hp=%d sec=%d size=%.2f",
    ent, hp, mhfu.read_u16(ent + OFF_SECTION), TIGREX_SIZE))
end)

-- drop any stale action-force closure from a previous hot-reload
mhfu.on_bigmonster_action(function(ctx) return ctx.action_id end, 100)

local tk = 0
local last_tp_area = -1

function mhfu_tick()
  mhfu.write_u8(0x090B3A6A, 0xFF)         -- paintball ALL bosses on the minimap
  tk = tk + 1

  local list = mhfu.entities_of_type(MON_TIGREX)
  local ent  = list and list[1]
  if not ent or ent == 0 then return end

  local parea = mhfu.get_area_index()
  local scr   = mhfu.get_screen_state()

  -- bring the Tigrex to each field section the player enters (incl. section 1)
  if scr ~= 17 or parea == BASECAMP_AREA then
    last_tp_area = -1
  elseif parea ~= last_tp_area then
    local px, py, pz = read_f(PLAYER_POS), read_f(PLAYER_POS + 4), read_f(PLAYER_POS + 8)
    write_f(ent + OFF_POS,     px + TP_OFFSET)
    write_f(ent + OFF_POS + 4, py)
    write_f(ent + OFF_POS + 8, pz)
    make_visible(ent, parea)
    last_tp_area = parea
    mhfu.log(string.format("[tigtop] Tigrex brought to your section %d near (%.0f,%.0f)", parea, px, pz))
  end

  local px, pz = read_f(PLAYER_POS), read_f(PLAYER_POS + 8)
  local mx, mz = read_f(ent + OFF_POS), read_f(ent + OFF_POS + 8)
  local dx, dz = px - mx, pz - mz
  if dx*dx + dz*dz < COLOC_DIST * COLOC_DIST then make_visible(ent, parea) end

  if tk % HEARTBEAT == 0 then
    local draw = mhfu.read_u32(ent + OFF_DRAWFLAG)
    local ai   = mhfu.read_u8(ent + OFF_AISTATE)
    mhfu.log(string.format("[tigtop] hb parea=%d sec=%d skipdraw=%d ai=%d pos(%.0f,%.0f)",
      parea, mhfu.read_u16(ent + OFF_SECTION), (draw & 0x4), ai, mx, mz))
  end
end

mhfu.log("[tigtop] registered — Tigrex ON TOP of Giadrome, size 0.3, section 1, paintball")
