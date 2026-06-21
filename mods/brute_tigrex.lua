-- brute_tigrex.lua — v1 integrated test: Brute Tigrex model inject + AI cycle.
--
-- STATUS 2026-06-19 (authoritative: docs/BRUTE_TIGREX_PORT.md): model + 46-bone
-- skeleton + textures load into a live quest (construction completes). The PRX-stack
-- clobber is fixed (frame-free joint-fix in brute_overlay_hook). Inject is now the
-- SAME-SIZE in-place path (mhfu.inject_register + inject_now) over file_06185. ANIM is
-- the remaining blocker — MHFU's in-game anim is a recursive 3-stream format the port
-- hasn't produced yet (see docs/ANIMATION_FORMAT.md). The narrative below is the older
-- relocate-era design, kept for context.
--
-- Integrated v1 test deliverable: combines the model injection (Phase 5 relocate
-- path) with the Lua AI layer so we can correlate executor a1 values to the
-- on-screen animation clips from the Brute Tigrex PAC.
--
-- WHAT THIS DOES:
--   1. Registers brute_tigrex_v4.bin as a RELOCATE inject over file_06185 (fid
--      6186).  The engine's raw-buffer pointer gets redirected to our xram copy;
--      the engine parses OUR skeleton/PMO/anim instead of the native Tigrex's.
--   2. Swaps the Giadrome -> Tigrex (host vehicle) so the engine loads the Tigrex
--      slot + AI overlay.
--   3. Cycles through PROBE_IDS action a1 values every ~2 s and LOGS each one so
--      we can watch the screen alongside framework.log to name each Brute clip.
--   4. Clears freeze gate, applies render fix, forces aggro, paints the map.
--
-- INJECT MECHANISM (Phase 5 relocate path, inject.cpp try_redirect_pkg):
--   brute_tigrex_v6.bin (455 KB, 7 subs matching file_06185's layout) is
--   structurally DIFFERENT from the native file_06185 (1.2 MB) — different sub
--   offsets/sizes.  The RELOCATE path matches the engine buffer via the ORIGINAL
--   file_06185 header (.orig) and redirects get_subresource a0 -> our xram copy.
--   The engine then parses OUR self-consistent 7-sub PAC.
--
--   v6 layout: [0] Brute 46-bone skel (MHFU 0x10C format, zero-padded from 0x5C)
--              [1] Brute PMO 1.0 88-grp  [2] Brute TMH
--              [3] Brute 19-clip anim (hsize=0x38, tables 1+3 populated with native
--                  Tigrex slot occupancy mapped round-robin to our 19 Brute clips;
--                  gap 0x40..0x1C7 also mirrored; tables 0/2/4 empty like native)
--              [4] native skel2 (6-bone)  [5] native PMO2  [6] native TMH2
--   (subs 4-6 copied from file_06185 verbatim — structural placeholder to prevent
--    the engine's secondary-object loader from reading past our sub table → crash.)
--
-- MEMSTICK LAYOUT (copy before cold-booting):
--   ms0:/PSP/PLUGINS/mhfu_framework/mods/brute_tigrex.lua  ← this file
--   ms0:/PSP/PLUGINS/mhfu_framework/inject/brute_tigrex_v6.bin
--   ms0:/PSP/PLUGINS/mhfu_framework/inject/file_06185.bin.orig
--     (the .orig = file_06185.bin verbatim from workspace/extracted/data_files/)
--     (cp workspace/extracted/data_files/file_06185.bin <memstick>/.../inject/file_06185.bin.orig)
--
-- NO PRX REBUILD NEEDED: lua_host already in mods.manifest; Lua-only change.
--
-- HOT-RELOAD: editing this file takes effect within ~0.5 s (worker re-executes
-- changed .lua files).  The inject registration fires at the next cold boot
-- (plugins load cold-boot only); the inject path itself fires at quest depart
-- (model loads at QUEST DEPART, not at section entry).
--
-- ANIMATION DISCOVERY (goal of this session):
--   v2 PAC carries 19 animation clips (slots 0-18).  The engine maps executor
--   a1 -> body-part vt8_input -> anim-descriptor -> clip index via the Tigrex
--   descriptor table at entity+0x640.  We don't yet know which a1 picks which
--   Brute clip.  Strategy: cycle PROBE_IDS, log each a1, watch the screen.
--   Once confirmed, rename PROBE_IDS -> MOVESET and drop the extras.
--
-- REFERENCES:
--   * inject.cpp try_redirect_pkg / try_overwrite_buffer
--   * docs/AI_SCRIPTING_ENGINE.md §32k (executor a1 derivation, freeze gate)
--   * framework/prx/include/mhfu/ai_script.h (a1 constants, offset table)
--   * framework/prx/mods/lua_host/scripts/relocate_test.lua (inject_relocate ref)

------------------------------------------------------------------------ CONFIG

-- Host species: the Giadrome quest's monster gets swapped to Tigrex.
-- Set to false to run on a native Tigrex quest (no swap).
-- 2026-06-19: back to TRUE. The clobber was NOT swap-specific — it was the
-- joint-fix stub's `jal` frame tipping the construction stack into the PRX. With
-- the FRAME-FREE inline joint-fix that's gone. The swap reliably loads the Brute
-- (image 15: overwrite + spawn hp 2400); the native quest crashed before the
-- model even loaded. Use the swap to get the Brute in.
local SWAP_GIADROME = true   -- Brute test (swap Giadrome->Tigrex host)

-- Monster size scalar for the Brute Tigrex appearance (>1 = larger).
-- Brute Tigrex is slightly bigger than regular Tigrex.
local BRUTE_SIZE = 1.05

-- Aggro range: keep the engine permanently aggroed once engaged.
local FORCE_AGGRO = false  -- v26 rest-pose visual test needs only the bind pose drawn

-- Action cycle period (driven by mhfu_tick at 2 Hz).
-- CYCLE_TICKS=4 -> ~2 s per action (slow enough to clearly see each clip).
local CYCLE_TICKS = 4

-- Log verbosity: 0 = silent, 1 = spawn/inject/death, 2 = every action pick.
-- Keep at 2 for this HITL session so we can correlate a1 -> screen clip.
local LOG_LEVEL = 1   -- 1 = spawn/inject/render/death only (CYCLE spam off)

-- Inject paths on the memstick.
local INJECT_DIR = "ms0:/PSP/PLUGINS/mhfu_framework/inject"
-- v7 = layout-identical PAC (each sub padded to native file_06185 offset/size,
-- total 1216512 == native, only content foreign). Same size as native -> use the
-- proven same-size IN-PLACE overwrite (inject_register) instead of relocate. The
-- engine's restructure/staging then lands the skeleton sub where native's would
-- (v6's compacted layout put skel at base+0x29744 = inside anim -> bad joint ptr).
-- v13 = Brute skel/model/textures + a real MHFU in-game (recursive 3-stream)
-- BIND-POSE anim built by tools/mhfu_model/anim_ingame.make_static_pose (single
-- main stream, 42 empty bone sections → every animated bone falls back to the
-- skeleton bind pose → Brute renders static, no Tigrex motion). Same 1216512 B as
-- native file_06185 so the same-size in-place inject path is unchanged. This is
-- the first milestone of the recursive in-game anim encoder (anim_ingame.py).
-- v26 = v25's load-proven skel/model/textures (stream-id partition fix) but with
-- the converted real-motion anim REPLACED by an identity-rotation REST-POSE anim
-- (anim_ingame.swap_anim_to_bindpose, split [31,9,5], streams main/sub1/sub3 ==
-- native layout).  ISOLATION TEST: offline our importer assembles the Brute mesh
-- fine in bind pose (skinning works); in-engine v25 (real motion) COLLAPSES it.
-- If v26 (rest pose, no foreign rotations) renders the splayed-but-present Brute
-- in-engine, skinning+load+stream-binding are proven and ONLY the cross-game
-- motion retarget remains.  If v26 ALSO collapses -> the bug is skinning/engine.
local BRUTE_PAC  = INJECT_DIR .. "/brute_tigrex_v37_rigidpalette.bin"
local ORIG_PAC   = INJECT_DIR .. "/file_06185.bin.orig"
-- engine fid = extracted index + 1 (file_06185 -> fid 6186; Phase 4 RE confirmed)
local TIGREX_FID = 6185

------------------------------------------------------------------------ CONSTANTS

local MON_TIGREX   = mhfu.MON_TIGREX
local MON_GIADROME = mhfu.MON_GIADROME

-- Executor a1 values for the Tigrex action-force seam (0x09AC5228).
-- Derivation: a1 = vt8_input(slot2) - 0x578 = vt8_input(slot0) - 0x3E8.
-- Source: ai_script.h MHFU_AI_A1_* constants + AI_SCRIPTING_ENGINE.md §32k.
local A1_IDLE_WALK       = 0x03   -- TIGREX_IDLE_WALKSTRAIGHT (input 0x057B)
local A1_IDLE_STAND      = 0x20   -- TIGREX_IDLE_STAND        (input 0x0598)
local A1_ANGRY_SPIN      = 0x2B   -- TIGREX_ANGRY_SPIN        (input 0x05A3)
local A1_ANGRY_CHARGE    = 0x11   -- TIGREX_ANGRY_CHARGE      (input 0x0589)
local A1_ANGRY_BITE_FWD  = 0x29   -- TIGREX_ANGRY_BITE_FORWARD(input 0x05A1)
local A1_ANGRY_JUMP_FWD  = 0x2F   -- TIGREX_ANGRY_JUMP_FORWARD(input 0x05A7)
local A1_ANGRY_TURN_LEFT = 0x08   -- TIGREX_ANGRY_TURN_LEFT   (input 0x0580)

-- Entity cell offsets (from ai_script.h).
local OFF_FREEZE_GATE  = 0x4B8  -- u32: bits 0x100|0x10000 halt AI tick
local OFF_SECTION      = 0x29A  -- u16: monster's tracked section index
local OFF_FLAGS638     = 0x638  -- u32: bit 0x8000 = render gate B
local OFF_PURSUE_VEC   = 0x5D0  -- f32 x3: pursuit target vector
local OFF_ENGAGE       = 0x5DC  -- f32: 1.0 = engaged

-- Map-paint cheat address (EU).
local ADDR_PAINTBALL = 0x090B3A6A

-- Freeze-gate bits to clear.
local FREEZE_BITS = 0x10100  -- 0x100 | 0x10000

------------------------------------------------------------------------ PROBE IDS

-- PROBE_IDS: executor a1 values to cycle through for clip mapping.
-- The engine maps a1 -> vt8_input -> anim-descriptor -> clip index via the
-- Tigrex descriptor table.  We don't know which a1 plays which Brute clip yet.
-- Log output during HITL: "[brute_tigrex] ACTION a1=0x%02X" — watch screen
-- simultaneously to map a1 -> clip name, then collapse into the final MOVESET.
--
-- Extended set includes: known Tigrex a1s + probes 0x30-0x33 for Brute-only clips.
-- Unknown a1s that map to nothing will play whatever the engine defaults to.
local PROBE_IDS = {
    0x03,   -- IDLE_WALK
    0x11,   -- ANGRY_CHARGE
    0x29,   -- ANGRY_BITE_FWD
    0x2B,   -- ANGRY_SPIN
    0x2F,   -- ANGRY_JUMP_FWD
    0x07,   -- ANGRY_TURN_RIGHT
    0x08,   -- ANGRY_TURN_LEFT
    0x2D,   -- ANGRY_THROW_ROCKS
    0x20,   -- IDLE_STAND
    0x50,   -- IDLE_SUSPICIOUS
    0x30,   -- [PROBE] unknown — may map to Brute-only clip
    0x31,   -- [PROBE] unknown
    0x32,   -- [PROBE] unknown
    0x33,   -- [PROBE] last known engine a1 (li a1,0x33 at 0x09D26558)
}
local PROBE_COUNT = #PROBE_IDS

-- Legacy alias used in mhfu_tick log (keep for clarity).
local MOVESET     = PROBE_IDS
local MOVESET_LEN = PROBE_COUNT

------------------------------------------------------------------------ INJECT

-- Register the Brute Tigrex v7 PAC via the same-size IN-PLACE path.
-- inject_register installs the get_subresource trampoline; at load the engine's
-- raw count=7 buffer is overwritten in place with v7 (1216512 B == native) BEFORE
-- the transform reads the subs, so the engine restructures OUR bytes on the game
-- thread (racefree). The .orig sibling (<path>.orig = native file_06185) is the
-- species match key + diff-fingerprint gate. inject_now primes the edit + .orig
-- into xram immediately (don't wait on the worker's first tick).
-- CAPTURE_NATIVE: skip the inject so a NATIVE Tigrex loads (for RE'ing the working
-- anim path as ground truth). The swap still puts a Tigrex in the Giadrome quest,
-- but with no inject it's the pristine native Tigrex (real skel/model/anim).
local CAPTURE_NATIVE = false  -- inject ON (Brute v25)
local inject_ok = false
if not CAPTURE_NATIVE then
    inject_ok = mhfu.inject_register(TIGREX_FID, BRUTE_PAC)
    if inject_ok then
        mhfu.inject_now(TIGREX_FID)   -- prime e->buf / e->obuf / diff fingerprint now
        mhfu.log("[brute_tigrex] inject_register OK fid=%d '%s' (primed)", TIGREX_FID, BRUTE_PAC)
    else
        mhfu.log("[brute_tigrex] inject_register FAILED — check paths + cold boot")
    end
else
    mhfu.log("[brute_tigrex] CAPTURE_NATIVE: inject SKIPPED — native Tigrex will load")
end

------------------------------------------------------------------------ STATE

local g_ent       = 0     -- live entity pointer (0 = not present)
local g_armed     = false -- action-force is active
local g_move_idx  = 1     -- current index into PROBE_IDS
local g_tick_ctr  = 0     -- ticks since last state advance
local g_render_ok = false -- render fix applied
local g_dbg_fkA   = -1     -- last-seen FK bind ptr A (for change-logging)
local g_dbg_fkB   = -1     -- last-seen FK bind ptr B

------------------------------------------------------------------------ HELPERS

local function log1(fmt, ...) if LOG_LEVEL >= 1 then mhfu.log(fmt:format(...)) end end
local function log2(fmt, ...) if LOG_LEVEL >= 2 then mhfu.log(fmt:format(...)) end end

-- HOME-section render fix (2026-06-20, re-corrected with the user's key info:
-- the Brute is anchored in ONE section the whole quest — the minimap shows him in
-- snow section 6 (area_index 100) throughout, while his +0x29A tracker holds an
-- UNINITIALISED value (92..109, never == the player area).  So +0x29A is NOT his
-- real section; the swap-spawn never initialised it (the giadrome render bug).
-- The engine's per-frame draw gate (0x09AC4960) culls him UNLESS +0x29A == player
-- area_index AND +0x638 & 0x8000.  Since +0x29A is garbage, he is always culled.
--
-- Fix: when the player is in his HOME section, FORCE +0x29A = player area and set
-- the +0x638 gate; the engine's gate then clears skip-draw itself.  We gate on the
-- HOME area (not every section) so he does NOT get dragged section-to-section as
-- the player moves (the earlier "follow" bug).  HOME_AREA is latched the first
-- time the player is co-located with his world position (or set explicitly).
local HOME_AREA = 100   -- v26 rest-pose: un-cull in snow section 6.  Rest pose = BIND pose
                        -- = coherent geometry (offline render_check bbox 2243, no degenerate
                        -- tris) -> draws safely, NO GE hang (unlike v25's scrambled motion).
                        -- Expect a stiff/splayed-but-present Brute = skinning proven in-engine.

local function apply_render_fix(ent)
    local area = mhfu.get_area_index()
    if area ~= HOME_AREA then
        return false                      -- player not in his section: leave culled
    end
    -- Player IS in his home section: force his tracker to match + open the gate so
    -- the engine un-culls him.  (He's physically here per the minimap; forcing
    -- +0x29A here does not teleport him — it just initialises the tracker the
    -- swap-spawn never set.)
    if mhfu.read_u16(ent + OFF_SECTION) ~= area then
        mhfu.write_u16(ent + OFF_SECTION, area)
    end
    local f = mhfu.read_u32(ent + OFF_FLAGS638)
    if (f & 0x8000) == 0 then
        mhfu.write_u32(ent + OFF_FLAGS638, f | 0x8000)
    end
    return true
end

-- Clear the AI-tick freeze gate.  Engine sets bits 0x100|0x10000 on forced
-- repeat-fire; the AI tick halts when those bits are set.  Called every tick
-- (the halted AI tick cannot run the per-tick clear once frozen).
local function clear_freeze_gate(ent)
    local v = mhfu.read_u32(ent + OFF_FREEZE_GATE)
    if (v & FREEZE_BITS) ~= 0 then
        mhfu.write_u32(ent + OFF_FREEZE_GATE, v & ~FREEZE_BITS)
    end
end

-- Force aggro: write the pursuit vec (entity+0x5D0) toward the player and
-- set engage flag (entity+0x5DC = 1.0).  This mirrors the known aggro-commit
-- seam (memory `big-monster-aggro-target`).
local function force_aggro(ent)
    local px, py, pz = mhfu.player_pos()
    mhfu.write_f32(ent + OFF_PURSUE_VEC + 0, px)
    mhfu.write_f32(ent + OFF_PURSUE_VEC + 4, py)
    mhfu.write_f32(ent + OFF_PURSUE_VEC + 8, pz)
    mhfu.write_f32(ent + OFF_ENGAGE, 1.0)
end

------------------------------------------------------------------------ EVENTS

-- 1. Quest injection: swap Giadrome → Tigrex before model load.
if SWAP_GIADROME then
    mhfu.on_quest_targets_building(function(quest)
        if quest == 0 then return end
        if mhfu.quest_has(quest, MON_GIADROME)
           and mhfu.quest_replace_monster(quest, MON_GIADROME, MON_TIGREX) then
            log1("[brute_tigrex] giadrome -> tigrex swap applied")
        end
    end)
end

-- 2. Spawn: record entity, apply initial setup.
mhfu.on_bigmonster_spawn(function(ent, mtype, slot, hp)
    log1("[brute_tigrex] spawn ent=0x%08X mtype=%d hp=%d", ent, mtype, hp)
    if ent == 0 then return end
    log1("[brute_tigrex] CON bc124=%d m122=0x%04X pmo=0x%08X anim=0x%08X s50=0x%08X",
         mhfu.read_u32(ent + 0x124), mhfu.read_u16(ent + 0x122),
         mhfu.read_u32(ent + 0x50), mhfu.read_u32(ent + 0x1ac),
         mhfu.read_u32(ent + 0x4C8))
    -- v14 (in-game bind-pose anim) loads stably, so it's safe to ARM the per-tick
    -- maintenance. We DON'T enable the AI action override (we want a static Brute),
    -- but the tick must run the SECTION-TRACKER RENDER FIX: a swap-spawned monster
    -- is culled (skip-draw bit at +0x004) until its first natural roam sets the
    -- section tracker +0x29A. The Brute never roams, so the tick forces +0x29A =
    -- player area + |0x8000 on +0x638 (memory `giadrome-tigrex-render-bug`).
    if mtype == MON_TIGREX then
        g_ent       = ent
        g_armed     = true
        g_render_ok = false
        log1("[brute_tigrex] armed tick (render fix + freeze net) on ent=0x%08X", ent)
    end
end)

-- 3. Death: disarm so we don't fire at a dead entity.
mhfu.on_bigmonster_death(function(ent, mtype, slot)
    if mtype ~= MON_TIGREX then return end
    if ent ~= g_ent then return end
    g_armed = false
    g_ent   = 0
    log1("[brute_tigrex] death — AI disarmed")
end)

-- 4. Action-force hook: the coherent seam (executor 0x09AC5228).
--    Fires on the exec thread (game-thread marshalled) for every executor call
--    on a Tigrex entity.  We return the current probe a1; the engine fans it
--    to all body-part slots itself (§32k).
--    LOG FORMAT: "[brute_tigrex] ACTION a1=0x%02X step=%d/%d engine=0x%02X"
--      -> watch the screen while reading the log to map a1 -> Brute clip name.
-- ===== ISOLATION TEST (model-only build) =====================================
-- The AI action override is DISABLED to determine whether the load crash is in
-- the MODEL/entity setup or in this AI action hook. The framework's executor
-- wrapper is NOT installed in this build (no on_bigmonster_action registration).
-- If the quest loads + the Brute renders with this off, the crash was the AI hook.
-- Re-enable the block below after the isolation result.
--[[ DISABLED FOR ISOLATION TEST
mhfu.on_bigmonster_action(function(ctx)
    if not g_armed then return ctx.action_id end
    if ctx.entity ~= g_ent then return ctx.action_id end
    clear_freeze_gate(ctx.entity)
    local a1 = PROBE_IDS[g_move_idx]
    log2("[brute_tigrex] ACTION a1=0x%02X step=%d/%d engine=0x%02X -- WATCH SCREEN",
         a1, g_move_idx, PROBE_COUNT, ctx.action_id)
    return a1
end, 10)
--]]

-- 5. Per-tick maintenance (2 Hz worker thread).
--    Advance the state machine, clear the freeze gate, apply the render fix,
--    force aggro, and paint the map.
function mhfu_tick()
    mhfu.write_u8(ADDR_PAINTBALL, 0xFF)   -- keep the boss visible on the map

    -- Self-acquire: if we don't have the entity yet (e.g. the spawn event already
    -- fired before a hot-reload), scan the registry for the Tigrex-host Brute so the
    -- render fix can run WITHOUT a cold boot.
    if g_ent == 0 then
        for s = 0, 31 do
            local e = mhfu.entity_at(s)
            if e ~= 0 and mhfu.entity_type(e) == MON_TIGREX then
                g_ent = e; g_armed = true; g_render_ok = false
                log1("[brute_tigrex] self-acquired ent=0x%08X (slot %d)", e, s)
                break
            end
        end
    end

    if not g_armed or g_ent == 0 then return end
    if not mhfu.entity_alive(g_ent) then
        g_armed = false; g_ent = 0; return
    end

    -- Freeze-gate net: zero stale bits even when the AI tick is halted.
    clear_freeze_gate(g_ent)

    -- Co-location render fix: every tick, force-render the Brute ONLY while the
    -- player is in his section (XZ-near).  Far away → leave him to roam.
    local colocated = apply_render_fix(g_ent)
    if colocated ~= g_render_ok then
        g_render_ok = colocated
        log1("[brute_tigrex] co-location %s (section=%d)",
             colocated and "ENTER — render-fix on" or "LEAVE — roaming",
             mhfu.read_u16(g_ent + OFF_SECTION))
    end

    -- Aggro maintenance.
    if FORCE_AGGRO then force_aggro(g_ent) end

    -- FK-BIND TRIGGER RE (2026-06-20): the anim loads valid but the per-frame FK
    -- pointer (blendbuf+0x64) is null → joints unposed → mesh collapses.  Log the
    -- bind state every tick so we can see WHEN it binds as the player approaches /
    -- the Brute engages.  blendbuf A = entity+0x150, B = entity+0x1d0; FK ptr @+0x64.
    do
        local fkA   = mhfu.read_u32(g_ent + 0x150 + 0x64)
        local fkB   = mhfu.read_u32(g_ent + 0x1d0 + 0x64)
        local eng   = mhfu.read_f32(g_ent + 0x5DC)
        local sec   = mhfu.read_u16(g_ent + OFF_SECTION)
        local area  = mhfu.get_area_index()
        if (fkA ~= g_dbg_fkA) or (fkB ~= g_dbg_fkB) then
            g_dbg_fkA, g_dbg_fkB = fkA, fkB
            log1("[fkbind] FK_A=0x%08X FK_B=0x%08X engage=%d sec=%d area=%d colocated=%s",
                 fkA, fkB, (eng and eng > 0.5) and 1 or 0, sec, area, tostring(sec == area))
        end
    end

    -- Advance probe state every CYCLE_TICKS ticks (~2 s at 2 Hz).
    g_tick_ctr = g_tick_ctr + 1
    if g_tick_ctr >= CYCLE_TICKS then
        g_tick_ctr = 0
        local prev = g_move_idx
        g_move_idx = (g_move_idx % PROBE_COUNT) + 1
        log2("[brute_tigrex] CYCLE step %d->%d a1 0x%02X->0x%02X",
             prev, g_move_idx, PROBE_IDS[prev], PROBE_IDS[g_move_idx])
    end
end

mhfu.log("[brute_tigrex] v1 integrated — inject_ok=%s swap=%s size=%.2f probes=%d cycle=%.1fs",
         tostring(inject_ok), tostring(SWAP_GIADROME), BRUTE_SIZE,
         PROBE_COUNT, CYCLE_TICKS * 0.5)
