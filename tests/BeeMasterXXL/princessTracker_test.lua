local sourceRoot = arg[1] or "src/BeeMasterXXL"
package.path = sourceRoot .. "/?.lua;" .. package.path

local bot = {
    inventory = {},
    inventoryLabel = "purify:current"
}

function bot.getItemsWithLabel(label)
    local result = {}
    for slot, item in pairs(bot.inventory) do
        if item.inventoryLabel == label then
            table.insert(result, slot)
        end
    end
    table.sort(result)
    return result
end

package.loaded.bot = bot
local princessTracker = require("princessTracker")

local function princess(tag, label)
    return {type = "beePrincess", tag = tag, inventoryLabel = label}
end

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual))
    end
end

-- A foreign princess may be relabelled by inventory_changed while the current
-- breeding cycle runs. It must be restored and ignored as a daughter.
bot.inventory = {
    [1] = princess("parent", "purify:current"),
    [2] = princess("foreign", nil)
}
local nextSlot = princessTracker.nextGeneration(1, function()
    bot.inventory[1] = nil
    bot.inventory[2].inventoryLabel = "purify:current"
    bot.inventory[3] = princess("daughter", "purify:current")
end, "test: ")
assertEqual(nextSlot, 3, "foreign princess was selected")
assertEqual(bot.inventory[2].inventoryLabel, nil, "foreign princess label was not restored")

-- A foreign princess left with the same label by an earlier cycle is still
-- excluded by its saved slot and NBT tag identity.
bot.inventory = {
    [1] = princess("parent", "purify:current"),
    [2] = princess("foreign", "purify:current")
}
nextSlot = princessTracker.nextGeneration(1, function()
    bot.inventory[1] = nil
    bot.inventory[3] = princess("daughter", "purify:current")
end, "test: ")
assertEqual(nextSlot, 3, "previously labelled foreign princess was selected")

-- Restore unrelated labels even when the breeding device reports an error.
bot.inventory = {
    [1] = princess("parent", "purify:current"),
    [2] = princess("foreign", "foreign:original")
}
local breedOk, breedError = pcall(function()
    princessTracker.nextGeneration(1, function()
        bot.inventory[2].inventoryLabel = "purify:current"
        error("device failed")
    end, "test: ")
end)
assertEqual(breedOk, false, "breeding error was swallowed")
assert(string.find(breedError, "device failed", 1, true))
assertEqual(bot.inventory[2].inventoryLabel, "foreign:original",
    "foreign princess label was not restored after an error")

-- A real duplicate daughter remains an error.
bot.inventory = {
    [1] = princess("parent", "purify:current")
}
local duplicateOk, duplicateError = pcall(function()
    princessTracker.nextGeneration(1, function()
        bot.inventory[1] = nil
        bot.inventory[3] = princess("daughter-a", "purify:current")
        bot.inventory[4] = princess("daughter-b", "purify:current")
    end, "test: ")
end)
assertEqual(duplicateOk, false, "duplicate daughters were accepted")
assert(string.find(duplicateError, "两只本次谱系的公主蜂", 1, true))

-- Missing daughter remains an error.
bot.inventory = {
    [1] = princess("parent", "purify:current")
}
local missingOk, missingError = pcall(function()
    princessTracker.nextGeneration(1, function()
        bot.inventory[1] = nil
    end, "test: ")
end)
assertEqual(missingOk, false, "missing daughter was accepted")
assert(string.find(missingError, "未找到本次谱系的公主蜂", 1, true))

print("princessTracker regression tests passed")
