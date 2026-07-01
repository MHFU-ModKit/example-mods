-- dup_test.lua — ADD + REMOVE (path B): a single ADDED Tigrex that FIGHTS, in
-- place of the quest's native monster. Proven (§4d): an ADDED big monster gets a
-- real target group + manager -> full combat provisioning -> it deals damage,
-- unlike a bare emId SWAP.
--
-- Giadrome quest (different family): the ONE AI-overlay slot follows the emId, and
-- the add-forge is disarmed, so a bare different-family add has no Tigrex overlay.
-- Fix: REPLACE Giadrome->Tigrex first (overlay+node0 = Tigrex), THEN ADD a 2nd
-- Tigrex (same family now -> resident -> group 1 + its own manager -> fights),
-- THEN REMOVE the primary (group-0 replaced-Tigrex, the non-fighting swap one) so
-- only the ADDED fighter remains. Net result = one Tigrex that fights = "swap that
-- actually works", via the add path.
--
-- native Tigrex quest: just ADD a 2nd Tigrex (control; both fight).
--
-- REMOVE mechanism (entity-level, no despawn API): the FIRST-spawned Tigrex =
-- primary (group 0). Each tick teleport it far away + force it into a non-player
-- section + clear its draw-visible bit so the player never sees/fights it; the
-- ADDED fighter (2nd spawn) is kept near the player and made visible.
--
-- COLD BOOT required. Deployed alongside cli_bridge.lua (brute_tigrex.lua .bak).

------------------------------------------------------------------------ CONFIG
local REMOVE_PRIMARY = true      -- suppress the primary so only the added fighter remains
local FAR            = 999999.0  -- shove the suppressed primary off-map (kept in the fighter's section)
local OFF_POS        = 0x200
local OFF_SECTION    = 0x29A
local OFF_FLAGS638   = 0x638
local OFF_FREEZE_GATE = 0x4B8    -- u32: bits 0x100|0x10000 halt the AI tick
local FREEZE_BITS    = 0x10100   -- 0x100 | 0x10000
-- FORCE the fighter to loop ONE action so you can walk into it (hitbox/damage test).
-- The Brute's SPIN = action 51 (labelled via the anim sweep; native-Tigrex spin =
-- 0x2B if 51 shows the wrong clip). Set FORCE_SPIN=false for normal AI.
local FORCE_SPIN     = false   -- forcing repeat-fire SETS the freeze gate (+0x4B8) → AI halts
                               -- ("frozen standing"); off = natural combat (walk into his attacks)
local SPIN_ACTION    = 51
--------------------------------------------------------------------------------

local MON_GIADROME = mhfu.MON_GIADROME
local MON_TIGREX   = mhfu.MON_TIGREX

------------------------------------------------------------- BRUTE MODEL INJECT
-- Inject the Brute v63 PAC over the Tigrex model (file_06185): loads his OWN
-- P3rd-derived skeleton (46-bone) + his OWN 77-clip moveset. The engine's Tigrex
-- overlay still drives combat (model-independent), so the added fighter fights
-- while wearing + animating the Brute. v63 is BIGGER than native -> relocate path
-- (xram). Registered at boot (top-level) so it catches the model load at section
-- entry -> COLD BOOT required for the Brute to appear. Both Tigrex share the one
-- Tigrex model resource, so the inject shows the Brute on the visible fighter (the
-- hidden primary is a Brute too, but it's off-map).
local INJECT_BRUTE = true
local INJECT_DIR   = "ms0:/PSP/PLUGINS/mhfu_framework/inject"
local BRUTE_PAC    = INJECT_DIR .. "/brute_tigrex_v63_clipfix.bin"
local ORIG_PAC     = INJECT_DIR .. "/file_06185.bin.orig"
local TIGREX_FID   = 6185
if INJECT_BRUTE then
  local ok = mhfu.inject_relocate(TIGREX_FID, BRUTE_PAC, ORIG_PAC)
  mhfu.log("[duptest] inject_relocate v63 %s fid=%d", ok and "OK" or "FAILED", TIGREX_FID)
end

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
local function write_f(a,f) mhfu.write_u32(a, float_to_u32(f)) end

-- fighter render-fix: the added monster's +0x29A section tracker can be STALE
-- (spawned in the intro section, never updated) -> the visibility gate culls it.
-- Force +0x29A = the player's section + set the visible bit so it renders. NOTE:
-- this reintroduces the "follows you across sections" behaviour (the price of the
-- stale-tracker render bug); a proper fix = relocate-once to a fixed huntable
-- section. For now it's needed just to SEE the Brute. BRING_TO_PLAYER also TPs it
-- next to you if it's off in another section, so you can fight it immediately.
-- Bring the fighter into the player's section so it renders. Forcing +0x29A alone
-- does NOT stick — the engine re-derives the section tracker from POSITION each
-- frame — so when the fighter is in a DIFFERENT section we physically relocate it
-- into the player's section (TP next to the player); once its section matches we
-- leave it alone so it can move + fight normally (only re-TPs if it drifts out or
-- the player changes section). NOTE: still "follows" on section change; a proper
-- relocate-once-to-a-fixed-huntable-section is the follow-up.
local function ensure_visible(ent, parea, px, py, pz)
  local sec = mhfu.read_u16(ent + OFF_SECTION)
  if px and parea and parea ~= 0 and sec ~= parea then
    write_f(ent + OFF_POS,     px + 900.0)   -- X
    write_f(ent + OFF_POS + 4, py)           -- Y (match the player's floor height)
    write_f(ent + OFF_POS + 8, pz)           -- Z
    mhfu.write_u16(ent + OFF_SECTION, parea)
  end
  local fl = mhfu.read_u32(ent + OFF_FLAGS638)
  if (fl & 0x8000) == 0 then mhfu.write_u32(ent + OFF_FLAGS638, fl | 0x8000) end
end

-- suppressed primary: keep it in the FIGHTER'S section (so no 2nd section lights
-- up on the map), shove it off-map in XZ, and clear its visible bit so it's not
-- drawn. Only ONE section highlights (the fighter's).
local function hide(ent, fighter_sec)
  write_f(ent + OFF_POS,     FAR)
  write_f(ent + OFF_POS + 8, FAR)
  if fighter_sec and fighter_sec ~= 0 then mhfu.write_u16(ent + OFF_SECTION, fighter_sec) end
  local fl = mhfu.read_u32(ent + OFF_FLAGS638)
  if (fl & 0x8000) ~= 0 then mhfu.write_u32(ent + OFF_FLAGS638, fl & ~0x8000) end
end

-- ADD + REMOVE at target-building (before the engine builds targets / loads models)
mhfu.on_quest_targets_building(function(quest)
  if quest == 0 then return end
  if mhfu.quest_has(quest, MON_TIGREX) then
    if mhfu.quest_add_monster(quest, MON_TIGREX) then
      mhfu.log("[duptest] native Tigrex quest -> ADDED 2nd Tigrex")
    else mhfu.log("[duptest] add FAILED (native)") end
  elseif mhfu.quest_has(quest, MON_GIADROME) then
    if mhfu.quest_replace_monster(quest, MON_GIADROME, MON_TIGREX) then
      mhfu.log("[duptest] Giadrome quest -> REPLACED primary Giadrome->Tigrex (overlay)")
      if mhfu.quest_add_monster(quest, MON_TIGREX) then
        mhfu.log("[duptest] ADDED 2nd Tigrex (fighter, group 1)")
      else mhfu.log("[duptest] add FAILED (after replace)") end
    else mhfu.log("[duptest] replace FAILED") end
  end
end)

-- spawn order: 1st Tigrex = primary (group 0, suppress); later = added fighter (keep)
local g_primary = 0
mhfu.on_bigmonster_spawn(function(ent, mtype, slot, hp)
  if mtype ~= MON_TIGREX then return end
  if g_primary == 0 then g_primary = ent end
  mhfu.log(string.format("[duptest] Tigrex SPAWN ent=0x%08X slot=%d hp=%d sec=%d %s",
    ent, slot, hp, mhfu.read_u16(ent + OFF_SECTION),
    (ent == g_primary) and "(PRIMARY->suppress)" or "(ADDED fighter)"))
end)

local function clear_freeze_gate(ent)
  local g = mhfu.read_u32(ent + OFF_FREEZE_GATE)
  if (g & FREEZE_BITS) ~= 0 then mhfu.write_u32(ent + OFF_FREEZE_GATE, g & ~FREEZE_BITS) end
end

-- Force the fighter to loop the SPIN so the player can walk into its hitbox. The
-- executor fans a1 to all body slots coherently (no desync). Skip the hidden
-- primary. Clear the freeze gate each fire or the AI tick halts.
mhfu.on_bigmonster_action(function(ctx)
  if not FORCE_SPIN then return ctx.action_id end
  if REMOVE_PRIMARY and ctx.entity == g_primary then return ctx.action_id end
  clear_freeze_gate(ctx.entity)
  return SPIN_ACTION
end, 10)

local tk = 0
function mhfu_tick()
  mhfu.write_u8(0x090B3A6A, 0xFF)   -- paintball bosses
  tk = tk + 1
  local parea = mhfu.get_area_index()
  local px, py, pz = read_f(PLAYER_POS), read_f(PLAYER_POS + 4), read_f(PLAYER_POS + 8)
  local list = mhfu.entities_of_type(MON_TIGREX)
  if not list or #list == 0 then return end

  -- primary = spawned first = group 0 = lowest entity address. Recover it here so
  -- a hot-reload (which zeroes g_primary and won't re-fire the spawn hook) still
  -- knows which to suppress.
  if REMOVE_PRIMARY and g_primary == 0 and #list >= 2 then
    g_primary = list[1]
    for i = 2, #list do if list[i] < g_primary then g_primary = list[i] end end
  end

  local kept, hidden = 0, 0
  for i = 1, #list do
    local ent = list[i]
    if ent and ent ~= 0 then
      if REMOVE_PRIMARY and ent == g_primary and #list > 1 then
        hide(ent, parea); hidden = hidden + 1               -- park primary in the player's section, off-map
      else
        ensure_visible(ent, parea, px, py, pz)              -- render-fix + bring to player
        if FORCE_SPIN then clear_freeze_gate(ent) end       -- keep AI tick alive while spin-locked
        kept = kept + 1
      end
    end
  end
  if tk % 30 == 0 then
    mhfu.log(string.format("[duptest] hb parea=%d tigrex=%d kept=%d hidden=%d",
      parea, #list, kept, hidden))
  end
end

mhfu.log("[duptest] registered — ADD+REMOVE (single added Tigrex that fights; REMOVE_PRIMARY="
  .. tostring(REMOVE_PRIMARY) .. ")")
