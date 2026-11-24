-- cc-mesh-bridge lib/std.lua (Stage 1 placeholder; full implementation in Stage 3)
local std = {
  VERSION = "0.1.0-stage1",
}

function std.serialize_json(tbl)
  if textutils and textutils.serialiseJSON then
    return textutils.serialiseJSON(tbl)
  end
  return "{}"
end

return std
