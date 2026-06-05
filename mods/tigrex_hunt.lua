-- tigrex_hunt.lua — "the hunter comes to YOU" (a fun one, hehe).
--
-- * Swaps the Giadrome for a Tigrex and shrinks him to 0.3.
-- * Roams him to whatever section the player is in (basecamp first), parks him near
--   the player, and lets him fly in / land / aggro naturally if the zone allows.
-- * If after 30 s he still hasn't engaged on his own, FORCES the aggro at the player.
--
-- The forced aggro uses the real engage mechanism (Section 33g): the engine sets engage
-- via a per-frame quad sv.q (fn 0x09AC6040) that writes monster+0x5D0..+0x5DF =
-- {pursuit vec3 at +0x5D0, engage flag 1.0 at +0x5DC}. In a non-combat zone (basecamp)
-- its target-resolver gate returns null, so that sv.q never runs -> our forced
-- +0x5D0 vec3 (toward the player) + +0x5DC=1.0 stick. We re-park him in melee range so
-- he actually swings.
--
-- Cold boot only (savestate bypasses the PRX/lua). Keep this the ONLY active .lua.

------------------------------------------------------------------------ CONFIG
local TIGREX_SIZE   = 0.3
local NEAR_OFFSET   = 500.0     -- park him this far (+X) from the player
local COLOC         = 6000.0    -- "same area" radius
local FAR_RECALL    = 7000.0    -- re-park him if he wanders past this
local AGGRO_DELAY   = 900       -- 30 s @ 30 Hz (quest timer ticks)
local MELEE_KEEP    = 900.0     -- after forcing, keep him within this so he can attack
local HEARTBEAT     = 30

local PLAYER_POS = 0x09998D50
local OFF_POS      = 0x200       -- world pos vec3 f32
local OFF_SECTION  = 0x29A       -- u16 monster section (visibility gate A)
local OFF_FLAGS638 = 0x638       -- bit 0x8000 = visibility gate B
local OFF_ENGAGE   = 0x05DC      -- f32 engage flag (1.0 = aggro)
local OFF_PURSUIT  = 0x05D0      -- f32x3 pursuit/target vec3 (written with engage)
local OFF_AISTATE  = 0x334       -- ai_state (2 = engaged)
local OFF_ACQUIRE  = 0x2A4       -- u8 target-acquired
--------------------------------------------------------------------------------

local MON_GIADROME = mhfu.MON_GIADROME
local MON_TIGREX   = mhfu.MON_TIGREX
local ENGAGE_BITS  = 0x3F800000  -- 1.0f

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

local function park(ent, px, py, pz, off)
  write_f(ent + OFF_POS,     px + off)
  write_f(ent + OFF_POS + 4, py)
  write_f(ent + OFF_POS + 8, pz)
end

-- Swap Giadrome -> Tigrex at native coords (full provisioning).
mhfu.on_quest_targets_building(function(quest)
  if quest == 0 then return end
  if mhfu.quest_has(quest, MON_GIADROME) and mhfu.quest_replace_monster(quest, MON_GIADROME, MON_TIGREX) then
    mhfu.log("[tighunt] giadrome -> tigrex")
  end
end)

mhfu.on_bigmonster_spawn(function(ent, mtype, slot, hp)
  if mtype ~= MON_TIGREX then return end
  mhfu.entity_set_size(ent, TIGREX_SIZE)
  mhfu.log(string.format("[tighunt] spawn ent=0x%08X hp=%d", ent, hp))
end)

-- neutralise any stale action-force closure from a previous hot-reload
mhfu.on_bigmonster_action(function(ctx) return ctx.action_id end, 100)

local tk           = 0
local last_area    = -1
local aggro_qt0    = nil   -- quest timer when he reached the player's section
local forced       = false

function mhfu_tick()
  mhfu.write_u8(0x090B3A6A, 0xFF)   -- paintball the boss on the minimap
  tk = tk + 1

  local list = mhfu.entities_of_type(MON_TIGREX)
  local ent  = list and list[1]
  if not ent or ent == 0 then return end

  local scr   = mhfu.get_screen_state()
  local parea = mhfu.get_area_index()
  if scr ~= 17 then last_area = -1; return end   -- not in an area (loading/menu)

  local px, py, pz = read_f(PLAYER_POS), read_f(PLAYER_POS+4), read_f(PLAYER_POS+8)
  local mx, my, mz = read_f(ent + OFF_POS), read_f(ent + OFF_POS+4), read_f(ent + OFF_POS+8)
  local d = math.sqrt((px-mx)^2 + (pz-mz)^2)

  -- On entering a new section: bring him here, park near the player, restart the clock.
  if parea ~= last_area then
    last_area = parea
    park(ent, px, py, pz, NEAR_OFFSET)
    make_visible(ent, parea)
    aggro_qt0 = mhfu.get_quest_timer()
    forced = false
    mhfu.log(string.format("[tighunt] roamed to section %d, parked near you; 30s aggro clock started", parea))
  end

  -- Keep him visible while co-located; recall him if he wanders off.
  if d < COLOC then make_visible(ent, parea) end
  if d > FAR_RECALL then park(ent, px, py, pz, NEAR_OFFSET); make_visible(ent, parea) end

  local eng = mhfu.read_u32(ent + OFF_ENGAGE)
  local engaged = (eng == ENGAGE_BITS)

  -- 30 s elapsed and still not engaged on his own -> FORCE the aggro at you.
  if (not engaged) and aggro_qt0 then
    local elapsed = aggro_qt0 - mhfu.get_quest_timer()   -- quest timer decrements
    if elapsed >= AGGRO_DELAY then
      if not forced then mhfu.log("[tighunt] 30s up, no natural aggro -> FORCING the hunt!"); forced = true end
      -- pursuit vec3 toward you + engage + engaged state (the engine won't overwrite
      -- these when its own sv.q gate fails, e.g. in basecamp)
      write_f(ent + OFF_PURSUIT,     px - mx)
      write_f(ent + OFF_PURSUIT + 4, py - my)
      write_f(ent + OFF_PURSUIT + 8, pz - mz)
      mhfu.write_u32(ent + OFF_ENGAGE, ENGAGE_BITS)
      mhfu.write_u16(ent + OFF_AISTATE, 2)
      mhfu.write_u8(ent + OFF_ACQUIRE, 1)
      -- keep him in melee range so he actually swings
      if d > MELEE_KEEP then park(ent, px, py, pz, MELEE_KEEP * 0.6); make_visible(ent, parea) end
    end
  end

  if tk % HEARTBEAT == 0 then
    mhfu.log(string.format("[tighunt] hb area=%d dist=%.0f engage=0x%08X ai=%d forced=%s",
      parea, d, eng, mhfu.read_u8(ent + OFF_AISTATE), tostring(forced)))
  end
end

mhfu.log("[tighunt] registered — Tigrex hunts you in your section; forces aggro after 30s")
