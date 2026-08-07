-- Gemini thought_signature 缓存与回注模块
--
-- 背景：Gemini 3.x 思考模型在函数调用（tool_calls）场景下，要求请求历史中的
-- functionCall 部分携带 thought_signature，否则返回 400。
-- OpenAI 兼容端点将签名放在 tool_calls[].extra_content.google.thought_signature。
-- 很多客户端（如 opencode）在重建对话历史时会丢弃 extra_content，导致下一轮请求失败。
--
-- 本模块在网关层透明解决此问题：
--   1. 捕获：从上游 Gemini 响应（流式 SSE / 非流式 JSON）中提取 thought_signature，
--      按 tool_call.id 缓存到 lua_shared_dict。
--   2. 回注：转发请求到 Gemini 前，扫描 messages[].tool_calls，对缺失签名的条目
--      从缓存查补 extra_content.google.thought_signature。
--
-- 签名是加密的不透明令牌，无法合成，只能从上游响应中捕获后回注。

local cjson = require('cjson.safe')

local _M = {}

local SHARED_DICT_NAME = 'gemini_signatures'
local SIGNATURE_TTL_SEC = 600 -- 10 分钟，覆盖一个对话轮次的重试窗口
local CACHE_KEY_PREFIX = 'sig:'

-- 判断 provider 是否为 Gemini OpenAI 兼容端点
function _M.is_gemini_provider(provider)
  if not provider or type(provider) ~= 'table' then
    return false
  end
  local base_url = provider.base_url or ''
  return base_url:find('googleapis.com', 1, true) ~= nil
end

-- 从 shared_dict 中按 tool_call_id 读取缓存的签名
local function get_cached_signature(tool_call_id)
  local shared = ngx.shared[SHARED_DICT_NAME]
  if not shared or not tool_call_id then
    return nil
  end
  return shared:get(CACHE_KEY_PREFIX .. tostring(tool_call_id))
end

-- 缓存单条签名
local function cache_signature(tool_call_id, signature)
  local shared = ngx.shared[SHARED_DICT_NAME]
  if not shared or not tool_call_id or not signature then
    return
  end
  shared:set(CACHE_KEY_PREFIX .. tostring(tool_call_id), tostring(signature), SIGNATURE_TTL_SEC)
end

-- 从 tool_calls 数组中提取并缓存签名
-- state: 可选的流式状态表（含 index_to_id 映射），非流式场景传 nil
local function capture_from_tool_calls(tool_calls, state)
  if type(tool_calls) ~= 'table' then
    return
  end
  for _, tc in ipairs(tool_calls) do
    if type(tc) == 'table' then
      -- 优先用 id 作为缓存 key
      local tc_id = tc.id
      -- 维护 index → id 映射（流式场景下 id 和 signature 可能分属不同 chunk）
      if state and tc.index ~= nil and tc_id then
        state.index_to_id[tc.index] = tc_id
      end
      -- 如果当前 chunk 没有 id 但有 index，尝试从映射中回查
      if not tc_id and state and tc.index ~= nil then
        tc_id = state.index_to_id[tc.index]
      end

      -- 提取 extra_content.google.thought_signature
      local sig
      if type(tc.extra_content) == 'table'
         and type(tc.extra_content.google) == 'table' then
        sig = tc.extra_content.google.thought_signature
      end

      if tc_id and sig then
        cache_signature(tc_id, sig)
      end
    end
  end
end

-- 从解码后的 SSE data 对象中捕获签名
-- state: new_stream_state() 返回的流式状态表
function _M.capture_from_sse_data(state, data_obj)
  if type(data_obj) ~= 'table' or type(data_obj.choices) ~= 'table' then
    return
  end
  for _, choice in ipairs(data_obj.choices) do
    if type(choice) == 'table' and type(choice.delta) == 'table' then
      capture_from_tool_calls(choice.delta.tool_calls, state)
    end
  end
end

-- 从非流式响应体（原始 JSON 字符串）中捕获签名
function _M.capture_from_response(raw_body)
  if type(raw_body) ~= 'string' or raw_body == '' then
    return
  end
  local body_obj = cjson.decode(raw_body)
  if type(body_obj) ~= 'table' or type(body_obj.choices) ~= 'table' then
    return
  end
  for _, choice in ipairs(body_obj.choices) do
    if type(choice) == 'table' and type(choice.message) == 'table' then
      capture_from_tool_calls(choice.message.tool_calls, nil)
    end
  end
end

-- 创建流式捕获状态（每个流式请求一个实例）
function _M.new_stream_state()
  return { index_to_id = {} }
end

-- 将缓存的签名回注到请求体的 messages 中
-- 返回: 注入的签名数量
function _M.inject_into_body(body)
  if type(body) ~= 'table' or type(body.messages) ~= 'table' then
    return 0
  end
  local shared = ngx.shared[SHARED_DICT_NAME]
  if not shared then
    return 0
  end

  local injected = 0
  for _, msg in ipairs(body.messages) do
    if type(msg) == 'table' and msg.role == 'assistant' and type(msg.tool_calls) == 'table' then
      for _, tc in ipairs(msg.tool_calls) do
        if type(tc) == 'table' and tc.id then
          -- 已有签名则跳过
          local existing
          if type(tc.extra_content) == 'table'
             and type(tc.extra_content.google) == 'table' then
            existing = tc.extra_content.google.thought_signature
          end
          if not existing then
            -- 从缓存查补
            local sig = get_cached_signature(tc.id)
            if sig then
              if type(tc.extra_content) ~= 'table' then
                tc.extra_content = {}
              end
              if type(tc.extra_content.google) ~= 'table' then
                tc.extra_content.google = {}
              end
              tc.extra_content.google.thought_signature = sig
              injected = injected + 1
            end
          end
        end
      end
    end
  end

  if injected > 0 then
    ngx.log(ngx.INFO, '[gemini_signature] injected ', injected, ' thought_signature(s) into request')
  end
  return injected
end

return _M
