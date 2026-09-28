-- Use Rime's compiled English dictionary, but rank across completion lengths.
local M = {}

local function update(memory, code, text, commits)
  if not memory:start_session() then return false end
  local written, result = pcall(function()
    local entry = DictEntry()
    entry.text = text
    entry.custom_code = code .. " "
    return memory:update_userdict(entry, commits, "")
  end)
  local finished = memory:finish_session()
  return written and result and finished
end

local function with_voice(env, operation)
  local memory
  local called, result = pcall(function()
    memory = Memory(env.engine, env.engine.schema, "voice_learning")
    return operation(memory)
  end)
  if memory then memory:disconnect() end
  return called, result
end

local function voice_aliases(memory)
  if not memory.user_dict or not memory.user_dict.loaded then return "unknown" end
  local iterator = memory.user_dict:lookup_words("", true, 513)
  local rows, bytes = {}, 3
  for entry in iterator:iter() do
    local code = entry.custom_code and entry.custom_code:gsub(" +$", "")
    local text = entry.text
    if entry.commit_count > 0 then
      if not code or not code:match("^[a-z]+$") or #code > 64
          or not text or not text:match("^[A-Za-z]+$") or #text > 64 then return "unknown" end
      local row = code .. "\t" .. text .. "\t" .. tostring(entry.commit_count)
      bytes = bytes + #row + 1
      if #rows == 512 or bytes > 65536 then return "unknown" end
      rows[#rows + 1] = row
    end
  end
  table.sort(rows)
  return "ok\n" .. table.concat(rows, "\n") .. (#rows > 0 and "\n" or "")
end

local clear_limit = 4096

local function positive_records(memory)
  if not memory.user_dict or not memory.user_dict.loaded then return nil end
  local iterator = memory.user_dict:lookup_words("", true, clear_limit + 1)
  local records = {}
  for entry in iterator:iter() do
    if entry.commit_count > 0 then
      local code = entry.custom_code and entry.custom_code:gsub(" +$", "")
      local text = entry.text
      if #records == clear_limit or not code or not code:match("^[a-z]+$") or #code > 64
          or not text or text == "" or #text > 256 or text:find("[%c]") then return nil end
      records[#records + 1] = { code = code, text = text, commits = entry.commit_count }
    end
  end
  return records
end

local function apply_records(memory, records, direction)
  if not memory:start_session() then return false end
  local applied = {}
  local called, result = pcall(function()
    for index, row in ipairs(records) do
      local entry = DictEntry()
      entry.text = row.text
      entry.custom_code = row.code .. " "
      applied[index] = { entry = entry, count = 0 }
      -- librime's native undo contract is one commit per update. Replay that
      -- proven primitive so an arbitrary accumulated count is removed exactly.
      for _ = 1, row.commits do
        if not memory:update_userdict(entry, direction, "") then return false end
        applied[index].count = applied[index].count + 1
      end
    end
    return true
  end)
  if not called or not result then
    -- Keep a mid-session update failure from leaving one namespace half-cleared.
    for index = #applied, 1, -1 do
      local row = applied[index]
      for _ = 1, row.count do memory:update_userdict(row.entry, -direction, "") end
    end
  end
  local finished = memory:finish_session()
  return called and result and finished
end

-- Management is invoked only at the host's idle boundary, after native undo
-- expires. Transport is bounded; failure must never masquerade as an empty list.
local function manage_learning(env, payload)
  local action, source, code, text, count = payload:match("^(%a+)\t(%a+)\t([a-z]+)\t([^\t\n]+)\t(%d+)$")
  if payload ~= "list" and (not action or (action ~= "delete" and action ~= "restore")
      or (source ~= "english" and source ~= "voice") or #code > 64 or #text > 256
      or text:find("[%c]") or not tonumber(count) or tonumber(count) < 1 or tonumber(count) > 2147483647) then
    return "failed"
  end
  local function operate(memory, namespace)
    local records = positive_records(memory)
    if not records then return nil end
    if payload == "list" then
      local rows = {}
      for _, row in ipairs(records) do
        rows[#rows + 1] = namespace .. "\t" .. row.code .. "\t" .. row.text .. "\t" .. tostring(row.commits)
      end
      return table.concat(rows, "\n") .. (#rows > 0 and "\n" or "")
    end
    local current = 0
    for _, row in ipairs(records) do
      if row.code == code and row.text == text then current = row.commits end
    end
    if (action == "delete" and current ~= tonumber(count)) or (action == "restore" and current ~= 0) then
      return "conflict"
    end
    -- Native negative updates tombstone the positive count. A single positive
    -- confirmation revives it and adds one; never replay N negative updates.
    if action == "restore" and tonumber(count) == 2147483647 then return "failed" end
    return update(memory, code, text, action == "delete" and -1 or 1) and "ok" or "failed"
  end
  if payload ~= "list" and source == "english" then return operate(env.memory, source) or "failed" end
  local called, result = with_voice(env, function(voice)
    if payload ~= "list" then return operate(voice, source) end
    local shared, aliases = operate(env.memory, "english"), operate(voice, "voice")
    if not shared or not aliases then return "failed" end
    return "ok\n" .. shared .. aliases
  end)
  return called and result or "failed"
end

local function clear_learning(env)
  local shared = positive_records(env.memory)
  if not shared then return false end
  local called, cleared = with_voice(env, function(voice)
    local aliases = positive_records(voice)
    if not aliases then return false end
    if not apply_records(env.memory, shared, -1) then return false end
    if apply_records(voice, aliases, -1) then return true end
    -- The namespaces are independent. Restore the first if the second fails.
    apply_records(env.memory, shared, 1)
    return false
  end)
  return called and cleared
end

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
  env.connection = env.engine.context.property_update_notifier:connect(function(context, name)
    if name == "inkflow_learning_invalidate" then
      env.input, env.entries, env.learnable = nil, nil, {}
      return
    end
    if name == "inkflow_learning_manage" then
      local payload = context:get_property(name)
      if payload == "" then return end
      local called, result = pcall(manage_learning, env, payload)
      context:set_property("inkflow_learning_manage_result", called and result or "failed")
      return
    end
    if name == "inkflow_clear_english_learning" then
      if context:get_property(name) == "" then return end
      local cleared = clear_learning(env)
      if cleared then env.input, env.entries, env.learnable = nil, nil, {} end
      context:set_property("inkflow_clear_english_learning_result", cleared and "ok" or "failed")
      return
    end
    if name == "inkflow_voice_aliases" then
      if context:get_property(name) == "" then return end
      local ok, result = with_voice(env, voice_aliases)
      context:set_property("inkflow_voice_aliases_result", ok and result or "unknown")
      return
    end
    if name ~= "inkflow_voice_learning" then return end
    local payload = context:get_property(name)
    if payload == "" then return end
    local source, canonical, text = payload:match("^([a-z]+)\t([a-z]+)\t([A-Za-z]+)$")
    if not source or not canonical or #source > 64 or #canonical > 64 or #text > 64 then
      context:set_property("inkflow_voice_learning_result", "failed")
      return
    end
    if not update(env.memory, canonical, text, 1) then
      context:set_property("inkflow_voice_learning_result", "failed")
      return
    end
    local voiceCalled, voiceUpdated = with_voice(env, function(memory)
      return update(memory, source, text, 1)
    end)
    if not voiceCalled or not voiceUpdated then
      -- Best-effort compensation avoids strengthening only the shared record.
      update(env.memory, canonical, text, -1)
      context:set_property("inkflow_voice_learning_result", "failed")
      return
    end
    context:set_property("inkflow_voice_learning_result", "ok")
  end)
end

function M.fini(env)
  env.connection:disconnect()
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
