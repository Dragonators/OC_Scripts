local now = 0
local active

local function cloneEntries(entries)
  local result = {}
  for slot, entry in pairs(entries) do
    local copy = {}
    for key, value in pairs(entry) do copy[key] = value end
    result[slot] = copy
  end
  return result
end

local function countEntries(entries)
  local count = 0
  for _ in pairs(entries) do count = count + 1 end
  return count
end

local addresses = {
  transposer = "transposer-address",
  database = "database-address",
  me_interface = "interface-address",
  gpu = "gpu-address",
}

local proxies = {}
local allMethods = {
  getInventorySize = false,
  getStackInSlot = false,
  getTankCount = false,
  getFluidInTank = false,
  transferItem = false,
  transferFluid = false,
  get = false,
  set = false,
  getCraftables = false,
  setFluidInterfaceConfiguration = false,
  getFluidInterfaceConfiguration = false,
}

package.preload.sides = function() return { down = 0, east = 5 } end
package.preload.unicode = function()
  return { len = function(value) return #tostring(value) end, sub = string.sub }
end
package.preload.computer = function()
  return { uptime = function() return now end }
end
package.preload.component = function()
  return {
    list = function(kind)
      local yielded = false
      return function()
        if yielded or not addresses[kind] then return nil end
        yielded = true
        return addresses[kind]
      end
    end,
    proxy = function(address) return assert(proxies[address], "unknown proxy " .. tostring(address)) end,
    methods = function() return allMethods end,
  }
end

local databaseSlots = {}
proxies[addresses.database] = {
  address = addresses.database,
  set = function(slot, name, damage, nbt)
    local fluidName = tostring(nbt):match('Fluid:"([^"]+)"')
    if name == "gregtech:gt.metaitem.01" then
      fluidName = ({[31001] = "plasma.iron", [31002] = "plasma.copper"})[damage]
    end
    databaseSlots[slot] = {
      name = name,
      damage = damage,
      label = fluidName and ("drop:" .. fluidName) or name,
      fluid = fluidName and { name = fluidName } or nil,
    }
    return true
  end,
  get = function(slot) return databaseSlots[slot] end,
}

local interface = { configured = {} }
local function noteConfiguredSlot(slot)
  local configured = countEntries(interface.configured)
  active.maxConfigured = math.max(active.maxConfigured, configured)
  if slot == 5 then active.usedSixthSlot = true end
end

proxies[addresses.me_interface] = {
  address = addresses.me_interface,
  setFluidInterfaceConfiguration = function(slot, databaseAddress, databaseSlot)
    if databaseAddress == nil then
      interface.configured[slot] = nil
      return true
    end
    assert(databaseAddress == addresses.database, "wrong database address")
    local drop = assert(databaseSlots[databaseSlot], "missing database fluid drop")
    interface.configured[slot] = assert(drop.fluid.name)
    noteConfiguredSlot(slot)
    if active.stopAfterSecondReturn and active.returnedCycles >= 2 then active.stopReady = true end
    return true
  end,
  getFluidInterfaceConfiguration = function(slot)
    local fluidName = interface.configured[slot]
    return fluidName and { fluid = { name = fluidName } } or nil
  end,
  getCraftables = function() return {} end,
}

local gpu = { address = addresses.gpu }
for _, method in ipairs({"setBackground", "setForeground", "fill", "setResolution"}) do
  gpu[method] = function() return true end
end
gpu.maxResolution = function() return 160, 50 end
gpu.set = function(_, _, value)
  if value == "本批完成" then
    active.completedCycles = active.completedCycles + 1
    if active.completedCycles == 1 then active.firstCycleCompletedAt = now end
    if active.stopOnFirstCompletion then active.stopReady = true end
  end
  return true
end
proxies[addresses.gpu] = gpu

local CACHE_SIDE, MAIN_SIDE = 5, 0
local function promptCacheEmpty()
  return countEntries(active.cacheItems) == 0 and countEntries(active.cacheFluids) == 0
end

local function markPromptReturnIfComplete()
  if active.promptBatchPresent and promptCacheEmpty() then
    active.promptBatchPresent = false
    active.returnedCycles = active.returnedCycles + 1
    if active.returnedCycles == 2 then active.secondPromptReturnedAt = now end
  end
end

local function injectNextPromptAfterMachineAdvance()
  active.cacheItems = cloneEntries(active.nextItems or active.originalItems)
  active.cacheFluids = cloneEntries(active.nextFluids or active.originalFluids)
  active.promptBatchPresent = true
  active.machineAdvanced = true
end

proxies[addresses.transposer] = {
  address = addresses.transposer,
  getInventorySize = function(side) return side == CACHE_SIDE and 8 or 0 end,
  getStackInSlot = function(side, slot)
    return side == CACHE_SIDE and active.cacheItems[slot] or nil
  end,
  getTankCount = function(side)
    if side == MAIN_SIDE then return 6 end
    if side == CACHE_SIDE then return 8 end
    return 0
  end,
  getFluidInTank = function(side, tank)
    if side == CACHE_SIDE then return active.cacheFluids[tank] end
    if side == MAIN_SIDE then
      local fluidName = interface.configured[tank - 1]
      return fluidName and { name = fluidName, label = fluidName, amount = 100000000 } or nil
    end
    return nil
  end,
  transferItem = function(from, to, amount, slot)
    assert(from == CACHE_SIDE and to == MAIN_SIDE, "prompt items must return to main network")
    local stack = assert(active.cacheItems[slot], "missing prompt item")
    local moved = math.min(amount, stack.size)
    stack.size = stack.size - moved
    if stack.size == 0 then active.cacheItems[slot] = nil end
    active.returnedItems = active.returnedItems + moved
    markPromptReturnIfComplete()
    return true, moved
  end,
  transferFluid = function(from, to, amount, sourceTank)
    if from == CACHE_SIDE and to == MAIN_SIDE then
      local tank = sourceTank + 1
      local fluid = assert(active.cacheFluids[tank], "missing prompt fluid")
      local moved = math.min(amount, fluid.amount)
      fluid.amount = fluid.amount - moved
      if fluid.amount == 0 then active.cacheFluids[tank] = nil end
      active.returnedFluids = active.returnedFluids + moved
      markPromptReturnIfComplete()
      return true, moved
    end

    assert(from == MAIN_SIDE and to == CACHE_SIDE, "supplied fluids must enter the cache")
    local fluidName = assert(interface.configured[sourceTank], "source tank was not configured")
    active.delivered[fluidName] = (active.delivered[fluidName] or 0) + amount
    active.deliveredTotal = active.deliveredTotal + amount
    if active.advanceAfterSupply and not active.machineAdvanced
        and active.deliveredTotal >= active.advanceAfterSupply then
      injectNextPromptAfterMachineAdvance()
    end
    return true, amount
  end,
}

os.sleep = function(duration)
  if active.stopReady then error("__FOG_BULK_TEST_STOP__", 0) end
  now = now + (duration or 0)
end

local function runScenario(configPath, scenario)
  active = scenario
  now = 0
  interface.configured = {}
  databaseSlots = {}
  scenario.cacheItems = cloneEntries(scenario.originalItems)
  scenario.cacheFluids = cloneEntries(scenario.originalFluids)
  scenario.promptBatchPresent = true
  scenario.returnedItems = 0
  scenario.returnedFluids = 0
  scenario.returnedCycles = 0
  scenario.completedCycles = 0
  scenario.maxConfigured = 0
  scenario.usedSixthSlot = false
  scenario.delivered = {}
  scenario.deliveredTotal = 0
  scenario.machineAdvanced = false

  local program = assert(loadfile("src/ExoticIOHub/fog_exotic.lua"))
  local ok, reason = pcall(program, configPath)
  assert(not ok and tostring(reason):find("__FOG_BULK_TEST_STOP__", 1, true),
    "runtime did not reach the controlled stop: " .. tostring(reason))
end

local quarkItems = {}
for index, material in ipairs({"Gold", "Tin", "Lead", "Silver", "Nickel", "Zinc", "Aluminium"}) do
  quarkItems[index] = {
    name = "miscutils:itemDust" .. material,
    label = material .. " Dust",
    damage = 0,
    size = index,
  }
end

local quark = {
  originalItems = quarkItems,
  originalFluids = {},
  advanceAfterSupply = 28 * 1296,
  stopAfterSecondReturn = true,
}
runScenario("tests/ExoticIOHub/fog_exotic_bulk_quark.cfg", quark)
assert(quark.returnedCycles == 2, "both quark prompt batches must return to main")
assert(quark.returnedItems == 56, "all quark prompt items must return")
assert(quark.returnedFluids == 0, "quark item-only fixture must not invent prompt fluid")
-- The controlled stop occurs immediately after cycle 2 returned its prompts,
-- before cycle 2 supply starts. Cycle 1 must nevertheless be complete.
assert(quark.deliveredTotal == 28 * 1296,
  "quark plasma formula or resume accounting changed: " .. tostring(quark.deliveredTotal))
assert(quark.maxConfigured == 6, "quark must configure six interface tanks in parallel")
assert(quark.usedSixthSlot, "quark must actually transfer through interface tank 6")
assert(quark.secondPromptReturnedAt - quark.firstCycleCompletedAt <= 0.6,
  "next prompt return took too long: " .. tostring(quark.secondPromptReturnedAt - quark.firstCycleCompletedAt))

local omittedItems = {}
for index, material in ipairs({"Gold", "Tin", "Lead", "Silver", "Nickel"}) do
  local slot = index + 2
  omittedItems[slot] = {
    name = "miscutils:itemDust" .. material,
    label = material .. " Dust",
    damage = 0,
    size = 1,
  }
end
for index, material in ipairs({"Iron", "Copper"}) do
  omittedItems[index] = {
    name = "gregtech:gt.metaitem.01",
    label = material .. " Dust",
    damage = 2000 + index,
    size = 1,
  }
end

local omitted = {
  originalItems = omittedItems,
  originalFluids = {},
  advanceAfterSupply = 5 * 1296,
  stopOnFirstCompletion = true,
}
runScenario("tests/ExoticIOHub/fog_exotic_bulk_quark.cfg", omitted)
assert(omitted.returnedCycles == 1 and omitted.returnedItems == 7,
  "all hints, including Iron/Copper dust, must return to main")
assert(omitted.delivered["plasma.iron"] == nil,
  "Iron Plasma must be omitted before interface configuration and transfer")
assert(omitted.delivered["plasma.copper"] == nil,
  "Copper Plasma must be omitted before interface configuration and transfer")
assert(omitted.deliveredTotal == 5 * 1296,
  "only the five real plasma inputs may be delivered: " .. tostring(omitted.deliveredTotal))
assert(omitted.maxConfigured == 5,
  "Iron/Copper fake inputs must not occupy interface tanks")

local magmatter = {
  originalItems = {
    [1] = { name = "miscutils:itemDustIron", label = "Iron Dust", damage = 0, size = 1 },
  },
  originalFluids = {
    [1] = { name = "fluid.temporalfluid", label = "Temporal Fluid", amount = 10 },
    [2] = { name = "fluid.spatialfluid", label = "Spatial Fluid", amount = 60 },
  },
  advanceAfterSupply = 10 + 60 + (60 - 10) * 144,
  stopOnFirstCompletion = true,
}
runScenario("tests/ExoticIOHub/fog_exotic_bulk_magmatter.cfg", magmatter)
assert(magmatter.returnedCycles == 1, "MagMatter prompts must return as one batch")
assert(magmatter.returnedItems == 1 and magmatter.returnedFluids == 70,
  "MagMatter item/fluid prompts were not all returned")
assert(magmatter.deliveredTotal == 10 + 60 + (60 - 10) * 144,
  "MagMatter amount formula changed")
assert(magmatter.maxConfigured == 3, "MagMatter must configure all three fluids together")

print(string.format(
  "fog_exotic_bulk_smoke_test: false methods accepted; quark=6+1; Iron/Copper omitted; magmatter=3; next return=%.2fs",
  quark.secondPromptReturnedAt - quark.firstCycleCompletedAt))
