-- Track the daughter princess produced by one breeding cycle without confusing
-- other princesses that are already present in the robot inventory.

local bot = require("bot")

local M = {}

local function isSamePrincess(snapshot, item)
    return snapshot and item and item.type == "beePrincess" and snapshot.tag == item.tag
end

function M.nextGeneration(princessSlot, breed, errorPrefix)
    local lineageLabel = bot.inventoryLabel
    local unrelatedPrincesses = {}

    for slot, item in pairs(bot.inventory) do
        if slot ~= princessSlot and item.type == "beePrincess" then
            unrelatedPrincesses[slot] = {
                tag = item.tag,
                inventoryLabel = item.inventoryLabel
            }
        end
    end

    local bred, breedError = pcall(breed)

    -- inventory_changed uses the current global label. A princess unrelated to
    -- this breeding cycle can therefore be relabelled while another slot is
    -- being processed. Restore its previous label before finding the daughter.
    for slot, snapshot in pairs(unrelatedPrincesses) do
        local item = bot.inventory[slot]
        if isSamePrincess(snapshot, item) then
            item.inventoryLabel = snapshot.inventoryLabel
        end
    end

    if not bred then
        error(breedError, 0)
    end

    local nextPrincessSlot
    for _, slot in pairs(bot.getItemsWithLabel(lineageLabel)) do
        local item = bot.inventory[slot]
        if item and item.type == "beePrincess"
            and not isSamePrincess(unrelatedPrincesses[slot], item) then
            if nextPrincessSlot then
                error(errorPrefix .. "出现了两只本次谱系的公主蜂")
            end
            nextPrincessSlot = slot
        end
    end

    if not nextPrincessSlot then
        error(errorPrefix .. "未找到本次谱系的公主蜂")
    end
    return nextPrincessSlot
end

return M
