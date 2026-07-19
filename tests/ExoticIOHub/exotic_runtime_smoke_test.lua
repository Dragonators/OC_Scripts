package.path = "src/ExoticIOHub/?.lua;../?.lua;./?.lua;" .. package.path

local scenario, now, virtualFiles = nil, 0, {}

io.open = function(path, mode)
  if mode == "w" then
    local buffer = {}
    return {
      write = function(_, value) buffer[#buffer + 1] = tostring(value); return true end,
      close = function() virtualFiles[path] = table.concat(buffer); return true end
    }
  elseif mode == "r" and virtualFiles[path] then
    return { read = function() return virtualFiles[path] end, close = function() return true end }
  end
  return nil, "file not found"
end

local function utf8Width(text)
  local width = 0
  for _, codepoint in utf8.codes(tostring(text)) do width = width + (codepoint > 127 and 2 or 1) end
  return width
end

local function utf8Truncate(text, maximum)
  local result, width = {}, 0
  for _, codepoint in utf8.codes(tostring(text)) do
    local cell = codepoint > 127 and 2 or 1
    if width + cell > maximum then break end
    result[#result + 1] = utf8.char(codepoint)
    width = width + cell
  end
  return table.concat(result)
end

package.preload.unicode = function()
  return { wlen = utf8Width, wtrunc = utf8Truncate, sub = string.sub }
end
package.preload.computer = function()
  return {
    uptime = function() return now end,
    getDeviceInfo = function() return { database = { capacity = tostring(scenario.databaseCapacity or 81) } } end
  }
end
package.preload.serialization = function()
  return { serialize = function() return "journal" end, unserialize = function() return nil, "not used" end }
end
package.preload.filesystem = function()
  return {
    exists = function(path) return virtualFiles[path] ~= nil end,
    path = function(path) return path:match("^(.*[/\\])") or "" end,
    makeDirectory = function() return true end,
    remove = function(path) virtualFiles[path] = nil; return true end,
    rename = function(from, to)
      virtualFiles[to], virtualFiles[from] = virtualFiles[from], nil
      return virtualFiles[to] ~= nil
    end
  }
end
package.preload.event = function()
  return {
    pull = function()
      now = now + 0.5
      scenario.events = scenario.events + 1
      if scenario.refillFluids and not scenario.didRefill and scenario.sentHintFluids > 0 then
        local occupied = false
        for _, fluid in pairs(scenario.ioFluids) do if fluid then occupied = true; break end end
        if not occupied then
          scenario.ioFluids = scenario.refillFluids
          scenario.ioItems = scenario.refillItems or scenario.ioItems
          scenario.didRefill = true
        end
      end
      if scenario.startPending and not scenario.keepHatchLoaded then
        scenario.startPending = false
        scenario.hatchTanks = {}
        scenario.machineTicks = scenario.machineDuration or 4
      elseif scenario.machineTicks > 0 then
        scenario.machineTicks = scenario.machineTicks - 1
      end
      if scenario.events >= (scenario.quitAfter or 35) then
        return "key_down", "keyboard", string.byte("q"), 16
      end
      return nil
    end
  }
end

local database = { slots = {} }
function database.set(slot, id, damage, nbt)
  database.slots[slot] = { name = id, damage = damage, nbt = nbt }
  return true
end
function database.get(slot)
  local stack = database.slots[slot]
  if not stack then return nil end
  if stack.name == "ae2fc:fluid_drop" then
    local fluid = stack.nbt:match('Fluid:"([^"]+)"')
    return { name = stack.name, label = "Drop of " .. fluid, fluidDrop = { name = fluid } }
  end
  return stack
end

local iohub = { selectedItem = 1, selectedTank = 1 }
function iohub.getStackInInternalSlot(slot) return scenario.ioItems[slot] end
function iohub.getFluidInInternalTank(tank)
  if scenario.componentDropped then error("iohub disconnected") end
  return scenario.ioFluids[tank]
end
function iohub.select(slot) iohub.selectedItem = slot; return slot end
function iohub.count(slot) return scenario.ioItems[slot] and scenario.ioItems[slot].size or 0, "items" end
function iohub.sendItems(count)
  local item = scenario.ioItems[iohub.selectedItem]
  if not item or item.size ~= count then return 0 end
  scenario.ioItems[iohub.selectedItem] = nil
  scenario.sentItems = scenario.sentItems + count
  scenario.sendTimes[#scenario.sendTimes + 1] = now
  return count, "items"
end
function iohub.selectTank(tank) iohub.selectedTank = tank; return tank end
function iohub.tankLevel(tank) return scenario.ioFluids[tank] and scenario.ioFluids[tank].amount or 0, "L" end
function iohub.sendFluids(amount)
  local fluid = scenario.ioFluids[iohub.selectedTank]
  if not fluid or fluid.amount < amount or scenario.refundFailure then return 0 end
  fluid.amount = fluid.amount - amount
  if fluid.amount == 0 then scenario.ioFluids[iohub.selectedTank] = nil end
  scenario.sentFluids = scenario.sentFluids + amount
  if not scenario.loading then scenario.sentHintFluids = scenario.sentHintFluids + amount end
  scenario.stock[fluid.name] = (scenario.stock[fluid.name] or 0) + amount
  scenario.sendTimes[#scenario.sendTimes + 1] = now
  return amount, "L"
end
function iohub.getFluidsInNetwork()
  if scenario.aeDisconnected then error("AE network disconnected") end
  local result = {}
  for name, amount in pairs(scenario.stock) do result[#result + 1] = { name = name, amount = amount, label = name } end
  return result
end
function iohub.getCraftables()
  if not scenario.craftBehavior then return {} end
  local status = {
    hasFailed = function() return scenario.craftBehavior == "failed", "simulated failure" end,
    isCanceled = function() return scenario.craftBehavior == "canceled", "simulated cancellation" end,
    isDone = function() return scenario.craftBehavior == "done_insufficient" end
  }
  return { { request = function() scenario.craftRequests = scenario.craftRequests + 1; return status end } }
end
function iohub.getCpus()
  local cpu = { cancel = function() scenario.cpuCancels = scenario.cpuCancels + 1; return true end }
  local busy = scenario.cpuBusy == true or (scenario.craftBehavior == "timeout" and scenario.craftRequests > 0)
  return { { name = "Test CPU", busy = busy, cpu = cpu } }
end
function iohub.getTankCount() return scenario.hatchCount or 9 end
function iohub.getTankLevel(_, tank)
  local fluid = scenario.hatchTanks[tank]
  return fluid and fluid.amount or 0
end
function iohub.getTankCapacity() return scenario.hatchCapacity or 2147483647 end
function iohub.getFluidInTank(_, tank) return scenario.hatchTanks[tank] end

local function databaseFluid(slot)
  local stack = database.slots[slot]
  return stack and stack.nbt and stack.nbt:match('FluidName:"([^"]+)"')
end

function iohub.requestFluids(_, slot, amount)
  if scenario.requestFailure then return 0 end
  local name = databaseFluid(slot)
  local available = scenario.stock[name] or 0
  local extracted = math.min(amount, available, scenario.ioTankCapacity or 1000000)
  if extracted <= 0 or scenario.ioFluids[iohub.selectedTank] then return 0 end
  scenario.stock[name] = available - extracted
  scenario.ioFluids[iohub.selectedTank] = { name = name, label = name, amount = extracted }
  scenario.loading = true
  return extracted
end

local function findHatchTank(name)
  local empty
  for tank = 1, 9 do
    local fluid = scenario.hatchTanks[tank]
    if fluid and fluid.name == name then return tank end
    if not fluid and not empty then empty = tank end
  end
  return empty
end

function iohub.fillRobot(_, amount)
  local fluid = scenario.ioFluids[iohub.selectedTank]
  if not fluid or scenario.fillFailure then return nil, "simulated fill failure" end
  local moved = scenario.partialFill and math.max(1, amount - 1) or amount
  local tank = findHatchTank(fluid.name)
  if not tank then return nil, "no space" end
  local target = scenario.hatchTanks[tank]
  if not target then target = { name = fluid.name, label = fluid.label, amount = 0 }; scenario.hatchTanks[tank] = target end
  target.amount = target.amount + moved
  fluid.amount = fluid.amount - moved
  if fluid.amount == 0 then scenario.ioFluids[iohub.selectedTank] = nil end
  scenario.injected[fluid.name] = (scenario.injected[fluid.name] or 0) + moved
  local kinds = 0
  for _ in pairs(scenario.injected) do kinds = kinds + 1 end
  if kinds == (scenario.expectedKinds or 7) then scenario.startPending = true end
  return true, moved
end

function iohub.drainRobot(_, amount)
  if scenario.drainFailure then return nil, "simulated drain failure" end
  for tank = 1, 9 do
    local fluid = scenario.hatchTanks[tank]
    if fluid then
      local moved = math.min(amount, fluid.amount, scenario.ioTankCapacity or 1000000)
      scenario.ioFluids[iohub.selectedTank] = { name = fluid.name, label = fluid.label, amount = moved }
      fluid.amount = fluid.amount - moved
      if fluid.amount == 0 then scenario.hatchTanks[tank] = nil end
      return true, moved
    end
  end
  return nil, "empty"
end

local machine = {}
function machine.getWorkProgress() return scenario.machineTicks > 0 and 100 or 0, "ticks" end
function machine.getWorkMaxProgress() return scenario.machineTicks > 0 and 200 or 0, "ticks" end
function machine.isMachineActive() return scenario.machineTicks > 0 end

local gpu = { width = 80, height = 25 }
function gpu.getForeground() return 0xFFFFFF end
function gpu.getBackground() return 0 end
function gpu.getResolution() return gpu.width, gpu.height end
function gpu.maxResolution() return 160, 50 end
function gpu.bind() return true end
function gpu.setResolution(width, height)
  gpu.width, gpu.height = width, height
  scenario.resolutions[#scenario.resolutions + 1] = { width, height }
  return true
end
function gpu.setBackground() return true end
function gpu.setForeground() return true end
function gpu.fill() return true end
function gpu.set(_, y, value)
  scenario.screenText = scenario.screenText .. " | " .. tostring(y) .. ":" .. tostring(value)
  return true
end

local function wrapOcProxy(proxy)
  for name, value in pairs(proxy) do
    if type(value) == "function" then
      proxy[name] = setmetatable({ invoke = value }, { __call = function(self, ...) return self.invoke(...) end })
    end
  end
  return proxy
end

local proxies = {
  iohub = wrapOcProxy(iohub), database = wrapOcProxy(database), machine = wrapOcProxy(machine), gpu = wrapOcProxy(gpu)
}
local directMethods = { iohub = { count = true, tankLevel = true } }
package.preload.component = function()
  return {
    get = function(prefix) return prefix end,
    proxy = function(address) return proxies[address] end,
    list = function() return function() return nil end end,
    methods = function(address)
      local result = {}
      for name, value in pairs(proxies[address] or {}) do
        local meta = type(value) == "table" and getmetatable(value) or nil
        if meta and meta.__call then result[name] = directMethods[address] and directMethods[address][name] == true or false end
      end
      return result
    end
  }
end

local componentMock = require("component")
assert(componentMock.methods("iohub").getStackInInternalSlot == false,
  "non-direct OC callbacks must be represented by false, not treated as missing")
assert(componentMock.methods("database").size == nil, "database size is not an OC callback")

local common = require("exotic_iohub_common")
local function reset(base)
  now, virtualFiles, database.slots = 0, {}, {}
  scenario = base
  scenario.ioItems = scenario.items or {}
  scenario.ioFluids = scenario.fluids or {}
  scenario.hatchTanks = scenario.hatchTanks or {}
  scenario.stock = scenario.stock or {}
  scenario.events, scenario.machineTicks = 0, 0
  scenario.sentItems, scenario.sentFluids, scenario.sentHintFluids = 0, 0, 0
  scenario.craftRequests, scenario.cpuCancels = 0, 0
  scenario.screenText, scenario.resolutions, scenario.sendTimes = "", {}, {}
  scenario.injected, scenario.didRefill, scenario.loading = {}, false, false
end

local function usedResolution(width, height)
  for _, value in ipairs(scenario.resolutions) do if value[1] == width and value[2] == height then return true end end
  return false
end
local function screenHas(text) return scenario.screenText:find(text, 1, true) ~= nil end

local quarkFluids, quarkStock = {}, {}
for index = 1, 7 do
  quarkFluids[index] = { name = "material" .. index, label = "Material " .. index, amount = index }
  quarkStock["plasma.material" .. index] = index * 1000
end
reset({ fluids = quarkFluids, stock = quarkStock })
assert(common.run({ mode = "quark", title = "Quark smoke" },
  "tests/ExoticIOHub/exotic_quark_smoke.cfg"))
for index = 1, 7 do assert(scenario.injected["plasma.material" .. index] == index * 1000) end
assert(scenario.sentHintFluids == 28, "all quark hints must return to AE")
assert(usedResolution(80, 25), "quark GUI must render at 80x25")

local refillFluids, refillStock, initialFluids = {}, {}, {}
for index = 1, 7 do
  initialFluids[index] = { name = "material" .. index, amount = index }
  refillFluids[index] = { name = "material" .. index, amount = 1 }
  refillStock["plasma.material" .. index] = (index + 1) * 1000
end
reset({ fluids = initialFluids, refillFluids = refillFluids, stock = refillStock, quitAfter = 45 })
assert(common.run({ mode = "quark", title = "Quark refill" },
  "tests/ExoticIOHub/exotic_quark_smoke.cfg"))
assert(scenario.didRefill and scenario.sentHintFluids == 35, "late samples must be accumulated")
for index = 1, 7 do assert(scenario.injected["plasma.material" .. index] == (index + 1) * 1000) end
for index = 2, 7 do assert(scenario.sendTimes[index] == scenario.sendTimes[1], "batch hint return must be immediate") end

reset({
  items = { [1] = { name = "miscutils:itemDustHypogen", label = "Hypogen Dust", damage = 0, size = 1 } },
  fluids = {
    [1] = { name = "fluid.temporalfluid", amount = 10 },
    [2] = { name = "fluid.spatialfluid", amount = 60 }
  },
  stock = { ["plasma.hypogen"] = 7200, ["fluid.temporalfluid"] = 10, ["fluid.spatialfluid"] = 60 },
  expectedKinds = 3
})
assert(common.run({ mode = "magmatter", title = "MagMatter smoke" },
  "tests/ExoticIOHub/exotic_magmatter_smoke.cfg"))
assert(scenario.injected["plasma.hypogen"] == 7200 and scenario.injected["fluid.temporalfluid"] == 10 and
  scenario.injected["fluid.spatialfluid"] == 60, "MagMatter must inject three fluids")
assert(scenario.sentItems == 1 and scenario.sentHintFluids == 70, "MagMatter hints must return to AE")
assert(usedResolution(120, 35), "MagMatter GUI must render at 120x35")

local faultConfig = "tests/ExoticIOHub/exotic_fault_smoke.cfg"
local materials = { "radon", "mercury", "argon", "xenon", "neon", "hydrogen", "helium" }
local function faultQuark(options)
  local fluids, stock = {}, {}
  for index, material in ipairs(materials) do
    fluids[index] = { name = material, amount = index }
    if options.stocked then stock["plasma." .. material] = index * 1000 end
  end
  local base = { fluids = fluids, stock = stock, quitAfter = options.quitAfter or 30 }
  for key, value in pairs(options) do base[key] = value end
  reset(base)
  assert(common.run({ mode = "quark", title = "Fault smoke" }, faultConfig))
end

reset({ hatchTanks = { [1] = { name = "water", amount = 1000 } }, quitAfter = 3 })
assert(common.run({ mode = "quark", title = "Dirty start" }, faultConfig))
assert(screenHas("启动时九重输入仓存在无归属残留"), "dirty ninefold hatch must latch")
assert(scenario.hatchTanks[1], "dirty startup must not auto-refund")

faultQuark({ stocked = true, partialFill = true, quitAfter = 25 })
assert(screenHas("装载失败") and screenHas("回送 AE"), "partial IO Hub injection must refund and latch")
local hatchLeft = false
for _, fluid in pairs(scenario.hatchTanks) do if fluid then hatchLeft = true end end
assert(not hatchLeft, "partial load must be recovered from the ninefold hatch")

faultQuark({ stocked = true, requestFailure = true, quitAfter = 25 })
assert(screenHas("从 AE 提取失败") and screenHas("已把本轮流体回送 AE"),
  "request failure must leave no staged input; screen=" .. scenario.screenText)

faultQuark({ stocked = true, keepHatchLoaded = true, quitAfter = 30 })
assert(screenHas("机器启动超时") and screenHas("九重仓原料已回送 AE"),
  "start timeout must return the ninefold contents")

faultQuark({ stocked = true, keepHatchLoaded = true, drainFailure = true, quitAfter = 30 })
assert(screenHas("九重仓回送失败") or screenHas("回送失败"), "failed recovery must preserve a locked fault")

faultQuark({ aeDisconnected = true, quitAfter = 15 })
assert(screenHas("getFluidsInNetwork") and screenHas("故障锁定"), "AE disconnection must latch")

faultQuark({ quitAfter = 18 })
assert(screenHas("氡等离子体液滴") and screenHas("缺少样板"), "missing patterns must use Chinese labels")

faultQuark({ craftBehavior = "timeout", quitAfter = 24 })
assert(screenHas("合成超时") and scenario.cpuCancels == 1, "craft timeout must cancel the named CPU")

faultQuark({ stocked = true, machineDuration = 20, quitAfter = 30 })
assert(screenHas("机器运行超过 recipeTimeout"), "recipe timeout must preserve the running state")

print("exotic_runtime_smoke_test: IO Hub to ninefold input hatch cycles and fault recovery passed")
