package.path = "src/ExoticIOHub/?.lua;../?.lua;./?.lua;" .. package.path

package.preload.component = function() return {} end
package.preload.computer = function() return { uptime = function() return 0 end } end
package.preload.event = function() return { pull = function() return nil end } end
package.preload.filesystem = function() return {} end
package.preload.serialization = function()
  return { serialize = function() return "" end, unserialize = function() return nil end }
end
package.preload.unicode = function()
  local utf8lib = utf8
  local function width(text)
    local result = 0
    for _, codepoint in utf8lib.codes(tostring(text)) do
      result = result + (codepoint > 127 and 2 or 1)
    end
    return result
  end
  local function truncate(text, maximum)
    local result, used = {}, 0
    for _, codepoint in utf8lib.codes(tostring(text)) do
      local cell = codepoint > 127 and 2 or 1
      if used + cell > maximum then break end
      result[#result + 1] = utf8lib.char(codepoint)
      used = used + cell
    end
    return table.concat(result)
  end
  return {
    wlen = width,
    wtrunc = truncate,
    sub = string.sub
  }
end

local common = require("exotic_iohub_common")
local api = common._test

local passed = 0
local function equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)), 2)
  end
  passed = passed + 1
end

local function truthy(value, message)
  if not value then error(message or "expected truthy", 2) end
  passed = passed + 1
end

equal(api.fluidDropNbt("plasma.iron"), '{Fluid:"plasma.iron"}', "AE2FC droplet NBT")
equal(api.universalCellNbt("plasma.iron"),
  '{Fluid:{FluidName:"plasma.iron",Amount:1000}}', "universal cell NBT")
equal(api.dualDatabaseIndex(1), 0, "dual hatch database index is zero-based")
equal(api.dropletNameZh("plasma.radon"), "氡等离子体液滴", "Chinese droplet name")
equal(api.dropletNameZh("plasma.test_only", "服务器中文名"), "服务器中文名液滴",
  "server Chinese label fallback")
equal(api.dropletNameZh("plasma.test_only", "English label"), "plasma.test_only液滴",
  "internal fluid name fallback")
equal(api.formatNumber(1234567), "1,234,567", "number formatting")
equal(require("unicode").wlen(api.fit("磁物质", 80)), 80, "80-column CJK fit")
equal(require("unicode").wlen(api.fit("简并夸克胶子等离子体", 120)), 120, "120-column CJK fit")

local bartExpected = {
  [3] = "plasma.zirconium",
  [30] = "plasma.thorium232",
  [64] = "plasma.ruthenium",
  [78] = "plasma.rhodium",
  [11000] = "plasma.hafnium",
  [11012] = "plasma.iodine"
}
for damage, expected in pairs(bartExpected) do
  equal(api.resolveDustPlasma({ name = "bartworks:gt.bwMetaGenerateddust", damage = damage }),
    expected, "BartWorks mapping " .. damage)
end

local gtppExpected = {
  CelestialTungsten = "plasma.celestialtungsten",
  Hypogen = "plasma.hypogen",
  Rhugnor = "plasma.rhugnor",
  ChromaticGlass = "plasma.chromaticglass",
  Dragonblood = "plasma.dragonblood"
}
for material, expected in pairs(gtppExpected) do
  equal(api.resolveDustPlasma({ name = "miscutils:itemDust" .. material, damage = 0 }),
    expected, "GT++ mapping " .. material)
end

local gtCandidates = {
  "cosmicneutronium", "draconium", "draconiumawakened", "ichorium", "neutronium",
  "flerovium", "bedrockium", "infinity", "tritanium"
}
local gtByDamage, probeDamage = {}, nil
for index, material in ipairs(gtCandidates) do gtByDamage[100 + index] = "plasma." .. material end
local fakeDatabase = {
  set = function(_, _, damage)
    probeDamage = damage - 29000
    return true
  end,
  get = function()
    return { fluid = { name = gtByDamage[probeDamage] } }
  end
}
for index, material in ipairs(gtCandidates) do
  equal(api.resolveDustPlasma({ name = "gregtech:gt.metaitem.01", damage = 100 + index }, fakeDatabase, 9),
    "plasma." .. material, "GT metadata probe " .. material)
end
equal(api.resolveDustPlasma({ name = "gregtech:gt.metaitem.01", damage = 382 }, fakeDatabase, 9),
  "plasma.ardite", "Ardite special case")
equal(api.resolveDustPlasma({ name = "some:oredict_dust", damage = 0, oreNames = { "dustNaquadah" } }),
  "plasma.naquadah", "ore dictionary mapping")
local unknownDust, unknownDustReason = api.resolveDustPlasma({
  name = "bartworks:gt.bwMetaGenerateddust", damage = 99999
})
equal(unknownDust, nil, "unknown BartWorks dust rejected")
truthy(unknownDustReason:match("BartWorks"), "unknown BartWorks reason")

local allFluidSnapshot = { items = {}, fluids = {} }
for i = 1, 7 do
  allFluidSnapshot.fluids[i] = { slot = i, name = "material" .. i, amount = i }
end
local allFluid = assert(api.buildQuarkRequirements(allFluidSnapshot, fakeDatabase, 9))
equal(#allFluid, 7, "all-fluid requirement count")
equal(allFluid[7].amount, 7000, "fluid hint x1000")

local duplicateFluids = { items = {}, fluids = {} }
for index, name in ipairs({ "radon", "radon", "argon", "xenon", "neon", "hydrogen", "helium" }) do
  duplicateFluids.fluids[index] = { slot = index, name = name, amount = index }
end
local merged = assert(api.buildQuarkRequirements(duplicateFluids, fakeDatabase, 9))
equal(#merged, 6, "duplicate plasma requirements merge")
equal(merged[1].amount, 3000, "duplicate plasma amounts merge")

local allDustSnapshot = { items = {}, fluids = {} }
local bartDamages = { 3, 30, 64, 78, 11000, 11012 }
for i, damage in ipairs(bartDamages) do
  allDustSnapshot.items[i] = {
    slot = i, name = "bartworks:gt.bwMetaGenerateddust", damage = damage, size = i
  }
end
allDustSnapshot.items[7] = { slot = 7, name = "miscutils:itemDustHypogen", damage = 0, size = 7 }
local allDust = assert(api.buildQuarkRequirements(allDustSnapshot, fakeDatabase, 9))
equal(#allDust, 7, "all-dust requirement count")
equal(allDust[7].amount, 7 * 1296, "dust hint x1296")

local mixed = assert(api.buildQuarkRequirements({
  items = {
    { slot = 1, name = "miscutils:itemDustHypogen", damage = 0, size = 2 },
    { slot = 2, name = "bartworks:gt.bwMetaGenerateddust", damage = 3, size = 1 }
  },
  fluids = {
    { slot = 1, name = "radon", amount = 4 },
    { slot = 2, name = "mercury", amount = 5 },
    { slot = 3, name = "argon", amount = 6 },
    { slot = 4, name = "xenon", amount = 7 },
    { slot = 5, name = "neon", amount = 8 }
  }
}, fakeDatabase, 9))
equal(#mixed, 7, "mixed requirement count")
equal(mixed[1].name, "plasma.radon", "fluid-to-plasma name")
equal(mixed[6].amount, 2592, "mixed dust amount")

local function magSnapshot(item, time, space)
  return {
    items = { item },
    fluids = {
      { slot = 1, name = "fluid.temporalfluid", label = "Tachyon Rich Temporal Fluid", amount = time },
      { slot = 2, name = "fluid.spatialfluid", label = "Spatially Enlarged Fluid", amount = space }
    }
  }
end

for index, material in ipairs(gtCandidates) do
  local requirements = assert(api.buildMagmatterRequirements(magSnapshot({
    slot = 1, name = "gregtech:gt.metaitem.01", damage = 100 + index, size = 1
  }, 50, 51), fakeDatabase, 9))
  equal(requirements[1].name, "plasma." .. material, "MagMatter GT candidate " .. material)
  equal(requirements[1].amount, 144, "MagMatter minimum difference")
  equal(requirements[2].amount, 50, "temporal fluid retained")
  equal(requirements[3].amount, 51, "spatial fluid retained")
end

for material, expected in pairs(gtppExpected) do
  local requirements = assert(api.buildMagmatterRequirements(magSnapshot({
    slot = 1, name = "miscutils:itemDust" .. material, damage = 0, size = 1
  }, 1, 100), fakeDatabase, 9))
  equal(requirements[1].name, expected, "MagMatter GT++ candidate " .. material)
  equal(requirements[1].amount, 99 * 144, "MagMatter maximum difference")
end

local invalid, invalidReason = api.buildMagmatterRequirements({
  items = { { slot = 1, name = "miscutils:itemDustHypogen", size = 1, damage = 0 } },
  fluids = { { slot = 1, name = "water", amount = 1 }, { slot = 2, name = "lava", amount = 2 } }
}, fakeDatabase, 9)
equal(invalid, nil, "wrong mode rejected")
truthy(invalidReason:match("时间流体"), "wrong mode error should mention temporal/spatial fluids")

local wrongCount, wrongCountReason = api.buildQuarkRequirements({ items = {}, fluids = {} }, fakeDatabase, 9)
equal(wrongCount, nil, "quark hint count rejected")
truthy(wrongCountReason:match("7"), "quark hint count reason")

local wrongDustCount, wrongDustCountReason = api.buildMagmatterRequirements(magSnapshot({
  slot = 1, name = "miscutils:itemDustHypogen", damage = 0, size = 2
}, 1, 2), fakeDatabase, 9)
equal(wrongDustCount, nil, "MagMatter dust count rejected")
truthy(wrongDustCountReason:match("数量"), "MagMatter dust count reason")

local wrongDelta, wrongDeltaReason = api.buildMagmatterRequirements(magSnapshot({
  slot = 1, name = "miscutils:itemDustHypogen", damage = 0, size = 1
}, 2, 2), fakeDatabase, 9)
equal(wrongDelta, nil, "MagMatter non-positive delta rejected")
truthy(wrongDeltaReason:match("大于"), "MagMatter delta reason")

local safeNbt = pcall(api.universalCellNbt, 'plasma.bad"name')
equal(safeNbt, false, "unsafe fluid name rejected before NBT generation")

truthy(api.allTasksExecuted({ { state = "executed" }, { state = "executed" } }, 2),
  "all executed accepted")
equal(api.allTasksExecuted({ { state = "executed" }, { state = "partially executed" } }, 2), false,
  "partial submit rejected")
equal(api.allTasksExecuted({ { state = "executed" } }, 2), false, "missing task result rejected")

local signatureA = api.snapshotSignature({
  items = { { slot = 2, name = "b", damage = 0, size = 1 }, { slot = 1, name = "a", damage = 0, size = 1 } },
  fluids = {}
})
local signatureB = api.snapshotSignature({
  items = { { slot = 1, name = "a", damage = 0, size = 1 }, { slot = 2, name = "b", damage = 0, size = 1 } },
  fluids = {}
})
equal(signatureA, signatureB, "stable signature ignores traversal order")

print(string.format("exotic_iohub_common_test: %d assertions passed", passed))
