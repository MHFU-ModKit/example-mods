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
local OFF_MAIN     = 0x298   -- act_set main_state (AI_SCRIPTING_ENGINE §33)
local OFF_OUTER    = 0x299   -- act_set sub_state; named "outer" before we knew what it was
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
  -- 🔴 `if u >= 0x80000000` is ALWAYS TRUE on the PSP build — lua_Integer is 32
  -- bits, so the literal wraps to -2147483648. Every float this decoded came out
  -- SIGN-FLIPPED, and it hid because the only thing computed from these was a
  -- distance, which negating both endpoints leaves unchanged. Test the bit.
  -- (mhfu.read_f32 is correct and is the better answer; see mhfu_port.lua.)
  local sign = 1.0; if (u & 0x80000000) ~= 0 then sign = -1.0 end; u = u & 0x7FFFFFFF
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

-- Drive the BEHAVIOUR channel directly — the test that decides whether a ported
-- monster can be given its own moves without a host analogue to copy.
--
-- This is `act_set` (0x09AC8818) reimplemented with plain memory writes, because
-- the framework has no native-call binding yet. The engine's version also clears
-- the per-slot cursors behind two condition checks; we do the unconditional part
-- only, which is the minimum a handler needs to run from its first phase:
--   +0x460/+0x461 = the previous pair (handlers read it on transitions)
--   +0x298/+0x299 = the new pair
--   +0x1D5..+0x1D7 = 0        <- the phase counter; a handler that finds this
--                                non-zero skips its own "start the clip" phase
--
-- ⚠️ PULSED, never per-tick. Per-tick maintenance of a big monster is what made
-- swapped monsters look combat-broken for two months (CLAUDE.md rule 8), and
-- rewriting the state every tick would restart the move before it ever reaches
-- its hitbox frames — the same failure a held a1-force already demonstrated.
local FORCE_STATE_MAIN   = -1    -- >= 0 arms behaviour-channel forcing
local FORCE_STATE_SUB    = 0
local FORCE_STATE_RANGE  = 1500  -- only pulse when the hunter is this close
local FORCE_STATE_PERIOD = 24    -- ticks between pulses (~12 s at ~2 ticks/s)
local g_state_forced = 0

local function act_set(ent, main, sub)
  mhfu.write_u8(ent + 0x460, mhfu.read_u8(ent + OFF_MAIN))
  mhfu.write_u8(ent + 0x461, mhfu.read_u8(ent + OFF_OUTER))
  mhfu.write_u8(ent + OFF_MAIN,  main)
  mhfu.write_u8(ent + OFF_OUTER, sub)
  mhfu.write_u8(ent + 0x1D5, 0)
  mhfu.write_u8(ent + 0x1D6, 0)
  mhfu.write_u8(ent + 0x1D7, 0)
  -- 🔴 Repeated forcing makes the engine OR in the exhaustion bits and halt the
  -- AI tick entirely (aggro survives, the monster just stops). tigrex_spin.lua
  -- hit this driving the SAME move over and over, which is exactly what a damage
  -- test does. Clear on the pulse — still not per-tick.
  local g = mhfu.read_u32(ent + OFF_FREEZE)
  if (g & FREEZE_BITS) ~= 0 then mhfu.write_u32(ent + OFF_FREEZE, g & ~FREEZE_BITS) end
end

-- 🔴 A big monster runs on TWO channels and this hook only moves ONE of them.
-- The executor 0x09AC5228(entity, a1) picks the CLIP; act_set(entity, main, sub)
-- writes entity+0x298/+0x299 and the species overlay runs
-- switch(+0x298) -> switch(+0x299) into the per-action code that owns the
-- hitboxes and effects (docs/AI_SCRIPTING_ENGINE.md §33). So forcing a1 changes
-- what you SEE, never what the move DOES. This probe records both channels at
-- every dispatch so the pairing can be checked against the offline table from
-- `tools/em_moveset.py --states`.
local FORCE_AFTER = 600          -- dispatches to observe before arming the force
local g_disp, g_armed = 0, false
local g_pairs = {}               -- "main:sub:a1" -> count, for NEW-triple logging
local g_state = -1               -- last (main,sub) seen, for transition logging

if LOG_ACTIONS or FORCE_ACTION ~= 0 then
  local last_fire = -100000
  mhfu.on_bigmonster_action(function(ctx)
    local a = ctx.action_id
    local main = mhfu.read_u8(ctx.entity + OFF_MAIN)
    local sub  = mhfu.read_u8(ctx.entity + OFF_OUTER)
    g_acts[a] = (g_acts[a] or 0) + 1
    g_disp = g_disp + 1

    -- the behaviour channel's own transitions, independent of what we force
    local st = main * 256 + sub
    if st ~= g_state then
      g_state = st
      log("[state] main=%d sub=%d (a1=%d) t=%d d=%d%s", main, sub, a, g_tk, g_disp,
          g_armed and " FORCED" or "")
    end

    -- the pairing under test: which clip does this behaviour state ask for?
    local key = string.format("%d:%d:%d", main, sub, a)
    if g_pairs[key] == nil then
      g_pairs[key] = 0
      if not g_armed then
        log("[pair] (%d,%d) -> a1=%d  t=%d", main, sub, a, g_tk)
      end
    end
    g_pairs[key] = g_pairs[key] + 1

    if FORCE_ACTION ~= 0 and g_disp > FORCE_AFTER then
      if not g_armed then
        g_armed = true
        log("[brute] FORCE PHASE BEGINS a1=%d after %d dispatches t=%d",
            FORCE_ACTION, g_disp, g_tk)
      end
      if FORCE_PERIOD <= 0 or (g_tk - last_fire) >= FORCE_PERIOD then
        last_fire = g_tk
        g_forced = g_forced + 1
        local g = mhfu.read_u32(ctx.entity + OFF_FREEZE)
        if (g & FREEZE_BITS) ~= 0 then mhfu.write_u32(ctx.entity + OFF_FREEZE, g & ~FREEZE_BITS) end
        g_last_act = FORCE_ACTION
        log("[brute] FORCE a1=%d (over %d) main=%d sub=%d #%d t=%d",
            FORCE_ACTION, a, main, sub, g_forced, g_tk)
        return FORCE_ACTION
      end
    end
    if a ~= g_last_act then
      g_last_act = a
      log("[brute] ACTION a1=%d (x%d) main=%d sub=%d t=%d", a, g_acts[a], main, sub, g_tk)
    end
    return nil
  end, 10)
  if FORCE_ACTION ~= 0 then
    log("[brute] action force ARMED a1=%d period=%d after=%d dispatches",
        FORCE_ACTION, FORCE_PERIOD, FORCE_AFTER)
  else
    log("[brute] action logging ARMED (observe-only, two-channel)")
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
  local hp_drop = 0
  if php ~= last_php then
    -- ⚠️ Only believe a drop between two SANE readings. When the hunter carts,
    -- the world frame shifts and HP reads garbage for a few ticks (a measured
    -- 53 -> 1179748 -> 131172 -> 100), which would otherwise book a colossal hit.
    if last_php >= 0 and last_php <= 200 and php <= 200 and php < last_php then
      hp_drop = last_php - php
    end
    log("[brute] PLAYER HP %d -> %d (t=%d)", last_php, php, tk)
    last_php = php
  end
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
  -- 🔴 Pulse ONLY when the monster is in the player's section and within reach.
  -- Forcing a STATIONARY attack (the spin) from the moment it spawns pins the
  -- monster in place, so it never roams to the player and the run reports
  -- "never co-located, nothing measured" — the force defeats its own test.
  if FORCE_STATE_MAIN >= 0 and msec == psec and d <= FORCE_STATE_RANGE
     and (tk % FORCE_STATE_PERIOD) == 0 then
    local m0, s0 = mhfu.read_u8(ent+OFF_MAIN), mhfu.read_u8(ent+OFF_OUTER)
    act_set(ent, FORCE_STATE_MAIN, FORCE_STATE_SUB)
    g_state_forced = g_state_forced + 1
    log("[actset] (%d,%d) -> (%d,%d) d=%d #%d t=%d", m0, s0,
        FORCE_STATE_MAIN, FORCE_STATE_SUB, d, g_state_forced, tk)
  end
  -- Attribute the drop: HP alone cannot tell a connected attack from TRIP-OVER
  -- damage (a big monster walking into the hunter, historically < 15 points),
  -- a small monster, or a fall — so record distance and behaviour state.
  -- (MHFU has NO cold damage; coldness only drains max stamina faster.)
  if hp_drop > 0 then
    log("[hit] -%d HP  d=%d main=%d sub=%d  t=%d", hp_drop, d,
        mhfu.read_u8(ent+OFF_MAIN), mhfu.read_u8(ent+OFF_OUTER), tk)
  end
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
