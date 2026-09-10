-- Promote exact English only for explicit short conflicts, after Chinese first.
local M = {}

function M.init(env)
  env.conflicts = {}
  local config = env.engine.schema.config
  local path = "inkflow_short_conflict/inputs"
  for index = 0, config:get_list_size(path) - 1 do
    local input = config:get_string(path .. "/@" .. index)
    if input then env.conflicts[input] = true end
  end
end

function M.func(input, env)
  local raw = env.engine.context.input
  if not env.conflicts[raw] then
    for candidate in input:iter() do yield(candidate) end
    return
  end

  local first, exact, remaining = nil, nil, {}
  for candidate in input:iter() do
    if not first then
      first = candidate
    elseif not exact and candidate.text == raw
        and candidate.start == 0 and candidate._end == #raw then
      exact = candidate
    else
      remaining[#remaining + 1] = candidate
    end
  end
  if first then yield(first) end
  if exact then yield(exact) end
  for _, candidate in ipairs(remaining) do yield(candidate) end
end

return M
