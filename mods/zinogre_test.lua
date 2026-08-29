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
    pac     = "zinogre_v2.bin",
    orig    = "file_06185.bin.orig",
    fid     = 6186,
    clips   = {},
    moves   = {},
  }

  local announced = false

  zin:brain(function(s)
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
