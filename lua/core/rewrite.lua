local cjson = require('cjson.safe')

local _M = {}

function _M.encode_body(body)
  return cjson.encode(body)
end

function _M.update_model(body, provider_model)
  body.model = provider_model
  return _M.encode_body(body)
end

-- 修复工具参数 schema 中的常见格式问题
local function fix_tool_schema(tool)
  if type(tool) ~= 'table' then
    return tool
  end

  local func = tool.function or tool
  if type(func) ~= 'table' then
    return tool
  end

  local params = func.parameters
  if type(params) ~= 'table' then
    return tool
  end

  -- 修复 required 字段：如果是空对象 {} 改为空数组 []
  if params.required ~= nil and type(params.required) ~= 'array' then
    -- 设置元表使 cjson 编码为空数组 []
    setmetatable(params.required, require('cjson').array_mt)
  end

  -- 递归修复嵌套属性中的 required
  local function fix_object_required(obj)
    if type(obj) ~= 'table' then
      return
    end
    if obj.required ~= nil and type(obj.required) ~= 'array' then
      setmetatable(obj.required, require('cjson').array_mt)
    end
    -- 递归处理 properties
    if type(obj.properties) == 'table' then
      for _, prop in pairs(obj.properties) do
        fix_object_required(prop)
      end
    end
    -- 递归处理 additionalProperties
    if type(obj.additionalProperties) == 'table' then
      fix_object_required(obj.additionalProperties)
    end
    -- 递归处理 items
    if type(obj.items) == 'table' then
      fix_object_required(obj.items)
    end
  end
  fix_object_required(params)

  return tool
end

-- 递归深拷贝（保留元表）
local function deep_copy(obj)
  if type(obj) ~= 'table' then
    return obj
  end
  local copy = {}
  for k, v in pairs(obj) do
    copy[k] = deep_copy(v)
  end
  return copy
end

-- 转换请求体以兼容特定 provider
function _M.transform_for_provider(body, provider_name)
  if type(body) ~= 'table' then
    return body
  end

  -- 深拷贝避免污染原始请求
  local transformed = deep_copy(body)

  -- Gemini: 修复可能的格式问题
  if provider_name and provider_name:find('gemini', 1, true) then
    -- 修复 tools 中的 schema
    if type(transformed.tools) == 'table' then
      for i, tool in ipairs(transformed.tools) do
        transformed.tools[i] = fix_tool_schema(tool)
      end
    end
    -- 移除可能不被支持或导致格式问题的字段
    transformed.parallel_tool_calls = nil
    transformed.service_tier = nil
  end

  -- Agnes: 修复工具参数 schema
  if provider_name and (provider_name:find('agnes%-ai', 1, true) or provider_name:find('agnes%-cn', 1, true)) then
    if type(transformed.tools) == 'table' then
      for i, tool in ipairs(transformed.tools) do
        transformed.tools[i] = fix_tool_schema(tool)
      end
    end
  end

  return transformed
end

return _M
