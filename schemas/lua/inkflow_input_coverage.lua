-- Read only already materialized native candidates. Return bounded, content-free
-- page metadata; no candidate or context text crosses this bridge.
local M = {}

local function candidate_metadata(candidate, input_length)
  local candidate_type = candidate.type or ""
  local source, exact, personal = "n", candidate._end == input_length and 1 or 0, 0
  if candidate_type == "user_table" then
    source = "c"
  elseif candidate_type == "english_exact" then
    source, exact = "e", 1
  elseif candidate_type == "english_completion" then
    source, exact = "e", 0
  elseif candidate_type:match("^english_personal_[123]$") then
    source, exact, personal = "e", 1, tonumber(candidate_type:sub(-1))
  elseif candidate_type == "mixed_exact" then
    source, exact = "m", 1
  elseif candidate_type:match("^mixed_personal_[123]$") then
    source, exact, personal = "m", 1, tonumber(candidate_type:sub(-1))
  end
  local has_letter = candidate.text:find("[A-Za-z]") ~= nil
  local has_non_ascii = candidate.text:find("[\128-\255]") ~= nil
  local class = has_letter and (has_non_ascii and "m" or "a") or (has_non_ascii and "n" or "o")
  return table.concat({candidate.start, candidate._end, class, exact, personal, source}, ",")
end

function M.init(env)
  env.connection = env.engine.context.property_update_notifier:connect(function(context, name)
    if name ~= "inkflow_input_coverage" then return end
    local request = context:get_property(name)
    if request == "" then return end
    local ok, result = pcall(function()
      local offset, count = request:match("^(%d+),(%d+)$")
      offset, count = tonumber(offset), tonumber(count)
      if not offset or not count or count < 1 or count > 9 then return "" end
      local segment = context.composition:back()
      if not segment or not segment.menu then return "" end
      local menu = segment.menu
      -- get_candidate_at can prepare more translations; never request unmaterialized rows.
      if offset + count > menu:candidate_count() then return "" end
      local rows = {request}
      for index = offset, offset + count - 1 do
        local candidate = menu:get_candidate_at(index)
        if not candidate then return "" end
        rows[#rows + 1] = candidate_metadata(candidate, #context.input)
      end
      return table.concat(rows, ";")
    end)
    context:set_property("inkflow_input_coverage_result", ok and result or "")
  end)
end

function M.fini(env)
  if env.connection then env.connection:disconnect() end
end

-- This translator only hosts the property observer; native translators own candidates.
function M.func() end

return M
