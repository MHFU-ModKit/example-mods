-- clip_probe.lua — SHOW ME WHAT THIS CLIP ACTUALLY IS.
--
-- 🔴 There is no way to read a clip's meaning out of a PAC. `a1` is an index;
-- what the packer put at that index is whatever the port pipeline decided, and
-- `docs/brute_tigrex_anim_ids.txt` is a table somebody built by FILMING an
-- earlier build. On `brute_tigrex_v67_hostslots.bin` every id turned out to be
-- shifted by one — but that was established for `a1=51` and nothing else, and a
-- showcase whose three clip ids have never been checked is a showcase that may
-- be playing three wrong animations very convincingly.
--
-- So: hold the monster in a behaviour state that does NOT move him, latch one
-- clip at a time on top of it, and say in the log which one is showing. Anything
-- that moves on screen is then the CLIP's own root motion and nothing else —
-- which is also the cleanest test of "he flings into the air", because the body
-- has no engine-driven motion to hide it.
--
--   python tools/clip_probe.py --clips 61,82,69
--
-- ⚠️ (2,1) is the pair, from `tools/em_state_census.py`: mean dwell 11.5 ticks,
-- the longest-held well-sampled state the engine actually enters. A pair the
-- engine never enters (main 4, the damage-reaction bank) returns on its first
-- tick and the clip restarts from frame 0 twice a second forever — which looks
-- exactly like an animation that does not play.
--
-- 🔴 AND IT IS NOT ACTUALLY STATIONARY. The census used to call it
-- "HOLDS + STATIONARY" because it moves 45 units per TICK, under that report's
-- old threshold of 60 (it says DRIFTS now, and the thresholds were retuned). At
-- 2 Hz that is **90 units a second in whatever direction he happens to face**,
-- and the first version of this probe held it continuously: the Brute walked
-- calmly off the map, 10 952 -> 31 164 units over 450 s, while the run sat
-- waiting for him to arrive. Two things follow, and both are here:
--   * the probe stays INERT until he is genuinely close (NEAR below), because
--     `same_section` is true long before he is anywhere near — `+0x29A` commits
--     to the destination section while the monster is still 20 000 units away;
--   * and it PINS him while a clip is showing. This is the pin's one honest use:
--     the underlying behaviour drifts slowly and predictably, so the lock has
--     45 units a tick to absorb rather than a pursuit state to fight, and
--     anything that then moves on screen is the CLIP.

mhfu.port = mhfu.port or { _queue = {} }
mhfu.port.mod = mhfu.port.mod or function(n, f) mhfu.port._queue[n] = f end

mhfu.port.mod("clip_probe", function(P)

  local log = P.log

  -- tools/clip_probe.py rewrites this line.
  local CLIPS = { 61, 82, 69 }
  local HOLD  = 16          -- ticks per clip (~8 s at the 2 Hz tick)
  local NEAR  = 3000        -- do nothing at all until he is this close

  local moves = {}
  for i, a1 in ipairs(CLIPS) do
    -- `anim` is a raw executor id, as opposed to `clip` which names an entry in
    -- the port's clip table. Same latch either way.
    moves["clip_" .. i] = { main = 2, sub = 1, anim = a1 }
  end

  local probe = P.define{
    name    = "clip_probe",
    species = mhfu.MON_TIGREX,
    replace = { mhfu.MON_GIADROME },
    pac     = "brute_tigrex_v67_hostslots.bin",
    orig    = "file_06185.bin.orig",
    fid     = 6186,
    moves   = moves,
  }

  local i, since = 1, nil

  local function show(n, s, why)
    i, since = n, s.tick
    probe:play("clip_" .. i)
    log("[clipprobe] showing a1=%d  (%d/%d)  d=%d  state=(%d,%d)  %s",
        CLIPS[i], i, #CLIPS, math.floor(s.dist), s.main, s.sub, why or "")
  end

  probe:brain(function(s)
    if not s.same_section or s.dist > NEAR then
      if since then
        since = nil
        probe:release()
        log("[clipprobe] %s (d=%d) — hands off",
            s.same_section and "too far" or "out of section", math.floor(s.dist))
      end
      return
    end
    probe:pin()
    if since == nil then
      show(i, s, "start")
    elseif (s.tick - since) >= HOLD then
      show((i % #CLIPS) + 1, s, "next")
    elseif s.move == nil then
      -- the host handler finished on its own; put the clip back without
      -- restarting the hold, so each id still gets its full window
      probe:play("clip_" .. i)
    end
  end)

  log("[clipprobe] registered — %d clips, %d ticks each, active inside %d units",
      #CLIPS, HOLD, NEAR)
end)
