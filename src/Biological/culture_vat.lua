local component = require("component")
local computer = require("computer")
local sides = require("sides")

local configPath = ...

local function log(level, text)
  io.write(string.format("[%6.1f] %-5s %s\n", computer.uptime(), level, text))
end

local function shallowMerge(base, override)
  local result = {}
  for k, v in pairs(base or {}) do result[k] = v end
  for k, v in pairs(override or {}) do result[k] = v end
  return result
end

local function loadConfig(path)
  local candidates = {}
  if path then candidates[#candidates + 1] = path end
  candidates[#candidates + 1] = "/etc/culture_vat_config.lua"
  candidates[#candidates + 1] = "culture_vat_config.lua"
  candidates[#candidates + 1] = "./culture_vat_config.lua"

  local lastError
  for _, candidate in ipairs(candidates) do
    local ok, cfg = pcall(dofile, candidate)
    if ok and type(cfg) == "table" then
      log("info", "loaded config: " .. candidate)
      return cfg
    end
    lastError = cfg
  end
  error("cannot load config: " .. tostring(lastError))
end

local config = loadConfig(configPath)
local states = {}
local proxyCache = {}
local hatchRuntime = {}
local groupHatches

local function itemName(item)
  if not item then return nil end
  return item.label or item.displayName or item.name
end

local function stackName(stack)
  if not stack then return nil end
  return stack.label or stack.displayName or stack.name
end

local function stackSize(stack)
  if not stack then return 0 end
  return tonumber(stack.size or stack.amount or stack.count) or 0
end

local function namesMatch(stackOrEntry, wanted)
  local left = stackName(stackOrEntry)
  local right = itemName(wanted)
  return left ~= nil and right ~= nil and left == right
end

local function normalizeFluidName(name)
  if not name then return nil end
  local normalized = tostring(name):lower()
  normalized = normalized:gsub("^%s+", ""):gsub("%s+$", "")
  normalized = normalized:gsub("^fluid%s+drops?%s+of%s+", "")
  normalized = normalized:gsub("^drops?%s+of%s+", "")
  return normalized
end

local function fluidNamesMatch(stackOrEntry, wanted)
  if namesMatch(stackOrEntry, wanted) then return true end
  local left = normalizeFluidName(stackName(stackOrEntry))
  local right = normalizeFluidName(itemName(wanted))
  return left ~= nil and right ~= nil and left == right
end

local function resolveAddress(componentType, prefix, required)
  local matches = {}
  for address in component.list(componentType) do
    if not prefix or address:sub(1, #prefix) == prefix then
      matches[#matches + 1] = address
    end
  end

  if #matches == 1 then return matches[1] end
  if #matches == 0 and not required then return nil end
  if #matches == 0 then
    error("no component found for type=" .. tostring(componentType) .. ", prefix=" .. tostring(prefix))
  end
  error("component prefix is ambiguous for type=" .. tostring(componentType) .. ", prefix=" .. tostring(prefix) .. ", matches=" .. #matches)
end

local function resolveAny(types, prefix, required)
  local matches = {}
  for _, componentType in ipairs(types or {}) do
    for address in component.list(componentType) do
      if not prefix or address:sub(1, #prefix) == prefix then
        matches[#matches + 1] = address
      end
    end
  end

  if #matches == 1 then return matches[1] end
  if #matches == 0 and not required then return nil end
  if #matches == 0 then
    error("no component found for prefix=" .. tostring(prefix))
  end
  error("component prefix is ambiguous for prefix=" .. tostring(prefix) .. ", matches=" .. #matches)
end

local function proxyFor(componentType, prefix)
  local key = componentType .. ":" .. tostring(prefix)
  if proxyCache[key] then return proxyCache[key] end
  local address = resolveAddress(componentType, prefix, true)
  local proxy = component.proxy(address)
  proxyCache[key] = proxy
  return proxy
end

local function proxyAny(types, prefix)
  local key = table.concat(types or {}, "|") .. ":" .. tostring(prefix)
  if proxyCache[key] then return proxyCache[key] end
  local address = resolveAny(types, prefix, true)
  local proxy = component.proxy(address)
  proxyCache[key] = proxy
  return proxy
end

local function checkedCall(target, method, ...)
  if not target[method] then
    error("component has no method: " .. method)
  end
  local ok, result = pcall(target[method], ...)
  if not ok then error(result) end
  return result
end

local function groupState(index)
  states[index] = states[index] or {machines = {}, nextProduct = 0, nextMachine = 0, nextPattern = 0, nextStatus = 0}
  return states[index]
end

local function machineState(groupIndex, machineIndex)
  local gs = groupState(groupIndex)
  gs.machines[machineIndex] = gs.machines[machineIndex] or {graceUntil = 0, retryAt = 0, lastActive = false}
  return gs.machines[machineIndex]
end

local function aeProxy()
  local ae = config.ae or {}
  local types = ae.preferredTypes or {"me_controller", "me_interface"}
  return proxyAny(types, ae.address)
end

local function normalizePatternList(list)
  local result = {}
  for _, entry in ipairs(list or {}) do
    if type(entry) == "table" and entry.name and entry.count then
      result[#result + 1] = {label = entry.name, count = tonumber(entry.count) or 0}
    end
  end
  return result
end

local function deriveFromPattern(groupIndex, group)
  local gs = groupState(groupIndex)
  local now = computer.uptime()
  if gs.derived and now < (gs.nextPattern or 0) then return gs.derived end

  local patternSpec = group.pattern
  if not patternSpec then error("group " .. tostring(group.name or groupIndex) .. " has no pattern") end

  local iface = proxyFor("me_interface", patternSpec.address)
  local pattern = checkedCall(iface, "getInterfacePattern", patternSpec.slot or 1)
  if type(pattern) ~= "table" then
    error("group " .. tostring(group.name or groupIndex) .. " pattern slot is empty or unreadable")
  end

  local outputs = normalizePatternList(pattern.outputs)
  local inputs = normalizePatternList(pattern.inputs)
  local outputIndex = patternSpec.outputIndex or 1
  local output = outputs[outputIndex]
  if not output then
    error("group " .. tostring(group.name or groupIndex) .. " pattern has no output #" .. tostring(outputIndex))
  end

  local radioItem
  local required = {}
  local radioIndex
  local lastInput = inputs[#inputs]
  if lastInput and lastInput.count == 64 then
    radioItem = {label = lastInput.label, count = 1}
    radioIndex = #inputs
  end

  for index, input in ipairs(inputs) do
    if index ~= radioIndex then
      required[#required + 1] = {label = input.label, count = input.count}
    end
  end

  gs.derived = {
    product = {label = output.label, count = output.count},
    radioItem = radioItem,
    radioIndex = radioIndex,
    pattern = {address = patternSpec.address, slot = patternSpec.slot or 1},
    required = required
  }
  gs.nextPattern = now + ((config.intervals or {}).pattern or 60)

  local radioText = radioItem and radioItem.label or "none"
  log("info", string.format("group %s pattern: product=%s, radio=%s, inputs=%d",
          tostring(group.name or groupIndex), output.label, radioText, #required))
  return gs.derived
end

local function amountInEntries(entries, wanted, amountField)
  local total = 0
  for _, entry in ipairs(entries or {}) do
    if namesMatch(entry, wanted) then
      total = total + (tonumber(entry[amountField]) or stackSize(entry))
    end
  end
  return total
end

local function fluidAmountInEntries(entries, wanted, amountField)
  local total = 0
  for _, entry in ipairs(entries or {}) do
    if fluidNamesMatch(entry, wanted) then
      total = total + (tonumber(entry[amountField]) or stackSize(entry))
    end
  end
  return total
end

local function fluidAmount(wanted)
  local ae = aeProxy()
  local fluids = checkedCall(ae, "getFluidsInNetwork")
  return fluidAmountInEntries(fluids, wanted, "amount")
end

local function itemAmount(wanted)
  local ae = aeProxy()
  local name = itemName(wanted)
  local items = {}
  local ok, filtered = pcall(ae.getItemsInNetwork, {label = name})
  if ok and type(filtered) == "table" then items = filtered end
  if amountInEntries(items, wanted, "size") == 0 then
    ok, filtered = pcall(ae.getItemsInNetwork, {name = name})
    if ok and type(filtered) == "table" then items = filtered end
  end
  if amountInEntries(items, wanted, "size") == 0 then
    items = checkedCall(ae, "getItemsInNetwork")
  end
  return amountInEntries(items, wanted, "size")
end

local function networkAmount(wanted)
  return itemAmount(wanted) + fluidAmount(wanted)
end

local function groupThresholds(group)
  return shallowMerge((config.defaults or {}).thresholds, group.thresholds)
end

local function groupWork(group)
  return shallowMerge((config.defaults or {}).work, group.work)
end

local function groupControl(group)
  return shallowMerge((config.defaults or {}).control, group.control)
end

local function groupActiveSpec(group)
  return shallowMerge((config.defaults or {}).active, group.active)
end

local function machineActiveSpec(group, machine)
  return shallowMerge(groupActiveSpec(group), machine.active)
end

local function requiredBatches(group)
  local batches = group.inputBatches
  if batches == nil then batches = (config.defaults or {}).inputBatches end
  if batches == nil or batches == "machines" then
    return #(group.machines or {})
  end
  return tonumber(batches) or 1
end

local function inputsReady(group, derived)
  local batches = requiredBatches(group)
  for _, required in ipairs(derived.required or {}) do
    local need = (tonumber(required.count) or 0) * batches
    local have = networkAmount(required)
    if have < need then
      return false, string.format("%s need=%d have=%d", itemName(required), need, have)
    end
  end
  return true
end

local function radioAvailable(group, derived)
  if not derived.radioItem then return true end
  local needed = 0
  for _ in ipairs(groupHatches(group)) do
    needed = needed + 1
  end
  if needed == 0 then return true end
  local have = itemAmount(derived.radioItem)
  if have < needed then
    return false, string.format("%s need=%d have=%d", itemName(derived.radioItem), needed, have)
  end
  return true
end

local function signalMode(spec)
  if spec and spec.mode then return spec.mode end
  if spec and spec.frequency then return "gt_wireless" end
  return "side"
end

local function signalComponentType(spec)
  spec = spec or {}
  if spec.componentType then return spec.componentType end
  local mode = signalMode(spec)
  if mode == "gt_wireless" then return "gtredstone" end
  return "redstone"
end

local function signalComponent(spec)
  spec = spec or {}
  return proxyFor(signalComponentType(spec), spec.address)
end

local function isPublicWireless(spec)
  if spec.isPublic == nil then return true end
  return spec.isPublic and true or false
end

local function validateSignalSpec(spec, label)
  local mode = signalMode(spec)
  signalComponent(spec)
  if mode == "gt_wireless" and not spec.frequency then
    error(label .. " requires frequency for GT wireless redstone")
  end
end

local function validateThresholds(thresholds, label)
  if thresholds.upper and thresholds.lower and thresholds.upper < thresholds.lower then
    error(label .. " thresholds.upper must be greater than or equal to thresholds.lower")
  end
end

local function setSignal(spec, enabled)
  local rs = signalComponent(spec)
  local value = enabled
  if spec.inverted then value = not value end

  local mode = signalMode(spec)
  if mode == "gt_wireless" then
    if not spec.frequency then error("GT wireless redstone signal requires frequency") end
    local strength = value and (spec.on or 15) or (spec.off or 0)
    checkedCall(rs, "setWireless", spec.frequency, strength, isPublicWireless(spec))
  else
    local strength = value and (spec.on or 15) or (spec.off or 0)
    checkedCall(rs, "setOutput", spec.side or sides.back, strength)
  end
end

local function readSignal(spec, output)
  local rs = signalComponent(spec)
  local active
  local mode = signalMode(spec)
  if mode == "gt_wireless" then
    if not spec.frequency then error("GT wireless redstone signal requires frequency") end
    local strength = checkedCall(rs, "getWireless", spec.frequency, isPublicWireless(spec))
    active = (tonumber(strength) or 0) > (spec.threshold or 0)
  else
    local strength
    if output and rs.getOutput then
      strength = checkedCall(rs, "getOutput", spec.side or sides.back)
    elseif rs.getInput then
      strength = checkedCall(rs, "getInput", spec.side or sides.back)
    else
      strength = 0
    end
    active = (tonumber(strength) or 0) > (spec.threshold or 0)
  end
  if spec.inverted then active = not active end
  return active and true or false
end

local function setGroupEnabled(group, enabled)
  setSignal(groupControl(group), enabled)
end

local function groupEnabled(group)
  return readSignal(groupControl(group), true)
end

local function hatchSpec(hatchId)
  local hatch = (config.hatches or {})[hatchId]
  if not hatch then error("unknown hatch: " .. tostring(hatchId)) end
  return shallowMerge((config.defaults or {}).hatch, hatch)
end

local function databaseAddress()
  local database = config.database or {}
  return resolveAddress("database", database.address, true)
end

local function databaseEntry()
  return (config.database or {}).entry or 1
end

function groupHatches(group)
  local result = {}
  local seen = {}
  for _, hatchId in ipairs(group.hatches or {}) do
    if not seen[hatchId] then
      seen[hatchId] = true
      result[#result + 1] = hatchId
    end
  end
  return result
end

local function ioHubFor(spec)
  return proxyFor("iohub", spec.ioHub or spec.address)
end

local function storeRadioDescriptor(derived)
  if not derived.radioIndex then return false end
  local iface = proxyFor("me_interface", derived.pattern.address)
  checkedCall(iface, "storeInterfacePatternInput", derived.pattern.slot, derived.radioIndex, databaseAddress(), databaseEntry())
  return true
end

local function hubSlot(spec)
  return spec.bufferSlot or spec.inventorySlot or 1
end

local function hatchSlot(spec)
  return spec.hatchSlot or spec.slot or 1
end

local function selectHubSlot(hub, spec)
  checkedCall(hub, "select", hubSlot(spec))
end

local function flushHubSlot(hub, spec)
  selectHubSlot(hub, spec)
  local count = tonumber(checkedCall(hub, "count")) or 0
  if count > 0 then
    checkedCall(hub, "sendItems", count)
  end
end

local function hatchTargetCount(spec)
  return spec.targetCount or 1
end

local function hatchSlotSize(hub, spec)
  return tonumber(checkedCall(hub, "getSlotStackSize", spec.side, hatchSlot(spec))) or 0
end

local function hatchSlotMatchesRadio(hub, spec)
  return checkedCall(hub, "compareStackToDatabase", spec.side, hatchSlot(spec), databaseAddress(), databaseEntry(), false) and true or false
end

local function requestRadioItem(spec, derived)
  if not storeRadioDescriptor(derived) then
    return false, "pattern has no radio item"
  end
  local hub = ioHubFor(spec)
  flushHubSlot(hub, spec)

  local amount = math.min(spec.requestAmount or spec.amount or 1, hatchTargetCount(spec))
  local requested = tonumber(checkedCall(hub, "requestItems", databaseAddress(), databaseEntry(), amount)) or 0
  if requested <= 0 then
    return false, string.format("hatch=%s cannot request %s from AE via IO Hub %s",
            tostring(spec.id or "?"), itemName(derived.radioItem), tostring(spec.ioHub or spec.address))
  end

  local dropped = checkedCall(hub, "dropIntoSlot", spec.side, hatchSlot(spec), requested)
  if dropped == true or (tonumber(dropped) or 0) > 0 then
    return true
  end

  flushHubSlot(hub, spec)
  return false, string.format("hatch=%s cannot drop %s into side=%s slot=%s requested=%d",
          tostring(spec.id or "?"), itemName(derived.radioItem), tostring(spec.side), tostring(hatchSlot(spec)), requested)
end

local function ensureHatch(hatchId, derived)
  local wanted = derived.radioItem
  if not wanted then return true end
  local spec = hatchSpec(hatchId)
  local runtime = hatchRuntime[hatchId] or {nextFeed = 0}
  hatchRuntime[hatchId] = runtime
  local now = computer.uptime()
  if now < (runtime.nextFeed or 0) then return true end

  spec.id = hatchId
  if not storeRadioDescriptor(derived) then
    return false, "pattern has no radio item"
  end

  local hub = ioHubFor(spec)
  local target = hatchTargetCount(spec)
  local current = hatchSlotSize(hub, spec)
  if current > 0 then
    if not hatchSlotMatchesRadio(hub, spec) then
      local message = string.format("hatch=%s slot=%s contains a different item; radio feed skipped",
              tostring(hatchId), tostring(hatchSlot(spec)))
      log("error", message)
      runtime.nextFeed = now + (spec.refeedInterval or spec.feedInterval or 60)
      return false, message
    end
    if current > target then
      log("warn", string.format("hatch=%s contains %d radio items, target=%d; radio feed skipped",
              tostring(hatchId), current, target))
    end
    runtime.nextFeed = now + (spec.refeedInterval or spec.feedInterval or 60)
    return true
  end

  local ok, why = requestRadioItem(spec, derived)
  if ok then
    runtime.nextFeed = now + (spec.refeedInterval or spec.feedInterval or 60)
  end
  return ok, why
end

local function removeHatch(hatchId, derived)
  if not derived.radioItem then return end
  local runtime = hatchRuntime[hatchId] or {}
  hatchRuntime[hatchId] = runtime
  runtime.nextFeed = 0
end

local function ensureGroupHatches(group, derived)
  if not derived.radioItem then return true end
  local ok = true
  local reasons = {}
  for _, hatchId in ipairs(groupHatches(group)) do
    local hatchOk, why = ensureHatch(hatchId, derived)
    if not hatchOk then
      ok = false
      reasons[#reasons + 1] = why or tostring(hatchId)
    end
  end
  if ok then return true end
  return false, table.concat(reasons, "; ")
end

local function stopGroupHatchFeed(group, derived)
  if not derived.radioItem then return end
  for _, hatchId in ipairs(groupHatches(group)) do
    removeHatch(hatchId, derived)
  end
end

local function machineActive(group, machine)
  local active = machineActiveSpec(group, machine)
  if not active.address and not active.side and not active.frequency then
    error("machine " .. tostring(machine.name) .. " has no active signal")
  end
  return readSignal(active, false)
end

local function sharedGroupActive(group)
  local active = groupActiveSpec(group)
  if not active.address and not active.side and not active.frequency then
    error("group " .. tostring(group.name) .. " has no active signal")
  end
  return readSignal(active, false)
end

local function startGroup(groupIndex, group, reason)
  local derived = deriveFromPattern(groupIndex, group)
  local ok, why = inputsReady(group, derived)
  if not ok then
    log("warn", string.format("group %s not started: input missing: %s", tostring(group.name or groupIndex), why))
    return false
  end
  ok, why = radioAvailable(group, derived)
  if not ok then
    log("warn", string.format("group %s not started: radio item missing: %s", tostring(group.name or groupIndex), why))
    return false
  end

  local now = computer.uptime()
  local work = groupWork(group)
  local hatchesOk, hatchWhy = ensureGroupHatches(group, derived)
  if not hatchesOk then
    log("warn", string.format("group %s not started: cannot prefill radio hatches",
            tostring(group.name or groupIndex)) .. (hatchWhy and (": " .. hatchWhy) or ""))
    return false
  end

  for index, machine in ipairs(group.machines or {}) do
    local ms = machineState(groupIndex, index)
    ms.graceUntil = now + (work.startGrace or 30)
    ms.retryAt = now + (work.retryInterval or 60)
  end

  setGroupEnabled(group, true)
  log("info", string.format("group %s enabled%s", tostring(group.name or groupIndex), reason and (": " .. reason) or ""))
  return true
end

local function stopGroup(groupIndex, group, reason)
  local derived = deriveFromPattern(groupIndex, group)
  stopGroupHatchFeed(group, derived)
  for index, machine in ipairs(group.machines or {}) do
    local ms = machineState(groupIndex, index)
    ms.graceUntil = 0
    ms.lastActive = false
  end
  setGroupEnabled(group, false)
  log("info", string.format("group %s disabled%s", tostring(group.name or groupIndex), reason and (": " .. reason) or ""))
end

local function productCheck(groupIndex, group)
  local derived = deriveFromPattern(groupIndex, group)
  local thresholds = groupThresholds(group)
  local amount = fluidAmount(derived.product)
  local enabled = groupEnabled(group)

  if thresholds.upper and amount >= thresholds.upper and enabled then
    stopGroup(groupIndex, group, string.format("%s=%d >= upper=%d", itemName(derived.product), amount, thresholds.upper))
  elseif thresholds.lower and amount <= thresholds.lower and not enabled then
    startGroup(groupIndex, group, string.format("%s=%d <= lower=%d", itemName(derived.product), amount, thresholds.lower))
  end
end

local function machineCheck(groupIndex, group)
  local derived = deriveFromPattern(groupIndex, group)
  local now = computer.uptime()
  local enabled = groupEnabled(group)
  local work = groupWork(group)

  if not enabled then
    stopGroupHatchFeed(group, derived)
    for index, machine in ipairs(group.machines or {}) do
      local ms = machineState(groupIndex, index)
      ms.lastActive = false
      ms.graceUntil = 0
    end
    return
  end

  local ready, why = inputsReady(group, derived)
  if not ready then
    if group.forceOffOnUnsafe then
      stopGroup(groupIndex, group, "input missing: " .. why)
      return
    end
    stopGroupHatchFeed(group, derived)
    for index, machine in ipairs(group.machines or {}) do
      local ms = machineState(groupIndex, index)
      ms.lastActive = false
      ms.graceUntil = 0
    end
    log("warn", string.format("group %s input missing, hatch feeding stopped: %s", tostring(group.name or groupIndex), why))
    return
  end

  local sharedActive = sharedGroupActive(group)
  local shouldFeed = false
  local shouldRetry = false
  for index, machine in ipairs(group.machines or {}) do
    local ms = machineState(groupIndex, index)
    local active
    if machine.active then
      active = machineActive(group, machine)
    else
      active = sharedActive
    end
    ms.lastActive = active

    if active or now < (ms.graceUntil or 0) then
      shouldFeed = true
    else
      if now >= (ms.retryAt or 0) then
        ms.graceUntil = now + (work.startGrace or 30)
        ms.retryAt = now + (work.retryInterval or 60)
        shouldFeed = true
        shouldRetry = true
      end
    end
  end
  if shouldFeed then
    local hatchesOk, hatchWhy = ensureGroupHatches(group, derived)
    if not hatchesOk then
      log("warn", string.format("group %s cannot fill radio hatches", tostring(group.name or groupIndex)) ..
              (hatchWhy and (": " .. hatchWhy) or ""))
    elseif shouldRetry then
      log("info", string.format("group %s retrying radio feed", tostring(group.name or groupIndex)))
    end
  else
    stopGroupHatchFeed(group, derived)
  end
end

local function statusLine(groupIndex, group)
  local derived = deriveFromPattern(groupIndex, group)
  local amount = fluidAmount(derived.product)
  local enabled = groupEnabled(group)
  local active = 0
  local sharedActive = sharedGroupActive(group)
  for _, machine in ipairs(group.machines or {}) do
    local machineIsActive
    if machine.active then
      machineIsActive = machineActive(group, machine)
    else
      machineIsActive = sharedActive
    end
    if machineIsActive then active = active + 1 end
  end
  log("stat", string.format("group=%s enabled=%s active=%d/%d product=%s amount=%d radio=%s",
          tostring(group.name or groupIndex), tostring(enabled), active, #(group.machines or {}),
          itemName(derived.product), amount, derived.radioItem and itemName(derived.radioItem) or "none"))
end

local function validate()
  if type(config.groups) ~= "table" or #config.groups == 0 then
    error("config.groups must contain at least one group")
  end
  aeProxy()
  for groupIndex, group in ipairs(config.groups) do
    validateSignalSpec(groupControl(group), "group " .. tostring(group.name or groupIndex) .. " control")
    validateThresholds(groupThresholds(group), "group " .. tostring(group.name or groupIndex))
    if type(group.machines) ~= "table" or #group.machines == 0 then
      error("group " .. tostring(group.name or groupIndex) .. " must contain machines")
    end
    for machineIndex, machine in ipairs(group.machines) do
      validateSignalSpec(
              machineActiveSpec(group, machine),
              "group " .. tostring(group.name or groupIndex) .. " machine " .. tostring(machine.name or machineIndex) .. " active")
    end
    for _, hatchId in ipairs(groupHatches(group)) do
      local spec = hatchSpec(hatchId)
      ioHubFor(spec)
    end
    local derived = deriveFromPattern(groupIndex, group)
    if derived.radioItem and #groupHatches(group) == 0 then
      error("group " .. tostring(group.name or groupIndex) .. " pattern requires radio hatches")
    end
  end
end

local function tickGroup(groupIndex, group)
  local now = computer.uptime()
  local interval = config.intervals or {}
  local gs = groupState(groupIndex)

  if now >= (gs.nextProduct or 0) then
    local ok, err = pcall(productCheck, groupIndex, group)
    if not ok then log("error", "product check failed for " .. tostring(group.name or groupIndex) .. ": " .. tostring(err)) end
    gs.nextProduct = now + (interval.product or 20)
  end

  if now >= (gs.nextMachine or 0) then
    local ok, err = pcall(machineCheck, groupIndex, group)
    if not ok then log("error", "machine check failed for " .. tostring(group.name or groupIndex) .. ": " .. tostring(err)) end
    gs.nextMachine = now + (interval.machine or interval.hatch or 5)
  end

  if interval.status and now >= (gs.nextStatus or 0) then
    local ok, err = pcall(statusLine, groupIndex, group)
    if not ok then log("error", "status failed for " .. tostring(group.name or groupIndex) .. ": " .. tostring(err)) end
    gs.nextStatus = now + interval.status
  end
end

validate()
log("info", "culture vat automation started; groups=" .. tostring(#config.groups))

while true do
  for groupIndex, group in ipairs(config.groups) do
    tickGroup(groupIndex, group)
  end
  os.sleep((config.intervals or {}).loop or 1)
end
