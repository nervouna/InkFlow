-- Use Rime's compiled English dictionary, but rank across completion lengths.
local M = {}

local function entry_code(memory, entry)
  local code = entry.custom_code
  if not code or code == "" then
    local decoded, syllables = pcall(function() return memory:decode(entry.code) end)
    if decoded and syllables then code = table.concat(syllables, "") end
  end
  if not code then return nil end
  code = code:gsub("%s+", "")
  if code:match("^[A-Za-z]+$") then return code end
end

local function normalized_code(memory, entry, fallback)
  local code = entry_code(memory, entry) or fallback
  return code and code:lower() or nil
end

function M.init(env)
  env.memory = Memory(env.engine, env.engine.schema, "english")
  env.memory:memorize(function(commits)
    -- Memory callbacks observe commits from every translator. CommitEntry keeps
    -- the selected Phrase's native language, so update() writes only that source
    -- dictionary; the current emitted-text guard excludes unrelated commits.
    for _, entry in ipairs(commits:get()) do
      if env.learnable and env.learnable[entry.text] then return commits:update(1) end
    end
    return false
  end)
end

function M.fini(env)
  env.memory:disconnect()
end

function M.func(input, segment, env)
  if not input:match("^[A-Za-z]+$") then
    env.input, env.entries, env.learnable = nil, nil, {}
    return
  end
  if env.input ~= input then
    local entries, seen = {}, {}
    local function row(text)
      local previous = seen[text]
      if not previous then
        previous = { text = text, exact = false, personal = false, commits = 0 }
        seen[text] = previous
        entries[#entries + 1] = previous
      end
      return previous
    end
    local function collect_static(completion)
      env.memory:dict_lookup(input, completion, 0)
      for entry in env.memory:iter_dict() do
        local previous = row(entry.text)
        if not previous.weight or entry.weight > previous.weight then previous.weight = entry.weight end
        local fallback = not completion and input or (entry.text:match("^[A-Za-z]+$") and entry.text or nil)
        local code = normalized_code(env.memory, entry, fallback)
        if not completion then
          previous.exact = true
          previous.static_entry = entry
          previous.code = code
        elseif not previous.static_entry then
          previous.static_entry = entry
          previous.code = previous.code or code
        end
      end
    end
    local function collect_personal_exact()
      if not env.memory.user_dict or not env.memory.user_dict.loaded then return end
      if not env.memory:user_lookup(input, false) then return end
      for entry in env.memory:iter_user() do
        local code = entry.custom_code and entry.custom_code:gsub(" +$", "")
        if code == input and entry.commit_count > 0 then
          local previous = row(entry.text)
          previous.exact = true
          previous.personal = true
          if entry.commit_count > previous.commits then previous.commits = entry.commit_count end
          previous.user_entry = entry
          previous.code = code:lower()
        end
      end
    end
    -- Exact code lookup is separate from completion lookup so aliases such as
    -- cpp -> C++ rank with exact words. One- and two-letter inputs stay exact-only.
    collect_static(false)
    collect_personal_exact()
    if #input >= 3 then collect_static(true) end
    table.sort(entries, function(a, b)
      if a.exact ~= b.exact then return a.exact end
      if a.personal ~= b.personal then return a.personal end
      if a.commits ~= b.commits then return a.commits > b.commits end
      local a_weight, b_weight = a.weight or 0, b.weight or 0
      if a_weight ~= b_weight then return a_weight > b_weight end
      if (a.text == input) ~= (b.text == input) then return a.text == input end
      return a.text < b.text
    end)
    -- Retain only one lookup per translator/session, including while paging.
    env.input, env.entries, env.learnable = input, entries, {}
    for _, entry in ipairs(entries) do
      if entry.code then env.learnable[entry.text] = entry end
    end
  end
  for _, entry in ipairs(env.entries) do
    local dictionary_entry = entry.static_entry or entry.user_entry
    -- Preserve the compiled internal code required by Phrase, while making the
    -- native memorize transaction persist the canonical lowercase lookup code.
    if entry.code then dictionary_entry.custom_code = entry.code .. " " end
    local phrase = Phrase(env.memory, "english", segment.start, segment._end, dictionary_entry)
    local candidate_type = entry.exact and "english_exact" or "english_completion"
    if entry.personal then candidate_type = "english_personal_" .. tostring(math.min(3, entry.commits)) end
    local candidate = ShadowCandidate(phrase:toCandidate(), candidate_type, entry.text, "", true)
    -- Native Chinese wins equal input coverage, including an unfinished final
    -- syllable. This entire stream still keeps its source-frequency order.
    candidate.quality = -1
    yield(candidate)
  end
end

return M
