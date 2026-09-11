-- zinogre_lunge.lua — the ported Zinogre's FIRST declared move, on screen.
--
-- Swap Giadrome -> the Zinogre port, bring him to the far side of snow section 1
-- once the hunter walks in, and drive `lunge` — host behaviour pair (1,4) with the
-- port's own `lunge_forward` clip painted on it — every time he is engaged. The
-- hunter's HP is held above a floor so a bad first take is a rerun, not a cart.
--
-- 🟢 THE NATIVE SEAMS (em_vhook v3, issues #15/#16) — what this take tests:
--   1. `play("lunge")` goes through the engine's own ENTER-ACTION (the slot-29
--      request), so the charge is PROVISIONED: it gets its run budget and hands to
--      the skid (0,3) BY ITSELF. Expect "entered natively (1,4), provisioned" and
--      then "move 'lunge' (1,4) ended after N ticks -> (0,3) ... adopted" with NO
--      "hold_max" and NO "PARKED" lines.
--   2. `lunge` CLAIMS every main-1 attack the Tigrex brain picks (slot-32
--      substitution): when he decides to bite/spin/whatever, he lunges instead.
--      The executor hook paints the lunge clip on it ("engine entered 'lunge'
--      itself"). The heartbeat's `sub=hits/landed` counts them.
--   3. A 30 Hz RULE ends a charge the frame he is past you (in (1,4) >= 15
--      frames, the gap growing, >= 250 units) -> lunge_stop, with no Lua in the
--      loop. `brain=` in the heartbeat counts its fires; the 2 Hz "past you"
--      shortcut below only runs when the seam is not live.
--
-- The alignment and every caveat behind it live in `ports/zinogre.toml` [moves.lunge];
-- this file is the runtime side of that manifest and nothing more. ⚠️ Nothing reads
-- port.toml at runtime yet (issue #17), so the two are kept in step BY HAND: the
-- clip slot and the (main,sub) below are transcribed, and a rebuild that moves slot 6
-- makes this file wrong without any error.
--
-- Drop next to mhfu_port.lua in ms0:/PSP/PLUGINS/mhfu_framework/mods/ and COLD BOOT
-- (plugins load on cold boot only; a --state launch runs without the framework).

mhfu.port = mhfu.port or { _queue = {} }
mhfu.port.mod = mhfu.port.mod or function(n, f) mhfu.port._queue[n] = f end

mhfu.port.mod("zinogre_lunge", function(P)
  local log = P.log

  ------------------------------------------------------------------ config
  -- 🔴 area_index IS NOT THE USER-FACING SECTION NUMBER and is not sequential:
  -- snow section 1 = 99, base camp = 98, section 6 = 100, section 5 = 93.
  local SNOW_SEC1  = 99
  local IN_AREA    = 17        -- screen_state; anything else is a load/menu/cutscene
  local COLOC      = 6000.0    -- XZ units; inside this, treat us as co-located
  local HP_FLOOR   = 70        -- below this the bar is written back up to MAX
  local PLAYER_HP  = 0x090B3724  -- u16, == player combat entity 0x090B3440 + 0x2E4
  local PLAYER_MAX = 0x090B385E  -- u16 max HP (docs/agent_memory_map.md; 100 base)
  local POPO_WAIT  = 10        -- ticks (~5 s) to look for a Popo before giving up
  local FALLBACK   = 1200.0    -- ...and dropping him this far +X of the hunter
  local HEARTBEAT  = 20        -- ticks (~10 s)
  -- 🔴 A LUNGE CARRIES ITS HITBOX ONCE PER ENTRY (measured 2026-09-11, the hitbox
  -- editor's first live run). The (1,4) handler spawns its attack node when the
  -- clip cursor crosses frame 40 in its opening phase, then sits in phase 3
  -- (+0x1D5) until its RUN BUDGET (+0x76C) is spent — and that budget is set by
  -- the engine's own way in (enter-action -> the main-1 translator ->
  -- 0x09AD9860(ent, 2, 1000.0, -700.0)), which a Lua act_set skips. So written
  -- from here the charge never ends: 38 s in (1,4), phase 3 throughout, the clip
  -- looping every 1.4 s, ZERO spawns, and he runs through you; the hits that did
  -- land were after a flinch knocked him out. Natively the handler hands to (0,3)
  -- (the skid) when the budget is out, (0,6) on a collision — `species/em75.json`
  -- `next`, drawn in the editor's Moves tab. The chain is DECLARED on the move
  -- below (`after` / `hold_max`) and the library walks it; this brain only ends a
  -- charge EARLY, once he is past you, so the next one comes sooner.
  local LUNGE_MIN_TICKS = 3    -- frame 40 at speed 2.4 is ~0.6 s in; the node lives ~1 s
  local LUNGE_MAX_TICKS = 8    -- ~4 s: a charge that never passes you still ends (hold_max)
  -- Cap HIS bar once, on first sight in-area. nil = leave the quest's 2800 alone.
  -- The hit tables (zinogre_hit.lua, #19) already push each hit to the most a grid
  -- byte can say (255%); this is the other lever if "a few hits" still is not.
  local ZIN_HP     = nil       -- e.g. 600

  local zin = P.define{
    name    = "zinogre",
    species = mhfu.MON_TIGREX,        -- the host overlay the port rides on
    replace = { mhfu.MON_GIADROME },  -- swapped at QUEST_TARGETS_BUILDING
    -- ⚠️ v10, NOT the v2 that zinogre_show.lua and zinogre_clips.lua still name.
    -- The clip vocabulary below is a fact about THIS build: the labels in
    -- ports/zinogre.toml are keyed to `zinogre_v10.bin@09091d56`, and slot 6 holds
    -- something else in another build. Check the inject dir actually has it.
    pac     = "zinogre_v10.bin",
    orig    = "file_06185.bin.orig",
    fid     = 6186,
    clips   = { lunge_forward = 6, dash_forward_stop = 21 },  -- a1 == packed slot
    moves   = {
      -- ⚠️ transcribed from ports/zinogre.toml [moves] BY HAND (issue #17): main,
      -- sub, clip, latch, after, hold_max — keep the two in step.
      -- `claim`: every main-1 enter-action the HOST brain makes becomes this move
      -- (the substitution seam). `after`/`hold_max` stay as the fallback chain for
      -- a framework without the seam; with it the charge ends itself.
      lunge      = { main = 1, sub = 4, clip = "lunge_forward", latch = 1,
                     after = "lunge_stop", hold_max = 8, claim = { main = 1 } },
      -- (0,3) is the engine's OWN skid after a charge. Its handler names no clip
      -- (`a1 []`), so undeclared the skid keeps whatever was playing; declared, the
      -- port's dash stop rides it. Its phase 0 seeds the +0x414 frame budget (60
      -- frames) itself, so entered from here it ends on its own -> (0,1)/(0,2).
      lunge_stop = { main = 0, sub = 3, clip = "dash_forward_stop", latch = 1 },
    },
  }

  -- THE NATIVE "PAST YOU" RULE (issue #16): evaluated every frame by the slot-29
  -- stub. In (1,4) for >= 15 frames (the hitbox spawns at clip frame 40 / speed
  -- 2.4 = ~17 frames in), the gap GROWING, and 250..1000 units away -> enter
  -- (0,3). Fires once per charge (the pair changes), then a 1 s cooldown.
  -- 🔴 THE WINDOW IS THE RULE. Take 2 (2026-09-11) ran it as `>= 250, receding`
  -- and it fired on 62 of 65 charges: with the hunter 2000+ units off, any charge
  -- not aimed dead at him reads as "receding" at frame 15, so the rule cut
  -- charges that never came near. "Just past you" is receding AND close: he
  -- crosses you at ~650 units/tick, so [250, 1000) is about one tick wide and
  -- the 30 Hz evaluation is what makes it catchable at all.
  zin:rule{ from = "lunge", min_frames = 15, receding = true, dist = { 250, 1000 },
            play = "lunge_stop", cooldown = 30, label = "just past you" }

  ------------------------------------------------------------------ state
  local placed_in   = nil     -- the area we last dropped him into; nil = armed
  local waited      = 0       -- ticks spent looking for a Popo
  local engaged_at  = nil     -- tick he first noticed the hunter
  local lunges      = 0
  local stops       = 0       -- charges ended EARLY (past you) into lunge_stop
  local saves       = 0       -- times the HP floor caught the hunter

  --- The live Popo furthest from the hunter, as {x, y, z}, plus its distance.
  -- Popos are the only reliable landmark in section 1, and "furthest" puts the
  -- Zinogre across the section so the approach is his own rather than a spawn on
  -- top of the hunter.
  local function furthest_popo(px, pz)
    local list = mhfu.entities_of_type(mhfu.MON_POPO)
    if not list then return nil, 0 end
    local best, bestd2 = nil, -1.0
    for i = 1, #list do
      local e = list[i]
      if e ~= 0 and mhfu.entity_alive(e) then
        local x, y, z = mhfu.entity_pos(e)
        local d2 = (x - px) * (x - px) + (z - pz) * (z - pz)
        if d2 > bestd2 then best, bestd2 = { x, y, z }, d2 end
      end
    end
    if not best then return nil, 0 end
    return best, math.sqrt(bestd2)
  end

  ------------------------------------------------------------------ brain
  local capped = false
  zin:brain(function(s)
    if s.ent == 0 then return end

    -- 0. optional: his HP, capped once (see ZIN_HP). Two cells carry it —
    -- +0x2E4 (what the framework's entity_hp reads) and +0x41E (the resolver's
    -- clamp, what port_state reads; both said 2800 -> 2400 last take) — so both
    -- are written, and a lower value simply sticks.
    if ZIN_HP and not capped and mhfu.get_screen_state() == IN_AREA
        and (s.hp or 0) > ZIN_HP then
      mhfu.write_u16(s.ent + 0x2E4, ZIN_HP)
      mhfu.write_u16(s.ent + 0x41E, ZIN_HP)
      capped = true
      log("[zin_lunge] his HP capped %d -> %d", s.hp, ZIN_HP)
    end

    -- 1. THE HUNTER'S HP FLOOR — refilled to MAX, not to the floor.
    -- 🔴 Measured 2026-09-11: one lunge hit took the bar 100 -> 26 (~74 damage).
    -- The first version wrote it back to 70, and the next hit killed from 70. A
    -- floor you refill TO is a floor one hit removes; refilling to max buys a
    -- whole bar per tick instead.
    -- ⚠️ Still a 2 Hz clamp: two ~74 hits inside half a second still cart you, and
    -- a single hit of 100+ is beyond it. Only while alive and in an area — a 0 is a
    -- cart in progress and writing over it fights the engine.
    local hp = s.player_hp or 0
    if hp > 0 and hp < HP_FLOOR and mhfu.get_screen_state() == IN_AREA then
      local max = mhfu.read_u16(PLAYER_MAX)
      if max < 50 or max > 200 then max = 100 end   -- cell unverified under buffs
      mhfu.write_u16(PLAYER_HP, max)
      saves = saves + 1
      if saves == 1 or saves % 10 == 0 then
        log("[zin_lunge] HP floor caught you at %d -> %d (%d times)", hp, max, saves)
      end
    end

    -- Everything below is about section 1 and needs a settled frame.
    if mhfu.get_screen_state() ~= IN_AREA then return end
    if s.area ~= SNOW_SEC1 then
      -- Leaving re-arms the drop, so walking out and back in stages him again.
      if placed_in ~= nil then
        log("[zin_lunge] you left section 1 (area %d) — re-arming the drop", s.area or -1)
      end
      placed_in, waited = nil, 0
      return
    end

    -- 2. ONE PHYSICAL RELOCATE, THE FIRST TIME THE HUNTER IS IN SECTION 1.
    -- 🔴 ONCE, not per tick. CLAUDE.md §8: maintaining a big monster every tick is
    -- what made swapped monsters look combat-broken for two months. Forcing +0x29A
    -- at 2 Hz does not hold him anyway — the position write is what does.
    if placed_in ~= SNOW_SEC1 then
      local spot, d = furthest_popo(s.px, s.pz)
      if not spot then
        waited = waited + 1
        if waited < POPO_WAIT then return end
        spot = { s.px + FALLBACK, s.py, s.pz }
        log("[zin_lunge] no live Popo after %d ticks — dropping him +%.0fX of you instead",
            waited, FALLBACK)
      else
        log("[zin_lunge] furthest Popo is %.0f units off; putting the Zinogre there", d)
      end
      mhfu.entity_set_pos(s.ent, spot[1], spot[2], spot[3])
      -- 3. THE VISIBILITY FIX, applied the moment he lands.
      -- A swap spawns at native coords but never initialises the section tracker
      -- +0x29A, so the per-frame gate 0x09AC4960 sets the skip-draw bit and he stays
      -- invisible until his first roam. `entity_make_visible` writes +0x29A and ORs
      -- 0x8000 into +0x638 — gates A and B — and the engine clears skip-draw itself.
      mhfu.entity_make_visible(s.ent, s.area)
      placed_in = SNOW_SEC1
      log("[zin_lunge] placed at (%.0f,%.0f) in area %d, visible; over to him",
          spot[1], spot[3], s.area)
      return
    end

    -- Hold the fix while we are co-located. `entity_make_visible` writes only when a
    -- cell actually differs, so this is idempotent, and it touches neither position
    -- nor the freeze gate — his own movement and AI are untouched.
    if s.dist < COLOC then mhfu.entity_make_visible(s.ent, s.area) end

    -- 3b. END A CHARGE EARLY once he is past you. `closing < 0` = the gap is
    -- growing; `since_play` is ticks since the pair was written. The library ends
    -- it anyway at `hold_max` (LUNGE_MAX_TICKS) and hands to `after`; this is the
    -- tactical shortcut so the next charge — and its fresh hitbox — comes sooner.
    -- ⚠️ FALLBACK ONLY: with the seam live the 30 Hz rule above does this the
    -- frame it is true, and a 2 Hz copy would just re-request what it did.
    if not s.native and s.move == "lunge" and s.main == 1 and s.sub == 4 then
      local held = s.since_play or 0
      if held >= LUNGE_MIN_TICKS and (s.closing or 0) < 0 then
        if zin:play("lunge_stop") then  -- the pair AND the port's stop clip
          stops = stops + 1
          if stops <= 3 or stops % 10 == 0 then
            log("[zin_lunge] charge #%d past you after %d ticks (closing %.0f) -> "
                .. "lunge_stop early; the next lunge brings a new hitbox",
                lunges, held, s.closing or 0)
          end
        end
      end
    end

    -- 4. LUNGE WHENEVER HE IS ENGAGED.
    -- ⚠️ `engaged` is +0x5DC: "has noticed you", the '!' over his head — not the
    -- yellow-eye full combat lock, which is a ~0.1 s window because the Felyne
    -- outranks the hunter in the target priority. It is the right gate; the eye is not.
    --
    -- 🔴 ONLY WHEN NO MOVE IS RUNNING. `s.move` goes nil when the engine leaves the
    -- pair we wrote, i.e. when the lunge is over. Re-pulsing before then restarts the
    -- clip from frame 0 — the move never reaches its hitbox frames — and repeated
    -- forcing makes the engine OR in the exhaustion bits and halt the AI outright.
    --
    -- ⚠️ NOT FROM THE SKID. Measured 2026-09-11 over 12 pulses: written from (1,2)
    -- the pair holds 9-97 ticks and dispatches a1=17 (the intel's computed value,
    -- confirmed live); written from the stop pair it lasted EXACTLY ONE tick and
    -- bounced — the engine finishes its stop first. (0,3) is that stop now; wait
    -- for it to hand to (0,1)/(0,2), the next pulse from there holds.
    --
    -- ⚠️ NOR WHILE HE IS ALREADY LUNGING ON HIS OWN. With `claim` the host brain's
    -- attacks ARE lunges (`engine entered 'lunge' itself`, no `s.move`), and asking
    -- for one on top of that is the refusal `play()` logs — 60 of them in take 2.
    if s.engaged and not s.move and not (s.main == 0 and s.sub == 3)
        and not (s.main == 1 and s.sub == 4) then
      if not engaged_at then
        engaged_at = s.tick
        log("[zin_lunge] engaged at d=%.0f — driving lunge from here", s.dist)
      end
      zin:face(s.px, s.pz)      -- aim it; the engine's own rotator renders the turn
      if zin:play("lunge") then
        lunges = lunges + 1
        log("[zin_lunge] lunge #%d  d=%.0f  pair=(%d,%d)->(1,4)  hp=%d",
            lunges, s.dist, s.main or -1, s.sub or -1, s.hp or 0)
      end
    end

    if s.tick % HEARTBEAT == 0 then
      local st = P.native_status and P.native_status() or nil
      local seam = "seam=off"
      if st and st.installed then
        seam = string.format("seam=on sub=%d/%d brain=%d req=%d ai=%d d29=%.0f",
                             st.sub_hits or 0, st.sub_landed or 0, st.brain_fires or 0,
                             st.req_done or 0, st.ai_ticks or 0, st.dist or 0)
      end
      -- `tgt` is +0x2F4 at this instant: PLAYER or CAT. It oscillates (the Felyne
      -- outranks the hunter in +0x542), so read the run of heartbeats, not one —
      -- a monster charging at the CAT is why `d` never shrinks in a take.
      log("[zin_lunge] hb area=%d sec=%d same=%s d=%.0f engaged=%s tgt=%s move=%s "
          .. "pair=(%d,%d) hp=%d you=%d lunges=%d %s",
          s.area or -1, s.section or -1, tostring(s.same_section), s.dist,
          tostring(s.engaged), s.targets_player and "PLAYER" or "other",
          tostring(s.move), s.main or -1, s.sub or -1,
          s.hp or 0, s.player_hp or 0, lunges, seam)
    end
  end)

  log("[zin_lunge] registered — Giadrome->Zinogre, section 1 (area %d), lunge on (1,4); "
      .. "claims main-1 attacks, 'past you' rule -> lunge_stop", SNOW_SEC1)
end)
