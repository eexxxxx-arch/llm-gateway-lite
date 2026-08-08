local keypool = require('core.keypool')

local _M = {}

local function weighted_choice(candidates, total_weight)
  if #candidates == 1 then
    return candidates[1]
  end

  local pick = math.random() * total_weight
  local acc = 0
  for _, item in ipairs(candidates) do
    acc = acc + item.weight
    if pick <= acc then
      return item
    end
  end
  return candidates[#candidates]
end

local function allow_provider(model_policy, provider_name)
  if not model_policy or not model_policy.allow_set then
    return true
  end
  return model_policy.allow_set[provider_name] == true
end

-- 检查 (provider_name, provider_model) 组合是否未被冷却
local function provider_model_ready(provider_name, provider_model)
  return keypool.is_provider_model_available(provider_name, provider_model)
end

local function get_model(config, std_model)
  if not config or not std_model then
    return nil, 'invalid arguments'
  end

  local model = config.models[std_model]
  if not model then
    return nil, 'unsupported_model'
  end
  return model, nil
end

local function get_default_chain(model)
  if model.policy and type(model.policy.default_providers) == 'table' and #model.policy.default_providers > 0 then
    return model.policy.default_providers
  end
  if model.policy and model.policy.default_provider then
    return { model.policy.default_provider }
  end
  return {}
end

function _M.select_provider_with_key(config, std_model, opts)
  local model, model_err = get_model(config, std_model)
  if not model then
    return nil, nil, nil, model_err
  end

  local exclude = opts and opts.exclude_providers or {}

  local prefer = opts and opts.prefer_provider
  if prefer and not exclude[prefer] and allow_provider(model.policy, prefer) then
    local provider = config.providers[prefer]
    local provider_model = model.provider_map[prefer]
    if provider and provider_model and provider_model_ready(prefer, provider_model) then
      local key = keypool.pick_key(provider, {
        exclude_key_ids = opts and opts.exclude_key_ids_by_provider and opts.exclude_key_ids_by_provider[provider.name] or nil
      })
      if key then
        return provider, provider_model, key, nil
      end
    end
  end

  local default_chain = get_default_chain(model)
  if #default_chain > 0 then
    local chain_items = {}
    for _, default_name in ipairs(default_chain) do
      if not exclude[default_name] and allow_provider(model.policy, default_name) then
        local provider = config.providers[default_name]
        local provider_model = model.provider_map[default_name]
        if provider and provider_model and provider_model_ready(default_name, provider_model) then
          table.insert(chain_items, { provider = provider, model = provider_model })
        end
      end
    end
    local selected_provider, selected_model, selected_key = keypool.pick_from_provider_chain(chain_items, {
      chain_id = std_model,
      exclude_key_ids_by_provider = opts and opts.exclude_key_ids_by_provider or nil,
    })
    if selected_provider and selected_key then
      return selected_provider, selected_model, selected_key, nil
    end
  end

  local candidates = {}
  local total = 0

  for provider_name, provider_model in pairs(model.provider_map or {}) do
    if not exclude[provider_name]
      and allow_provider(model.policy, provider_name)
      and provider_model_ready(provider_name, provider_model)
    then
      local provider = config.providers[provider_name]
      if provider and keypool.has_available_key(provider) then
        local weight = tonumber(provider.weight) or 1
        table.insert(candidates, {
          name = provider_name,
          weight = weight,
          model = provider_model,
        })
        total = total + weight
      end
    end
  end

  if #candidates == 0 then
    -- 兜底：所有候选都不可用时，再扫描一次（不放宽 provider-model 冷却，只避免前面分支的漏判）
    -- 如果所有 provider-model 确实都在冷却中，严格遵守冷却时间，返回无 provider 可用
    -- 否则会把 cooldown 机制完全架空，导致连接错误的 provider 被立即反复撞击
    for provider_name, provider_model in pairs(model.provider_map or {}) do
      if not exclude[provider_name]
        and allow_provider(model.policy, provider_name)
        and provider_model_ready(provider_name, provider_model)
      then
        local provider = config.providers[provider_name]
        if provider and keypool.has_available_key(provider) then
          local weight = tonumber(provider.weight) or 1
          table.insert(candidates, {
            name = provider_name,
            weight = weight,
            model = provider_model,
          })
          total = total + weight
        end
      end
    end
  end

  if #candidates == 0 then
    return nil, nil, nil, 'no_provider_available'
  end

  local selected = weighted_choice(candidates, total)
  local selected_provider = config.providers[selected.name]
  local selected_key = keypool.pick_key(selected_provider, {
    exclude_key_ids = opts and opts.exclude_key_ids_by_provider and opts.exclude_key_ids_by_provider[selected_provider.name] or nil
  })
  if not selected_key then
    return nil, nil, nil, 'no_provider_available'
  end
  return selected_provider, selected.model, selected_key, nil
end

function _M.select_provider(config, std_model, opts)
  local provider, provider_model, _, err = _M.select_provider_with_key(config, std_model, opts)
  return provider, provider_model, err
end

return _M
