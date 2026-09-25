-- Keep one admitted exact English candidate visible behind the native first
-- candidate before Rime paginates. Swift owns the final evidence ranking.
local M = {}

function M.init(env)
  local configured = env.engine.schema.config:get_int("inkflow_short_conflict/lookahead") or 256
  env.max_lookahead = math.max(1, math.min(256, configured))
end

function M.func(input, env)
  local raw = env.engine.context.input
  local thread = coroutine.create(function()
    for candidate in input:iter() do coroutine.yield(candidate) end
  end)
  local exhausted = false
  local function next_candidate()
    if exhausted then return nil end
    local ok, candidate = coroutine.resume(thread)
    if not ok then error(candidate) end
    if coroutine.status(thread) == "dead" then exhausted = true end
    return candidate
  end
  local buffered, exact_index = {}, nil
  -- A Translation iterator is lazy. Inspect only a fixed prefix before the
  -- first yield, then resume the same iterator so native paging stays intact.
  while #buffered < env.max_lookahead do
    local candidate = next_candidate()
    if not candidate then break end
    buffered[#buffered + 1] = candidate
    local candidate_type = candidate.type or ""
    if #buffered > 1 and (candidate_type == "english_exact"
            or candidate_type:match("^english_personal_[123]$"))
        and candidate.start == 0 and candidate._end == #raw then
      exact_index = #buffered
      break
    end
  end
  if exact_index then
    yield(buffered[1])
    yield(buffered[exact_index])
    for index = 2, #buffered do
      if index ~= exact_index then yield(buffered[index]) end
    end
  else
    for _, candidate in ipairs(buffered) do yield(candidate) end
  end
  while true do
    local candidate = next_candidate()
    if not candidate then break end
    yield(candidate)
  end
end

return M
