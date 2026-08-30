-- zinogre_test.lua — does a NO-SIMILAR-NATIVE port load, render and animate?
--
-- The Brute rides the Tigrex rig because it IS a Tigrex. The Zinogre is not: a
-- Fanged Wyvern whose 51 bones branch at bone 1 into a front and a rear half, so
-- MHFU has nothing comparable and the port ships the monster's OWN skeleton, its
-- OWN per-vertex skin and its OWN clips. Everything the retarget path leans on
-- is gone, which is exactly what makes it the test.
--
-- It is also the first build carrying a stream partition READ OFF THE BONE TREE
-- rather than sliced off the end ([33, 6, 7], head at source bones 18-23) — see
-- docs/ANIMATION_FORMAT.md "Stream partition".
--
-- 🔴 THIS SCRIPT DELIBERATELY DOES NOTHING PER TICK. No act_set, no clip latch,
-- no size, no freeze gate, no coordinate pin. A clean REPLACE alone fights and
-- kills, and every earlier "swapped monsters look combat-broken" reading came
-- from a script maintaining the monster every frame. The question here is
-- whether the ENGINE drives our data, so the engine is left alone with it.
--
-- The driver reads the verdict out of memory: tools/test_ported_monster.py.

mhfu.port = mhfu.port or { _queue = {} }
mhfu.port.mod = mhfu.port.mod or function(n, f) mhfu.port._queue[n] = f end

mhfu.port.mod("zinogre_test", function(P)
  local log = P.log

  local zin = P.define{
    name    = "zinogre",
    species = mhfu.MON_TIGREX,
    replace = { mhfu.MON_GIADROME },
    pac     = "zinogre_v10.bin",
    orig    = "file_06185.bin.orig",
    fid     = 6186,
    clips   = {},
    moves   = {},
  }

  local announced, unculled = false, false

  zin:brain(function(s)
    -- 🔴 ONE-SHOT VISIBILITY FIX — the swap spawns him with +0x29A never
    -- initialised, so the per-frame gate 0x09AC4960 skip-draws him even when he
    -- is standing in front of you. It compares RAW area indices, and the port
    -- always comes up 109 (section 6's NIGHT-bank index) against a day-bank
    -- player. Same section NUMBER, different index -> culled. Three walks were
    -- spent finding an invisible monster before this went in the script.
    --
    -- ⚠️ ONE WRITE, guarded, and only once he is genuinely NEAR — never per tick
    -- (CLAUDE.md rule 8). The engine clears its own skip-draw bit the next frame,
    -- and a real section transition maintains the field from then on. The
    -- distance gate matters because +0x29A also LAGS by tens of seconds while he
    -- roams, so "the fields disagree" alone is not evidence he is here.
    -- ⚠️ 2500, not 6000. The first version used 6000 and fired while the hunter
    -- was still at BASE CAMP with the monster 6734 units away in section 6: it
    -- wrote the CAMP's index into +0x29A, so he drew in the camp. The whole map
    -- shares one world frame, so a distance is only evidence of co-location at
    -- SHORT range — which is exactly the caveat the memory map puts on +0x29A.
    if (not unculled) and s.ent and s.ent ~= 0 and s.dist and s.dist < 2500
       and s.section ~= s.area then
      mhfu.write_u16(s.ent + 0x29A, s.area)
      unculled = true
      log("[zinogre] uncull: +0x29A %d -> %d at %d units (skip-draw clears itself)",
          s.section or -1, s.area or -1, math.floor(s.dist))
    end

    if announced then return end
    announced = true
    -- entity+0x1A4 is the FK walk length, and the engine sets it to the INJECTED
    -- skeleton's bone_count - 1. Reading 51 here rather than the Tigrex's 48 is
    -- the cheapest possible proof that our rig is the one being driven, and it
    -- is a number the retarget path can never produce.
    log("[zinogre] alive ent=0x%08X joints=%d animbase=0x%08X hp=%d pair=(%d,%d)",
        s.ent or 0, mhfu.read_u16((s.ent or 0) + 0x1A4),
        mhfu.read_u32((s.ent or 0) + 0x1AC), s.hp or 0, s.main or 0, s.sub or 0)
  end)
end)
