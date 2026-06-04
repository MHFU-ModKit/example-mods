-- tigrex_section1.lua — EXPERIMENT: can a big monster live in snow section 1?
--
-- Swap Giadrome->Tigrex, size 0.3, and once the player reaches snow section 1
-- (area_index 99) teleport the Tigrex next to the player ONE time, then apply the
-- +0x29A visibility fix (Section 33) and leave him alone. Heartbeat logs whether
-- he's actually TICKING (frame counter +0x092 advancing) and his AI state
-- (+0x334) so we can tell "visible statue" from "fully working monster".
--
-- Section 1 historically had no big-monster spawn tile / AI attach (a forced
-- section-1 Tigrex was invisible + inert). The +0x29A fix solves visibility; this
-- mod tests whether ticking/AI also work now.
--
-- HOT-RELOAD: edit on the memstick, ~0.5s, no cold boot. Use this file ALONE
-- (move tigrex_spin.lua out of the mods dir — only one mhfu_tick can be active).

------------------------------------------------------------------------ CONFIG
local TIGREX_SIZE  = 0.3
local BASECAMP_AREA = 98       -- the only in-area zone we DON'T summon him to
                               -- (field section area_index is NOT sequential:
                               --  sec1=99, sec6=100, sec5=93 — basecamp sits among them)
local COLOC_DIST   = 6000.0    -- world units; co-location => same section
local TP_OFFSET    = 600.0     -- place him this far (+X) from the player
local HEARTBEAT    = 8         -- ~4 s (worker ~2 Hz)
local PLAYER_POS   = 0x09998D50 -- camera target == player world pos (vec3 f32)
local OFF_POS      = 0x200      -- entity world pos vec3 f32
local OFF_SECTION  = 0x29A      -- u16 monster section index (visibility gate A)
local OFF_FLAGS638 = 0x638      -- bit 0x8000 = gate B
local OFF_DRAWFLAG = 0x004      -- bit 0x4 = engine skip-draw (output)
local OFF_AISTATE  = 0x334      -- AI state byte ({1,2,5,10}=active; 0=inert)
local OFF_FRAME    = 0x092      -- frame counter (advances if ticking)
--------------------------------------------------------------------------------

local MON_GIADROME = mhfu.MON_GIADROME
local MON_TIGREX   = mhfu.MON_TIGREX

-- u32 bits -> IEEE-754 single
local function u32_to_float(u)
  if u == 0 then return 0.0 end
  local sign = (u >> 31) == 1 and -1.0 or 1.0
  local exp  = (u >> 23) & 0xFF
  local mant = u & 0x7FFFFF
  if exp == 0   then return sign * mant * (2.0 ^ -149) end
  if exp == 255 then return sign * math.huge end
  return sign * (1.0 + mant * (2.0 ^ -23)) * (2.0 ^ (exp - 127))
end
-- IEEE-754 single -> u32 bits
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
  local m = math.floor((mant - 1.0) * 8388608.0 + 0.5)  -- 2^23
  if m >= 8388608 then m = m - 8388608; E = E + 1; if E >= 255 then return sign | 0x7F800000 end end
  return (sign | (E << 23) | (m & 0x7FFFFF)) & 0xFFFFFFFF
end
local function read_f(a)  return u32_to_float(mhfu.read_u32(a)) end
local function write_f(a, f) mhfu.write_u32(a, float_to_u32(f)) end

local function make_visible(ent, parea)
  if mhfu.read_u16(ent + OFF_SECTION) ~= parea then
    mhfu.write_u16(ent + OFF_SECTION, parea)            -- gate cond A
  end
  local fl = mhfu.read_u32(ent + OFF_FLAGS638)
  if (fl & 0x8000) == 0 then mhfu.write_u32(ent + OFF_FLAGS638, fl | 0x8000) end  -- cond B
end

-- Swap Giadrome -> Tigrex at native coords before the loading-screen model load.
mhfu.on_quest_targets_building(function(quest)
  if quest == 0 then return end
  if mhfu.quest_has(quest, MON_GIADROME)
     and mhfu.quest_replace_monster(quest, MON_GIADROME, MON_TIGREX) then
    mhfu.log("[tigsec1] giadrome -> tigrex")
  end
end)

mhfu.on_bigmonster_spawn(function(ent, mtype, slot, hp)
  if mtype ~= MON_TIGREX then return end
  mhfu.entity_set_size(ent, TIGREX_SIZE)
  mhfu.log(string.format("[tigsec1] spawn ent=0x%08X hp=%d sec=%d (will teleport to section 1)",
    ent, hp, mhfu.read_u16(ent + OFF_SECTION)))
end)

-- neutralise any stale action-force closure from a previous hot-reload
mhfu.on_bigmonster_action(function(ctx) return ctx.action_id end, 100)

local tk           = 0
local last_tp_area = -1   -- player area at last teleport (edge-trigger per section)
local tp_frame0    = nil  -- frame counter at teleport, to measure ticking

function mhfu_tick()
  mhfu.write_u8(0x090B3A6A, 0xFF)   -- paintball the boss on the minimap
  tk = tk + 1

  local list = mhfu.entities_of_type(MON_TIGREX)
  local ent  = list and list[1]
  if not ent or ent == 0 then return end

  local parea = mhfu.get_area_index()
  local scr   = mhfu.get_screen_state()

  -- EDGE-TRIGGER: each time the player ENTERS a new field section (in-area), bring
  -- the Tigrex to that section ~600u away. Reset latch outside field sections /
  -- during loads so re-entering re-teleports. He then roams/attacks freely within
  -- the section (we don't pin him every frame).
  if scr ~= 17 or parea == BASECAMP_AREA then
    last_tp_area = -1   -- in basecamp / loading: arm the next field entry
  elseif parea ~= last_tp_area then
    local px, py, pz = read_f(PLAYER_POS), read_f(PLAYER_POS + 4), read_f(PLAYER_POS + 8)
    write_f(ent + OFF_POS,     px + TP_OFFSET)
    write_f(ent + OFF_POS + 4, py)
    write_f(ent + OFF_POS + 8, pz)
    make_visible(ent, parea)
    last_tp_area = parea
    tp_frame0    = mhfu.read_u8(ent + OFF_FRAME)
    mhfu.log(string.format("[tigsec1] brought Tigrex to your section %d near (%.0f,%.0f)", parea, px, pz))
  end

  -- keep him visible while co-located (writes only the section cell, not position,
  -- so it does NOT mask his own AI movement)
  local px, pz = read_f(PLAYER_POS), read_f(PLAYER_POS + 8)
  local mx, mz = read_f(ent + OFF_POS), read_f(ent + OFF_POS + 8)
  local dx, dz = px - mx, pz - mz
  if dx*dx + dz*dz < COLOC_DIST * COLOC_DIST then make_visible(ent, parea) end

  -- heartbeat: is he VISIBLE (bit0x4 clear) and TICKING (frame advancing) + AI alive?
  if tk % HEARTBEAT == 0 then
    local fr   = mhfu.read_u8(ent + OFF_FRAME)
    local draw = mhfu.read_u32(ent + OFF_DRAWFLAG)
    local ai   = mhfu.read_u8(ent + OFF_AISTATE)
    local sec  = mhfu.read_u16(ent + OFF_SECTION)
    local tick = (tp_frame0 ~= nil) and ((fr - tp_frame0) & 0xFF) or 0
    mhfu.log(string.format(
      "[tigsec1] hb parea=%d sec=%d skipdraw=%d ai_state=%d frame=%d (+%d since tp) pos(%.0f,%.0f)",
      parea, sec, (draw & 0x4), ai, fr, tick, mx, mz))
  end
end

mhfu.log("[tigsec1] registered — section-1 Tigrex experiment")
