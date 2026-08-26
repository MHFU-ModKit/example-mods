-- brute_showcase.lua — a ported MHP3rd Brute Tigrex, dropped into an MHFU
-- Giadrome quest and given a scripted fight loop.
--
-- What it demonstrates, and why each half is interesting:
--
--   ASSETS   The quest's Giadrome is REPLACED by a Tigrex (no second big
--            monster, no target-group tricks), and the Brute's PAC is
--            relocate-injected over the Tigrex model file — his skeleton, mesh,
--            textures and animations, with nothing written to disk.
--
--   AI       The Brute charges, is stopped short, struggles in place as if
--            caught in a falltrap, breaks free, and charges again. None of those
--            moves exist in the Tigrex's AI as a sequence. They are assembled
--            from the two channels: host BEHAVIOUR pairs for the physics, the
--            Brute's OWN clips for what you see.
--
-- 🔴 THE LIMIT THIS BRAIN IS SHAPED BY: mhfu_tick is 2 Hz. A charge covers
-- 649-1127 units per tick depending on which host state runs it (measured across
-- 60k logged ticks; the pursuit walk is ~180). So "stop him just before he
-- reaches the player" cannot be a fixed threshold — by the time a tick sees
-- d=400 he is already past the hunter.
--
-- 🔴 AND THE CONSEQUENCE THAT MATTERS ON SCREEN: the distance he COMES TO REST
-- at is set by how far he moves in the one tick the brain cannot see. Abort a
-- 1127-unit charge and he stops somewhere in (SAFE, SAFE + 1183]; abort a
-- 651-unit one and he stops in (SAFE, SAFE + 683]. Played by hand the first
-- reads as "he is always miles away". So the charge is CHOSEN BY SPEED — the
-- candidate whose per-tick travel best matches the gap we want closed — and the
-- fast one is only used from far out. That is the whole reason `speed` is a
-- field here and not a comment.

-- ---------------------------------------------------------------- bootstrap
-- Load order in the mods directory is readdir order — not alphabetical, not
-- guaranteed. Whichever of the two files lands first creates the namespace.
mhfu.port = mhfu.port or { _queue = {} }
mhfu.port.mod = mhfu.port.mod or function(n, f) mhfu.port._queue[n] = f end

mhfu.port.mod("brute_showcase", function(P)

  local log = P.log

  -- ------------------------------------------------------------ the port
  --
  -- CLIPS — the Brute's own animation vocabulary, by executor a1.
  --
  -- ⚠️ These ids are PER BUILD. `docs/brute_tigrex_anim_ids.txt` was labelled by
  -- filming an earlier Brute PAC; on v67_hostslots `a1=51` played the clip that
  -- file calls 52, so the whole table was shifted by one. THAT OFFSET IS
  -- CONFIRMED FOR a1=51 AND NOTHING ELSE — none of the three ids below has been
  -- filmed on this PAC. `tools/anim_capture.sh <pac> <a1>` is how you check, and
  -- there is no way to read a clip's meaning out of the file.
  local brute = P.define{
    name    = "brute_tigrex",
    species = mhfu.MON_TIGREX,
    replace = { mhfu.MON_GIADROME },
    pac     = "brute_tigrex_v67_hostslots.bin",
    orig    = "file_06185.bin.orig",
    fid     = 6186,

    clips = {
      charge     = 61,   -- label 62 "crazy forward charge"
      trapped    = 82,   -- label 83 "stuck in falltrap"
      break_free = 69,   -- label 70 "break free from trap"
    },

    -- MOVES — the alignment. `main`/`sub` is the host behaviour that runs (the
    -- physics, the hitbox, the damage); `clip` is what the Brute shows while it
    -- does. The host's own opinion about which animation belongs to that pair is
    -- discarded at the executor seam.
    --
    -- 🔴 EVERY PAIR HERE COMES OUT OF `tools/em_state_census.py`, AND THAT IS
    -- THE FIX FROM THE LAST SESSION. The first working build ran its pinned loop
    -- on (4,15) and (4,8), picked off the offline dispatcher table because their
    -- handlers ask the executor for trap animations. Main 4 is the DAMAGE-
    -- REACTION bank: on an undamaged, untrapped monster those handlers return on
    -- their first tick. Live, 411 of 411 forced moves lasted exactly ONE tick —
    -- the clip restarted from frame 0 twice a second and never played through,
    -- and the engine fell back to the pursuit state (2,4) every single time. The
    -- census says the engine enters (4,15) and (4,8) ZERO times in ~1600
    -- observed transitions. What replaced them is what the engine actually
    -- dwells in:
    --
    --   state    dwell   n   move/tick   verdict
    --   (2, 1)    11.5   45         45   HOLDS + DRIFTS   <- struggling
    --   (3, 0)    10.9  123        121   HOLDS + MOVES    <- breaking free
    --   (0, 4)     8.9    8         84   HOLDS + MOVES    <- spares
    --   (0, 8)    10.4   99        147   HOLDS + MOVES
    --
    -- ⚠️ Dwell measured when the ENGINE chose a state is still not proof it will
    -- accept being FORCED — (3,6) closes 649 units/tick when the engine picks it
    -- and bounced out in 1-7 ticks when this mod forced it from 5400 units. So
    -- every list below is a SHORTLIST the brain rotates through on refusal, and
    -- `last_move_ticks` is how it finds out.
    moves = {
      charge_a   = { main = 2, sub = 8,  clip = "charge"     },
      charge_b   = { main = 2, sub = 13, clip = "charge"     },
      charge_c   = { main = 3, sub = 6,  clip = "charge"     },
      charge_d   = { main = 1, sub = 1,  clip = "charge"     },

      trapped_a  = { main = 2, sub = 1,  clip = "trapped"    },
      trapped_b  = { main = 0, sub = 4,  clip = "trapped"    },

      break_a    = { main = 3, sub = 0,  clip = "break_free" },
      break_b    = { main = 0, sub = 8,  clip = "break_free" },
    },
  }

  -- ------------------------------------------------------------ modes
  -- SCRIPT = false loads the port and leaves his AI COMPLETELY ALONE: the quest
  -- swap and the asset inject still happen, so you get the ported Brute with his
  -- own skeleton, mesh, textures and animations fighting you with the host
  -- Tigrex's brain and his host moveset. That is the right mode for "does the
  -- port actually work", and the right one to play first — the scripted loop is
  -- deliberately unnatural.
  local SCRIPT = true

  -- 🔴 THE PIN STAYS, AND NOW IT HAS A NUMBER ON IT. The plan was to retire it:
  -- the census called (2,1) "HOLDS + STATIONARY", so a lock should have had
  -- nothing to do. It was wrong, and the report's threshold was why — 45 units
  -- per TICK is 90 units a SECOND, and a probe that held (2,1) continuously
  -- walked the Brute 10 952 -> 31 164 units off the map in 450 s. So (2,1)
  -- drifts, slowly, in whatever direction he faces, and the struggle does need
  -- holding down.
  --
  -- What HAS changed is what the pin is fighting. The old build's struggle pair
  -- bounced out on its first tick into the pursuit state (2,4), and the lock
  -- then had 526-646 units to undo EVERY TICK — that tug of war is what "he
  -- floats forward and clips back" was. Against (2,1) it has ~45. The
  -- `pin has corrected N ticks, M units total` line is the gauge: divide and
  -- compare to 45, and to the old 526.
  --
  --   "off"      never pin. Use it to see the drift for yourself.
  --   "backstop" pin only if he crosses SAFE — the diagnostic setting.
  --   "always"   pin for the whole struggle. The right one for FOOTAGE.
  local PIN = "always"

  -- ------------------------------------------------------------ tuning
  --
  -- 🔴 THESE NUMBERS ARE THE ANSWER TO "HE WAS USUALLY VERY FAR AWAY". The loop
  -- used to live at 1600-4200 units because RELEASE_AT was 1600 and a 1127-unit
  -- charge cannot be aborted closer than ~1600. Both halves are fixed: the
  -- charge is picked to match the gap (below), and the release gap came down
  -- with it. The camera sits ~490 units behind the hunter, so a monster resting
  -- at 650 fills the frame — which is the shot.
  local STANDOFF      = 650    -- where we WANT him to come to rest
  local SAFE          = 320    -- and where he must never finish closer than
  local RELEASE_AT    = 1050   -- hunter has opened this gap -> charge again
  local CHARGE_FROM   = 1250   -- only start a charge from at least this far out
  -- 🔴 A BAND, not a floor. Beyond it the Brute is left to his own AI: his
  -- pursuit walk closes ~180 units/tick and it is the only thing that reliably
  -- brings him in from across a section. Forcing an attack state at 5000 units
  -- just makes the handler bounce straight back out, which is what take 1 spent
  -- its whole window doing.
  local CHARGE_UNTIL  = 3600

  -- 🔴 THE ABORT IS PREDICTIVE, and it has to be. A fixed threshold T means the
  -- Brute comes to rest anywhere in (T - v, T], where v is how far he moves in
  -- the 500 ms the brain cannot see. So the brain projects: abort when ONE MORE
  -- STEP AT HIS CURRENT SPEED would bring him inside SAFE.
  --
  -- ⚠️ The head-room is 1.05, not something comfortable like 1.2. At 1.2 the
  -- projection trips a whole step early: the dry-run had him abort at d=1733
  -- when one more 1127-unit step would have put him at 606 — safely outside
  -- SAFE and, at a camera distance of ~490, right on top of the hunter on
  -- screen. Being conservative here does not make him safer, it parks him two
  -- screens away.
  local LOOKAHEAD     = 1.05
  -- ⚠️ `closing`, not `travelled`. The gap shrinks at the RELATIVE rate, and a
  -- hunter walking into the charge contributes his own speed to it — a dry run
  -- of that had the Brute finish at d=189 against a SAFE of 320.
  local function abort_line(s)
    local rate = math.max(s.travelled, s.closing or 0)
    return SAFE + math.max(rate * LOOKAHEAD, 250)
  end

  local CHARGE_EVERY  = 6      -- ticks between charge pulses (~3 s)
  local TRAPPED_FOR   = 8      -- ticks of struggling (~4 s)
  local BREAK_FOR      = 5     -- ticks of breaking free (~2.5 s)
  local MIN_DWELL     = 2      -- a forced move that ends this fast was REFUSED
  local CHARGE_MIN_TRAVEL = 250

  -- ------------------------------------------------------------ shortlists
  --
  -- 🔴 THE CHARGE IS PICKED BY SPEED. `speed` starts at the census figure and is
  -- then overwritten by what the move actually achieved this run, so a build on
  -- a different host state or a different section corrects itself. The pick is
  -- the candidate whose per-tick travel is closest to the gap we want closed
  -- (d - STANDOFF) — which is what stops him near the hunter instead of near the
  -- ridge. `?` speeds are the census's "never seen on two consecutive co-located
  -- ticks"; they get a neutral guess and are corrected on first use.
  local CHARGES = {
    { move = "charge_a", speed = 1127 },   -- (2,8)   census n=46
    { move = "charge_b", speed =  651 },   -- (2,13)  census n=4
    { move = "charge_c", speed =  649 },   -- (3,6)   census n=120, refused once
    { move = "charge_d", speed =  400 },   -- (1,1)   never observed
  }
  local TRAPPEDS = { "trapped_a", "trapped_b" }
  local BREAKS   = { "break_a", "break_b" }

  local function rotate(list, i)
    return (i % #list) + 1
  end

  -- Skip a candidate the engine has refused three times, but never let the list
  -- empty out: if everything is struck off, forgive them all and start again.
  -- A permanently empty shortlist is a brain that silently stops doing anything.
  local function pick_charge(d)
    local want = d - STANDOFF
    local best, best_err
    for _, c in ipairs(CHARGES) do
      if (c.strikes or 0) < 3 then
        local err = math.abs(c.speed - want)
        if not best_err or err < best_err then best, best_err = c, err end
      end
    end
    if not best then
      for _, c in ipairs(CHARGES) do c.strikes = 0 end
      log("[showcase] every charge candidate was struck off — forgiving all")
      best = CHARGES[1]
    end
    return best
  end

  -- ------------------------------------------------------------ the brain
  local phase, since, last_note = "off", 0, ""
  local cur, charge_travel = nil, 0     -- the charge candidate in flight
  local ti, bi = 1, 1                   -- struggle / break-free shortlist cursors

  local function enter(p, s, why)
    if phase == p then return end
    phase, since = p, s.tick
    log("[showcase] -> %s  d=%d  travelled=%d  state=(%d,%d)  hp=%d  "
        .. "mon=(%d,%d)/%d plr=(%d,%d)/%d  tgt=%s  %s",
        p, math.floor(s.dist), math.floor(s.travelled), s.main, s.sub, s.hp,
        math.floor(s.x), math.floor(s.z), s.section,
        math.floor(s.px), math.floor(s.pz), s.area,
        s.targets_player and "PLAYER" or string.format("0x%08X", s.target),
        why or "")
  end

  if not SCRIPT then
    log("[showcase] assets only — the Brute is loaded, his AI is untouched")
    return
  end

  brute:brain(function(s)
    -- ---- the gate: same section AND actually hunting the player -------------
    -- ⚠️ Engage (+0x5DC) is DETECTED/PURSUING, not full combat — the '!' over his
    -- head, not the yellow eye. Played by hand the yellow eye never appeared at
    -- all, and `s.target` is why: a Giadrome->Tigrex swap resolves its combat
    -- target to the CAT, not the hunter. The gate stays on `engaged` because
    -- that is the condition the loop is ABOUT ("he has committed to coming at
    -- you"), but every phase line now carries `tgt=` so a take says which it was.
    if not (s.same_section and s.engaged) then
      if phase ~= "off" then
        brute:release()
        enter("off", s, s.same_section and "disengaged" or "left the section")
      end
      -- a cheap heartbeat so a run that never engages is diagnosable
      local note = string.format(
        "%s sec=%d/%d eng=%s acq=%d tgt=0x%08X%s d=%d  mon=(%d,%d) plr=(%d,%d)",
        s.same_section and "here" or "away", s.section, s.area,
        tostring(s.engaged), s.acquired, s.target,
        s.targets_player and " (PLAYER)" or "", math.floor(s.dist),
        math.floor(s.x), math.floor(s.z), math.floor(s.px), math.floor(s.pz))
      if note ~= last_note and (s.tick % 10) == 0 then
        last_note = note
        log("[showcase] idle: %s", note)
      end
      return
    end

    -- A frame change invalidates the speed signal the abort is projected from,
    -- and `release()` here is right rather than merely safe: he is somewhere
    -- else now, and whatever was scripted was scripted about the old geometry.
    if s.reframed then
      if phase ~= "off" then brute:release(); enter("hunting", s, "world frame changed") end
      return
    end

    -- ---- pinned: struggle, break free, struggle ----------------------------
    if phase == "pinned" or phase == "breaking" then
      if s.dist > RELEASE_AT then
        brute:unpin()
        enter("hunting", s, "hunter got away")
        return
      end
      -- Under "always" this is just the lock coming on with the phase. Under
      -- "backstop" it only fires when he has crossed SAFE anyway, which is the
      -- signal that the pair under it is the wrong one.
      if PIN ~= "off" and not s.pinned
         and (PIN == "always" or s.dist < SAFE) then
        brute:pin()
        if PIN ~= "always" then
          log("[showcase] pin engaged at d=%d — (%d,%d) is not holding him",
              math.floor(s.dist), s.main, s.sub)
        end
      end

      -- A struggle pair that ends on its first tick is being refused the same
      -- way (4,15) was; rotate to the next one rather than re-issuing it twice a
      -- second forever.
      if s.last_move and s.last_move_ticks <= MIN_DWELL then
        if s.last_move == TRAPPEDS[ti] then
          ti = rotate(TRAPPEDS, ti)
          log("[showcase] '%s' lasted %d ticks — refused, trying %s",
              s.last_move, s.last_move_ticks, TRAPPEDS[ti])
        elseif s.last_move == BREAKS[bi] then
          bi = rotate(BREAKS, bi)
          log("[showcase] '%s' lasted %d ticks — refused, trying %s",
              s.last_move, s.last_move_ticks, BREAKS[bi])
        end
      end

      -- 🔴 KEEP HIM IN THE SCRIPTED MOVE. A host handler runs for a couple of
      -- seconds and then hands back to the Tigrex's own AI — and the Tigrex's own
      -- AI, standing next to a hunter, ATTACKS. Re-issuing on move-end is what
      -- makes "he cannot hit the player" true rather than merely likely. play()
      -- enforces its own minimum gap, so this is not per-tick forcing.
      local held = s.tick - since
      if phase == "pinned" and held >= TRAPPED_FOR then
        brute:play(BREAKS[bi])
        enter("breaking", s, "struggling loose")
      elseif phase == "breaking" and held >= BREAK_FOR then
        brute:play(TRAPPEDS[ti])
        enter("pinned", s, "stuck again")
      elseif s.move == nil then
        brute:play(phase == "pinned" and TRAPPEDS[ti] or BREAKS[bi])
      end
      return
    end

    -- ---- charging: abort the moment he is close enough ---------------------
    -- ⚠️ Aborting IS act_set. Writing a new pair mid-move zeroes the phase
    -- cursor, so the running handler never reaches its hitbox frames. That is
    -- the mechanism the two-channel work proved, used here to interrupt rather
    -- than to start.
    if phase == "charging" and s.dist <= abort_line(s) then
      if cur then
        -- what the charge ACTUALLY achieved, fed back into the pick for next
        -- time. `charge_travel` is 0 when the abort fires on the very tick after
        -- the pulse (this branch is tested before the accumulator runs), so take
        -- this tick's own travel too or the log reports a charge that moved him
        -- 1127 units as "closed 0/tick".
        local achieved = math.max(charge_travel, s.travelled)
        if achieved >= CHARGE_MIN_TRAVEL then cur.speed = achieved end
        log("[showcase] %s closed %d/tick, stopped at d=%d (wanted %d)",
            cur.move, math.floor(achieved), math.floor(s.dist), STANDOFF)
      end
      if PIN == "always" then brute:pin() end
      brute:play(TRAPPEDS[ti])
      enter("pinned", s, "charge aborted in reach")
      return
    end

    -- ---- hunting: line him up and send him ---------------------------------
    if s.dist <= abort_line(s) then
      -- he closed on his own AI without ever charging — stop him anyway, the
      -- loop is about what he does NEXT TO the hunter as much as the charge
      if PIN == "always" then brute:pin() end
      brute:play(TRAPPEDS[ti])
      enter("pinned", s, "walked into reach")
      return
    end

    -- ---- out of band: his own AI walks him in -----------------------------
    if s.dist > CHARGE_UNTIL then
      if phase ~= "hunting" then brute:release(); enter("hunting", s, "too far — his own AI") end
      return
    end

    -- ---- charging ----------------------------------------------------------
    if phase == "charging" then
      charge_travel = math.max(charge_travel, s.travelled)
      -- The move is over. Did it actually move him? If not, this candidate is
      -- being refused and it earns a strike.
      if s.move == nil then
        if cur then
          if charge_travel < CHARGE_MIN_TRAVEL then
            cur.strikes = (cur.strikes or 0) + 1
            log("[showcase] %s moved him %d/tick in %d ticks — refused (strike %d)",
                cur.move, math.floor(charge_travel), s.last_move_ticks or 0, cur.strikes)
          else
            cur.speed = charge_travel
            log("[showcase] %s moved him %d/tick over %d ticks  d=%d",
                cur.move, math.floor(charge_travel), s.last_move_ticks or 0,
                math.floor(s.dist))
          end
        end
        charge_travel = 0
        if s.dist >= CHARGE_FROM and s.dist > abort_line(s) then
          cur = pick_charge(s.dist)
          brute:face(s.px, s.pz)
          brute:play(cur.move)
        else
          enter("hunting", s, "charge over, too close to start another")
        end
      end
      return
    end

    if s.dist >= CHARGE_FROM and (s.tick - since) >= CHARGE_EVERY then
      cur = pick_charge(s.dist)
      brute:face(s.px, s.pz)     -- +0x1F4, so the engine's own rotator turns him
      charge_travel = 0
      brute:play(cur.move)
      enter("charging", s, string.format("%s (speed %d) for a %d gap",
                                         cur.move, cur.speed,
                                         math.floor(s.dist - STANDOFF)))
      return
    end

    if phase == "off" then enter("hunting", s, "engaged") end
  end)

  log("[showcase] brute_showcase registered (pin=%s standoff=%d safe=%d "
      .. "release=%d band=%d..%d)",
      PIN, STANDOFF, SAFE, RELEASE_AT, CHARGE_FROM, CHARGE_UNTIL)
end)
