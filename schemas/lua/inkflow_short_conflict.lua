-- Keep one admitted exact English candidate visible behind the native first
-- candidate before Rime paginates. Swift owns the final evidence ranking.
local M = {}

function M.init(env)
  local configured = env.engine.schema.config:get_int("inkflow_short_conflict/lookahead") or 256
  env.max_lookahead = math.max(1, math.min(256, configured))
end

function M.func(input, env)
  local context = env.engine.context
  -- Without a whole-input exact English candidate this filter preserves the stream.
  -- A missing signal (older resources) takes the usual bounded search.
  if context:get_property("_inkflow_no_exact_english") == "1" then
    for candidate in input:iter() do yield(candidate) end
    return
  end
  local raw = context.input
  local next_candidate, translation = input:iter()
  local buffered, exact_index = {}, nil
  -- A Translation iterator is lazy. Inspect only a fixed prefix before the
  -- first yield, then consume the same iterator so native paging stays intact.
  while #buffered < env.max_lookahead do
    local candidate = next_candidate(translation)
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
    local candidate = next_candidate(translation)
    if not candidate then break end
    yield(candidate)
  end
end

return M
