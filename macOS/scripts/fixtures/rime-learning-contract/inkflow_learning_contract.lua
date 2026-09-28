-- Test-only executable contract for the pinned librime-lua bundle. Production
-- translators do not load this module in Task 1.
local M = {}

local result_property = "inkflow_learning_contract_result"

local function valid_code(code)
  return code and code:match("^[a-z]+$") ~= nil
end

local function valid_text(text)
  return text and text ~= "" and text:find("[%c]") == nil
end

local function memory_for(env, namespace)
  if namespace == "shared" then return env.shared end
  if namespace == "voice" then return env.voice end
end

local function memory_namespace(namespace)
  if namespace == "shared" then return "inkflow_contract_shared" end
  if namespace == "voice" then return "inkflow_contract_voice" end
end

local function with_memory(env, namespace, operation)
  local config = memory_namespace(namespace)
  if not config then return false end
  local memory
  local called, result = pcall(function()
    memory = Memory(env.engine, env.engine.schema, config)
    return operation(memory)
  end)
  if memory then memory:disconnect() end
  return called, result
end

local function set_result(context, result)
  context:set_property(result_property, result)
end

local function exact_rows(memory, code)
  local rows = {}
  if not memory.user_dict or not memory.user_dict.loaded then return nil end
  if not memory:user_lookup(code, false) then return rows end
  for entry in memory:iter_user() do
    local normalized = entry.custom_code and entry.custom_code:gsub(" +$", "")
    if normalized == code and entry.commit_count > 0 then
      rows[#rows + 1] = entry.text .. "\t" .. normalized .. "\t" .. tostring(entry.commit_count)
    end
  end
  table.sort(rows)
  return rows
end

local function update(memory, code, text, commits)
  if not memory:start_session() then return false end
  local wrote, updated = pcall(function()
    local entry = DictEntry()
    entry.text = text
    -- UserDictionary custom codes are token streams terminated by a space.
    entry.custom_code = code .. " "
    return memory:update_userdict(entry, commits, "")
  end)
  -- A successful update is not durable until the transaction closes cleanly.
  local finished = memory:finish_session()
  return wrote and updated and finished
end

local function seed_overflow(memory, code, text, count)
  if not memory:start_session() then return false end
  local written, updated = pcall(function()
    for value = 0, count - 1 do
      local entry = DictEntry()
      entry.text = "Bulk" .. tostring(value)
      entry.custom_code = string.format("a%c%c%c ",
        97 + math.floor(value / 676), 97 + math.floor(value / 26) % 26, 97 + value % 26)
      if not memory:update_userdict(entry, 1, "") then return false end
    end
    local entry = DictEntry()
    entry.text = text
    entry.custom_code = code .. " "
    return memory:update_userdict(entry, 1, "")
  end)
  local finished = memory:finish_session()
  return written and updated and finished
end

function M.init(env)
  env.shared = Memory(env.engine, env.engine.schema, "inkflow_contract_shared")
  env.voice = Memory(env.engine, env.engine.schema, "inkflow_contract_voice")
  for namespace, memory in pairs({ shared = env.shared, voice = env.voice }) do
    memory:memorize(function(commits)
      -- Multiple Memory instances observe commits. Only the namespace that
      -- produced this Phrase is allowed to adopt it.
      if env.selection_namespace ~= namespace then return false end
      local learned = commits:update(1)
      env.selection_namespace = nil
      set_result(env.engine.context, learned and "selected" or "failed")
      return learned
    end)
  end
  env.connection = env.engine.context.property_update_notifier:connect(function(context, name)
    if name ~= "inkflow_learning_contract" then return end
    local payload = context:get_property(name)
    if payload == "" then return end
    local operation, namespace, code, text, extra = payload:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t?([^\t]*)\t?([^\t]*)$")
    local memory = memory_for(env, namespace)
    if not memory or not valid_code(code) then set_result(context, "invalid"); return end
    if operation == "query" then
      local queried, rows = with_memory(env, namespace, function(fresh) return exact_rows(fresh, code) end)
      if not queried or not rows then set_result(context, "failed"); return end
      set_result(context, "ok\t" .. tostring(#rows) .. (#rows > 0 and "\t" .. table.concat(rows, "\t") or ""))
      return
    end
    if operation == "reject" then set_result(context, "rejected"); return end
    if operation == "ambiguous" then set_result(context, "ambiguous"); return end
    if not valid_text(text) then set_result(context, "invalid"); return end
    if operation == "candidate" then
      env.candidate = { namespace = namespace, code = code, text = text }
      set_result(context, "ok")
      return
    end
    if operation == "update" then
      local commits = tonumber(extra)
      if commits ~= 1 and commits ~= -1 then set_result(context, "invalid"); return end
      local called, updated = with_memory(env, namespace, function(fresh) return update(fresh, code, text, commits) end)
      set_result(context, called and updated and "ok" or "failed")
      return
    end
    if operation == "batch" then
      local count = tonumber(extra) or 512
      if count ~= 512 and count ~= 4096 then set_result(context, "invalid"); return end
      local called, updated = with_memory(env, namespace, function(fresh)
        return seed_overflow(fresh, code, text, count)
      end)
      set_result(context, called and updated and "ok" or "failed")
      return
    end
    set_result(context, "invalid")
  end)
end

function M.fini(env)
  if env.connection then env.connection:disconnect() end
  if env.shared then env.shared:disconnect() end
  if env.voice then env.voice:disconnect() end
end

function M.func(input, segment, env)
  local candidate = env.candidate
  if not candidate or candidate.code ~= input then return end
  local memory = memory_for(env, candidate.namespace)
  if not memory then return end
  -- Phrase learning needs the compiled DictEntry code, not only custom_code.
  -- Explicit arbitrary-code writes use custom_code through update_userdict above.
  memory:dict_lookup(input, false, 0)
  for entry in memory:iter_dict() do
    if entry.text == candidate.text then
      local phrase = Phrase(memory, "inkflow_learning_contract", segment.start, segment._end, entry)
      phrase.quality = 100
      env.selection_namespace = candidate.namespace
      local shadow = ShadowCandidate(phrase:toCandidate(), "inkflow_learning_contract", candidate.text, "", true)
      shadow.quality = 100
      yield(shadow)
    end
  end
end

return M
