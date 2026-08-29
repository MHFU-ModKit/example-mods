-- zinogre_fx.lua — can WE fire the engine's own visual effects on a PORT?
--
-- The port question this answers is narrower than it sounds. A monster's
-- effects are not data: the engine has no per-action effect table, the species
-- overlay emits them as literal arguments from inside per-action MIPS
-- (`AI_SCRIPTING_ENGINE.md` §33), and the MHP3rd Zinogre's file group is exactly
-- em040m0 + em040m1 + model + geometry + moveset, with no effect file. So there is
-- nothing to "port". What there is, is MHFU's own effect library and a spawn
-- entry point that takes an id and a bone — and if a mod can call that at a
-- frame it chooses, a scripted moveset can have visuals without porting
-- anything at all.
--
-- 🔴 THERE IS EXACTLY ONE SAFE PLACE TO MAKE THE CALL, AND IT WAS MEASURED.
-- `spawn_effect` allocates from the effect manager, so it has to be game-thread-
-- synced. Two seams qualify on paper; only one survives:
--
--   * `on_bigmonster_action` — exec thread, game thread blocked. WORKS.
--   * a native `ai_step` prefix firing every N frames — the game stopped logging
--     within a second or two of arming, twice, while a DRY run of the same driver
--     (every line except the engine call) logged its completion and carried on.
--     Strong rather than proven — the debugger link also drops by itself here, so
--     judge it on framework.log going silent, not on the driver's traceback — and
--     enough that the driver is gone.
--
-- So this sweeps through the action hook: one effect id per action dispatch. The
-- rate is the monster's, not ours — which is why the monster is parked close and
-- why the sweep walks em75's OWN 28 ids rather than 0..120. An id the host
-- overlay never asks for tells us nothing we can act on until the cheap ids are
-- characterised.
--
-- 🔴 BEFORE BELIEVING A NULL RESULT, GREP framework.log FOR
-- `exec entry not original`. `on_bigmonster_action` is a CODE-WORD patch on the
-- executor entry and only lands JIT-cold; if PPSSPP has already translated the
-- block the framework logs `[ai] exec entry not original (0x68xxxxxx) — skip
-- patch` and refuses, and this script's callback is then never called at all.
-- Three takes armed cleanly and fired nothing for exactly that reason, which
-- reads identically to "every effect id is dead".
--
-- 🔴 A ZERO HANDLE IS USUALLY THE SECTION GATE, NOT A DEAD ID. `0x09ACB3E0` drops
-- the spawn when `entity+0x29A ~= <current section>` and returns normally. The
-- first two fires of an earlier take both read 0 and both landed in the same
-- second the driver teleported the monster — so this one waits for `same_section`
-- AND a settled placement before it starts counting.
mhfu.port = mhfu.port or { _queue = {} }
mhfu.port.mod = mhfu.port.mod or function(n, f) mhfu.port._queue[n] = f end

mhfu.port.mod("zinogre_fx", function(P)
  local log = P.log

  local zin = P.define{
    name    = "zinogre",
    species = mhfu.MON_TIGREX,
    replace = { mhfu.MON_GIADROME },
    pac     = "zinogre_v2.bin",
    orig    = "file_06185.bin.orig",
    fid     = 6186,
    clips   = {},
    -- ⚠️ TWO THROWAWAY BEHAVIOUR PAIRS, AND THEY EXIST ONLY TO MAKE HIM ACT.
    -- The sweep costs one effect id per EXECUTOR DISPATCH, and a monster that is
    -- not doing anything does not dispatch: two takes armed cleanly, then logged
    -- `pair=(1,0) dist=1040` unchanged for minutes and fired nothing at all.
    -- act_set is what forces a dispatch, so the brain alternates these to keep
    -- them coming. Whether the engine ACCEPTS the pair does not matter here —
    -- a rejected one still bounces out through the executor, which is the event
    -- being counted.
    --
    -- 🔴 NOT A PATTERN TO COPY INTO A SHIPPING MOD. Pulsing act_set on a timer is
    -- per-tick maintenance in disguise (CLAUDE.md §8) and it is what made swapped
    -- monsters look combat-broken for two months. It is here because this take
    -- measures the EFFECT CALL, not the monster.
    moves = {
      nudge_a = { main = 1, sub = 3 },
      nudge_b = { main = 2, sub = 1 },
    },
  }

  -- em75's own vocabulary, recovered offline by tools/em_effects.py from all 55
  -- of its spawn sites. These are the ids the host overlay actually asks for, so
  -- they are the ones certain to be valid for this species.
  local IDS = { 10, 11, 14, 24, 28, 29, 36, 37, 39, 40, 42, 43, 55, 56, 59, 60,
                61, 62, 66, 70, 71, 72, 79, 81, 84, 85, 87, 100 }

  -- em75 spawns 60 at bone 33 and 79/85/87 at bone 37 — the TIGREX's mouth and
  -- head. The port carries its own 51-bone rig, so those indices land elsewhere;
  -- bone 37 read (8989, 1153, 9124) against a root of (8962, 1000, 8768), i.e.
  -- forward and above, which is the closest thing to a head among the bones
  -- sampled. Treated as a working guess, not a mapping.
  local BONE = 37
  local WATCH_BONES = { 0, 1, 5, 10, 15, 18, 20, 23, 30, 33, 37, 40, 45, 50 }

  local SETTLE = 6            -- ticks in-section before the first fire (3 s)

  local i, fired, ok, settled, announced, ent_seen = 0, 0, 0, 0, false, 0
  local done, ready, nudge = false, false, 0

  -- THE ONE SAFE SEAM. Fires the current candidate and advances. Abstains from
  -- the clip decision (returns nil) so the engine's own choice stands and the
  -- monster keeps behaving normally, which is what keeps dispatches coming.
  mhfu.on_bigmonster_action(function(ctx)
    if done or not ready or ent_seen == 0 or ctx.entity ~= ent_seen then return nil end
    i = i + 1
    if i > #IDS then
      done = true
      log("[zfx] sweep complete: %d fired, %d accepted", fired, ok)
      return nil
    end
    local id = IDS[i]
    local h = mhfu.spawn_effect(ctx.entity, id, BONE)
    fired = fired + 1
    if h ~= 0 then ok = ok + 1 end
    log("[zfx] fire id=%d bone=%d -> h=0x%X  (%d/%d, action=%d)",
        id, BONE, h, i, #IDS, ctx.action_id or -1)
    return nil
  end, 20)

  zin:brain(function(s)
    local e = s.ent or 0
    if e == 0 then return end
    ent_seen = e

    if not announced then
      announced = true
      log("[zfx] alive ent=0x%08X joints=%d sec=%d area=%s",
          e, mhfu.read_u16(e + 0x1A4), s.section or -1, tostring(s.area))
      -- 🔴 The joint array base is entity+0x190, NOT the +0x4C8 an earlier probe
      -- used — `0x0886421C(entity+0x80, bone)` is literally
      -- `*(u32*)(entity+0x190) + bone*0x250`, world xyz at +0x100 in the record.
      -- Confirmed live: every bone below reads finite, distinct and plausible.
      for _, b in ipairs(WATCH_BONES) do
        local x, y, z = mhfu.bone_pos(e, b)
        if x then log("[zfx] bone %2d -> (%.0f, %.0f, %.0f)", b, x, y, z) end
      end
    end

    if done then return end

    if not s.same_section then
      if ready then
        ready, settled = false, 0
        log("[zfx] paused — monster section %d != area %s",
            s.section or -1, tostring(s.area))
      end
      return
    end

    if not ready then
      settled = settled + 1
      if settled >= SETTLE then
        ready = true
        log("[zfx] ARMED — %d ids, one per action dispatch, bone %d", #IDS, BONE)
      end
      return
    end

    -- keep the dispatches coming (see the `moves` note above)
    nudge = nudge + 1
    if nudge % 4 == 0 then
      zin:play(nudge % 8 == 0 and "nudge_a" or "nudge_b", 3)
    end

    if (s.tick or 0) % 20 == 0 then
      log("[zfx] progress %d/%d fired=%d accepted=%d dist=%.0f pair=(%d,%d)",
          i, #IDS, fired, ok, s.dist or -1, s.main or -1, s.sub or -1)
    end
  end)
end)
