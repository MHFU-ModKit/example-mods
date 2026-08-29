-- zinogre_clips.lua — can WE choose which of the port's clips the Zinogre plays?
--
-- The passive test (zinogre_test.lua) answers a different question: does the
-- ENGINE drive our data. This one asks whether the animation channel is
-- STEERABLE — whether an a1 we pick installs the clip we meant, and whether that
-- clip then runs instead of being restarted out from under itself.
--
-- 🔴 IT LATCHES THE CLIP ONLY, AND WRITES NO BEHAVIOUR PAIR. That is deliberate
-- and it is the only reason the measurement is clean. Writing (main, sub) as
-- well would mean a forced handler is also running, and a pair the engine never
-- enters bounces straight back out on its first tick — 411 of 411 forced moves
-- lasted exactly one tick, so the clip restarted twice a second and nothing ever
-- played through. That failure would be indistinguishable from "the port's clips
-- don't work", which is the thing being measured. So: behaviour stays the
-- engine's, animation is ours, and any clip that fails to run fails on its own.
--
-- 🔴 ADVANCE ON CONSUMPTION, NEVER ON A TIMER. A latch is consumed by the next
-- EXECUTOR DISPATCH, not after so many seconds, and the dispatch rate is a
-- property of what the monster is doing — not a constant. The first version of
-- this probe rotated every 4 s and measured almost nothing: parked 2200 units
-- away the Zinogre sat in one looping idle for 65 s at a stretch, so 200 s of
-- probing produced FIVE dispatches and 40+ candidates were overwritten before
-- any of them ever reached the executor. Waiting for the previous one to land
-- makes the probe take as long as the monster needs and lose nothing.
--
-- The verdict is read out of memory, not off the screen — tools/port_clip_probe.py
-- watches ent+0x80's clip-state block and matches each clip's `end` against the
-- authored length in the PAC we built. This script logs the same block itself so
-- the request and the result sit on one line in framework.log.

mhfu.port = mhfu.port or { _queue = {} }
mhfu.port.mod = mhfu.port.mod or function(n, f) mhfu.port._queue[n] = f end

mhfu.port.mod("zinogre_clips", function(P)
  local log = P.log

  local zin = P.define{
    name    = "zinogre",
    species = mhfu.MON_TIGREX,
    replace = { mhfu.MON_GIADROME },
    pac     = "zinogre_v1.bin",
    orig    = "file_06185.bin.orig",
    fid     = 6186,
    clips   = {}, moves = {},
  }

  -- The port keeps the SOURCE slot index, so these are MHP3rd Zinogre slots.
  -- Every one is LONG and carries an authored length no other slot in either
  -- pack shares, so a single `end` read names the clip with no ambiguity:
  --   10 = 408f (loop)   12 = 380f (loop)   19 = 344f
  --    4 = 264f (loop)    2 = 252f          18 = 242f
  -- Slots 3 and 43+ are deliberately absent: they hold a filler copy of the idle
  -- clip (30 host slots got one), so forcing them would prove nothing.
  local PROBE = { 10, 12, 19, 4, 2, 18 }

  -- clip-state block: ent+0x80 + slot*0x40, slot 0 is the body
  local CB = 0x80
  local C_PHASE, C_END, C_PTR, C_FLAGS = 0x10, 0x1C, 0x38, 0x3C
  local A1_APPLIED = 0x324           -- u16, reads 1000 + a1

  local i, armed, waited, started = 0, false, 0, false

  local function state(e)
    return mhfu.read_f32(e + CB + C_PHASE), mhfu.read_f32(e + CB + C_END),
           mhfu.read_u32(e + CB + C_PTR), mhfu.read_u16(e + CB + C_FLAGS),
           mhfu.read_u16(e + A1_APPLIED)
  end

  zin:brain(function(s)
    local e = s.ent or 0
    if e == 0 then return end
    if not started then
      started = true
      log("[zclips] alive ent=0x%08X joints=%d — %d clips, advancing on dispatch",
          e, mhfu.read_u16(e + 0x1A4), #PROBE)
    end

    local phase, fin, ptr, flags, applied = state(e)

    if armed then
      waited = waited + 1
      -- ⚠️ `_clip_uses == 0` means the latch is GONE, not that it was used: the
      -- runtime also drops it when the engine leaves the pair. So this line
      -- reports what the clip-state block actually holds and lets the reader
      -- judge — `applied` == the a1 we asked for is the only proof it landed,
      -- and most of the time it will NOT be, because the engine re-dispatches
      -- its own choice within a second and a 1-use latch does not fight back.
      if (zin._clip_uses or 0) == 0 then
        armed = false
        log("[zclips] latch a1=%d gone -> applied=%d end=%.0f phase=%.0f ptr=0x%08X "
            .. "flags=0x%04X pair=(%d,%d) after %d ticks",
            PROBE[i], applied > 1000 and applied - 1000 or applied, fin, phase,
            ptr, flags, s.main or -1, s.sub or -1, waited)
      elseif waited >= 60 then
        -- ⚠️ Give up on a candidate rather than let one stall the whole take.
        -- Advancing on consumption is right; waiting on it FOREVER is not, and
        -- 30 s with no dispatch means the monster is in a long idle loop, which
        -- says nothing about the clip we asked for.
        armed = false
        log("[zclips] NO DISPATCH for a1=%d in %d ticks — skipping (pair=(%d,%d))",
            PROBE[i], waited, s.main or -1, s.sub or -1)
      elseif waited % 10 == 0 then
        log("[zclips] waiting on a dispatch for a1=%d (%d ticks) pair=(%d,%d)",
            PROBE[i], waited, s.main or -1, s.sub or -1)
      end
      return
    end

    -- let the clip we just installed actually play before asking for another
    if waited > 0 and phase < fin and fin > 0 then
      waited = waited + 1
      if waited < 40 then return end     -- 20 s ceiling, then move on regardless
    end

    i = i + 1
    if i > #PROBE then i = 1 end
    armed, waited = true, 0
    zin:latch(PROBE[i], 1)
    log("[zclips] arm a1=%d (%d/%d) pair=(%d,%d) dist=%.0f",
        PROBE[i], i, #PROBE, s.main or -1, s.sub or -1, s.dist or -1)
  end)
end)
