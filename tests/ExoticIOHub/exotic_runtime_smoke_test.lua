package.path = "src/ExoticIOHub/?.lua;../?.lua;./?.lua;" .. package.path

local scenario
local now = 0
local virtualFiles = {}

io.open = function(path, mode)
  if mode == "w" then
    local buffer = {}
    return {
      write = function(_, value) buffer[#buffer + 1] = tostring(value); return true end,
      close = function() virtualFiles[path] = table.concat(buffer); return true end
    }
  elseif mode == "r" and virtualFiles[path] then
    return {
      read = function() return virtualFiles[path] end,
      close = function() return true end
    }
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
    getDeviceInfo = function()
      return { database = { capacity = tostring(scenario.databaseCapacity or 81) } }
    end
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
      if scenario.dualHasFluid and not scenario.keepDualDirty then
        scenario.dualHasFluid = false
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
function iohub.getStackInInternalSlot(slot) return scenario.items[slot] end
function iohub.getFluidInInternalTank(tank)
  if scenario.componentDropped then error("iohub disconnected") end
  return scenario.fluids[tank]
end
function iohub.select(slot) iohub.selectedItem = slot; return slot end
function iohub.count(slot) return scenario.items[slot] and scenario.items[slot].size or 0 end
function iohub.sendItems(count)
  local item = scenario.items[iohub.selectedItem]
  if not item or item.size ~= count then return 0 end
  scenario.items[iohub.selectedItem] = nil
  scenario.sentItems = scenario.sentItems + count
  return count
end
function iohub.selectTank(tank) iohub.selectedTank = tank; return tank end
function iohub.tankLevel(tank) return scenario.fluids[tank] and scenario.fluids[tank].amount or 0 end
function iohub.sendFluids(amount)
  local fluid = scenario.fluids[iohub.selectedTank]
  if not fluid or fluid.amount ~= amount then return 0 end
  scenario.fluids[iohub.selectedTank] = nil
  scenario.sentFluids = scenario.sentFluids + amount
  return amount
end
function iohub.getFluidsInNetwork()
  if scenario.aeDisconnected then error("AE network disconnected") end
  local result = {}
  for name, amount in pairs(scenario.stock) do
    result[#result + 1] = { name = name, amount = amount, label = name }
  end
  return result
end
function iohub.getCraftables()
  if not scenario.craftBehavior then return {} end
  local status = {
    hasFailed = function() return scenario.craftBehavior == "failed", "simulated failure" end,
    isCanceled = function() return scenario.craftBehavior == "canceled", "simulated cancellation" end,
    isDone = function() return scenario.craftBehavior == "done_insufficient" end
  }
  return {
    {
      request = function()
        scenario.craftRequests = scenario.craftRequests + 1
        return status
      end
    }
  }
end
function iohub.getCpus()
  local cpu = {
    cancel = function()
      scenario.cpuCancels = scenario.cpuCancels + 1
      return true
    end
  }
  local busy = scenario.cpuBusy == true or (scenario.craftBehavior == "timeout" and scenario.craftRequests > 0)
  return { { name = "Test CPU", busy = busy, cpu = cpu } }
end

local dual = { queued = {} }
function dual.isEmpty() return not scenario.dualHasFluid end
function dual.addTask(_, index, amount, isFluid)
  local stack = database.slots[index + 1]
  if not stack or not isFluid then return {} end
  local fluid = stack.nbt:match('FluidName:"([^"]+)"')
  dual.queued[#dual.queued + 1] = { id = #dual.queued + 1, fluid = fluid, amount = amount }
  return { id = #dual.queued, state = "added" }
end
function dual.cancelTask(id)
  for index, task in ipairs(dual.queued) do
    if task.id == id then table.remove(dual.queued, index); return { id = id, state = "cancelled" } end
  end
  return {}
end
function dual.submitTask()
  local states = {}
  scenario.submitted = {}
  for index, task in ipairs(dual.queued) do
    local state = scenario.partialSubmit and index == #dual.queued and "partially executed" or "executed"
    states[index] = { id = task.id, state = state }
    scenario.submitted[index] = task
  end
  if #dual.queued > 0 then scenario.dualHasFluid = true end
  dual.queued = {}
  return states
end
function dual.refund()
  scenario.refundCount = scenario.refundCount + 1
  if scenario.refundWorks == false then return false end
  scenario.dualHasFluid = false
  return true
end

local machine = {}
function machine.getWorkProgress() return scenario.machineTicks > 0 and 100 or 0 end
function machine.getWorkMaxProgress() return scenario.machineTicks > 0 and 200 or 0 end
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
function gpu.set(x, y, value)
  scenario.screen[y] = value
  scenario.screenText = (scenario.screenText or "") .. " | " .. tostring(y) .. ":" .. tostring(value)
  return true
end

local function wrapOcProxy(proxy)
  for name, value in pairs(proxy) do
    if type(value) == "function" then
      proxy[name] = setmetatable({ invoke = value }, {
        __call = function(self, ...) return self.invoke(...) end
      })
    end
  end
  return proxy
end

local proxies = {
  iohub = wrapOcProxy(iohub),
  dual = wrapOcProxy(dual),
  database = wrapOcProxy(database),
  machine = wrapOcProxy(machine),
  gpu = wrapOcProxy(gpu)
}
local directMethods = {
  iohub = { count = true, tankLevel = true }
}
package.preload.component = function()
  return {
    get = function(prefix) return prefix end,
    proxy = function(address) return proxies[address] end,
    list = function() return function() return nil end end,
    methods = function(address)
      local result = {}
      for name, value in pairs(proxies[address] or {}) do
        local meta = type(value) == "table" and getmetatable(value) or nil
        if meta and meta.__call then
          result[name] = directMethods[address] and directMethods[address][name] == true or false
        end
      end
      return result
    end
  }
end

local componentMock = require("component")
local ioMethods = componentMock.methods("iohub")
assert(ioMethods.getStackInInternalSlot == false and ioMethods.getFluidInInternalTank == false,
  "non-direct OC callbacks must be represented by false, not treated as missing")
assert(ioMethods.count == true and type(proxies.iohub.getStackInInternalSlot) == "table",
  "OC component callbacks must be exercised as callable proxy tables")
assert(componentMock.methods("database").size == nil,
  "database size is an internal Java property, not an OC callback")

local common = require("exotic_iohub_common")

local journalPaths = {
  "tests/ExoticIOHub/.exotic_quark_smoke.state",
  "tests/ExoticIOHub/.exotic_quark_smoke.state.tmp",
  "tests/ExoticIOHub/.exotic_magmatter_smoke.state",
  "tests/ExoticIOHub/.exotic_magmatter_smoke.state.tmp"
}

for _, path in ipairs(journalPaths) do os.remove(path) end

local function reset(base)
  now = 0
  virtualFiles = {}
  database.slots = {}
  dual.queued = {}
  scenario = base
  scenario.events = 0
  scenario.machineTicks = 0
  scenario.dualHasFluid = scenario.initialDualDirty == true
  scenario.sentItems = 0
  scenario.sentFluids = 0
  scenario.submitted = {}
  scenario.refundCount = 0
  scenario.craftRequests = 0
  scenario.cpuCancels = 0
  scenario.screen = {}
  scenario.screenText = ""
  scenario.resolutions = {}
end

local function usedResolution(width, height)
  for _, resolution in ipairs(scenario.resolutions) do
    if resolution[1] == width and resolution[2] == height then return true end
  end
  return false
end

local quarkFluids, quarkStock = {}, {}
for index = 1, 7 do
  quarkFluids[index] = { name = "material" .. index, label = "Material " .. index, amount = index }
  quarkStock["plasma.material" .. index] = index * 1000
end
reset({ items = {}, fluids = quarkFluids, stock = quarkStock })
assert(common.run({ mode = "quark", title = "Quark smoke" },
  "tests/ExoticIOHub/exotic_quark_smoke.cfg"))
assert(#scenario.submitted == 7,
  "quark must submit seven fluids; screen=" .. scenario.screenText)
assert(scenario.sentItems == 0 and scenario.sentFluids == 28, "all quark hints must return to AE")
assert(usedResolution(80, 25), "quark GUI must render at 80x25")

reset({
  items = { [1] = { name = "miscutils:itemDustHypogen", label = "Hypogen Dust", damage = 0, size = 1 } },
  fluids = {
    [1] = { name = "fluid.temporalfluid", label = "Temporal", amount = 10 },
    [2] = { name = "fluid.spatialfluid", label = "Spatial", amount = 60 }
  },
  stock = {
    ["plasma.hypogen"] = 50 * 144,
    ["fluid.temporalfluid"] = 10,
    ["fluid.spatialfluid"] = 60
  }
})
assert(common.run({ mode = "magmatter", title = "MagMatter smoke" },
  "tests/ExoticIOHub/exotic_magmatter_smoke.cfg"))
assert(#scenario.submitted == 3, "MagMatter must submit plasma, temporal and spatial fluid together")
assert(scenario.sentItems == 1, "MagMatter dust hint must return to AE")
assert(scenario.sentFluids == 70, "MagMatter temporal/spatial hints must return to AE")
assert(usedResolution(120, 35), "MagMatter GUI must render at 120x35")

local faultConfig = "tests/ExoticIOHub/exotic_fault_smoke.cfg"
local quarkMaterials = { "radon", "mercury", "argon", "xenon", "neon", "hydrogen", "helium" }

local function faultQuark(options)
  options = options or {}
  local fluids, stock = {}, {}
  for index, material in ipairs(quarkMaterials) do
    fluids[index] = { name = material, label = material, amount = index }
    if options.stocked then stock["plasma." .. material] = index * 1000 end
  end
  local base = { items = {}, fluids = fluids, stock = stock, quitAfter = options.quitAfter or 35 }
  for key, value in pairs(options) do base[key] = value end
  reset(base)
  assert(common.run({ mode = "quark", title = "Fault smoke" }, faultConfig))
end

local function screenHas(text)
  return scenario.screenText:find(text, 1, true) ~= nil
end

reset({
  items = {}, fluids = {}, stock = {}, initialDualDirty = true,
  keepDualDirty = true, quitAfter = 3
})
assert(common.run({ mode = "quark", title = "Dirty start smoke" }, faultConfig))
assert(screenHas("启动时 OC 二合一输入枢纽存在无归属残留"), "dirty dual hatch must latch a startup fault")
assert(scenario.refundCount == 0 and scenario.dualHasFluid, "dirty startup must not auto-refund unknown residue")

reset({
  items = { [1] = { name = "miscutils:itemDustHypogen", damage = 0, size = 1 } },
  fluids = {
    [1] = { name = "fluid.temporalfluid", amount = 10 },
    [2] = { name = "fluid.spatialfluid", amount = 20 }
  },
  stock = {}, quitAfter = 5
})
assert(common.run({ mode = "quark", title = "Wrong recipe smoke" }, faultConfig))
assert(screenHas("样板长时间不完整"), "MagMatter signature in quark mode must fault")
assert(scenario.sentItems == 0 and scenario.sentFluids == 0, "wrong-mode hints must remain untouched")

faultQuark({ componentDropped = true, quitAfter = 3 })
assert(screenHas("读取 IO 枢纽流体槽") and screenHas("故障锁定"), "component loss must latch a fault")

faultQuark({ aeDisconnected = true, quitAfter = 20 })
assert(screenHas("getFluidsInNetwork") and screenHas("故障锁定"), "AE disconnection must latch a fault")

faultQuark({ quitAfter = 22 })
assert(screenHas("氡等离子体液滴") and screenHas("缺少样板"),
  "missing patterns must show translated Chinese droplet names")

faultQuark({ craftBehavior = "done_insufficient", cpuBusy = true, quitAfter = 22 })
assert(screenHas("等待CPU") and scenario.craftRequests == 0, "busy named CPU must defer crafting")

faultQuark({ craftBehavior = "failed", quitAfter = 28 })
assert(screenHas("合成连续失败") and scenario.craftRequests == 2, "repeated craft failure must latch")

faultQuark({ craftBehavior = "canceled", quitAfter = 28 })
assert(screenHas("合成连续失败") and scenario.craftRequests == 2, "repeated craft cancellation must latch")

faultQuark({ craftBehavior = "done_insufficient", quitAfter = 28 })
assert(screenHas("样板单次产量不足") and scenario.craftRequests == 2,
  "insufficient per-pattern output must stop after the configured attempt limit")

faultQuark({ craftBehavior = "timeout", quitAfter = 24 })
assert(screenHas("合成超时") and scenario.cpuCancels == 1, "craft timeout must cancel the named CPU and latch")

faultQuark({ stocked = true, partialSubmit = true, quitAfter = 24 })
assert(screenHas("双输入任务未全部执行") and scenario.refundCount == 1 and not scenario.dualHasFluid,
  "partial submission must refund and latch")

faultQuark({
  stocked = true, partialSubmit = true, refundWorks = false,
  keepDualDirty = true, quitAfter = 24
})
assert(screenHas("退款失败") and scenario.refundCount == 1 and scenario.dualHasFluid,
  "failed refund must preserve the dual-hatch contents and latch")

faultQuark({ stocked = true, keepDualDirty = true, quitAfter = 24 })
assert(screenHas("机器启动超时，原料已退款") and scenario.refundCount == 1,
  "machine start timeout must refund")

faultQuark({ stocked = true, machineDuration = 20, quitAfter = 30 })
assert(screenHas("机器运行超过 recipeTimeout") and scenario.refundCount == 0,
  "recipe timeout must preserve the running machine state")

for _, path in ipairs(journalPaths) do os.remove(path) end

print("exotic_runtime_smoke_test: two complete cycles and 13 fault scenarios passed")
