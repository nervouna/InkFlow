local M = { version = "1", request = "inkflow_request", result = "inkflow_result" }

function M.parse(request)
  local version, op, rest = request:match("^(%d+)\t([a-z_]+)(.*)$")
  if version ~= M.version then return nil end
  local fields = {}
  if rest ~= "" then
    if rest:sub(1, 1) ~= "\t" or rest:find("[\r\n]") then return nil end
    for field in (rest:sub(2) .. "\t"):gmatch("([^\t]*)\t") do fields[#fields + 1] = field end
  end
  return op, fields
end

function M.observer(handlers)
  return function(context, name)
    if name ~= M.request then return end
    local request = context:get_property(name)
    if request == "" then return end
    local op, fields = M.parse(request)
    if not op or not handlers[op] then return end
    local called, status, body = pcall(handlers[op], fields, context)
    if not called then status, body = "failed", nil end
    context:set_property(M.result, M.version .. "\t" .. op .. "\t" .. tostring(status) .. "\n" .. (body or ""))
  end
end

return M
