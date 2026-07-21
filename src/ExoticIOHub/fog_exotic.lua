-- FOG Exotic Module automation, written from scratch for GTNH 2.8.4 / OC 1.11.20.
-- One computer controls one module. Pass a config file as the first argument.

local component = require("component")
local computer = require("computer")
local sides = require("sides")
local unicode = require("unicode")

local argv = {...}
local configPath = argv[1] or "/etc/fog_exotic.cfg"

local configChunk, configError = loadfile(configPath)
if not configChunk then
  error("无法读取配置文件 " .. configPath .. ": " .. tostring(configError), 0)
end

local configOK, config = pcall(configChunk)
if not configOK or type(config) ~= "table" then
  error("配置文件必须 return 一个 table: " .. tostring(config), 0)
end

config.mode = config.mode or "quark"
config.components = config.components or {}
config.sides = config.sides or {}
config.timing = config.timing or {}
config.gui = config.gui or {}

if config.mode ~= "quark" and config.mode ~= "magmatter" then
  error("config.mode 只能是 quark 或 magmatter", 0)
end

local timing = {
  poll = config.timing.poll or 0.25,
  stableScans = config.timing.stableScans or 2,
  interfaceWarmup = config.timing.interfaceWarmup or 0.75,
  interfaceClearTimeout = config.timing.interfaceClearTimeout or 8,
  returnStallTimeout = config.timing.returnStallTimeout or 10,
  missingPatternRetry = config.timing.missingPatternRetry or 5,
  craftPoll = config.timing.craftPoll or 0.25,
  craftWarningAfter = config.timing.craftWarningAfter or 600,
  interfaceSupplyGrace = config.timing.interfaceSupplyGrace or 2,
  transferYield = config.timing.transferYield or 0.05,
  returnVerifyDelay = config.timing.returnVerifyDelay or 0.1,
  advanceWarningAfter = config.timing.advanceWarningAfter or 30,
  cycleSettle = config.timing.cycleSettle or 0,
}

local MAX_INTERFACE_SLOTS = 6

local FLUID_ZH = {
  ["plasma.advancednitinol"] = "高级镍钛诺等离子体",
  ["plasma.aluminium"] = "铝等离子体",
  ["plasma.americium"] = "镅等离子体",
  ["plasma.antimony"] = "锑等离子体",
  ["plasma.ardite"] = "阿迪特等离子体",
  ["plasma.argon"] = "氩等离子体",
  ["plasma.arsenic"] = "砷等离子体",
  ["plasma.astraltitanium"] = "星体钛等离子体",
  ["plasma.barium"] = "钡等离子体",
  ["plasma.bedrockium"] = "基岩等离子体",
  ["plasma.beryllium"] = "铍等离子体",
  ["plasma.bismuth"] = "铋等离子体",
  ["plasma.boron"] = "硼等离子体",
  ["plasma.bromine"] = "溴等离子体",
  ["plasma.cadmium"] = "镉等离子体",
  ["plasma.caesium"] = "铯等离子体",
  ["plasma.calcium"] = "钙等离子体",
  ["plasma.californium"] = "锎等离子体",
  ["plasma.carbon"] = "碳等离子体",
  ["plasma.celestialtungsten"] = "天体钨等离子体",
  ["plasma.cerium"] = "铈等离子体",
  ["plasma.chlorine"] = "氯等离子体",
  ["plasma.chromaticglass"] = "彩色玻璃等离子体",
  ["plasma.chrome"] = "铬等离子体",
  ["plasma.cobalt"] = "钴等离子体",
  ["plasma.copper"] = "铜等离子体",
  ["plasma.cosmicneutronium"] = "宇宙中子态素等离子体",
  ["plasma.creon"] = "创律合金等离子体",
  ["plasma.curium"] = "锔等离子体",
  ["plasma.desh"] = "戴斯等离子体",
  ["plasma.deuterium"] = "氘等离子体",
  ["plasma.draconium"] = "龙等离子体",
  ["plasma.draconiumawakened"] = "觉醒龙等离子体",
  ["plasma.dragonblood"] = "龙血等离子体",
  ["plasma.dysprosium"] = "镝等离子体",
  ["plasma.empty"] = "空等离子体",
  ["plasma.erbium"] = "铒等离子体",
  ["plasma.europium"] = "铕等离子体",
  ["plasma.fermium"] = "镄等离子体",
  ["plasma.flerovium_gt5u"] = "等离子体",
  ["plasma.fluorine"] = "氟等离子体",
  ["plasma.force"] = "力量等离子体",
  ["plasma.gadolinium"] = "钆等离子体",
  ["plasma.gallium"] = "镓等离子体",
  ["plasma.germanium"] = "锗等离子体",
  ["plasma.gold"] = "金等离子体",
  ["plasma.hafnium"] = "铪等离子体",
  ["plasma.helium"] = "氦等离子体",
  ["plasma.helium_3"] = "氦-3等离子体",
  ["plasma.holmium"] = "钬等离子体",
  ["plasma.hydrogen"] = "氢等离子体",
  ["plasma.hypogen"] = "海珀珍等离子体",
  ["plasma.ichorium"] = "灵宝等离子体",
  ["plasma.indium"] = "铟等离子体",
  ["plasma.infinity"] = "无尽等离子体",
  ["plasma.iodine"] = "碘等离子体",
  ["plasma.iridium"] = "铱等离子体",
  ["plasma.iron"] = "铁等离子体",
  ["plasma.krypton"] = "氪等离子体",
  ["plasma.lanthanum"] = "镧等离子体",
  ["plasma.lead"] = "铅等离子体",
  ["plasma.lithium"] = "锂等离子体",
  ["plasma.lutetium"] = "镥等离子体",
  ["plasma.magic"] = "魔力等离子体",
  ["plasma.magnesium"] = "镁等离子体",
  ["plasma.manganese"] = "锰等离子体",
  ["plasma.mercury"] = "汞等离子体",
  ["plasma.meteoriciron"] = "陨铁等离子体",
  ["plasma.molybdenum"] = "钼等离子体",
  ["plasma.naquadah"] = "硅岩等离子体",
  ["plasma.naquadria"] = "超能硅岩等离子体",
  ["plasma.neodymium"] = "钕等离子体",
  ["plasma.neon"] = "氖等离子体",
  ["plasma.neptunium"] = "镎等离子体",
  ["plasma.neutronium"] = "中子等离子体",
  ["plasma.nickel"] = "镍等离子体",
  ["plasma.niobium"] = "铌等离子体",
  ["plasma.nitrogen"] = "氮等离子体",
  ["plasma.null"] = "NULL等离子体",
  ["plasma.oriharukon"] = "奥利哈钢等离子体",
  ["plasma.osmium"] = "锇等离子体",
  ["plasma.oxygen"] = "氧等离子体",
  ["plasma.palladium"] = "钯等离子体",
  ["plasma.phosphorus"] = "磷等离子体",
  ["plasma.platinum"] = "铂等离子体",
  ["plasma.plutonium"] = "钚-239等离子体",
  ["plasma.plutonium238"] = "钚-238等离子体",
  ["plasma.plutonium241"] = "钚-241等离子体",
  ["plasma.polonium"] = "钋等离子体",
  ["plasma.potassium"] = "钾等离子体",
  ["plasma.praseodymium"] = "镨等离子体",
  ["plasma.promethium"] = "钷等离子体",
  ["plasma.protactinium"] = "镤等离子体",
  ["plasma.radium"] = "镭等离子体",
  ["plasma.radon"] = "氡等离子体",
  ["plasma.rhenium"] = "铼等离子体",
  ["plasma.rhodium"] = "铑等离子体",
  ["plasma.rhugnor"] = "鲁格诺等离子体",
  ["plasma.rubidium"] = "铷等离子体",
  ["plasma.runite"] = "虚恩等离子体",
  ["plasma.ruthenium"] = "钌等离子体",
  ["plasma.samarium"] = "钐等离子体",
  ["plasma.scandium"] = "钪等离子体",
  ["plasma.selenium"] = "硒等离子体",
  ["plasma.silicon"] = "生硅等离子体",
  ["plasma.silver"] = "银等离子体",
  ["plasma.sixphasedcopper"] = "六相铜等离子体",
  ["plasma.sodium"] = "钠等离子体",
  ["plasma.strontium"] = "锶等离子体",
  ["plasma.sulfur"] = "硫等离子体",
  ["plasma.tantalum"] = "钽等离子体",
  ["plasma.technetium"] = "锝等离子体",
  ["plasma.tellurium"] = "碲等离子体",
  ["plasma.terbium"] = "铽等离子体",
  ["plasma.thallium"] = "铊等离子体",
  ["plasma.thorium"] = "钍等离子体",
  ["plasma.thorium232"] = "钍-232等离子体",
  ["plasma.thulium"] = "铥等离子体",
  ["plasma.tin"] = "锡等离子体",
  ["plasma.titanium"] = "钛等离子体",
  ["plasma.tritanium"] = "三钛等离子体",
  ["plasma.tritium"] = "氚等离子体",
  ["plasma.tungsten"] = "钨等离子体",
  ["plasma.uranium"] = "铀-238等离子体",
  ["plasma.uranium232"] = "铀-232等离子体",
  ["plasma.uranium233"] = "铀-233等离子体",
  ["plasma.uranium235"] = "铀-235等离子体",
  ["plasma.vanadium"] = "钒等离子体",
  ["plasma.xenon"] = "氙等离子体",
  ["plasma.ytterbium"] = "镱等离子体",
  ["plasma.yttrium"] = "钇等离子体",
  ["plasma.zinc"] = "锌等离子体",
  ["plasma.zirconium"] = "锆等离子体",
  ["spatialfluid"] = "扩大化空间流体",
  ["temporalfluid"] = "富快子时间流体",
}

-- Installed GTNH 2.8.4 / GregTech 5.09.51.482 item metadata.
local BARTWORKS_DUST = {
  [3] = "zirconium",
  [30] = "thorium232",
  [64] = "ruthenium",
  [78] = "rhodium",
  [11000] = "hafnium",
  [11012] = "iodine",
}

local MAGMATTER_GT_DUST = {
  [2129] = "neutronium",
  [2329] = "tritanium",
  [2395] = "bedrockium",
  [2397] = "infinity",
  [2976] = "draconiumawakened",
  [2978] = "ichorium",
  [2982] = "cosmicneutronium",
  [2984] = "flerovium_gt5u",
}

local COLORS = {
  bg = 0x10141F,
  panel = 0x1A2233,
  header = 0x25395C,
  text = 0xE8EDF7,
  muted = 0x8F9BB3,
  accent = 0x4CC9F0,
  good = 0x72E6A2,
  warn = 0xFFD166,
  bad = 0xFF6B7A,
  bar = 0x2D3A50,
}

local ui = {
  state = "启动",
  detail = "正在读取组件",
  cycle = 0,
  requests = {},
  current = 0,
  done = 0,
  total = 0,
  logs = {},
}

local devices = {}
local gpu
local screenWidth, screenHeight = 80, 25
local interfaceSlotCount = 1
local configuredSlotCount = 0
local interfaceKnownClear = false

local function sideValue(value, key)
  if type(value) == "number" then return value end
  if type(value) == "string" and sides[value] ~= nil then return sides[value] end
  error("config.sides." .. key .. " 必须是 sides 名称或数字", 0)
end

local cacheSide = sideValue(config.sides.cache or "east", "cache")
local mainSide = sideValue(config.sides.main or "down", "main")

local function clip(value, width)
  local text = tostring(value or "")
  if width <= 0 then return "" end
  if unicode.len(text) <= width then return text end
  if width == 1 then return unicode.sub(text, 1, 1) end
  return unicode.sub(text, 1, width - 1) .. "…"
end

local function pad(value, width)
  local text = clip(value, width)
  return text .. string.rep(" ", math.max(0, width - unicode.len(text)))
end

local function log(message)
  local stamp = string.format("%6.1f", computer.uptime())
  table.insert(ui.logs, stamp .. "  " .. tostring(message))
  while #ui.logs > 4 do table.remove(ui.logs, 1) end
end

local function gpuWrite(x, y, value, foreground, background)
  if not gpu or y < 1 or y > screenHeight or x > screenWidth then return end
  gpu.setForeground(foreground or COLORS.text)
  gpu.setBackground(background or COLORS.bg)
  gpu.set(x, y, clip(value, screenWidth - x + 1))
end

local function render()
  if not gpu then return end

  gpu.setBackground(COLORS.bg)
  gpu.setForeground(COLORS.text)
  gpu.fill(1, 1, screenWidth, screenHeight, " ")

  gpu.setBackground(COLORS.header)
  gpu.fill(1, 1, screenWidth, 3, " ")
  gpuWrite(3, 1, "FOG 奇异模块自动化", COLORS.text, COLORS.header)
  local modeLabel = config.mode == "quark" and "简并夸克胶子等离子体" or "磁物质"
  gpuWrite(3, 2, modeLabel .. "  ·  周期 " .. ui.cycle, COLORS.accent, COLORS.header)
  gpuWrite(math.max(3, screenWidth - 20), 2, os.date("%H:%M:%S"), COLORS.muted, COLORS.header)

  gpu.setBackground(COLORS.panel)
  gpu.fill(2, 5, screenWidth - 2, 3, " ")
  local stateColor = COLORS.accent
  if ui.state:find("缺失") or ui.state:find("暂停") then stateColor = COLORS.warn end
  if ui.state:find("故障") then stateColor = COLORS.bad end
  if ui.state:find("完成") then stateColor = COLORS.good end
  gpuWrite(4, 5, "当前状态", COLORS.muted, COLORS.panel)
  gpuWrite(14, 5, ui.state, stateColor, COLORS.panel)
  gpuWrite(4, 6, clip(ui.detail, screenWidth - 8), COLORS.text, COLORS.panel)

  local tableTop = 9
  gpuWrite(3, tableTop, "#", COLORS.muted)
  gpuWrite(7, tableTop, "目标流体", COLORS.muted)
  gpuWrite(math.max(32, screenWidth - 28), tableTop, "需求", COLORS.muted)
  gpuWrite(math.max(46, screenWidth - 14), tableTop, "状态", COLORS.muted)

  local maxRows = math.max(1, screenHeight - 17)
  for index = 1, math.min(#ui.requests, maxRows) do
    local request = ui.requests[index]
    local row = tableTop + index
    local complete = (request.delivered or 0) >= request.amount
    local active = request.status and request.status ~= "等待" and not complete
    local marker = complete and "✓" or (active and "▶" or "·")
    local color = complete and COLORS.good or (active and COLORS.accent or COLORS.text)
    gpuWrite(3, row, marker .. " " .. index, color)
    gpuWrite(7, row, clip(request.displayName, math.max(12, screenWidth - 42)), color)
    gpuWrite(math.max(32, screenWidth - 28), row, tostring(request.amount) .. " mB", COLORS.text)
    local requestStatus = complete and "已送入" or (request.status or "等待")
    gpuWrite(math.max(46, screenWidth - 14), row, requestStatus, complete and COLORS.good or COLORS.muted)
  end

  local progressY = screenHeight - 6
  local progressWidth = math.max(10, screenWidth - 20)
  local ratio = ui.total > 0 and math.min(1, ui.done / ui.total) or 0
  gpuWrite(3, progressY, "进度", COLORS.muted)
  gpu.setBackground(COLORS.bar)
  gpu.fill(9, progressY, progressWidth, 1, " ")
  if ratio > 0 then
    gpu.setBackground(COLORS.accent)
    gpu.fill(9, progressY, math.max(1, math.floor(progressWidth * ratio)), 1, " ")
  end
  gpuWrite(10, progressY, string.format("%d / %d mB", ui.done, ui.total), COLORS.text, ratio > 0.55 and COLORS.accent or COLORS.bar)

  gpuWrite(3, screenHeight - 4, "最近事件", COLORS.muted)
  local firstLog = math.max(1, #ui.logs - 2)
  local logRow = 1
  for index = firstLog, #ui.logs do
    gpuWrite(3, screenHeight - 4 + logRow, clip(ui.logs[index], screenWidth - 5), COLORS.text)
    logRow = logRow + 1
  end
end

local function setState(state, detail)
  ui.state = state
  ui.detail = detail or ""
  render()
end

local function componentAddresses(kind, prefix)
  local matches = {}
  for address in component.list(kind, true) do
    if not prefix or prefix == "" or address:sub(1, #prefix) == prefix then
      table.insert(matches, address)
    end
  end
  table.sort(matches)
  return matches
end

local function resolveComponent(kind, prefix, optional)
  local matches = componentAddresses(kind, prefix)
  if #matches == 0 then
    if optional then return nil end
    error("未找到组件 " .. kind .. (prefix and prefix ~= "" and ("，地址前缀 " .. prefix) or ""), 0)
  end
  if #matches > 1 then
    error("组件 " .. kind .. " 不唯一，请在配置中填写地址前缀", 0)
  end
  return component.proxy(matches[1])
end

local function assertMethods(proxy, label, required)
  local methods = component.methods(proxy.address)
  for _, name in ipairs(required) do
    -- component.methods() maps method name to callback directness. A false value
    -- means the method exists but is non-direct; only nil means it is absent.
    if methods[name] == nil then error(label .. " 缺少方法 " .. name, 0) end
  end
end

local function setupComponents()
  devices.transposer = resolveComponent("transposer", config.components.transposer)
  devices.database = resolveComponent("database", config.components.database)
  devices.interface = resolveComponent(config.components.meInterfaceType or "me_interface", config.components.meInterface)
  devices.machine = resolveComponent("gt_machine", config.components.gtMachine, true)
  gpu = resolveComponent("gpu", config.components.gpu)

  assertMethods(devices.transposer, "转运器", {
    "getInventorySize", "getStackInSlot", "getTankCount", "getFluidInTank", "transferItem", "transferFluid",
  })
  assertMethods(devices.database, "数据库升级", {"get", "set"})
  assertMethods(devices.interface, "二合一 ME 接口", {
    "getCraftables", "setFluidInterfaceConfiguration", "getFluidInterfaceConfiguration",
  })
  if devices.machine then assertMethods(devices.machine, "GT 机器", {"isWorkAllowed"}) end

  local reportedTanks = devices.transposer.getTankCount(mainSide) or 0
  if reportedTanks < 1 then error("二合一 ME 接口侧没有可见流体槽，请检查 main 方向", 0) end
  interfaceSlotCount = math.min(MAX_INTERFACE_SLOTS, reportedTanks)

  local maxWidth, maxHeight = gpu.maxResolution()
  screenWidth = math.min(config.gui.width or 80, maxWidth)
  screenHeight = math.min(config.gui.height or 25, maxHeight)
  if screenWidth < 50 or screenHeight < 18 then
    error("屏幕分辨率至少需要 50x18，当前最大为 " .. maxWidth .. "x" .. maxHeight, 0)
  end
  gpu.setResolution(screenWidth, screenHeight)
  log("组件自检通过；接口可并行使用 " .. interfaceSlotCount .. " 个流体槽")
end

local function checkedCall(label, fn, ...)
  local result = {pcall(fn, ...)}
  if not result[1] then error(label .. ": " .. tostring(result[2]), 0) end
  table.remove(result, 1)
  return table.unpack(result)
end

local function fluidSuffix(name)
  return tostring(name or ""):match("([^.]+)$")
end

local function translatedFluid(name)
  return FLUID_ZH[name] or FLUID_ZH[fluidSuffix(name)] or tostring(name)
end

local function dropDisplayName(name)
  -- GTNH 2.8.4 zh_CN: item.fluid_drop.name=%s液滴
  return translatedFluid(name) .. "液滴"
end

local function scanCache()
  local snapshot = {items = {}, fluids = {}}
  local inventorySize = devices.transposer.getInventorySize(cacheSide) or 0
  for slot = 1, inventorySize do
    local stack = devices.transposer.getStackInSlot(cacheSide, slot)
    if stack and (stack.size or 0) > 0 then
      stack.slot = slot
      table.insert(snapshot.items, stack)
    end
  end

  local tankCount = devices.transposer.getTankCount(cacheSide) or 0
  for tank = 1, tankCount do
    local fluid = devices.transposer.getFluidInTank(cacheSide, tank)
    if fluid and (fluid.amount or 0) > 0 then
      fluid.tank = tank
      table.insert(snapshot.fluids, fluid)
    end
  end
  return snapshot
end

local function snapshotSignature(snapshot)
  local parts = {}
  for _, item in ipairs(snapshot.items) do
    table.insert(parts, string.format("I:%s:%s:%s", tostring(item.name), tostring(item.damage), tostring(item.size)))
  end
  for _, fluid in ipairs(snapshot.fluids) do
    table.insert(parts, string.format("F:%s:%s", tostring(fluid.name), tostring(fluid.amount)))
  end
  table.sort(parts)
  return table.concat(parts, "|")
end

local function plasmaFromItem(item)
  if string.lower(tostring(item.name or "")) == "draconicevolution:draconiumdust" then
    return "plasma.draconium"
  end

  if item.name == "miscutils:itemDustDragonMetal" then
    return "plasma.dragonblood"
  end

  local gtppMaterial = tostring(item.name or ""):match("^miscutils:itemDust(.+)$")
  if gtppMaterial then return "plasma." .. string.lower(gtppMaterial) end

  if item.name == "bartworks:gt.bwMetaGenerateddust" then
    local material = BARTWORKS_DUST[item.damage]
    if not material then return nil, "未知 BartWorks 粉尘 damage=" .. tostring(item.damage) end
    return "plasma." .. material
  end

  if item.name == "gregtech:gt.metaitem.01" then
    if config.mode == "magmatter" then
      local material = MAGMATTER_GT_DUST[item.damage]
      if not material then return nil, "未知磁物质 GT 粉尘 damage=" .. tostring(item.damage) end
      return "plasma." .. material
    end

    if item.damage == 382 then return "plasma.ardite" end
    local setOK, setReason = devices.database.set(8, item.name, item.damage + 29000, "")
    if not setOK then return nil, "无法生成等离子体单元数据库项: " .. tostring(setReason) end
    local cell = devices.database.get(8)
    if not cell or not cell.fluid or not cell.fluid.name then
      return nil, "粉尘 damage=" .. tostring(item.damage) .. " 没有对应的等离子体单元"
    end
    return cell.fluid.name
  end

  return nil, "不支持的提示物品 " .. tostring(item.name) .. ":" .. tostring(item.damage)
end

local function addRequest(requests, byFluid, fluidName, amount, source)
  if byFluid[fluidName] then
    byFluid[fluidName].amount = byFluid[fluidName].amount + amount
    byFluid[fluidName].source = byFluid[fluidName].source .. " + " .. source
    return
  end
  local request = {
    fluidName = fluidName,
    displayName = translatedFluid(fluidName),
    amount = amount,
    source = source,
  }
  byFluid[fluidName] = request
  table.insert(requests, request)
end

-- GTNH 2.8's Exotic Module can emit Iron/Copper dust hints while its
-- ore-dictionary conversion silently drops the corresponding plasma input
-- from the internal recipe. Supplying these two fluids only leaves a full
-- stale batch in the ingredient buffer, so they are deliberately not sent.
local FOG_OMITTED_QUARK_INPUTS = {
  ["plasma.iron"] = true,
  ["plasma.copper"] = true,
}

local function buildQuarkRequests(snapshot)
  for _, fluid in ipairs(snapshot.fluids) do
    if FOG_OMITTED_QUARK_INPUTS[string.lower(tostring(fluid.name or ""))] then
      return nil, "检测到旧版本遗留的铁/铜等离子体；请先手动返回主网后再继续"
    end
  end
  if #snapshot.items + #snapshot.fluids ~= 7 then
    return nil, "等待 7 份提示，目前物品 " .. #snapshot.items .. "、流体 " .. #snapshot.fluids
  end

  local requests, byFluid = {}, {}
  requests.ignored = {}
  for _, item in ipairs(snapshot.items) do
    if (item.size or 0) < 1 or item.size > 7 then
      return nil, "粉尘提示数量超出 1..7: " .. tostring(item.label or item.name)
    end
    local target, reason = plasmaFromItem(item)
    if not target then return nil, reason end
    local amount = item.size * 1296
    if FOG_OMITTED_QUARK_INPUTS[string.lower(target)] then
      table.insert(requests.ignored, {
        fluidName = target,
        displayName = translatedFluid(target),
        amount = amount,
        source = tostring(item.label or item.name),
      })
    else
      addRequest(requests, byFluid, target, amount, tostring(item.label or item.name))
    end
  end
  for _, fluid in ipairs(snapshot.fluids) do
    if (fluid.amount or 0) < 1 or fluid.amount > 64 then
      return nil, "流体提示数量超出 1..64: " .. tostring(fluid.label or fluid.name)
    end
    local suffix = fluidSuffix(fluid.name)
    if not suffix or suffix == "" then return nil, "无法识别流体 " .. tostring(fluid.name) end
    local target = "plasma." .. string.lower(suffix)
    if FOG_OMITTED_QUARK_INPUTS[target] then
      table.insert(requests.ignored, {
        fluidName = target,
        displayName = translatedFluid(target),
        amount = fluid.amount * 1000,
        source = tostring(fluid.label or fluid.name),
      })
    else
      addRequest(requests, byFluid, target, fluid.amount * 1000, tostring(fluid.label or fluid.name))
    end
  end
  return requests
end

local function buildMagmatterRequests(snapshot)
  if #snapshot.items ~= 1 or #snapshot.fluids ~= 2 then
    return nil, "等待 1 份粉尘和 2 份流体提示，目前物品 " .. #snapshot.items .. "、流体 " .. #snapshot.fluids
  end

  local temporal, spatial
  for _, fluid in ipairs(snapshot.fluids) do
    local suffix = string.lower(fluidSuffix(fluid.name) or "")
    if suffix == "temporalfluid" then temporal = fluid end
    if suffix == "spatialfluid" then spatial = fluid end
  end

  -- Registry name is authoritative. The amount ranges are a compatibility fallback.
  if not temporal or not spatial then
    for _, fluid in ipairs(snapshot.fluids) do
      if fluid.amount >= 1 and fluid.amount <= 50 then temporal = temporal or fluid end
      if fluid.amount >= 51 and fluid.amount <= 100 then spatial = spatial or fluid end
    end
  end
  if not temporal or not spatial or temporal == spatial then
    return nil, "无法区分富快子时间流体(1..50)和扩大化空间流体(51..100)"
  end

  local plasma, reason = plasmaFromItem(snapshot.items[1])
  if not plasma then return nil, reason end
  local difference = spatial.amount - temporal.amount
  if difference < 1 then return nil, "空间流体数量必须大于时间流体数量" end

  local requests, byFluid = {}, {}
  addRequest(requests, byFluid, fluidSuffix(temporal.name), temporal.amount, "时间流体提示")
  addRequest(requests, byFluid, fluidSuffix(spatial.name), spatial.amount, "空间流体提示")
  addRequest(requests, byFluid, plasma, difference * 144, tostring(snapshot.items[1].label or snapshot.items[1].name))
  return requests
end

local function prepareDatabase(requests)
  if #requests > 7 then error("内部错误：数据库请求超过 7 项", 0) end
  for index, request in ipairs(requests) do
    local nbt = string.format('{Fluid:"%s"}', request.fluidName)
    local ok, reason = devices.database.set(index, "ae2fc:fluid_drop", 0, nbt)
    if not ok then error("无法写入数据库槽 " .. index .. ": " .. tostring(reason), 0) end
    local drop = devices.database.get(index)
    if not drop then error("数据库槽 " .. index .. " 未生成液滴", 0) end
    request.databaseSlot = index
    request.drop = drop
    request.dropDisplayName = dropDisplayName(request.fluidName)
  end
end

local function clearInterface(slotCount)
  slotCount = slotCount or configuredSlotCount
  for slot = 0, slotCount - 1 do
    checkedCall("清空二合一接口配置失败", devices.interface.setFluidInterfaceConfiguration, slot)
  end
  configuredSlotCount = 0
  interfaceKnownClear = false
end

local function interfaceFluid(slot)
  local fluid = devices.transposer.getFluidInTank(mainSide, (slot or 0) + 1)
  if fluid and (fluid.amount or 0) > 0 then return fluid end
  return nil
end

local function interfaceIsClear(slotCount)
  for slot = 0, (slotCount or interfaceSlotCount) - 1 do
    if interfaceFluid(slot) then return false end
  end
  return true
end

local function waitInterfaceClear(slotCount, forceClear)
  slotCount = slotCount or interfaceSlotCount
  if not forceClear and configuredSlotCount == 0 and interfaceKnownClear then return end

  local warned = false
  while true do
    if forceClear or configuredSlotCount > 0 or not interfaceIsClear(slotCount) then
      clearInterface(forceClear and slotCount or math.max(configuredSlotCount, slotCount))
      forceClear = false
    end
    local started = computer.uptime()
    repeat
      if interfaceIsClear(slotCount) then
        interfaceKnownClear = true
        return
      end
      os.sleep(timing.poll)
    until computer.uptime() - started >= timing.interfaceClearTimeout

    if not warned then
      log("接口残余流体未退回主网；等待网络恢复")
      warned = true
    end
    setState("暂停：接口未清空", "不会把残余流体送进缓存；请检查主网容量与频道")
    os.sleep(timing.missingPatternRetry)
    forceClear = true
  end
end

local function waitForCycleAdvance()
  local started = computer.uptime()
  local warned = false

  while true do
    local snapshot = scanCache()

    if config.mode == "quark" then
      local requests = buildQuarkRequests(snapshot)
      if requests then
        log("已观察到下一轮完整提示，确认上一轮已被机器取用")
        return snapshot, requests
      end
    else
      -- MagMatter supply contains the same Time/Space fluids as its hints, so
      -- never guess which amount is stale. Only a clean, valid next prompt is
      -- accepted as the machine-advance signal.
      local requests = buildMagmatterRequests(snapshot)
      if requests then
        log("已观察到下一轮完整提示，确认上一轮已被机器取用")
        return snapshot, requests
      end
    end

    local elapsed = computer.uptime() - started
    local detail = string.format("已送入全部目标流体；等待下一轮完整提示（%.1f 秒）", elapsed)
    if elapsed >= timing.advanceWarningAfter then
      detail = detail .. "；请检查库存二合一输入仓网络与缓存内容"
      if not warned then
        log("目标流体已送入缓存，但机器尚未生成下一轮提示；继续等待，不会提前开始下一轮")
        warned = true
      end
    end
    setState("等待机器取料", detail)
    os.sleep(timing.poll)
  end
end

local function returnPromptsToMain(initialSnapshot)
  waitInterfaceClear()
  local lastProgress = computer.uptime()
  local warned = false
  local snapshot = initialSnapshot or scanCache()

  while #snapshot.items > 0 or #snapshot.fluids > 0 do
    local before = snapshotSignature(snapshot)

    -- A dedicated batch-return phase: all fluids and all items go to the same main-network interface.
    for _, fluid in ipairs(snapshot.fluids) do
      checkedCall("提示流体返网失败", devices.transposer.transferFluid,
        cacheSide, mainSide, fluid.amount, fluid.tank - 1)
    end
    for _, item in ipairs(snapshot.items) do
      checkedCall("提示物品返网失败", devices.transposer.transferItem,
        cacheSide, mainSide, item.size, item.slot)
    end

    os.sleep(timing.returnVerifyDelay)
    snapshot = scanCache()
    local after = snapshotSignature(snapshot)
    if after ~= before then
      lastProgress = computer.uptime()
      warned = false
    elseif computer.uptime() - lastProgress >= timing.returnStallTimeout then
      if not warned then log("提示物返主网停滞；不会改送其他容器") end
      warned = true
      setState("暂停：返主网受阻", "请检查二合一 ME 接口方向、频道和主网容量")
      os.sleep(timing.missingPatternRetry)
      lastProgress = computer.uptime()
    end
  end
  log("本批提示物品与流体已全部返回主网")
end

local function machineAllowsWork()
  if not devices.machine then return true end
  local ok, allowed = pcall(devices.machine.isWorkAllowed)
  return ok and allowed
end

local function craftablesFor(request)
  local filter = {name = request.drop.name, label = request.drop.label}
  return devices.interface.getCraftables(filter) or {}
end

local function jobState(job)
  local okFailed, failed, reason = pcall(job.hasFailed)
  if okFailed and failed then return "failed", reason end
  local okCanceled, canceled = pcall(job.isCanceled)
  if okCanceled and canceled then return "canceled" end
  local okDone, done = pcall(job.isDone)
  if okDone and done then return "done" end
  return "running"
end

local function requestCraftOnce(request)
  local craftables = checkedCall("查询 AE 样板失败", craftablesFor, request)
  if #craftables == 0 then return nil, "missing" end

  local craftable = craftables[1]
  local ok, job, requestReason
  if config.aeCpuName and config.aeCpuName ~= "" then
    ok, job, requestReason = pcall(craftable.request, 1, true, config.aeCpuName)
  else
    ok, job, requestReason = pcall(craftable.request, 1, true)
  end
  if ok and job then
    log("已请求：" .. request.dropDisplayName)
    return job
  end
  return nil, "failed", requestReason or job or "AE 未返回 crafting handle"
end

local function updateBatchUI(requests, batchNumber, batchCount)
  local missing, crafting = nil, 0
  ui.done, ui.total, ui.current = 0, 0, 0
  for index, request in ipairs(ui.requests) do
    ui.done = ui.done + math.min(request.amount, request.delivered or 0)
    ui.total = ui.total + request.amount
    if ui.current == 0 and (request.delivered or 0) < request.amount then ui.current = index end
    if request.status == "缺失样板" then missing = missing or request end
    if request.status == "并行合成" then crafting = crafting + 1 end
  end

  if missing then
    setState("缺失样板", "主网中找不到：" .. missing.dropDisplayName)
  elseif crafting > 0 then
    setState("并行备料", string.format("第 %d/%d 批；%d 项正在 AE 合成", batchNumber, batchCount, crafting))
  else
    setState("批量快速注入", string.format("第 %d/%d 批；最多 %d 种流体同时供给", batchNumber, batchCount, #requests))
  end
end

local function supplyBatch(requests, batchNumber, batchCount)
  local configured = #requests
  local firstCraftAt = computer.uptime() + timing.interfaceSupplyGrace

  for slot, request in ipairs(requests) do
    request.delivered = request.delivered or 0
    request.interfaceSlot = slot - 1
    request.status = "接口备料"
    request.activeJob = nil
    request.requestedAt = nil
    request.nextCraftAt = firstCraftAt
    request.craftWarned = false
    request.missingLogged = false
    checkedCall("设置二合一接口失败", devices.interface.setFluidInterfaceConfiguration,
      request.interfaceSlot, devices.database.address, request.databaseSlot)
  end
  configuredSlotCount = configured
  interfaceKnownClear = false
  os.sleep(timing.interfaceWarmup)

  while true do
    local allDone, movedThisPass = true, false
    local now = computer.uptime()

    for _, request in ipairs(requests) do
      local remaining = request.amount - (request.delivered or 0)
      if remaining > 0 then
        allDone = false
        local fluid = interfaceFluid(request.interfaceSlot)
        if fluid then
          if fluid.name ~= request.fluidName then
            error("二合一接口槽 " .. request.interfaceSlot .. " 出现错误流体：期望 "
              .. request.fluidName .. "，实际 " .. tostring(fluid.name), 0)
          end

          local moveAmount = math.min(remaining, fluid.amount)
          local ok, movedOK, moved = pcall(devices.transposer.transferFluid,
            mainSide, cacheSide, moveAmount, request.interfaceSlot)
          if not ok then error("补给流体失败：" .. tostring(movedOK), 0) end
          moved = tonumber(moved) or 0
          if movedOK and moved > 0 then
            request.delivered = request.delivered + moved
            request.status = request.delivered >= request.amount and "已送入" or "快速注入"
            request.missingLogged = false
            movedThisPass = true
            if request.activeJob then
              local state = jobState(request.activeJob)
              if state ~= "running" then request.activeJob = nil end
            end
          else
            request.status = "输入受阻"
          end
        elseif request.activeJob then
          local state, reason = jobState(request.activeJob)
          if state == "failed" or state == "canceled" then
            log("合成失败，将重新查询 " .. request.dropDisplayName .. "：" .. tostring(reason or state))
            request.activeJob = nil
            request.nextCraftAt = now + timing.missingPatternRetry
            request.status = "等待重试"
          elseif state == "done" then
            request.activeJob = nil
            request.nextCraftAt = now + timing.interfaceSupplyGrace
            request.status = "等待接口"
          else
            request.status = "并行合成"
            if not request.craftWarned and now - request.requestedAt >= timing.craftWarningAfter then
              request.craftWarned = true
              log(request.dropDisplayName .. " 合成超过警戒时间；继续等待且不取消 CPU")
            end
          end
        elseif now >= request.nextCraftAt then
          local job, state, reason = requestCraftOnce(request)
          if job then
            request.activeJob = job
            request.requestedAt = now
            request.craftWarned = false
            request.status = "并行合成"
          elseif state == "missing" then
            request.status = "缺失样板"
            if not request.missingLogged then
              log("缺失样板：" .. request.dropDisplayName)
              request.missingLogged = true
            end
            request.nextCraftAt = now + timing.missingPatternRetry
          else
            request.status = "下单失败"
            log("下单失败：" .. request.dropDisplayName .. "；" .. tostring(reason))
            request.nextCraftAt = now + timing.missingPatternRetry
          end
        else
          request.status = "等待主网"
        end
      else
        request.status = "已送入"
      end
    end

    updateBatchUI(requests, batchNumber, batchCount)
    if allDone then break end
    os.sleep(movedThisPass and timing.transferYield or timing.craftPoll)
  end

  waitInterfaceClear(configured)
  log(string.format("第 %d/%d 批快速注入完成（%d 种流体）", batchNumber, batchCount, configured))
end

local function pendingRequests(requests)
  local pending = {}
  for _, request in ipairs(requests) do
    if (request.delivered or 0) < request.amount then
      table.insert(pending, request)
    end
  end
  return pending
end

local function supplyAllRequests(requests)
  local pending = pendingRequests(requests)
  if #pending == 0 then return end
  local batchCount = math.ceil(#pending / interfaceSlotCount)
  waitInterfaceClear(interfaceSlotCount)

  for first = 1, #pending, interfaceSlotCount do
    local batch = {}
    for index = first, math.min(#pending, first + interfaceSlotCount - 1) do
      table.insert(batch, pending[index])
    end
    local batchNumber = math.floor((first - 1) / interfaceSlotCount) + 1
    supplyBatch(batch, batchNumber, batchCount)
  end
end

local function processCycle(cycle)
  ui.requests = cycle.requests
  ui.current = 0
  ui.done = 0
  ui.total = 0
  for _, request in ipairs(cycle.requests) do request.status = request.status or "等待" end
  if not cycle.ignoredLogged then
    for _, ignored in ipairs(cycle.requests.ignored or {}) do
      log(string.format("已忽略神锻假输入：%d mB %s（铁/铜提示不会形成实际输入）",
        ignored.amount, ignored.displayName))
    end
    cycle.ignoredLogged = true
  end
  if not cycle.promptsReturned then
    setState("整批返主网", "提示物品和提示流体将统一进入主 AE 网络")
    local initialSnapshot = cycle.promptSnapshot
    cycle.promptSnapshot = nil
    returnPromptsToMain(initialSnapshot)
    cycle.promptsReturned = true
  end
  if not cycle.databasePrepared then
    prepareDatabase(cycle.requests)
    cycle.databasePrepared = true
  end

  supplyAllRequests(cycle.requests)
  ui.current = #cycle.requests + 1
  ui.done = ui.total
  for _, request in ipairs(cycle.requests) do request.status = "等待取料" end
  local nextSnapshot, nextRequests = waitForCycleAdvance()
  for _, request in ipairs(cycle.requests) do request.status = "已取用" end
  setState("本批完成", "已观察到下一轮完整提示；上一轮已确认取用")
  log("周期 " .. ui.cycle .. " 完成")
  os.sleep(timing.cycleSettle)
  return nextSnapshot, nextRequests
end

local function main()
  setupComponents()
  waitInterfaceClear(interfaceSlotCount, true)
  setState("自检完成", "正在等待机器生成提示")

  local stableSignature, stableCount = nil, 0
  local carriedSnapshot, carriedRequests = nil, nil
  while true do
    if not machineAllowsWork() then
      stableSignature, stableCount = nil, 0
      setState("暂停：机器已禁用", "启用机器后自动继续")
      os.sleep(timing.poll)
    else
      local snapshot, requests, reason
      local usingCarry = carriedSnapshot ~= nil
      if usingCarry then
        snapshot, requests = carriedSnapshot, carriedRequests
        carriedSnapshot, carriedRequests = nil, nil
      else
        snapshot = scanCache()
        if config.mode == "quark" then
          requests, reason = buildQuarkRequests(snapshot)
        else
          requests, reason = buildMagmatterRequests(snapshot)
        end
      end

      if not requests then
        stableSignature, stableCount = nil, 0
        setState("等待提示", reason)
        os.sleep(timing.poll)
      else
        if usingCarry then
          -- waitForCycleAdvance already proved this is a complete next prompt.
          -- Reusing both the snapshot and parsed requests avoids two full sets
          -- of synchronized transposer/database calls between cycles.
          stableCount = timing.stableScans
        else
          local signature = snapshotSignature(snapshot)
          if signature == stableSignature then
            stableCount = stableCount + 1
          else
            stableSignature, stableCount = signature, 1
          end
        end

        if stableCount < timing.stableScans then
          setState("确认提示", "检测到完整提示，等待内容稳定 " .. stableCount .. "/" .. timing.stableScans)
          os.sleep(timing.poll)
        else
          ui.cycle = ui.cycle + 1
          local cycle = {requests = requests, promptsReturned = false, promptSnapshot = snapshot}
          local cycleFinished = false
          while not cycleFinished do
            local ok, nextSnapshot, nextRequests = pcall(processCycle, cycle)
            if ok then
              cycleFinished = true
              carriedSnapshot, carriedRequests = nextSnapshot, nextRequests
            else
              local cycleError = nextSnapshot
              log("周期故障：" .. tostring(cycleError))
              setState("故障暂停", "保留本批进度，修复后自动重试：" .. tostring(cycleError))
              pcall(clearInterface, interfaceSlotCount)
              os.sleep(timing.missingPatternRetry)
            end
          end
          stableSignature, stableCount = nil, 0
        end
      end
    end
  end
end

local function errorTrace(message)
  if debug and debug.traceback then return debug.traceback(message, 2) end
  return tostring(message)
end

local ok, fatal = xpcall(main, errorTrace)
if devices.interface then pcall(clearInterface, interfaceSlotCount) end
if gpu then
  gpu.setBackground(0x000000)
  gpu.setForeground(0xFFFFFF)
  gpu.fill(1, 1, screenWidth, screenHeight, " ")
  gpu.set(1, 1, ok and "脚本已停止" or ("脚本终止：" .. clip(fatal, screenWidth - 10)))
end
if not ok then error(fatal, 0) end
