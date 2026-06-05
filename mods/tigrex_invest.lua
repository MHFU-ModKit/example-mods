-- tigrex_invest.lua — INVESTIGATION scenario for the FPU-breakpoint fork.
--
-- Goal: cold-boot into snow section 1 with a Tigrex that NATIVELY aggros the
-- player, held stable so we can FPU-breakpoint the engage write (+0x05DC 0->1.0).
--
-- Does ONLY what's needed, no forced-gate noise (so the aggro/engage is genuine):
--   * swap Giadrome -> Tigrex at native coords (full provisioning: model+AI+draw)
--   * size 0.3
--   * on each field-section entry, relocate him next to the player (carries his
--     attached AI -> he aggros natively in section 1) + apply the +0x29A visibility fix
--   * FREEZE player HP so his hits can't kill/knock the player back to basecamp
--   * paintball minimap
--
-- Cold boot only (savestate bypasses the PRX/lua). Keep this the ONLY active .lua.

local TIGREX_SIZE  = 0.3
local BASECAMP_AREA = 98
local COLOC        = 6000.0
local TP_OFFSET    = 1000.0     -- relocate him this far from the player ONCE, then
                                -- leave him FREE to do his fly-in + land + aggro
                                -- entry (pinning him traps his pre-entry state and
                                -- the engine resets him back -> never engages)
local PLAYER_POS   = 0x09998D50
local HP_CUR       = 0x090B3724      -- u16 current HP
local HP_MAX       = 0x090B385E      -- u16 max HP
local OFF_POS      = 0x200
local OFF_SECTION  = 0x29A
local OFF_FLAGS638 = 0x638
local OFF_ENGAGE   = 0x05DC
local OFF_AISTATE  = 0x334
local HEARTBEAT    = 6

local MON_GIADROME = mhfu.MON_GIADROME
local MON_TIGREX   = mhfu.MON_TIGREX

local function u32_to_float(u)
  if u == 0 then return 0.0 end
  local s = (u >> 31) == 1 and -1.0 or 1.0
  local e = (u >> 23) & 0xFF
  local m = u & 0x7FFFFF
  if e == 0   then return s * m * (2.0 ^ -149) end
  if e == 255 then return s * math.huge end
  return s * (1.0 + m * (2.0 ^ -23)) * (2.0 ^ (e - 127))
end
local function float_to_u32(f)
  if f ~= f then return 0x7FC00000 end
  if f == 0.0 then return 0 end
  local s = 0
  if f < 0.0 then s = 0x80000000; f = -f end
  local e = math.floor(math.log(f, 2.0))
  local m = f / (2.0 ^ e)
  while m >= 2.0 do m = m/2.0; e = e+1 end
  while m <  1.0 do m = m*2.0; e = e-1 end
  local E = e + 127
  if E >= 255 then return s | 0x7F800000 end
  if E <= 0   then return s end
  local mm = math.floor((m - 1.0) * 8388608.0 + 0.5)
  if mm >= 8388608 then mm = mm-8388608; E = E+1; if E>=255 then return s|0x7F800000 end end
  return (s | (E << 23) | (mm & 0x7FFFFF)) & 0xFFFFFFFF
end
local function read_f(a)  return u32_to_float(mhfu.read_u32(a)) end
local function write_f(a,f) mhfu.write_u32(a, float_to_u32(f)) end

local function make_visible(ent, parea)
  if mhfu.read_u16(ent + OFF_SECTION) ~= parea then mhfu.write_u16(ent + OFF_SECTION, parea) end
  local fl = mhfu.read_u32(ent + OFF_FLAGS638)
  if (fl & 0x8000) == 0 then mhfu.write_u32(ent + OFF_FLAGS638, fl | 0x8000) end
end

mhfu.on_quest_targets_building(function(quest)
  if quest == 0 then return end
  if mhfu.quest_has(quest, MON_GIADROME) and mhfu.quest_replace_monster(quest, MON_GIADROME, MON_TIGREX) then
    mhfu.log("[tiginvest] giadrome -> tigrex")
  end
end)

mhfu.on_bigmonster_spawn(function(ent, mtype, slot, hp)
  if mtype ~= MON_TIGREX then return end
  mhfu.entity_set_size(ent, TIGREX_SIZE)
  mhfu.log(string.format("[tiginvest] spawn ent=0x%08X hp=%d", ent, hp))
end)

mhfu.on_bigmonster_action(function(ctx) return ctx.action_id end, 100)  -- neutralise stale closures

local tk = 0
local last_tp_area = -1

function mhfu_tick()
  mhfu.write_u8(0x090B3A6A, 0xFF)                      -- paintball
  local hpmax = mhfu.read_u16(HP_MAX)                  -- HP freeze (survive aggro)
  if hpmax > 0 then mhfu.write_u16(HP_CUR, hpmax) end
  tk = tk + 1

  local list = mhfu.entities_of_type(MON_TIGREX)
  local ent = list and list[1]
  if not ent or ent == 0 then return end

  local parea = mhfu.get_area_index()
  local scr   = mhfu.get_screen_state()
  local px, py, pz = read_f(PLAYER_POS), read_f(PLAYER_POS+4), read_f(PLAYER_POS+8)
  local mx, mz = read_f(ent + OFF_POS), read_f(ent + OFF_POS+8)

  -- Field section: relocate him next to the player ONCE on entry, then leave him
  -- FREE so he flies in, lands, and aggros naturally (engage 0->1.0). Keep him
  -- visible while co-located, but do NOT pin his position (pinning traps his
  -- pre-entry state and the engine resets him -> no engage).
  if scr == 17 and parea ~= BASECAMP_AREA then
    if parea ~= last_tp_area then
      write_f(ent + OFF_POS, px + TP_OFFSET); write_f(ent + OFF_POS + 4, py); write_f(ent + OFF_POS + 8, pz)
      make_visible(ent, parea)
      last_tp_area = parea
      mhfu.log(string.format("[tiginvest] relocated Tigrex into section %d (free to enter)", parea))
    end
    if (px-mx)*(px-mx) + (pz-mz)*(pz-mz) < COLOC*COLOC then make_visible(ent, parea) end
  else
    last_tp_area = -1
  end

  if tk % HEARTBEAT == 0 then
    mhfu.log(string.format("[tiginvest] hb area=%d engage=0x%08X ai=%d pos=(%.0f,%.0f)",
      parea, mhfu.read_u32(ent + OFF_ENGAGE), mhfu.read_u8(ent + OFF_AISTATE), mx, mz))
  end
end

mhfu.log("[tiginvest] registered — section-1 native-aggro investigation scenario")
