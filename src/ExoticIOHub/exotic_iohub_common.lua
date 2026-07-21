local component = require("component")
local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")
local serialization = require("serialization")
local unicode = require("unicode")

local translations = require("exotic_zh_cn")

local M = {}
local unpack = table.unpack or unpack
local ESCAPE_KEY = 0x01
local FLUID_DROP_ID = "ae2fc:fluid_drop"
local GT_ITEM_ID = "gregtech:gt.metaitem.01"

local bartMaterials = {
  [3] = "zirconium",
  [30] = "thorium232",
  [64] = "ruthenium",
  [78] = "rhodium",
  [11000] = "hafnium",
  [11012] = "iodine"
}

local defaults = {
  interfaceAddress = nil,
  transposerAddress = nil,
  interfaceSide = nil,
  inputHatchSide = nil,
  databaseAddress = nil,
  gtMachineAddress = nil,
  gpuAddress = nil,
  screenAddress = nil,
  cpuName = "",
  pollInterval = 0.2,
  craftPollInterval = 0.5,
  craftTimeout = 600,
  interfaceFillTimeout = 15,
  dispatchTimeout = 30,
  recipeTimeout = 900,
  partialHintTimeout = 30,
  maxCraftAttempts = 6,
  stableSamples = 1,
  recycleQuietSeconds = 1,
  screenWidth = 120,
  screenHeight = 35,
  logLines = 6,
  databaseSlots = {
    fluidDropStart = 1,
    craftDrop = 8,
    plasmaProbe = 9
  },
  journalPath = nil
}

local colors = {
  bg = 0x08111B,
  header = 0x17324D,
  panel = 0x101E2D,
  panel2 = 0x193047,
  line = 0x36536D,
  text = 0xEAF2F8,
  dim = 0x91A7B8,
  cyan = 0x5EDCEB,
  blue = 0x70A7FF,
  purple = 0xB792FF,
  good = 0x65D69A,
  warn = 0xF1CA6D,
  bad = 0xEF7070,
  white = 0xFFFFFF
}

local function pack(...)
  return { n = select("#", ...), ... }
end

local function deepCopy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[deepCopy(key)] = deepCopy(item) end
  return result
end

local function applyDefaults(target, template)
  for key, value in pairs(template) do
    if target[key] == nil then
      target[key] = deepCopy(value)
    elseif type(target[key]) == "table" and type(value) == "table" then
      applyDefaults(target[key], value)
    end
  end
end

local function hasCjk(text)
  return tostring(text or ""):find("[\228-\233][\128-\191][\128-\191]") ~= nil
end

local function fluidNameZh(name, serverLabel)
  if translations[name] then return translations[name] end
  if hasCjk(serverLabel) then return tostring(serverLabel) end
  return tostring(name or "未知流体")
end

local function dropletNameZh(name, serverLabel)
  return fluidNameZh(name, serverLabel) .. "液滴"
end

local function validFluidName(name)
  return type(name) == "string" and name:match("^[%w%._%-]+$") ~= nil
end

local function fluidDropNbt(name)
  assert(validFluidName(name), "非法流体注册名: " .. tostring(name))
  return string.format('{Fluid:"%s"}', name)
end

local function dustOreMaterial(item)
  if type(item.oreNames) ~= "table" then return nil end
  for _, oreName in pairs(item.oreNames) do
    local material = tostring(oreName):match("^dust(.+)$")
    if material and material ~= "" then return material:lower() end
  end
  return nil
end

local function databaseCall(database, method, ...)
  local fn = database and database[method]
  if fn == nil then return nil, "数据库缺少方法 " .. tostring(method) end
  local result = pack(pcall(fn, ...))
  if not result[1] then return nil, tostring(result[2]) end
  return result[2], result[3]
end

local function resolveDustPlasma(item, database, probeSlot)
  if type(item) ~= "table" then return nil, "无效粉末数据" end

  local material = dustOreMaterial(item)
  if material then return "plasma." .. material end

  if item.name == "bartworks:gt.bwMetaGenerateddust" then
    material = bartMaterials[tonumber(item.damage)]
    if not material then return nil, "未知 BartWorks 粉末元数据 " .. tostring(item.damage) end
    return "plasma." .. material
  end

  material = tostring(item.name or ""):match("^miscutils:itemDust([%w_]+)$")
  if material then return "plasma." .. material:lower() end

  if item.name == GT_ITEM_ID then
    if tonumber(item.damage) == 382 then return "plasma.ardite" end
    if not database then return nil, "GT 粉末需要数据库探测" end
    local ok, reason = databaseCall(database, "set", probeSlot, GT_ITEM_ID, 29000 + tonumber(item.damage), "")
    if not ok then return nil, "写入 GT 等离子单元探针失败: " .. tostring(reason) end
    local probe, getReason = databaseCall(database, "get", probeSlot)
    local name = probe and probe.fluid and probe.fluid.name
    if not name then return nil, "GT 等离子单元探针没有流体信息: " .. tostring(getReason or item.label) end
    return name
  end

  return nil, string.format("不支持的粉末 %s / meta %s", tostring(item.name), tostring(item.damage))
end

local function plasmaFromFluidHint(name)
  local material = tostring(name or ""):match("([%w_%-]+)$")
  if not material then return nil end
  return "plasma." .. material:lower()
end

local function mergeRequirements(requirements)
  local result, byName = {}, {}
  for _, requirement in ipairs(requirements) do
    local existing = byName[requirement.name]
    if existing then
      existing.amount = existing.amount + requirement.amount
      existing.source = existing.source .. "+" .. requirement.source
    else
      requirement.attempts = 0
      requirement.stock = 0
      requirement.status = "等待"
      result[#result + 1] = requirement
      byName[requirement.name] = requirement
    end
  end
  return result
end

local function buildQuarkRequirements(snapshot, database, probeSlot)
  if #snapshot.items + #snapshot.fluids ~= 7 then
    return nil, "简并夸克胶子模式必须恰好收到 7 种样板"
  end
  local requirements = {}
  for _, hint in ipairs(snapshot.fluids) do
    local name = plasmaFromFluidHint(hint.name)
    if not name then return nil, "无法解析流体样板 " .. tostring(hint.name) end
    requirements[#requirements + 1] = {
      name = name,
      amount = tonumber(hint.amount) * 1000,
      label = dropletNameZh(name),
      source = "流体槽" .. tostring(hint.slot)
    }
  end
  for _, hint in ipairs(snapshot.items) do
    local name, reason = resolveDustPlasma(hint, database, probeSlot)
    if not name then return nil, reason end
    requirements[#requirements + 1] = {
      name = name,
      amount = tonumber(hint.size) * 1296,
      label = dropletNameZh(name),
      source = "物品槽" .. tostring(hint.slot)
    }
  end
  return mergeRequirements(requirements)
end

local function isNamedFluid(name, suffix)
  name = tostring(name or ""):lower()
  return name == suffix or name == "fluid." .. suffix or name:sub(-#suffix) == suffix
end

local function buildMagmatterRequirements(snapshot, database, probeSlot)
  if #snapshot.items ~= 1 or #snapshot.fluids ~= 2 then
    return nil, "磁物质模式必须收到 1 个粉末、时间流体和空间流体"
  end
  if tonumber(snapshot.items[1].size) ~= 1 then return nil, "磁物质粉末提示数量必须为 1" end
  local timeHint, spaceHint
  for _, hint in ipairs(snapshot.fluids) do
    if isNamedFluid(hint.name, "temporalfluid") then timeHint = hint end
    if isNamedFluid(hint.name, "spatialfluid") then spaceHint = hint end
  end
  if not timeHint or not spaceHint then return nil, "未同时识别到时间流体和空间流体" end
  local delta = tonumber(spaceHint.amount) - tonumber(timeHint.amount)
  if delta <= 0 then return nil, "空间流体量必须大于时间流体量" end
  local plasma, reason = resolveDustPlasma(snapshot.items[1], database, probeSlot)
  if not plasma then return nil, reason end
  return {
    {
      name = plasma,
      amount = delta * 144,
      label = dropletNameZh(plasma),
      source = "粉末差值",
      attempts = 0,
      stock = 0,
      status = "等待"
    },
    {
      name = timeHint.name,
      amount = tonumber(timeHint.amount),
      label = fluidNameZh(timeHint.name, timeHint.label),
      source = "时间流体回送",
      attempts = 0,
      stock = 0,
      status = "等待"
    },
    {
      name = spaceHint.name,
      amount = tonumber(spaceHint.amount),
      label = fluidNameZh(spaceHint.name, spaceHint.label),
      source = "空间流体回送",
      attempts = 0,
      stock = 0,
      status = "等待"
    }
  }
end

local function snapshotSignature(snapshot)
  local parts = {}
  for _, item in ipairs(snapshot.items) do
    parts[#parts + 1] = string.format("I:%d:%s:%s:%s", item.slot, item.name, item.damage, item.size)
  end
  for _, fluid in ipairs(snapshot.fluids) do
    parts[#parts + 1] = string.format("F:%d:%s:%s", fluid.slot, fluid.name, fluid.amount)
  end
  table.sort(parts)
  return table.concat(parts, "|")
end

M._test = {
  resolveDustPlasma = resolveDustPlasma,
  buildQuarkRequirements = buildQuarkRequirements,
  buildMagmatterRequirements = buildMagmatterRequirements,
  fluidDropNbt = fluidDropNbt,
  dropletNameZh = dropletNameZh,
  snapshotSignature = snapshotSignature
}

local function loadConfig(path)
  local loader, reason = loadfile(path)
  if not loader then error("无法读取配置 " .. path .. ": " .. tostring(reason)) end
  local ok, config = pcall(loader)
  if not ok then error("配置执行失败: " .. tostring(config)) end
  if type(config) ~= "table" then error("配置文件必须 return 一个 table") end
  applyDefaults(config, defaults)
  return config
end

local function formatNumber(value)
  local number = math.floor(tonumber(value) or 0)
  local sign = number < 0 and "-" or ""
  local reversed = tostring(math.abs(number)):reverse():gsub("(%d%d%d)", "%1,")
  return sign .. reversed:reverse():gsub("^,", "")
end

local function fit(text, width)
  text = tostring(text or "")
  if width <= 0 then return "" end
  if unicode.wlen(text) > width then
    text = unicode.wtrunc(text, math.max(1, width - 1))
    while unicode.wlen(text) > width - 1 do text = unicode.sub(text, 1, -2) end
    text = text .. "…"
  end
  return text .. string.rep(" ", math.max(0, width - unicode.wlen(text)))
end

M._test.fit = fit
M._test.formatNumber = formatNumber

local function short(address)
  return address and tostring(address):sub(1, 8) or "-"
end

local function resultCall(proxy, method, ...)
  if not proxy or proxy[method] == nil then
    return { ok = false, error = "缺少方法 " .. tostring(method), n = 0 }
  end
  local raw = pack(pcall(proxy[method], ...))
  if not raw[1] then return { ok = false, error = tostring(raw[2]), n = 0 } end
  local values = { n = raw.n - 1 }
  for i = 2, raw.n do values[i - 1] = raw[i] end
  return { ok = true, values = values, n = values.n }
end

local function valueCall(proxy, method, ...)
  local result = resultCall(proxy, method, ...)
  if not result.ok then error(method .. ": " .. result.error) end
  return unpack(result.values, 1, result.n)
end

local function numberCall(proxy, method, ...)
  local value = valueCall(proxy, method, ...)
  if value == nil then return nil end
  local number = tonumber(value)
  if number == nil then error(method .. " 返回非数字: " .. tostring(value)) end
  return number
end

local function componentAddress(kind, prefix)
  if prefix and prefix ~= "" then
    local ok, address = pcall(component.get, prefix, kind)
    if ok and address then return address end
    error("找不到组件 " .. kind .. " / " .. tostring(prefix))
  end
  local matches = {}
  for address in component.list(kind, true) do matches[#matches + 1] = address end
  if #matches == 1 then return matches[1] end
  if #matches == 0 then error("未找到组件 " .. kind) end
  error("存在多个 " .. kind .. "，请在配置中填写地址前缀")
end

local function validateMethods(address, label, methods)
  local available = component.methods(address)
  for _, method in ipairs(methods) do
    if available[method] == nil then error(label .. " 缺少回调 " .. method) end
  end
end

function M.run(profile, configPath)
  assert(profile and (profile.mode == "quark" or profile.mode == "magmatter"), "invalid profile")
  local config = loadConfig(configPath)
  if not config.journalPath then config.journalPath = "/var/exotic_" .. profile.mode .. ".state" end

  local state = {
    startedAt = computer.uptime(),
    phase = "SELF_TEST",
    paused = false,
    quitting = false,
    fault = nil,
    cycle = 0,
    hints = nil,
    requirements = {},
    stableSignature = nil,
    stableCount = 0,
    partialSince = nil,
    recycleIndex = 1,
    recycleQuietUntil = nil,
    recycleTotals = nil,
    ensureIndex = 1,
    craft = nil,
    phaseSince = computer.uptime(),
    observedConsumption = false,
    logs = {},
    uiCache = {},
    machine = { progress = 0, maximum = 0, active = false },
    snapshot = { items = {}, fluids = {} }
  }

  local devices, addresses = {}, {}
  local gpu, oldUi = nil, {}

  local function log(level, message)
    table.insert(state.logs, 1, { level = level or "info", message = tostring(message), at = computer.uptime() })
    while #state.logs > config.logLines do table.remove(state.logs) end
  end

  local function setPhase(phase, message)
    state.phase = phase
    state.phaseSince = computer.uptime()
    if message then log("info", message) end
  end

  local function fail(message)
    -- pcall(error(...)) prefixes the Lua source path and line number. Strip the
    -- first such prefix so an 80-column screen shows the actionable message.
    state.fault = tostring(message):gsub("^.-:%d+:%s*", "", 1)
    setPhase("FAULT")
    log("error", state.fault)
  end

  local function writeJournal(stage)
    local record = {
      version = 1,
      mode = profile.mode,
      stage = stage,
      savedAt = computer.uptime(),
      recycleIndex = state.recycleIndex,
      recycleQuietUntil = state.recycleQuietUntil,
      recycleTotals = state.recycleTotals,
      hints = state.hints,
      requirements = state.requirements
    }
    local parent = filesystem.path(config.journalPath)
    if parent and parent ~= "" and not filesystem.exists(parent) then filesystem.makeDirectory(parent) end
    local temp = config.journalPath .. ".tmp"
    local file, reason = io.open(temp, "w")
    if not file then error("无法写入周期日志: " .. tostring(reason)) end
    file:write(serialization.serialize(record))
    file:close()
    if filesystem.exists(config.journalPath) then filesystem.remove(config.journalPath) end
    assert(filesystem.rename(temp, config.journalPath), "无法提交周期日志")
  end

  local function loadJournal()
    if not filesystem.exists(config.journalPath) then return nil end
    local file = assert(io.open(config.journalPath, "r"))
    local text = file:read("*a")
    file:close()
    local record, reason = serialization.unserialize(text)
    if type(record) ~= "table" then error("周期日志损坏: " .. tostring(reason)) end
    if record.mode ~= profile.mode then error("周期日志属于另一运行模式") end
    return record
  end

  local function clearJournal()
    if filesystem.exists(config.journalPath) then filesystem.remove(config.journalPath) end
  end

  local function readSnapshot()
    local snapshot = { items = {}, fluids = {} }
    local itemSlots = numberCall(devices.transposer, "getInventorySize", config.inputHatchSide) or 0
    if itemSlots < 1 then error("转运器指定方向没有可读物品库存") end
    for slot = 1, itemSlots do
      local result = resultCall(devices.transposer, "getStackInSlot", config.inputHatchSide, slot)
      if not result.ok then error("读取进阶存储输入仓物品槽失败: " .. result.error) end
      local item = result.values[1]
      if type(item) == "table" and tonumber(item.size or 0) > 0 then
        local oreNames = nil
        if type(item.oreNames) == "table" then
          oreNames = {}
          for key, name in pairs(item.oreNames) do oreNames[key] = tostring(name) end
        end
        snapshot.items[#snapshot.items + 1] = {
          slot = slot,
          name = item.name,
          damage = tonumber(item.damage) or 0,
          size = tonumber(item.size) or 0,
          label = item.label,
          oreNames = oreNames
        }
      end
    end
    local fluidTanks = numberCall(devices.transposer, "getTankCount", config.inputHatchSide) or 0
    if fluidTanks < 1 then error("转运器指定方向没有可读流体库存") end
    for tank = 1, fluidTanks do
      local result = resultCall(devices.transposer, "getFluidInTank", config.inputHatchSide, tank)
      if not result.ok then error("读取进阶存储输入仓流体槽失败: " .. result.error) end
      local fluid = result.values[1]
      if type(fluid) == "table" and tonumber(fluid.amount or 0) > 0 and fluid.name then
        snapshot.fluids[#snapshot.fluids + 1] = {
          slot = tank,
          name = fluid.name,
          amount = tonumber(fluid.amount) or 0,
          label = fluid.label
        }
      end
    end
    state.snapshot = snapshot
    return snapshot
  end

  local function snapshotEmpty(snapshot)
    return #snapshot.items == 0 and #snapshot.fluids == 0
  end

  local function machineData()
    local progress = numberCall(devices.machine, "getWorkProgress") or 0
    local maximum = numberCall(devices.machine, "getWorkMaxProgress") or 0
    local active = valueCall(devices.machine, "isMachineActive") == true
    state.machine = { progress = progress, maximum = maximum, active = active }
    return state.machine
  end

  local function networkFluids()
    local list = valueCall(devices.interface, "getFluidsInNetwork") or {}
    local result = {}
    for _, fluid in pairs(list) do
      if type(fluid) == "table" and fluid.name then
        result[fluid.name] = (result[fluid.name] or 0) + tonumber(fluid.amount or 0)
      end
    end
    return result
  end

  local function inputHatchSnapshot()
    local count = numberCall(devices.transposer, "getTankCount", config.inputHatchSide)
    if not count or count < 1 then error("转运器指定方向没有可用流体仓") end
    local snapshot = { count = count, tanks = {}, byName = {}, total = 0 }
    for tank = 1, count do
      local level = numberCall(devices.transposer, "getTankLevel", config.inputHatchSide, tank) or 0
      if level > 0 then
        local fluid = valueCall(devices.transposer, "getFluidInTank", config.inputHatchSide, tank)
        if type(fluid) ~= "table" or not fluid.name then
          error("无法读取进阶存储输入仓第 " .. tank .. " 槽流体")
        end
        local entry = { slot = tank, name = fluid.name, amount = level, label = fluid.label }
        snapshot.tanks[#snapshot.tanks + 1] = entry
        snapshot.byName[entry.name] = (snapshot.byName[entry.name] or 0) + level
        snapshot.total = snapshot.total + level
      end
    end
    return snapshot
  end

  local function inputHatchEmpty()
    return inputHatchSnapshot().total == 0
  end

  local function requirementNames()
    local allowed = {}
    for _, requirement in ipairs(state.requirements) do allowed[requirement.name] = true end
    return allowed
  end

  local function transferResult(result, method)
    if not result.ok then error(method .. " 调用失败: " .. tostring(result.error)) end
    local moved = tonumber(result.values[2]) or 0
    if result.values[1] ~= true or moved <= 0 then
      error(method .. " 未传输流体: " .. tostring(result.values[2] or result.values[1]))
    end
    return moved
  end

  local function interfaceTank()
    local level = numberCall(devices.transposer, "getTankLevel", config.interfaceSide, 1) or 0
    if level <= 0 then return nil end
    local fluid = valueCall(devices.transposer, "getFluidInTank", config.interfaceSide, 1)
    if type(fluid) ~= "table" or not fluid.name then error("无法读取 ME 二合一接口流体") end
    return { name = fluid.name, label = fluid.label, amount = level }
  end

  local function setInterfaceFluid(databaseSlot)
    local result
    if databaseSlot then
      result = resultCall(devices.interface, "setFluidInterfaceConfiguration", 0,
        addresses.database, databaseSlot)
    else
      result = resultCall(devices.interface, "setFluidInterfaceConfiguration", 0)
    end
    if not result.ok or result.values[1] ~= true then
      error("设置 ME 二合一接口流体失败: " .. tostring(result.error or result.values[2]))
    end
  end

  local function clearInterfaceFluid(waitForEmpty)
    setInterfaceFluid(nil)
    if waitForEmpty == false then return end
    local started = computer.uptime()
    while interfaceTank() do
      if computer.uptime() - started > config.interfaceFillTimeout then
        error("ME 二合一接口清空超时")
      end
      event.pull(config.pollInterval)
    end
  end

  local function proxy(kind, prefix)
    local address = componentAddress(kind, prefix)
    return component.proxy(address), address
  end

  local function initializeComponents()
    devices.interface, addresses.interface = proxy("me_interface", config.interfaceAddress)
    devices.transposer, addresses.transposer = proxy("transposer", config.transposerAddress)
    devices.database, addresses.database = proxy("database", config.databaseAddress)
    devices.machine, addresses.machine = proxy("gt_machine", config.gtMachineAddress)
    devices.gpu, addresses.gpu = proxy("gpu", config.gpuAddress)
    addresses.screen = componentAddress("screen", config.screenAddress)
    gpu = devices.gpu

    validateMethods(addresses.interface, "ME 二合一接口", {
      "getFluidInterfaceConfiguration", "setFluidInterfaceConfiguration",
      "getFluidsInNetwork", "getCraftables", "getCpus"
    })
    validateMethods(addresses.transposer, "转运器", {
      "getInventorySize", "getStackInSlot", "getTankCount", "getTankLevel",
      "getTankCapacity", "getFluidInTank", "transferItem", "transferFluid"
    })
    validateMethods(addresses.database, "数据库", { "get", "set" })
    validateMethods(addresses.machine, "gt_machine", { "getWorkProgress", "getWorkMaxProgress", "isMachineActive" })
    if type(config.interfaceSide) ~= "number" or config.interfaceSide < 0 or config.interfaceSide > 5 then
      error("配置 interfaceSide 必须是 sides.bottom/top/north/south/west/east 之一")
    end
    if type(config.inputHatchSide) ~= "number" or config.inputHatchSide < 0 or config.inputHatchSide > 5 then
      error("配置 inputHatchSide 必须是 sides.bottom/top/north/south/west/east 之一")
    end
    if config.interfaceSide == config.inputHatchSide then error("interfaceSide 与 inputHatchSide 不能相同") end

    local needed = math.max(config.databaseSlots.fluidDropStart + 6, config.databaseSlots.craftDrop,
      config.databaseSlots.plasmaProbe)
    local deviceInfo = valueCall(computer, "getDeviceInfo")
    local databaseInfo = type(deviceInfo) == "table" and deviceInfo[addresses.database] or nil
    local databaseCapacity = databaseInfo and tonumber(databaseInfo.capacity) or nil
    if not databaseCapacity then error("无法通过 computer.getDeviceInfo() 读取数据库容量") end
    if databaseCapacity < needed then
      error("数据库至少需要 " .. needed .. " 个槽位")
    end

    oldUi.foreground = gpu.getForeground()
    oldUi.background = gpu.getBackground()
    oldUi.width, oldUi.height = gpu.getResolution()
    local maxWidth, maxHeight = gpu.maxResolution()
    if maxWidth < 80 or maxHeight < 25 then error("GUI 至少需要 80×25 分辨率") end
    local width = math.min(math.max(80, config.screenWidth), maxWidth)
    local height = math.min(math.max(25, config.screenHeight), maxHeight)
    assert(gpu.bind(addresses.screen, true), "GPU 无法绑定屏幕")
    gpu.setResolution(width, height)
    state.uiWidth, state.uiHeight = width, height
    gpu.setBackground(colors.bg)
    gpu.setForeground(colors.text)
    gpu.fill(1, 1, width, height, " ")
  end

  local function restoreUi()
    if not gpu then return end
    pcall(gpu.setBackground, oldUi.background or 0x000000)
    pcall(gpu.setForeground, oldUi.foreground or 0xFFFFFF)
    if oldUi.width and oldUi.height then pcall(gpu.setResolution, oldUi.width, oldUi.height) end
  end

  local function draw(key, x, y, text, width, foreground, background)
    if y < 1 or y > state.uiHeight or width <= 0 then return end
    text = fit(text, width)
    local signature = table.concat({ x, y, text, foreground or colors.text, background or colors.bg }, ":")
    if state.uiCache[key] == signature then return end
    state.uiCache[key] = signature
    gpu.setForeground(foreground or colors.text)
    gpu.setBackground(background or colors.bg)
    gpu.set(x, y, text)
  end

  local phaseLabels = {
    SELF_TEST = "自检", WAIT_HINTS = "等待样板", RECYCLE_HINTS = "回收样板",
    ENSURE_CRAFTED = "补充合成", VERIFY_STOCK = "库存复核", DISPATCH = "注入输入仓",
    WAIT_START = "等待开机", WAIT_COMPLETE = "等待完成", FAULT = "故障锁定"
  }

  local function progressBar(width)
    local maximum = math.max(1, state.machine.maximum or 0)
    local ratio = math.max(0, math.min(1, (state.machine.progress or 0) / maximum))
    local filled = math.floor(width * ratio + 0.5)
    return string.rep("█", filled) .. string.rep("░", width - filled)
  end

  local function render()
    if not gpu then return end
    local width, height = state.uiWidth, state.uiHeight
    draw("header1", 1, 1, "  " .. profile.title, width, colors.white, colors.header)
    local mode = profile.mode == "quark" and "简并夸克胶子" or "磁物质"
    draw("header2", 1, 2, "  模式 " .. fit(mode, 16) .. "阶段 " ..
      fit(phaseLabels[state.phase] or state.phase, 18) .. string.format("周期 %d  运行 %ds",
      state.cycle, math.floor(math.max(0, computer.uptime() - state.startedAt))),
      width, colors.cyan, colors.header)

    local progressWidth = math.max(10, width - 34)
    draw("machine", 2, 4, string.format("机器: %s  %s %s  %d/%d",
      state.machine.active and "运行" or "待机", progressBar(progressWidth),
      state.paused and "[已暂停]" or "", math.floor(state.machine.progress or 0),
      math.floor(state.machine.maximum or 0)),
      width - 2, state.machine.active and colors.good or colors.dim, colors.bg)
    draw("components", 2, 5, string.format("ME %s  TP %s  DB %s  GT %s  样板 %d+%d",
      short(addresses.interface), short(addresses.transposer),
      short(addresses.database), short(addresses.machine),
      #state.snapshot.items, #state.snapshot.fluids), width - 2, colors.dim, colors.bg)

    local tableTop = 7
    draw("tableHeader", 2, tableTop, fit("流体/液滴", math.max(18, width - 54)) ..
      fit("需求(L)", 14) .. fit("AE库存(L)", 14) .. "状态", width - 3, colors.white, colors.panel2)
    local nameWidth = math.max(18, width - 54)
    for row = 1, 7 do
      local requirement = state.requirements[row]
      local text, color = "", colors.text
      if requirement then
        text = fit(requirement.label, nameWidth) .. fit(formatNumber(requirement.amount), 14) ..
          fit(formatNumber(requirement.stock), 14) .. tostring(requirement.status or "等待")
        if requirement.status == "就绪" or requirement.status == "已装载" then color = colors.good
        elseif requirement.status == "缺少样板" or requirement.status == "失败" then color = colors.bad
        elseif requirement.status == "合成中" then color = colors.warn end
      end
      draw("req" .. row, 2, tableTop + row, text, width - 3, color, row % 2 == 0 and colors.panel or colors.bg)
    end

    local infoY = tableTop + 9
    local faultText = state.fault and ("故障: " .. state.fault) or
      "安全策略: 提示物全部回 AE；转运器向空进阶存储输入仓精确供液"
    draw("fault", 2, infoY, faultText, width - 3, state.fault and colors.bad or colors.dim, colors.bg)

    local logTop = math.max(infoY + 2, height - config.logLines - 2)
    draw("logHeader", 2, logTop, "运行日志", width - 3, colors.cyan, colors.panel2)
    for row = 1, config.logLines do
      local entry = state.logs[row]
      local text, color = "", colors.dim
      if entry then
        text = string.format("[%6.1fs] %s", entry.at - state.startedAt, entry.message)
        color = entry.level == "error" and colors.bad or entry.level == "warn" and colors.warn or colors.text
      end
      draw("log" .. row, 2, logTop + row, text, width - 3, color, colors.bg)
    end
    draw("footer", 1, height, "  Space 暂停/继续   R 安全恢复/回送   Q/Esc 退出", width, colors.white, colors.header)
  end

  local function buildRequirements(snapshot)
    if profile.mode == "quark" then
      return buildQuarkRequirements(snapshot, devices.database, config.databaseSlots.plasmaProbe)
    end
    return buildMagmatterRequirements(snapshot, devices.database, config.databaseSlots.plasmaProbe)
  end

  local function itemKey(item)
    return tostring(item.name) .. ":" .. tostring(tonumber(item.damage) or 0)
  end

  local function fluidKey(fluid)
    return tostring(fluid.name)
  end

  local function newRecycleTotals(hints)
    local totals = { items = {}, fluids = {}, allowedItems = {}, allowedFluids = {} }
    for _, item in ipairs(hints.items or {}) do totals.allowedItems[itemKey(item)] = true end
    for _, fluid in ipairs(hints.fluids or {}) do totals.allowedFluids[fluidKey(fluid)] = true end
    return totals
  end

  local function addRecycledItem(item, amount)
    local key = itemKey(item)
    local total = state.recycleTotals.items[key]
    if not total then
      total = {
        name = item.name, damage = tonumber(item.damage) or 0, size = 0,
        label = item.label, oreNames = item.oreNames
      }
      state.recycleTotals.items[key] = total
    end
    total.size = total.size + amount
  end

  local function addRecycledFluid(fluid, amount)
    local key = fluidKey(fluid)
    local total = state.recycleTotals.fluids[key]
    if not total then
      total = { name = fluid.name, amount = 0, label = fluid.label }
      state.recycleTotals.fluids[key] = total
    end
    total.amount = total.amount + amount
  end

  local function recycledSnapshot()
    local snapshot = { items = {}, fluids = {} }
    for _, item in pairs(state.recycleTotals.items or {}) do
      snapshot.items[#snapshot.items + 1] = item
    end
    for _, fluid in pairs(state.recycleTotals.fluids or {}) do
      snapshot.fluids[#snapshot.fluids + 1] = fluid
    end
    return snapshot
  end

  local function sendItemToAE(hint)
    local current = valueCall(devices.transposer, "getStackInSlot", config.inputHatchSide, hint.slot)
    if current == nil or tonumber(current.size or 0) <= 0 then return 0 end
    if current.name ~= hint.name or tonumber(current.damage) ~= tonumber(hint.damage) then
      error("物品槽 " .. hint.slot .. " 已被未知物品替换，拒绝回送")
    end
    local before = tonumber(current.size) or 0
    local sent = numberCall(devices.transposer, "transferItem", config.inputHatchSide,
      config.interfaceSide, before, hint.slot) or 0
    if sent ~= before then
      error(string.format("物品槽 %d 回送 AE 不完整: %d/%d", hint.slot, sent, before))
    end
    addRecycledItem(current, sent)
    return sent
  end

  local function sendFluidToAE(hint, trackAsHint)
    local current = valueCall(devices.transposer, "getFluidInTank", config.inputHatchSide, hint.slot)
    if current == nil or tonumber(current.amount or 0) <= 0 then return 0 end
    if current.name ~= hint.name then
      error("流体槽 " .. hint.slot .. " 已被未知流体替换，拒绝回送")
    end
    local before = tonumber(current.amount) or 0
    local sent = transferResult(resultCall(devices.transposer, "transferFluid",
      config.inputHatchSide, config.interfaceSide, before, hint.slot - 1), "transferFluid")
    if sent ~= before then
      error(string.format("流体槽 %d 回送 AE 不完整: %d/%d", hint.slot, sent, before))
    end
    if trackAsHint ~= false then addRecycledFluid(current, sent) end
    return sent
  end

  local function refundKnownInputsUnsafe()
    local allowed = requirementNames()
    clearInterfaceFluid(true)
    local stored = readSnapshot()
    if #stored.items > 0 then return false, "进阶存储输入仓中存在物品，拒绝把它当作配方原料回送" end
    for _, fluid in ipairs(stored.fluids) do
      if not allowed[fluid.name] then return false, "进阶存储输入仓中存在未知流体 " .. tostring(fluid.name) end
    end
    for _, fluid in ipairs(stored.fluids) do sendFluidToAE(fluid, false) end

    local guard = 0
    while true do
      local hatch = inputHatchSnapshot()
      if hatch.total == 0 then return true end
      for _, fluid in ipairs(hatch.tanks) do
        if not allowed[fluid.name] then return false, "进阶存储输入仓中存在未知流体 " .. tostring(fluid.name) end
      end
      local source = hatch.tanks[1]
      local moved = transferResult(resultCall(devices.transposer, "transferFluid",
        config.inputHatchSide, config.interfaceSide, source.amount, source.slot - 1), "transferFluid")
      if moved ~= source.amount then
        return false, string.format("输入仓经 ME 接口回送 AE 不完整: %d/%d L", moved, source.amount)
      end
      guard = guard + 1
      if guard > 128 then return false, "输入仓回送次数异常" end
    end
  end

  local function refundKnownInputs()
    local ok, result, reason = pcall(refundKnownInputsUnsafe)
    if not ok then return false, tostring(result) end
    return result, reason
  end

  local function isProductFluid(name)
    if profile.mode == "quark" then return isNamedFluid(name, "quarkgluonplasma") end
    return isNamedFluid(name, "magmatter")
  end

  local function routeProducts(snapshot)
    local routed = false
    for _, fluid in ipairs(snapshot.fluids) do
      if isProductFluid(fluid.name) then
        sendFluidToAE(fluid, false)
        log("info", "成品已送回主网: " .. fluidNameZh(fluid.name, fluid.label) .. " " ..
          formatNumber(fluid.amount) .. " L")
        routed = true
      end
    end
    return routed
  end

  local function recycleStep()
    state.recycleTotals = state.recycleTotals or newRecycleTotals(state.hints)
    if state.recycleQuietUntil and computer.uptime() < state.recycleQuietUntil then return end
    local snapshot = readSnapshot()
    if snapshotEmpty(snapshot) then
      local totalSnapshot = recycledSnapshot()
      local requirements, reason = buildRequirements(totalSnapshot)
      if not requirements then error("累计回送样板无效: " .. tostring(reason)) end
      state.hints = totalSnapshot
      state.requirements = requirements
      writeJournal("recycled")
      state.ensureIndex = 1
      setPhase("ENSURE_CRAFTED", "输入仓已整体静默，全部样板已回送 AE")
      return
    end

    state.recycleQuietUntil = nil
    for _, item in ipairs(snapshot.items) do
      if not state.recycleTotals.allowedItems[itemKey(item)] then
        error("回送期间出现未知物品: " .. tostring(item.label or item.name))
      end
    end
    for _, fluid in ipairs(snapshot.fluids) do
      if not state.recycleTotals.allowedFluids[fluidKey(fluid)] then
        error("回送期间出现未知流体: " .. tostring(fluid.label or fluid.name))
      end
    end

    local sentItems, sentFluids = 0, 0
    for _, item in ipairs(snapshot.items) do sentItems = sentItems + sendItemToAE(item) end
    for _, fluid in ipairs(snapshot.fluids) do sentFluids = sentFluids + sendFluidToAE(fluid) end
    state.recycleQuietUntil = computer.uptime() + config.recycleQuietSeconds
    state.recycleIndex = state.recycleIndex + 1
    writeJournal("recycling")
    log("info", string.format("整轮回送输入仓: 物品 %d，流体 %d L", sentItems, sentFluids))
  end

  local function namedCpuBusy()
    if not config.cpuName or config.cpuName == "" then return false end
    local cpus = valueCall(devices.interface, "getCpus") or {}
    for _, cpu in pairs(cpus) do
      if cpu.name == config.cpuName then return cpu.busy == true end
    end
    error("未找到专用合成 CPU: " .. config.cpuName)
  end

  local function cancelNamedCpu()
    if not config.cpuName or config.cpuName == "" then return false end
    local cpus = valueCall(devices.interface, "getCpus") or {}
    for _, cpu in pairs(cpus) do
      if cpu.name == config.cpuName and cpu.cpu and cpu.busy then
        local ok = resultCall(cpu.cpu, "cancel")
        return ok.ok and ok.values[1] == true
      end
    end
    return false
  end

  local function updateRequirementStock()
    local stock = networkFluids()
    for _, requirement in ipairs(state.requirements) do
      requirement.stock = stock[requirement.name] or 0
      if requirement.stock >= requirement.amount then requirement.status = "就绪" end
    end
    return stock
  end

  local function startCraft(requirement)
    local ok, reason = databaseCall(devices.database, "set", config.databaseSlots.craftDrop,
      FLUID_DROP_ID, 0, fluidDropNbt(requirement.name))
    if not ok then error("写入 AE2FC 液滴失败: " .. tostring(reason)) end
    local drop = valueCall(devices.database, "get", config.databaseSlots.craftDrop)
    local craftables = valueCall(devices.interface, "getCraftables", { name = drop.name, label = drop.label }) or {}
    local craftable = craftables[1]
    if not craftable then
      requirement.status = "缺少样板"
      requirement.label = dropletNameZh(requirement.name, drop.label)
      return false
    end
    if namedCpuBusy() then
      requirement.status = "等待CPU"
      return false
    end
    local request
    if config.cpuName and config.cpuName ~= "" then
      request = resultCall(craftable, "request", 1, true, config.cpuName)
    else
      request = resultCall(craftable, "request", 1, true)
    end
    if not request.ok or not request.values[1] then
      error("下单失败: " .. tostring(request.error or request.values[2]))
    end
    requirement.status = "合成中"
    requirement.attempts = requirement.attempts + 1
    state.craft = { status = request.values[1], startedAt = computer.uptime(), requirement = requirement }
    writeJournal("crafting")
    log("info", "已下单 " .. requirement.label .. "，第 " .. requirement.attempts .. " 次")
    return true
  end

  local function craftStep()
    local requirement = state.requirements[state.ensureIndex]
    if not requirement then
      state.craft = nil
      setPhase("VERIFY_STOCK", "所有流体库存已满足")
      return
    end

    local stock = updateRequirementStock()
    if (stock[requirement.name] or 0) >= requirement.amount then
      requirement.status = "就绪"
      state.craft = nil
      state.ensureIndex = state.ensureIndex + 1
      return
    end

    if state.craft then
      local status = state.craft.status
      local failed = resultCall(status, "hasFailed")
      local canceled = resultCall(status, "isCanceled")
      local done = resultCall(status, "isDone")
      if not failed.ok or not canceled.ok or not done.ok then error("无法读取 AE 合成状态") end
      if failed.values[1] or canceled.values[1] then
        requirement.status = "失败"
        state.craft = nil
        if requirement.attempts >= config.maxCraftAttempts then
          error("合成连续失败: " .. requirement.label .. " / " .. tostring(failed.values[2] or canceled.values[2]))
        end
        log("warn", "合成失败，稍后重试 " .. requirement.label)
        return
      end
      if done.values[1] then
        state.craft = nil
        requirement.status = "复核"
        return
      end
      if computer.uptime() - state.craft.startedAt > config.craftTimeout then
        cancelNamedCpu()
        state.craft = nil
        requirement.status = "失败"
        error("合成超时: " .. requirement.label)
      end
      return
    end

    if requirement.attempts >= config.maxCraftAttempts then
      error("样板单次产量不足或 AE 未入库: " .. requirement.label)
    end
    startCraft(requirement)
  end

  local function dispatch()
    local hatch = inputHatchSnapshot()
    if hatch.total > 0 then error("装载前进阶存储输入仓不为空，拒绝覆盖现有流体") end
    if hatch.count < #state.requirements then
      error(string.format("输入仓只有 %d 个流体槽，配方需要 %d 种流体", hatch.count, #state.requirements))
    end
    local stock = updateRequirementStock()
    for index, requirement in ipairs(state.requirements) do
      if (stock[requirement.name] or 0) < requirement.amount then
        state.ensureIndex = 1
        setPhase("ENSURE_CRAFTED", "装载前库存发生变化，重新补充")
        return
      end
      local capacity = numberCall(devices.transposer, "getTankCapacity", config.inputHatchSide, index) or 0
      if capacity < requirement.amount then
        error(string.format("进阶存储输入仓第 %d 槽容量不足: %d/%d L", index, capacity, requirement.amount))
      end
    end

    writeJournal("loading")
    local loadOk, loadReason = pcall(function()
      clearInterfaceFluid(true)
      for index, requirement in ipairs(state.requirements) do
        local slot = config.databaseSlots.fluidDropStart + index - 1
        local ok, reason = databaseCall(devices.database, "set", slot, FLUID_DROP_ID, 0,
          fluidDropNbt(requirement.name))
        if not ok then error("写入 AE2FC 液滴失败: " .. tostring(reason)) end
        setInterfaceFluid(slot)

        local remaining = requirement.amount
        while remaining > 0 do
          local started = computer.uptime()
          local supplied
          repeat
            supplied = interfaceTank()
            if supplied and supplied.name ~= requirement.name then supplied = nil end
            if not supplied then
              if computer.uptime() - started > config.interfaceFillTimeout then
                error("ME 二合一接口等待流体超时: " .. requirement.label)
              end
              event.pull(config.pollInterval)
            end
          until supplied

          local requested = math.min(remaining, supplied.amount)
          local moved = transferResult(resultCall(devices.transposer, "transferFluid",
            config.interfaceSide, config.inputHatchSide, requested, 0), "transferFluid")
          if moved ~= requested then
            error(string.format("转运器注入输入仓不完整: %s %d/%d L", requirement.label, moved, requested))
          end
          remaining = remaining - moved
        end
        clearInterfaceFluid(true)
        requirement.status = "已装载"
        log("info", string.format("已注入 %s %s L (%d/%d)", requirement.label,
          formatNumber(requirement.amount), index, #state.requirements))
        writeJournal("loading")
      end
    end)
    if not loadOk then
      local loadMessage = tostring(loadReason):gsub("^.-:%d+:%s*", "", 1)
      local cleared, clearReason = pcall(clearInterfaceFluid, true)
      if not cleared then loadMessage = loadMessage .. "；接口清理失败: " .. tostring(clearReason) end
      local currentMachine = machineData()
      if currentMachine.progress > 0 or currentMachine.active then
        state.observedConsumption = true
        writeJournal("running")
        setPhase("WAIT_COMPLETE", "装载后机器已启动，忽略迟到的校验错误")
        return
      end
      local refunded, refundReason = refundKnownInputs()
      if not refunded then
        error("输入仓装载失败且自动回送失败: " .. loadMessage .. "；" .. tostring(refundReason))
      end
      error("输入仓装载失败，已把本轮流体回送 AE: " .. loadMessage)
    end

    local currentMachine = machineData()
    hatch = inputHatchSnapshot()
    if currentMachine.progress > 0 or currentMachine.active or hatch.total == 0 then
      state.observedConsumption = true
      writeJournal("running")
      setPhase("WAIT_COMPLETE", "全部流体已注入，机器已接收配方")
      return
    end
    local expectedTotal = 0
    for _, requirement in ipairs(state.requirements) do
      expectedTotal = expectedTotal + requirement.amount
      if (hatch.byName[requirement.name] or 0) ~= requirement.amount then
        error("进阶存储输入仓装载校验失败: " .. requirement.label)
      end
    end
    if hatch.total ~= expectedTotal then error("进阶存储输入仓存在本轮之外的额外流体") end
    writeJournal("loaded")
    state.observedConsumption = false
    setPhase("WAIT_START", "全部流体已逐种注入进阶存储输入仓，等待机器自动识别")
  end

  local function finishCycle()
    clearJournal()
    state.cycle = state.cycle + 1
    state.hints = nil
    state.requirements = {}
    state.stableSignature = nil
    state.stableCount = 0
    state.partialSince = nil
    state.recycleIndex = 1
    state.recycleQuietUntil = nil
    state.recycleTotals = nil
    state.ensureIndex = 1
    state.craft = nil
    setPhase("WAIT_HINTS", "本轮完成，等待下一组样板")
  end

  local function recoverJournal(record)
    state.hints = record.hints
    state.requirements = record.requirements or {}
    state.recycleQuietUntil = nil
    state.recycleTotals = record.recycleTotals
    local machine = machineData()
    local snapshot = readSnapshot()
    local hatch = inputHatchSnapshot()
    if machine.progress > 0 or machine.active then
      state.observedConsumption = true
      setPhase("WAIT_COMPLETE", "从周期日志恢复运行中配方")
      return
    end
    if record.stage == "loading" then
      local refunded, reason = refundKnownInputs()
      if not refunded then return fail("恢复中断装载时回送失败: " .. tostring(reason)) end
      state.ensureIndex = 1
      writeJournal("recycled")
      setPhase("ENSURE_CRAFTED", "中断的输入仓装载已回送 AE，重新复核库存")
      return
    end
    if record.stage == "loaded" and hatch.total > 0 then
      state.observedConsumption = false
      setPhase("WAIT_START", "从周期日志恢复已装载的输入仓配方")
      return
    end
    if state.hints and snapshotSignature(snapshot) == snapshotSignature(state.hints) then
      state.recycleIndex = 1
      setPhase("RECYCLE_HINTS", "从周期日志恢复样板处理")
      return
    end
    if record.stage == "captured" or record.stage == "recycling" then
      state.recycleIndex = tonumber(record.recycleIndex) or 1
      setPhase("RECYCLE_HINTS", "从周期日志恢复样板处理")
      return
    end
    if snapshotEmpty(snapshot) and hatch.total == 0 and
      (record.stage == "recycled" or record.stage == "crafting") then
      state.ensureIndex = 1
      setPhase("ENSURE_CRAFTED", "从周期日志恢复库存补充")
      return
    end
    if record.stage == "running" then
      if routeProducts(snapshot) then snapshot = readSnapshot() end
      clearJournal()
      state.cycle = state.cycle + 1
      state.hints, state.requirements = nil, {}
      setPhase("WAIT_HINTS", "恢复时确认上一轮已被机器消耗")
      return
    end
    fail("周期日志与当前输入仓/机器状态不一致，按 R 尝试安全回送后人工检查")
  end

  local function selfTest()
    initializeComponents()
    local interfaceTanks = numberCall(devices.transposer, "getTankCount", config.interfaceSide)
    if not interfaceTanks or interfaceTanks < 1 then
      error("转运器 interfaceSide 没有检测到 ME 二合一接口流体槽")
    end
    clearInterfaceFluid(true)
    local record = loadJournal()
    machineData()
    local snapshot = readSnapshot()
    if record then
      log("warn", "检测到未完成周期日志，执行安全恢复")
      recoverJournal(record)
    elseif not snapshotEmpty(snapshot) then
      local expected = profile.mode == "quark" and 7 or 3
      local requirements = #snapshot.items + #snapshot.fluids == expected and buildRequirements(snapshot) or nil
      if requirements then
        setPhase("WAIT_HINTS", "自检通过，检测到待处理样板")
      else
        fail("启动时进阶存储输入仓存在非本模式残留，拒绝自动覆盖或回送")
      end
    else
      setPhase("WAIT_HINTS", "自检通过，等待机器输出样板")
    end
  end

  local function waitHintsStep()
    machineData()
    local snapshot = readSnapshot()
    if routeProducts(snapshot) then snapshot = readSnapshot() end
    local total = #snapshot.items + #snapshot.fluids
    if total == 0 then
      state.stableSignature, state.stableCount, state.partialSince = nil, 0, nil
      return
    end
    if total > 7 then error("进阶存储输入仓出现超过 7 种残留，拒绝自动处理") end
    local expected = profile.mode == "quark" and 7 or 3
    if total ~= expected then
      state.partialSince = state.partialSince or computer.uptime()
      if computer.uptime() - state.partialSince > config.partialHintTimeout then
        error("样板长时间不完整: 当前 " .. total .. " / 期望 " .. expected)
      end
      return
    end

    local signature = snapshotSignature(snapshot)
    if signature == state.stableSignature then state.stableCount = state.stableCount + 1
    else state.stableSignature, state.stableCount = signature, 1 end
    if state.stableCount < config.stableSamples then return end

    local requirements, reason = buildRequirements(snapshot)
    if not requirements then error(reason) end
    state.hints = snapshot
    state.requirements = requirements
    state.recycleIndex = 1
    state.recycleQuietUntil = nil
    state.recycleTotals = nil
    writeJournal("captured")
    setPhase("RECYCLE_HINTS", "样板稳定且签名正确，开始回送 AE")
  end

  local function waitStartStep()
    local machine = machineData()
    local empty = inputHatchEmpty()
    if machine.progress > 0 or machine.active or empty then
      state.observedConsumption = empty
      writeJournal("running")
      setPhase("WAIT_COMPLETE", "机器已接收本轮原料")
      return
    end
    if computer.uptime() - state.phaseSince > config.dispatchTimeout then
      local refunded, reason = refundKnownInputs()
      if not refunded then error("机器启动超时且输入仓回送失败: " .. tostring(reason)) end
      error("机器启动超时，输入仓原料已回送 AE")
    end
  end

  local function waitCompleteStep()
    local machine = machineData()
    if machine.progress > 0 or machine.active then
      state.observedConsumption = true
      if computer.uptime() - state.phaseSince > config.recipeTimeout then
        error("机器运行超过 recipeTimeout，保持现场并锁定")
      end
      return
    end
    if state.observedConsumption then
      local snapshot = readSnapshot()
      if routeProducts(snapshot) then readSnapshot() end
      finishCycle()
    end
  end

  local function retryOrRefund()
    if not devices.transposer or not devices.interface then return end
    if (state.phase == "WAIT_START" or state.phase == "FAULT") and #state.requirements > 0 then
      local refunded, reason = refundKnownInputs()
      if not refunded then
        fail("人工恢复回送失败，保持锁定: " .. tostring(reason))
        return
      end
    end
    state.fault = nil
    local record = loadJournal()
    if record then recoverJournal(record)
    else
      state.requirements = {}
      state.hints = nil
      setPhase("WAIT_HINTS", "人工重试完成")
    end
  end

  local function step()
    if state.phase == "WAIT_HINTS" then waitHintsStep()
    elseif state.phase == "RECYCLE_HINTS" then recycleStep()
    elseif state.phase == "ENSURE_CRAFTED" then craftStep()
    elseif state.phase == "VERIFY_STOCK" then
      updateRequirementStock()
      setPhase("DISPATCH")
    elseif state.phase == "DISPATCH" then dispatch()
    elseif state.phase == "WAIT_START" then waitStartStep()
    elseif state.phase == "WAIT_COMPLETE" then waitCompleteStep() end
  end

  local ok, reason = pcall(selfTest)
  if not ok then
    if gpu and state.uiWidth then fail(reason) else restoreUi(); error(reason) end
  end

  local lastCraftPoll = 0
  while not state.quitting do
    if not state.paused and state.phase ~= "FAULT" then
      local now = computer.uptime()
      if state.phase ~= "ENSURE_CRAFTED" or now - lastCraftPoll >= config.craftPollInterval then
        local stepOk, stepReason = pcall(step)
        if not stepOk then fail(stepReason) end
        if state.phase == "ENSURE_CRAFTED" then lastCraftPoll = now end
      end
    else
      pcall(machineData)
    end
    render()
    local signal = { event.pull(config.pollInterval) }
    if signal[1] == "key_down" then
      local char, code = signal[3], signal[4]
      if code == ESCAPE_KEY or char == string.byte("q") or char == string.byte("Q") then
        state.quitting = true
      elseif char == 32 then
        state.paused = not state.paused
        log("info", state.paused and "已暂停" or "已继续")
      elseif char == string.byte("r") or char == string.byte("R") then
        local retryOk, retryReason = pcall(retryOrRefund)
        if not retryOk then fail(retryReason) end
      end
    end
  end

  pcall(clearInterfaceFluid, true)
  restoreUi()
  return true
end

return M
