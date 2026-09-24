-- Keep one admitted exact English candidate visible behind the native first
-- candidate before Rime paginates. Swift owns the final evidence ranking.
local M = {}

function M.func(input, env)
  local raw = env.engine.context.input
  local first, exact, remaining = nil, nil, {}
  for candidate in input:iter() do
    local candidate_type = candidate.type or ""
    if not first then
      first = candidate
    elseif not exact and (candidate_type == "english_exact"
            or candidate_type:match("^english_personal_[123]$"))
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
