local _M = {}

_M.config = nil
_M.config_hash = nil
_M.env_cache = {}
_M.reload_interval = tonumber(os.getenv('GATEWAY_RELOAD_INTERVAL_SEC') or '5') or 5
_M.key_cooldown_sec = tonumber(os.getenv('GATEWAY_KEY_COOLDOWN_SEC') or '600') or 600
_M.expose_selection_headers = os.getenv('GATEWAY_EXPOSE_SELECTION') == '1'

-- 429 / 重试精细化控制
-- (provider, model) 组合级别的冷却时长：用于上游共享池限流等「换 key 也没用」的场景
_M.provider_model_cooldown_sec = tonumber(os.getenv('GATEWAY_PM_COOLDOWN_SEC') or '120') or 120
-- 429 中如果检测到是 key 级限流（非共享池），使用更短的 key 冷却（避免一刀切 600s）
_M.key_rate_limit_cooldown_sec = tonumber(os.getenv('GATEWAY_KEY_RL_COOLDOWN_SEC') or '180') or 180
-- 429 中如果检测到是配额耗尽（insufficient_quota / quota exceeded），使用长冷却
-- 配额耗尽是半永久状态（不会在几分钟内恢复），长冷却避免反复撞墙产生噪音
_M.key_quota_cooldown_sec = tonumber(os.getenv('GATEWAY_KEY_QUOTA_COOLDOWN_SEC') or '3600') or 3600
-- 重试之间的基础退避毫秒数（实际会按 attempt 指数退避，并加上 jitter）
_M.retry_backoff_base_ms = tonumber(os.getenv('GATEWAY_RETRY_BACKOFF_MS') or '50') or 50
-- 是否解析并尊重上游响应中的 Retry-After / X-RateLimit-Reset 等头部
_M.respect_retry_after = (os.getenv('GATEWAY_RESPECT_RETRY_AFTER') or '1') ~= '0'

-- 从文件读取鉴权开关（解决 OpenResty 环境变量访问问题）
local function read_auth_enabled()
  local file = io.open('/tmp/gateway/auth_enabled', 'r')
  if file then
    local value = file:read('*line')
    file:close()
    return value
  end
  return 'true'  -- 默认启用鉴权
end

_M.auth_enabled = read_auth_enabled()

function _M.getenv(name)
  local cached = _M.env_cache[name]
  if cached ~= nil then
    if cached == false then
      return nil
    end
    return cached
  end

  local val = os.getenv(name)
  if val == nil then
    _M.env_cache[name] = false
  else
    _M.env_cache[name] = val
  end
  return val
end

function _M.set_config(cfg, hash)
  _M.config = cfg
  _M.config_hash = hash
end

function _M.get_config()
  return _M.config
end

function _M.get_hash()
  return _M.config_hash
end

return _M
