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
--   AI       The Brute charges, is stopped short, is pinned in place struggling
--            as if caught in a falltrap, breaks free, and charges again. None of
--            those moves exist in the Tigrex's AI as a sequence. They are
--            assembled from the two channels: host BEHAVIOUR pairs for the
--            physics, the Brute's OWN clips for what you see.
--
-- 🔴 THE LIMIT THIS BRAIN IS SHAPED BY: mhfu_tick is 2 Hz. A charge covers
-- 649-1127 units per tick depending on which host state runs it (measured across
-- 60k logged ticks; the pursuit walk is ~180). So "stop him just before he
-- reaches the player" cannot be a fixed threshold — by the time a tick sees
-- d=400 he is already past the hunter. The abort is PROJECTED from his measured
-- speed instead, and the coordinate pin is the backstop for the half-second the
-- brain cannot see.

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
  -- filming an earlier Brute PAC; on v67_hostslots every id shifted by one, so
  -- `a1 = label - 1` (a1=51 plays the clip the file calls 52, "throw rocks").
  -- Re-derive with `tools/anim_capture.sh <pac> <a1>` when the PAC changes —
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
    moves = {
      -- 🔴 THE CHARGE IS A SHORTLIST, NOT A PICK — and the first take is why.
      -- The candidates are mined out of 60k logged ticks by per-state closing
      -- speed: (2,8) closes 1127 units/tick, (3,6) 649, (2,13) 539; everything
      -- else is under 200. But those are speeds the states reach when the ENGINE
      -- chooses them. Forced at 5400 units, (3,6) exited after 1-7 ticks with
      -- ~30 units of travel: it is a close-range lunge whose handler refuses a
      -- target that far away. Measurement narrows the field; only trying tells
      -- you which one takes. The brain rotates on a charge that does not move
      -- him, and logs what each one achieved.
      charge_a   = { main = 2, sub = 8,  clip = "charge"     },
      charge_b   = { main = 3, sub = 6,  clip = "charge"     },
      charge_c   = { main = 2, sub = 13, clip = "charge"     },
      charge_d   = { main = 1, sub = 1,  clip = "charge"     },
      -- Main 4 is the reaction/trap bank. (4,15) asks the host for a1 83 and
      -- (4,8) for 70/71/77/78 — trap semantics on the host side too, so the
      -- behaviour and the clip mean the same thing rather than merely looking
      -- like it. Both are stationary, which is what a pinned monster needs.
      trapped    = { main = 4, sub = 15, clip = "trapped"    },
      break_free = { main = 4, sub = 8,  clip = "break_free" },
    },
  }

  -- ------------------------------------------------------------ modes
  -- SCRIPT = false loads the port and leaves his AI COMPLETELY ALONE: the quest
  -- swap and the asset inject still happen, so you get the ported Brute with his
  -- own skeleton, mesh, textures and animations fighting you with the host
  -- Tigrex's brain and his host moveset. That is the right mode for "does the
  -- port actually work", and the right one to play first — the scripted loop is
  -- deliberately unnatural.
  --
  -- PIN = false keeps the scripted loop but drops the coordinate lock. The lock
  -- is what makes his movement look odd: it rewrites his position twice a second
  -- while the animation keeps playing, so he visibly snaps back (a take logged
  -- 152 corrections, some of 400+ units). Without it he can reach the hunter,
  -- which is the trade.
  local SCRIPT        = true
  local PIN           = true   -- lock his coordinates during the pinned phase

  -- ------------------------------------------------------------ tuning
  local CHARGES       = { "charge_a", "charge_b", "charge_c", "charge_d" }
  local CHARGE_MIN_TRAVEL = 250  -- a charge that moves less than this per tick
                                 -- is being refused; try the next candidate
  -- 🔴 A BAND, not a floor. Outside it the Brute is left to his own AI: his
  -- pursuit walk closes ~180 units/tick and it is the only thing that reliably
  -- brings him in from across a section. Forcing an attack state at 5000 units
  -- just makes the handler bounce straight back out, which is what take 1 spent
  -- its whole window doing.
  local CHARGE_UNTIL  = 4200   -- beyond this, hands off — let him walk in
  local CHARGE_FROM   = 1900   -- only start a charge from at least this far out
  -- 🔴 THE ABORT IS PREDICTIVE, and it has to be. A fixed threshold T means the
  -- Brute comes to rest anywhere in (T - v, T], where v is how far he moves in
  -- the 500 ms the brain cannot see — and v is 1127 units on the fastest charge
  -- candidate and 180 on a walk. One threshold cannot serve both: set it for the
  -- charge and he stops a screen away when he walks in; set it for the walk and
  -- a charge lands on top of the hunter.
  --
  -- So the brain projects instead: abort when ONE MORE STEP AT HIS CURRENT SPEED
  -- would bring him inside SAFE. `travelled` is the measured per-tick distance,
  -- the only speed signal a 2 Hz brain gets; the 300 floor covers a standing
  -- start.
  --
  -- ⚠️ The head-room is 1.05, not something comfortable like 1.2. At 1.2 the
  -- projection trips a whole step early: the dry-run had him abort at d=1733
  -- when one more 1127-unit step would have put him at 606 — safely outside
  -- SAFE and, at a camera distance of ~490, right on top of the hunter on
  -- screen. Being conservative here does not make him safer, it just parks him
  -- two screens away.
  local SAFE          = 450    -- never let a charge finish closer than this
  local LOOKAHEAD     = 1.05
  local function abort_line(s) return SAFE + math.max(s.travelled * LOOKAHEAD, 300) end
  -- ⚠️ 1600, not 1900. The hunter has to open this gap to re-trigger a charge,
  -- and in snowy-mountains section 6 the room to back away from a pinned monster
  -- is not much more than that before a zone gate takes over — a take spent its
  -- second half on the far side of a loading screen because the retreat needed
  -- 1900.
  local RELEASE_AT    = 1600   -- player has escaped the pin -> charge again
  local CHARGE_EVERY  = 7      -- ticks between charge pulses (~3.5 s)
  local TRAPPED_FOR   = 8      -- ticks of struggling (~4 s)
  local BREAK_FOR     = 5      -- ticks of breaking free (~2.5 s)

  -- ------------------------------------------------------------ the brain
  local phase, since, last_note = "off", 0, ""
  local ci, charge_travel = 1, 0   -- which charge candidate, and what it achieved

  local function enter(p, s, why)
    if phase == p then return end
    phase, since = p, s.tick
    log("[showcase] -> %s  d=%d  travelled=%d  state=(%d,%d)  hp=%d  "
        .. "mon=(%d,%d)/%d plr=(%d,%d)/%d  %s",
        p, math.floor(s.dist), math.floor(s.travelled), s.main, s.sub, s.hp,
        math.floor(s.x), math.floor(s.z), s.section,
        math.floor(s.px), math.floor(s.pz), s.area, why or "")
  end

  if not SCRIPT then
    log("[showcase] assets only — the Brute is loaded, his AI is untouched")
    return
  end

  brute:brain(function(s)
    -- ---- the gate: same section AND actually hunting the player -------------
    -- Engage (+0x5DC) is the engine's own "combat mode entered" flag — the same
    -- state the yellow eye marker reflects. Outside it the Brute is left
    -- completely alone, which is the point: the scripted loop is what he does
    -- when he decides to fight, not a permanent override.
    if not (s.same_section and s.engaged) then
      if phase ~= "off" then
        brute:release()
        enter("off", s, s.same_section and "disengaged" or "left the section")
      end
      -- a cheap heartbeat so a run that never engages is diagnosable
      local note = string.format(
        "%s sec=%d/%d eng=%s d=%d  mon=(%d,%d) plr=(%d,%d)",
        s.same_section and "here" or "away", s.section, s.area,
        tostring(s.engaged), math.floor(s.dist),
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
      -- 🔴 KEEP HIM IN THE SCRIPTED MOVE. A host handler runs for a couple of
      -- seconds and then hands back to the Tigrex's own AI — and the Tigrex's own
      -- AI, standing next to a hunter, ATTACKS. Re-issuing on move-end is what
      -- makes "he cannot hit the player" true rather than merely likely. play()
      -- enforces its own minimum gap, so this is not per-tick forcing.
      local held = s.tick - since
      if phase == "pinned" and held >= TRAPPED_FOR then
        brute:play("break_free")
        enter("breaking", s, "struggling loose")
      elseif phase == "breaking" and held >= BREAK_FOR then
        brute:play("trapped")
        enter("pinned", s, "stuck again")
      elseif s.move == nil then
        brute:play(phase == "pinned" and "trapped" or "break_free")
      end
      return
    end

    -- ---- charging: abort the moment he is close enough ---------------------
    -- ⚠️ Aborting IS act_set. Writing a new pair mid-move zeroes the phase
    -- cursor, so the running handler never reaches its hitbox frames. That is
    -- the mechanism the two-channel work proved, used here to interrupt rather
    -- than to start. The pin is the backstop for the 500 ms the brain is blind.
    if phase == "charging" and s.dist <= abort_line(s) then
      if PIN then brute:pin() end
      brute:play("trapped")
      enter("pinned", s, "charge aborted in reach")
      return
    end

    -- ---- hunting: line him up and send him ---------------------------------
    if s.dist <= abort_line(s) then
      -- he closed on his own AI without ever charging — pin him anyway, the
      -- loop is about what he does NEXT TO the hunter as much as the charge
      if PIN then brute:pin() end
      brute:play("trapped")
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
      -- being refused and the next one gets the next attempt.
      if s.move == nil then
        local name = CHARGES[ci]
        if charge_travel < CHARGE_MIN_TRAVEL then
          ci = (ci % #CHARGES) + 1
          log("[showcase] %s moved him %d/tick — refused, trying %s  (d=%d t=%d)",
              name, math.floor(charge_travel), CHARGES[ci], math.floor(s.dist), s.tick)
        else
          log("[showcase] %s moved him %d/tick  d=%d t=%d",
              name, math.floor(charge_travel), math.floor(s.dist), s.tick)
        end
        charge_travel = 0
        if s.dist >= CHARGE_FROM and s.dist > abort_line(s) then
          brute:face(s.px, s.pz)
          brute:play(CHARGES[ci])
        end
      end
      return
    end

    if s.dist >= CHARGE_FROM and (s.tick - since) >= CHARGE_EVERY then
      brute:face(s.px, s.pz)     -- +0x1F4, so the engine's own rotator turns him
      charge_travel = 0
      brute:play(CHARGES[ci])
      enter("charging", s, "lined up with " .. CHARGES[ci])
      return
    end

    if phase == "off" then enter("hunting", s, "engaged") end
  end)

  log("[showcase] brute_showcase registered (pin=%s safe=%d release=%d band=%d..%d)",
      tostring(PIN), SAFE, RELEASE_AT, CHARGE_FROM, CHARGE_UNTIL)
end)
