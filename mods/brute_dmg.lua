-- brute_dmg.lua — a Giadrome quest turned into a DAMAGING ported Brute Tigrex.
--
-- One big monster, no second Tigrex, no target-group tricks:
--   1. REPLACE the quest's Giadrome with Tigrex at QUEST_TARGETS_BUILDING, so
--      the engine natively builds a Tigrex target/manager/collision node.
--   2. RELOCATE-INJECT the ported Brute PAC over file_06185, so that native
--      Tigrex loads the Brute's own skeleton, mesh, textures and animations.
--
-- 🔴 THE RULE THIS SCRIPT EXISTS TO OBEY: do NOT write to the monster every
-- tick. Earlier Brute/Tigrex scripts forced the section tracker (+0x29A), the
-- visibility flag (+0x638), the size and the freeze gate on every tick to fix
-- a spawn-visibility bug. A clean swap with none of that was measured dealing
-- 51/52/11 damage and killing the hunter, which is exactly what those scripts
-- reported as impossible. So the maintenance is OFF by default; MAINTAIN=true
-- turns it back on to reproduce the old broken behaviour on purpose.
--
-- The visibility bug fixes itself: the monster spawns in its own section and
-- ROAMS to the player, and that transition initialises +0x29A naturally. Walk
-- to a section the Tigrex is native to (6, 7, 8, sometimes 3) and wait.

local MON_TIGREX   = mhfu.MON_TIGREX
local MON_GIADROME = mhfu.MON_GIADROME

local INJECT_DIR = "ms0:/PSP/PLUGINS/mhfu_framework/inject"
local BRUTE_PAC  = INJECT_DIR .. "/brute_tigrex_v64_nativeanim.bin"
local ORIG_PAC   = INJECT_DIR .. "/file_06185.bin.orig"
local TIGREX_FID = 6186          -- cosmetic id for file_06185; match is by content

local INJECT_BRUTE = true        -- false = plain native Tigrex (the proven baseline)
local MAINTAIN     = false       -- true = old per-tick render/section/size forcing
local FORCE_ACTION = 0           -- 0 = observe only; forced_attack_test.sh rewrites this line
local LOG_ACTIONS  = true        -- log every action id the AI dispatches (on even while forcing)
-- 🔴 A HELD force does not attack. Rewriting EVERY dispatch to one id was
-- measured on the NATIVE-animation control (v64, a1=48 "bite forward once"):
-- 5155 co-located ticks, closest approach 66 units, ZERO damage and zero
-- trips — while the same build unforced landed a -70. Re-entering the
-- executor with the same id every dispatch appears to restart the move, so
-- it never reaches its hitbox-active frames. PULSE instead: fire once, then
-- hand the id stream back for FORCE_PERIOD ticks so the move plays out.
-- 0 restores the old hold-everything behaviour on purpose.
local FORCE_PERIOD = 8           -- ticks between pulses (~2 ticks/s, so ~4s)

-- 🔴 The player's WORLD position is the combat entity's transform row 3, NOT
-- `mhfu.player_pos()` — that helper reads MHFU_PLAYER_POS 0x09998D50, which is
-- the CAMERA EYE. It is why this probe logged d=26000 for a monster the host-side
-- bot measured at 365 units. (Framework bug; fixing the header needs a PRX
-- rebuild, so the distance is computed locally here.)
local PLAYER_ENT   = 0x090B3440
local OFF_PLAYER_XYZ = 0x40

local OFF_POS      = 0x200
local OFF_SECTION  = 0x29A
local OFF_OUTER    = 0x299
local OFF_INNER    = 0x1D5
local OFF_BC       = 0x0BC
local OFF_ENGAGE   = 0x5DC
local OFF_NODE     = 0x2EC
local OFF_HP       = 0x41E
local OFF_FLAGS638 = 0x638
local OFF_FREEZE   = 0x4B8
local FREEZE_BITS  = 0x100 | 0x10000

-- 🔴 TWO logging traps, both silent:
--   1. mhfu.log takes a SINGLE string — it does not printf, extra args vanish.
--   2. mhfu.log called at SCRIPT LOAD or from an event CALLBACK never reaches
--      framework.log; only the mhfu_tick worker context does. So callbacks push
--      onto a pending queue and the tick drains it.
local PEND, PEND_N = {}, 0
local function log(fmt, ...)
  local line = (select("#", ...) == 0) and fmt or string.format(fmt, ...)
  PEND_N = PEND_N + 1
  PEND[PEND_N] = line
end
local function drain()
  if PEND_N == 0 then return end
  for i = 1, PEND_N do mhfu.log(PEND[i]); PEND[i] = nil end
  PEND_N = 0
end

local function u32_to_float(u)
  if u == 0 then return 0.0 end
  local sign = 1.0; if u >= 0x80000000 then sign = -1.0; u = u - 0x80000000 end
  local exp, mant = (u >> 23) & 0xFF, u & 0x7FFFFF
  if exp == 0   then return sign * mant * (2.0 ^ -149) end
  if exp == 255 then return sign * math.huge end
  return sign * (1.0 + mant * (2.0 ^ -23)) * (2.0 ^ (exp - 127))
end
local function read_f(a) return u32_to_float(mhfu.read_u32(a)) end

-- 1. inject (registered at boot; fires when the quest loads the model) -------
if INJECT_BRUTE then
  local ok = mhfu.inject_relocate(TIGREX_FID, BRUTE_PAC, ORIG_PAC)
  log("[brute] inject_relocate %s fid=%d '%s'", ok and "OK" or "FAILED", TIGREX_FID, BRUTE_PAC)
else
  log("[brute] inject SKIPPED — native Tigrex baseline")
end

-- 2. swap --------------------------------------------------------------------
mhfu.on_quest_targets_building(function(quest)
  log("[brute] TARGETS_BUILDING quest=0x%08X", quest)
  if quest == 0 then return end
  if mhfu.quest_has(quest, MON_GIADROME) then
    if mhfu.quest_replace_monster(quest, MON_GIADROME, MON_TIGREX) then
      log("[brute] SWAP giadrome -> tigrex applied")
    else
      log("[brute] SWAP FAILED")
    end
  else
    log("[brute] no giadrome in this quest — nothing swapped")
  end
end)

-- 3. spawn -------------------------------------------------------------------
local g_ent = 0
mhfu.on_bigmonster_spawn(function(ent, mtype, slot, hp)
  if mtype ~= MON_TIGREX then return end
  g_ent = ent
  log("[brute] SPAWN ent=0x%08X slot=%d hp=%d sec=%d pos=(%d,%d,%d) f638=0x%X",
      ent, slot, hp, mhfu.read_u16(ent+OFF_SECTION),
      math.floor(read_f(ent+OFF_POS)), math.floor(read_f(ent+OFF_POS+4)),
      math.floor(read_f(ent+OFF_POS+8)),
      mhfu.read_u32(ent+OFF_FLAGS638))
  log("[brute] CON joints=%d anim=0x%08X skel=0x%08X",
      mhfu.read_u32(ent+0x1A4), mhfu.read_u32(ent+0x1AC), mhfu.read_u32(ent+0x4C8))
end)

mhfu.on_bigmonster_death(function(ent) if ent == g_ent then g_ent = 0 end end)

-- 4. optional deterministic action forcing ----------------------------------
-- Observe-only action logging. Returning nil from the handler leaves the id
-- untouched (`ret = q->in` unless a number comes back), so this is a pure tap on
-- the executor seam 0x09AC5228 — no forcing, no engine risk. It answers the
-- question the damage runs could not: WHICH actions does the AI actually ask
-- for, and does the ported build receive the same ones as the native?
local g_acts = {}
local g_tk = 0
local g_last_act = -1
local g_forced = 0

if LOG_ACTIONS or FORCE_ACTION ~= 0 then
  local last_fire = -100000
  mhfu.on_bigmonster_action(function(ctx)
    -- Returning nil leaves the id untouched (`ret = q->in` unless a number comes
    -- back), so the logging half is a pure tap on the executor seam 0x09AC5228.
    local a = ctx.action_id
    g_acts[a] = (g_acts[a] or 0) + 1
    if FORCE_ACTION ~= 0 and (FORCE_PERIOD <= 0 or (g_tk - last_fire) >= FORCE_PERIOD) then
      last_fire = g_tk
      g_forced = g_forced + 1
      -- the engine ORs the freeze bits in during forced fire; clear or the AI
      -- tick halts and the monster stands still.
      local g = mhfu.read_u32(ctx.entity + OFF_FREEZE)
      if (g & FREEZE_BITS) ~= 0 then mhfu.write_u32(ctx.entity + OFF_FREEZE, g & ~FREEZE_BITS) end
      g_last_act = FORCE_ACTION
      log("[brute] FORCE a1=%d (over %d) #%d t=%d", FORCE_ACTION, a, g_forced, g_tk)
      return FORCE_ACTION
    end
    -- ⚠️ Log every CHANGE, not just an id's first sighting. Logging only first
    -- occurrences made "3 of 28 dispatched in reach" mean "3 of 28 FIRST
    -- SIGHTINGS" — the leading edge of the stream, not the stream.
    if a ~= g_last_act then
      g_last_act = a
      log("[brute] ACTION a1=%d (x%d) t=%d", a, g_acts[a], g_tk)
    end
    return nil
  end, 10)
  if FORCE_ACTION ~= 0 then
    log("[brute] action force ARMED a1=%d period=%d", FORCE_ACTION, FORCE_PERIOD)
  else
    log("[brute] action logging ARMED (observe-only)")
  end
end

-- 5. observe only ------------------------------------------------------------
local tk, last_php, last_line = 0, -1, ""
function mhfu_tick()
  drain()
  mhfu.paint_map()
  tk = tk + 1
  g_tk = tk
  local php = mhfu.get_player_hp()
  if php ~= last_php then log("[brute] PLAYER HP %d -> %d (t=%d)", last_php, php, tk); last_php = php end
  local ent = g_ent
  if ent == 0 or not mhfu.entity_alive(ent) then return end
  if MAINTAIN then
    mhfu.entity_make_visible(ent, mhfu.get_area_index())
    local g = mhfu.read_u32(ent + OFF_FREEZE)
    if (g & FREEZE_BITS) ~= 0 then mhfu.write_u32(ent + OFF_FREEZE, g & ~FREEZE_BITS) end
  end
  local msec, psec = mhfu.read_u16(ent+OFF_SECTION), mhfu.get_area_index()
  local px = read_f(PLAYER_ENT + OFF_PLAYER_XYZ)
  local pz = read_f(PLAYER_ENT + OFF_PLAYER_XYZ + 8)
  local mx, mz = read_f(ent+OFF_POS), read_f(ent+OFF_POS+8)
  local d = math.floor(math.sqrt((mx-px)^2 + (mz-pz)^2))
  local line = string.format(
    "sec=%d/%d%s out=%d in=%d bc0=%d eng=%.1f node=0x%X hp=%d d=%d",
    msec, psec, (msec == psec) and " SAME" or "",
    mhfu.read_u8(ent+OFF_OUTER), mhfu.read_u8(ent+OFF_INNER),
    mhfu.read_u32(ent+OFF_BC) & 1, read_f(ent+OFF_ENGAGE),
    mhfu.read_u32(ent+OFF_NODE), mhfu.read_u16(ent+OFF_HP), d)
  if line ~= last_line then log("[brute] t=%d %s", tk, line); last_line = line end
end

log("[brute] brute_dmg registered inject=%s maintain=%s force=%d",
    tostring(INJECT_BRUTE), tostring(MAINTAIN), FORCE_ACTION)
