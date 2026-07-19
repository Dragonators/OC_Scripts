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
local UNIVERSAL_CELL_ID = "IC2:itemFluidCell"
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
  ioHubAddress = nil,
  dualHatchAddress = nil,
  databaseAddress = nil,
  gtMachineAddress = nil,
  gpuAddress = nil,
  screenAddress = nil,
  cpuName = "",
  pollInterval = 0.5,
  craftPollInterval = 2,
  craftTimeout = 600,
  dispatchTimeout = 30,
  recipeTimeout = 900,
  partialHintTimeout = 30,
  maxCraftAttempts = 6,
  stableSamples = 2,
  screenWidth = 120,
  screenHeight = 35,
  logLines = 6,
  databaseSlots = {
    fluidCellStart = 1,
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

local function universalCellNbt(name)
  assert(validFluidName(name), "非法流体注册名: " .. tostring(name))
  return string.format('{Fluid:{FluidName:"%s",Amount:1000}}', name)
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
  if type(fn) ~= "function" then return nil, "数据库缺少方法 " .. tostring(method) end
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

local function allTasksExecuted(states, expected)
  if type(states) ~= "table" or #states ~= expected then return false end
  for _, task in ipairs(states) do
    if type(task) ~= "table" or task.state ~= "executed" then return false end
  end
  return true
end

local function dualDatabaseIndex(luaSlot)
  return assert(tonumber(luaSlot), "database slot required") - 1
end

M._test = {
  resolveDustPlasma = resolveDustPlasma,
  buildQuarkRequirements = buildQuarkRequirements,
  buildMagmatterRequirements = buildMagmatterRequirements,
  fluidDropNbt = fluidDropNbt,
  universalCellNbt = universalCellNbt,
  dropletNameZh = dropletNameZh,
  snapshotSignature = snapshotSignature,
  allTasksExecuted = allTasksExecuted,
  dualDatabaseIndex = dualDatabaseIndex
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
  if not proxy or type(proxy[method]) ~= "function" then
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
    if not available[method] then error(label .. " 缺少回调 " .. method) end
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
    for slot = 1, 32 do
      local result = resultCall(devices.iohub, "getStackInInternalSlot", slot)
      if not result.ok then error("读取 IO 枢纽物品槽失败: " .. result.error) end
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
    for tank = 1, 8 do
      local result = resultCall(devices.iohub, "getFluidInInternalTank", tank)
      if not result.ok then error("读取 IO 枢纽流体槽失败: " .. result.error) end
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

  local function dualEmpty()
    return valueCall(devices.dual, "isEmpty") == true
  end

  local function machineData()
    local progress = tonumber(valueCall(devices.machine, "getWorkProgress")) or 0
    local maximum = tonumber(valueCall(devices.machine, "getWorkMaxProgress")) or 0
    local active = valueCall(devices.machine, "isMachineActive") == true
    state.machine = { progress = progress, maximum = maximum, active = active }
    return state.machine
  end

  local function networkFluids()
    local list = valueCall(devices.iohub, "getFluidsInNetwork") or {}
    local result = {}
    for _, fluid in pairs(list) do
      if type(fluid) == "table" and fluid.name then
        result[fluid.name] = (result[fluid.name] or 0) + tonumber(fluid.amount or 0)
      end
    end
    return result
  end

  local function proxy(kind, prefix)
    local address = componentAddress(kind, prefix)
    return component.proxy(address), address
  end

  local function initializeComponents()
    devices.iohub, addresses.iohub = proxy("iohub", config.ioHubAddress)
    devices.dual, addresses.dual = proxy("dualhatch", config.dualHatchAddress)
    devices.database, addresses.database = proxy("database", config.databaseAddress)
    devices.machine, addresses.machine = proxy("gt_machine", config.gtMachineAddress)
    devices.gpu, addresses.gpu = proxy("gpu", config.gpuAddress)
    addresses.screen = componentAddress("screen", config.screenAddress)
    gpu = devices.gpu

    validateMethods(addresses.iohub, "IO 枢纽", {
      "getStackInInternalSlot", "getFluidInInternalTank", "select", "count", "selectTank", "tankLevel",
      "sendItems", "sendFluids", "getFluidsInNetwork", "getCraftables", "getCpus"
    })
    validateMethods(addresses.dual, "OC 二合一输入枢纽",
      { "addTask", "cancelTask", "submitTask", "isEmpty", "refund" })
    validateMethods(addresses.database, "数据库", { "get", "set", "size" })
    validateMethods(addresses.machine, "gt_machine", { "getWorkProgress", "getWorkMaxProgress", "isMachineActive" })

    local needed = math.max(config.databaseSlots.fluidCellStart + 6, config.databaseSlots.craftDrop,
      config.databaseSlots.plasmaProbe)
    if tonumber(valueCall(devices.database, "size")) < needed then
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
    ENSURE_CRAFTED = "补充合成", VERIFY_STOCK = "库存复核", DISPATCH = "整批提交",
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
    draw("components", 2, 5, string.format("IO %s  双输入 %s  DB %s  GT %s  样板 %d+%d",
      short(addresses.iohub), short(addresses.dual), short(addresses.database), short(addresses.machine),
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
        if requirement.status == "就绪" then color = colors.good
        elseif requirement.status == "缺少样板" or requirement.status == "失败" then color = colors.bad
        elseif requirement.status == "合成中" then color = colors.warn end
      end
      draw("req" .. row, 2, tableTop + row, text, width - 3, color, row % 2 == 0 and colors.panel or colors.bg)
    end

    local infoY = tableTop + 9
    local faultText = state.fault and ("故障: " .. state.fault) or "安全策略: 未识别残留不会自动回送；提交异常会退款并锁定"
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
    draw("footer", 1, height, "  Space 暂停/继续   R 安全重试/退款   Q/Esc 退出", width, colors.white, colors.header)
  end

  local function buildRequirements(snapshot)
    if profile.mode == "quark" then
      return buildQuarkRequirements(snapshot, devices.database, config.databaseSlots.plasmaProbe)
    end
    return buildMagmatterRequirements(snapshot, devices.database, config.databaseSlots.plasmaProbe)
  end

  local function sendItemToAE(hint)
    local current = valueCall(devices.iohub, "getStackInInternalSlot", hint.slot)
    if current ~= nil and (current.name ~= hint.name or tonumber(current.damage) ~= tonumber(hint.damage)
        or tonumber(current.size) ~= tonumber(hint.size)) then
      error("物品槽 " .. hint.slot .. " 已被未知物品替换，拒绝回送")
    end
    valueCall(devices.iohub, "select", hint.slot)
    local before = tonumber(valueCall(devices.iohub, "count", hint.slot)) or 0
    if before <= 0 then return end
    local sent = tonumber(valueCall(devices.iohub, "sendItems", before)) or 0
    local after = tonumber(valueCall(devices.iohub, "count", hint.slot)) or 0
    if sent ~= before or after ~= 0 then
      error(string.format("物品槽 %d 回送 AE 不完整: %d/%d，剩余 %d", hint.slot, sent, before, after))
    end
  end

  local function sendFluidToAE(hint)
    local current = valueCall(devices.iohub, "getFluidInInternalTank", hint.slot)
    if current ~= nil and (current.name ~= hint.name or tonumber(current.amount) ~= tonumber(hint.amount)) then
      error("流体槽 " .. hint.slot .. " 已被未知流体替换，拒绝回送")
    end
    valueCall(devices.iohub, "selectTank", hint.slot)
    local before = tonumber(valueCall(devices.iohub, "tankLevel", hint.slot)) or 0
    if before <= 0 then return end
    local sent = tonumber(valueCall(devices.iohub, "sendFluids", before)) or 0
    local after = tonumber(valueCall(devices.iohub, "tankLevel", hint.slot)) or 0
    if sent ~= before or after ~= 0 then
      error(string.format("流体槽 %d 回送 AE 不完整: %d/%d，剩余 %d", hint.slot, sent, before, after))
    end
  end

  local function isProductFluid(name)
    if profile.mode == "quark" then return isNamedFluid(name, "quarkgluonplasma") end
    return isNamedFluid(name, "magmatter")
  end

  local function routeProducts(snapshot)
    local routed = false
    for _, fluid in ipairs(snapshot.fluids) do
      if isProductFluid(fluid.name) then
        sendFluidToAE(fluid)
        log("info", "成品已送回主网: " .. fluidNameZh(fluid.name, fluid.label) .. " " ..
          formatNumber(fluid.amount) .. " L")
        routed = true
      end
    end
    return routed
  end

  local function recycleStep()
    local combined = {}
    for _, hint in ipairs(state.hints.items) do combined[#combined + 1] = { kind = "item", hint = hint } end
    for _, hint in ipairs(state.hints.fluids) do combined[#combined + 1] = { kind = "fluid", hint = hint } end
    local current = combined[state.recycleIndex]
    if not current then
      local remaining = readSnapshot()
      if not snapshotEmpty(remaining) then error("样板处理后 IO 枢纽仍有残留") end
      writeJournal("recycled")
      state.ensureIndex = 1
      setPhase("ENSURE_CRAFTED", "全部样板已回送 AE，开始核验库存")
      return
    end
    if current.kind == "item" then sendItemToAE(current.hint)
    else sendFluidToAE(current.hint) end
    state.recycleIndex = state.recycleIndex + 1
    writeJournal("recycling")
  end

  local function namedCpuBusy()
    if not config.cpuName or config.cpuName == "" then return false end
    local cpus = valueCall(devices.iohub, "getCpus") or {}
    for _, cpu in pairs(cpus) do
      if cpu.name == config.cpuName then return cpu.busy == true end
    end
    error("未找到专用合成 CPU: " .. config.cpuName)
  end

  local function cancelNamedCpu()
    if not config.cpuName or config.cpuName == "" then return false end
    local cpus = valueCall(devices.iohub, "getCpus") or {}
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
    local craftables = valueCall(devices.iohub, "getCraftables", { name = drop.name, label = drop.label }) or {}
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

  local function refundDual()
    if dualEmpty() then return true end
    local result = resultCall(devices.dual, "refund")
    if not result.ok or result.values[1] ~= true or not dualEmpty() then return false end
    return true
  end

  local function dispatch()
    if not dualEmpty() then error("提交前 OC 二合一输入枢纽不为空") end
    local stock = updateRequirementStock()
    for _, requirement in ipairs(state.requirements) do
      if (stock[requirement.name] or 0) < requirement.amount then
        state.ensureIndex = 1
        setPhase("ENSURE_CRAFTED", "提交前库存发生变化，重新补充")
        return
      end
    end

    local queuedIds = {}
    writeJournal("queueing")
    local queueOk, queueReason = pcall(function()
      for index, requirement in ipairs(state.requirements) do
        local slot = config.databaseSlots.fluidCellStart + index - 1
        local ok, reason = databaseCall(devices.database, "set", slot, UNIVERSAL_CELL_ID, 0,
          universalCellNbt(requirement.name))
        if not ok then error("写入通用流体单元失败: " .. tostring(reason)) end
        -- DualInputHachOC reads UpgradeDatabase#getStackInSlot directly, so this
        -- callback uses the Java inventory's zero-based index, unlike database.get/set.
        local added = resultCall(devices.dual, "addTask", addresses.database, dualDatabaseIndex(slot),
          requirement.amount, true)
        local task = added.ok and added.values[1]
        if type(task) ~= "table" or task.state ~= "added" or not task.id then
          error("加入双输入任务失败: " .. requirement.label)
        end
        queuedIds[#queuedIds + 1] = task.id
      end
    end)
    if not queueOk then
      for _, id in ipairs(queuedIds) do pcall(devices.dual.cancelTask, id) end
      error(queueReason)
    end

    writeJournal("dispatching")
    local submitted = resultCall(devices.dual, "submitTask")
    if not submitted.ok then
      for _, id in ipairs(queuedIds) do pcall(devices.dual.cancelTask, id) end
      if not refundDual() then error("提交调用失败且退款失败: " .. submitted.error) end
      error("提交调用失败，已取消队列并退款: " .. submitted.error)
    end
    local states = submitted.ok and submitted.values[1]
    local allExecuted = allTasksExecuted(states, #state.requirements)
    if not allExecuted then
      local refunded = refundDual()
      if not refunded then error("双输入任务部分执行且退款失败，禁止自动重试") end
      error("双输入任务未全部执行，已退款")
    end

    writeJournal("dispatched")
    state.observedConsumption = false
    setPhase("WAIT_START", "全部流体已在同一 tick 提交")
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
    state.ensureIndex = 1
    state.craft = nil
    setPhase("WAIT_HINTS", "本轮完成，等待下一组样板")
  end

  local function recoverJournal(record)
    state.hints = record.hints
    state.requirements = record.requirements or {}
    local machine = machineData()
    local snapshot = readSnapshot()
    if machine.progress > 0 or machine.active then
      state.observedConsumption = true
      setPhase("WAIT_COMPLETE", "从周期日志恢复运行中配方")
      return
    end
    if record.stage == "queueing" or record.stage == "dispatching" then
      local flushed = resultCall(devices.dual, "submitTask")
      local states = flushed.ok and flushed.values[1]
      if allTasksExecuted(states, #state.requirements) then
        writeJournal("dispatched")
        setPhase("WAIT_START", "已恢复并提交崩溃前的完整任务队列")
        return
      end
      if not refundDual() then
        fail("恢复未完成任务队列时退款失败")
        return
      end
      state.ensureIndex = 1
      writeJournal("recycled")
      setPhase("ENSURE_CRAFTED", "未完成任务队列已清理并退款")
      return
    end
    if not dualEmpty() then
      state.observedConsumption = false
      setPhase("WAIT_START", "从周期日志恢复已提交配方")
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
    if snapshotEmpty(snapshot) and (record.stage == "recycled" or record.stage == "crafting") then
      state.ensureIndex = 1
      setPhase("ENSURE_CRAFTED", "从周期日志恢复库存补充")
      return
    end
    if snapshotEmpty(snapshot) and (record.stage == "dispatched" or record.stage == "running") then
      clearJournal()
      state.cycle = state.cycle + 1
      state.hints, state.requirements = nil, {}
      setPhase("WAIT_HINTS", "恢复时确认上一轮已被机器消耗")
      return
    end
    fail("周期日志与当前 IO/机器状态不一致，按 R 尝试退款后人工检查")
  end

  local function selfTest()
    initializeComponents()
    local record = loadJournal()
    machineData()
    readSnapshot()
    if record then
      log("warn", "检测到未完成周期日志，执行安全恢复")
      recoverJournal(record)
    elseif not dualEmpty() then
      fail("启动时 OC 二合一输入枢纽存在无归属残留")
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
    if total > 7 then error("IO 枢纽出现超过 7 种残留，拒绝自动处理") end
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
    writeJournal("captured")
    setPhase("RECYCLE_HINTS", "样板稳定且签名正确，开始回送 AE")
  end

  local function waitStartStep()
    local machine = machineData()
    local empty = dualEmpty()
    if machine.progress > 0 or machine.active or empty then
      state.observedConsumption = empty
      writeJournal("running")
      setPhase("WAIT_COMPLETE", "机器已接收本轮原料")
      return
    end
    if computer.uptime() - state.phaseSince > config.dispatchTimeout then
      if not refundDual() then error("机器启动超时且退款失败") end
      error("机器启动超时，原料已退款")
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
    if state.observedConsumption and dualEmpty() then finishCycle() end
  end

  local function retryOrRefund()
    if not devices.dual then return end
    if state.phase == "WAIT_START" or state.phase == "FAULT" then
      if not refundDual() then
        fail("人工重试退款失败，保持锁定")
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
      pcall(readSnapshot)
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

  restoreUi()
  return true
end

return M
