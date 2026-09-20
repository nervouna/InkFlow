-- Read only already materialized native candidates. No text or learning state.
local M = {}

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
        rows[#rows + 1] = candidate.start .. "," .. candidate._end
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
