-- relocate_test.lua — Phase 5 topology-GROW live test (no DATA.BIN edits).
--
-- Delivers a BIGGER PMO than the engine's fixed raw-buffer heap block by
-- redirecting the load transform's source: at get_subresource the C side
-- recognizes the Tigrex raw buffer (matches file_06185.bin.orig) and rewrites the
-- caller's a0 to a GROWN PAC held in xram. The engine then reformats OUR larger
-- PMO into the decoded draw buffer.
--
-- Tests the open question: does the engine's decode/reformat alloc size from the
-- data (=> growth works) or cap it (=> spike clips / crashes)?
--
-- HOST: build the grown PAC from the pristine original, e.g.
--   PYTHONPATH=tools python -m mhfu_model.pmo_topology \
--     inject/file_06185.bin.orig inject/file_06185_grown.bin -n 30 --shift 0,1200,0
-- then deploy file_06185_grown.bin + file_06185.bin.orig into inject/.
--
-- The grown model adds a tall spike (a +1200-Y vertex fan on one body group) so a
-- successful render is unmistakable. Disable model_inject.lua while testing (both
-- claim file 6185).

local PAC_ID    = 6185
local GROWN     = "ms0:/PSP/PLUGINS/mhfu_framework/inject/file_06185_grown.bin"
local ORIG      = "ms0:/PSP/PLUGINS/mhfu_framework/inject/file_06185.bin.orig"

if mhfu.inject_relocate(PAC_ID, GROWN, ORIG) then
    mhfu.log("[relocate_test] registered grown " .. GROWN)
else
    mhfu.log("[relocate_test] inject_relocate FAILED")
end
