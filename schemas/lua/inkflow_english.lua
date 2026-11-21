local channel = require("inkflow_channel")
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
  local called, status, body = pcall(function()
    memory = Memory(env.engine, env.engine.schema, "voice_learning")
    return operation(memory)
  end)
  if memory then memory:disconnect() end
  return called, status, body
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
  return "ok", table.concat(rows, "\n") .. (#rows > 0 and "\n" or "")
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
      for _ = 1, row.commits do
        if not memory:update_userdict(entry, direction, "") then return false end
        applied[index].count = applied[index].count + 1
      end
    end
    return true
  end)
  if not called or not result then
    for index = #applied, 1, -1 do
      local row = applied[index]
      for _ = 1, row.count do memory:update_userdict(row.entry, -direction, "") end
    end
  end
  local finished = memory:finish_session()
  return called and result and finished
end

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
    if action == "restore" and tonumber(count) == 2147483647 then return "failed" end
    return update(memory, code, text, action == "delete" and -1 or 1) and "ok" or "failed"
  end
  if payload ~= "list" and source == "english" then return operate(env.memory, source) or "failed" end
  local called, status, body = with_voice(env, function(voice)
    if payload ~= "list" then return operate(voice, source) end
    local shared, aliases = operate(env.memory, "english"), operate(voice, "voice")
    if not shared or not aliases then return "failed" end
    return "ok", shared .. aliases
  end)
  if not called then return "failed" end
  return status or "failed", body
end

local function clear_learning(env)
  local shared = positive_records(env.memory)
  if not shared then return false end
  local called, cleared = with_voice(env, function(voice)
    local aliases = positive_records(voice)
    if not aliases then return false end
    if not apply_records(env.memory, shared, -1) then return false end
    if apply_records(voice, aliases, -1) then return true end
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

local function mixed_runs(candidate)
  local runs, public = {}, candidate.type == "mixed_exact"
  for _, item in ipairs(candidate:get_genuines()) do
    local kind = item.type
    if kind == "user_table" then return {} end
    public = public or kind == "mixed_exact"
    local phrase = kind:match("^mixed_personal_[0-3]$") and item:to_phrase()
    if phrase then
      for display, code in phrase.entry.custom_code:gmatch("([^\t\n]+)\t([^\t\n]+)") do
        runs[#runs + 1] = { display = display, code = code }
      end
    end
  end
  if #runs == 0 and public then
    for run in candidate.text:gmatch("[A-Za-z]+") do runs[#runs + 1] = { display = run, code = run:lower() } end
  end
  return runs
end

local function learn_mixed(env, context)
  for _, segment in ipairs(context.composition:toSegmentation():get_segments()) do
    local candidate = segment:get_selected_candidate()
    for _, run in ipairs(candidate and mixed_runs(candidate) or {}) do
      local entry = DictEntry()
      entry.text = run.display
      entry.custom_code = run.code .. " "
      env.memory:update_userdict(entry, 1, "")
    end
  end
end

local function learned(memory, run)
  if not memory.user_dict or not memory.user_dict.loaded or not memory:user_lookup(run.code, false) then return false end
  for entry in memory:iter_user() do
    local code = entry.custom_code and entry.custom_code:gsub(" +$", "")
    if code == run.code and entry.text == run.display and entry.commit_count > 0 then return true end
  end
  return false
end

local function forget(env, context)
  local candidate = context:get_selected_candidate()
  for _, run in ipairs(candidate and mixed_runs(candidate) or {}) do
    if learned(env.memory, run) then update(env.memory, run.code, run.display, -1) end
  end
  env.input, env.entries, env.learnable = nil, nil, {}
  context:refresh_non_confirmed_composition()
end

local function forget_sentence(env, context, text, step)
  local candidate = context:get_selected_candidate()
  if not candidate or candidate.text ~= text then return "failed" end
  local item = candidate:get_genuines()[1]
  local sentence = item and item:to_sentence()
  local heaviest
  for _, entry in ipairs(sentence and sentence.entrys or {}) do
    if entry.commit_count > 0 and (not heaviest or entry.weight > heaviest.weight) then heaviest = entry end
  end
  if not heaviest then return "unknown" end
  if step == "0" or not env.forgotten then env.forgotten = {} end
  local memory = Memory(env.engine, env.engine.schema, "translator")
  local forgotten = memory:update_userdict(heaviest, -1, "")
  memory:disconnect()
  if forgotten then env.forgotten[#env.forgotten + 1] = heaviest end
  context:refresh_non_confirmed_composition()
  return forgotten and "ok" or "failed"
end

local function unforget_sentence(env, context)
  local words = env.forgotten or {}
  env.forgotten = {}
  if #words == 0 then return "unknown" end
  local memory = Memory(env.engine, env.engine.schema, "translator")
  local revived = true
  for _, entry in ipairs(words) do revived = memory:update_userdict(entry, 1, "") and revived end
  memory:disconnect()
  context:refresh_non_confirmed_composition()
  return revived and "ok" or "failed"
end

function M.init(env)
  env.memory = Memory(env.engine, env.engine.schema, "english")
  env.memory:memorize(function(commits)
    for _, entry in ipairs(commits:get()) do
      if env.learnable and env.learnable[entry.text] then return commits:update(1) end
    end
    return false
  end)
  env.commit_connection = env.engine.context.commit_notifier:connect(function(context)
    learn_mixed(env, context)
  end)
  env.delete_connection = env.engine.context.delete_notifier:connect(function(context)
    forget(env, context)
  end)
  env.connection = env.engine.context.property_update_notifier:connect(channel.observer({
    forget_sentence = function(fields, context) return forget_sentence(env, context, fields[1], fields[2]) end,
    unforget_sentence = function(_, context) return unforget_sentence(env, context) end,
    learning_invalidate = function()
      env.input, env.entries, env.learnable = nil, nil, {}
      return "ok"
    end,
    learning_manage = function(fields) return manage_learning(env, table.concat(fields, "\t")) end,
    clear_english_learning = function()
      local cleared = clear_learning(env)
      if cleared then env.input, env.entries, env.learnable = nil, nil, {} end
      return cleared and "ok" or "failed"
    end,
    voice_aliases = function()
      local called, status, body = with_voice(env, voice_aliases)
      if not called then return "unknown" end
      return status, body
    end,
    voice_learning = function(fields)
      local source, canonical, text = table.concat(fields, "\t"):match("^([a-z]+)\t([a-z]+)\t([A-Za-z]+)$")
      if not source or not canonical or #source > 64 or #canonical > 64 or #text > 64 then return "failed" end
      if not update(env.memory, canonical, text, 1) then return "failed" end
      local voiceCalled, voiceUpdated = with_voice(env, function(memory)
        return update(memory, source, text, 1)
      end)
      if not voiceCalled or not voiceUpdated then
        update(env.memory, canonical, text, -1)
        return "failed"
      end
      return "ok"
    end,
  }))
end

function M.fini(env)
  env.commit_connection:disconnect()
  env.delete_connection:disconnect()
  env.connection:disconnect()
  env.memory:disconnect()
end

local function report_conflict_lookup(context, possible)
  local absent = possible and "" or "1"
  if context:get_property("_inkflow_no_exact_english") ~= absent then
    context:set_property("_inkflow_no_exact_english", absent)
  end
end

function M.func(input, segment, env)
  if not input:match("^[A-Za-z]+$") then
    env.input, env.entries, env.learnable = nil, nil, {}
    report_conflict_lookup(env.engine.context, false)
    return
  end
  if env.input ~= input then
    local lower = input:lower()
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
    local function collect_static(query, completion)
      env.memory:dict_lookup(query, completion, 0)
      for entry in env.memory:iter_dict() do
        local previous = row(entry.text)
        if not previous.weight or entry.weight > previous.weight then previous.weight = entry.weight end
        local fallback = not completion and query or (entry.text:match("^[A-Za-z]+$") and entry.text or nil)
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
      if not env.memory:user_lookup(lower, false) then return end
      for entry in env.memory:iter_user() do
        local code = entry.custom_code and entry.custom_code:gsub(" +$", "")
        if code == lower and entry.commit_count > 0 then
          local previous = row(entry.text)
          previous.exact = true
          previous.personal = true
          if entry.commit_count > previous.commits then previous.commits = entry.commit_count end
          previous.user_entry = entry
          previous.code = code:lower()
        end
      end
    end
    local queries = lower == input and { input } or { input, lower }
    for _, query in ipairs(queries) do collect_static(query, false) end
    collect_personal_exact()
    if #input >= 3 then
      for _, query in ipairs(queries) do collect_static(query, true) end
    end
    local typed = seen[input]
    if lower ~= input and typed and typed.exact then
      for _, entry in ipairs(entries) do
        if entry ~= typed then entry.personal, entry.commits = false, 0 end
      end
    end
    table.sort(entries, function(a, b)
      if a.exact ~= b.exact then return a.exact end
      if lower ~= input and (a.text == input) ~= (b.text == input) then return a.text == input end
      if a.personal ~= b.personal then return a.personal end
      if a.commits ~= b.commits then return a.commits > b.commits end
      local a_weight, b_weight = a.weight or 0, b.weight or 0
      if a_weight ~= b_weight then return a_weight > b_weight end
      if (a.text == input) ~= (b.text == input) then return a.text == input end
      return a.text < b.text
    end)
    env.input, env.entries, env.learnable = input, entries, {}
    for _, entry in ipairs(entries) do
      if entry.code then env.learnable[entry.text] = entry end
    end
  end
  local first = env.entries[1]
  local whole = segment.start == 0 and segment._end == #env.engine.context.input
  report_conflict_lookup(env.engine.context, whole and first and first.exact)
  for _, entry in ipairs(env.entries) do
    local dictionary_entry = entry.static_entry or entry.user_entry
    if entry.code then dictionary_entry.custom_code = entry.code .. " " end
    local phrase = Phrase(env.memory, "english", segment.start, segment._end, dictionary_entry)
    local candidate_type = entry.exact and "english_exact" or "english_completion"
    if entry.personal then candidate_type = "english_personal_" .. tostring(math.min(3, entry.commits)) end
    local candidate = ShadowCandidate(phrase:toCandidate(), candidate_type, entry.text, "", true)
    candidate.quality = -1
    yield(candidate)
  end
end

return M
