-- Transactional BeeMasterXXL fixed installer for OpenOS.
-- Release payload is pinned to an immutable Git tag.

local component = require("component")
local filesystem = require("filesystem")
local internet = require("internet")
local shell = require("shell")

local releaseTag = "beemasterxxl-fixed-v4"
local baseUrl = "https://raw.githubusercontent.com/Dragonators/OC_Scripts/"
    .. releaseTag .. "/src/BeeMasterXXL/"
local targetRoot = shell.resolve((...) or "/home")
local stageRoot = filesystem.concat(targetRoot, ".beemaster-install-stage")
local rollbackRoot = filesystem.concat(targetRoot, ".beemaster-install-rollback")
local rollbackMarker = filesystem.concat(rollbackRoot, "ACTIVE")

local files = {
    "analyzeGenes.lua",
    "apiary.lua",
    "bee.lua",
    "beeData.lua",
    "biomes.lua",
    "bot.lua",
    "config.lua",
    "device.lua",
    "doUntil.lua",
    "environment.lua",
    "install.lua",
    "installer.lua",
    "mutations.lua",
    "princessTracker.lua",
    "strategy.lua",
    "tools.lua",
    "lib/inflate-bit32.lua",
    "lib/inflate-bwo.lua",
    "lib/nbt.lua",
    "lib/zzlib.lua",
    "readme.md"
}

local function ensureDirectory(path)
    if filesystem.exists(path) then
        if not filesystem.isDirectory(path) then
            error(path .. " 已存在但不是目录")
        end
        return
    end
    local ok, reason = filesystem.makeDirectory(path)
    if not ok then
        error("无法创建目录 " .. path .. "：" .. tostring(reason))
    end
end

local function removeTree(path)
    if not filesystem.exists(path) then
        return
    end
    if filesystem.isDirectory(path) then
        local iterator, reason = filesystem.list(path)
        if not iterator then
            error("无法读取目录 " .. path .. "：" .. tostring(reason))
        end
        for name in iterator do
            removeTree(filesystem.concat(path, name))
        end
    end
    local ok, reason = filesystem.remove(path)
    if not ok then
        error("无法删除 " .. path .. "：" .. tostring(reason))
    end
end

local function closeInput(file, path)
    -- OpenOS filesystem.close() returns no value on success. Only a thrown
    -- component error indicates failure.
    local ok, reason = pcall(function()
        file:close()
    end)
    if not ok then
        error("关闭 " .. path .. " 失败：" .. tostring(reason))
    end
end

local function finishOutput(file, path)
    local flushed, flushError = file:flush()
    if not flushed then
        pcall(function()
            file:close()
        end)
        error("刷新 " .. path .. " 失败：" .. tostring(flushError))
    end
    local closed, closeError = pcall(function()
        file:close()
    end)
    if not closed then
        error("关闭 " .. path .. " 失败：" .. tostring(closeError))
    end
end

local function writeAllChecked(path, content)
    local output, reason = io.open(path, "wb")
    if not output then
        error("无法写入 " .. path .. "：" .. tostring(reason))
    end
    local written, writeError = output:write(content)
    if not written then
        output:close()
        filesystem.remove(path)
        error("写入 " .. path .. " 失败：" .. tostring(writeError))
    end
    local ok, finishError = pcall(finishOutput, output, path)
    if not ok then
        filesystem.remove(path)
        error(finishError)
    end
end

local function readAllChecked(path)
    local input, reason = io.open(path, "rb")
    if not input then
        error("无法读取 " .. path .. "：" .. tostring(reason))
    end
    local content, readError = input:read("*a")
    if content == nil then
        input:close()
        error("读取 " .. path .. " 失败：" .. tostring(readError))
    end
    closeInput(input, path)
    return content
end

local function copyChecked(sourcePath, targetPath)
    local input, inputError = io.open(sourcePath, "rb")
    if not input then
        error("无法读取 " .. sourcePath .. "：" .. tostring(inputError))
    end
    local output, outputError = io.open(targetPath, "wb")
    if not output then
        input:close()
        error("无法写入 " .. targetPath .. "：" .. tostring(outputError))
    end

    local copied, copyError = pcall(function()
        while true do
            local chunk, readError = input:read(8192)
            if chunk == nil then
                if readError then
                    error(readError)
                end
                break
            end
            local written, writeError = output:write(chunk)
            if not written then
                error(writeError or "unknown write error")
            end
        end
        finishOutput(output, targetPath)
        output = nil
        closeInput(input, sourcePath)
        input = nil
    end)

    if output then
        output:close()
    end
    if input then
        input:close()
    end
    if not copied then
        filesystem.remove(targetPath)
        error("复制 " .. sourcePath .. " 失败：" .. tostring(copyError))
    end
end

local function download(relativePath, targetPath)
    local tempPath = targetPath .. ".download"
    if filesystem.exists(tempPath) then
        removeTree(tempPath)
    end

    local requestOk, response = pcall(internet.request, baseUrl .. relativePath)
    if not requestOk then
        error("下载 " .. relativePath .. " 失败：" .. tostring(response))
    end

    local output, openError = io.open(tempPath, "wb")
    if not output then
        error("无法写入 " .. tempPath .. "：" .. tostring(openError))
    end

    local streamed, streamError = pcall(function()
        for chunk in response do
            local written, writeError = output:write(chunk)
            if not written then
                error(writeError or "unknown write error")
            end
        end
        finishOutput(output, tempPath)
        output = nil
    end)

    if output then
        output:close()
    end
    if not streamed then
        filesystem.remove(tempPath)
        error("读取 " .. relativePath .. " 失败：" .. tostring(streamError))
    end
    if not filesystem.exists(tempPath) or filesystem.size(tempPath) <= 0 then
        filesystem.remove(tempPath)
        error(relativePath .. " 下载结果为空")
    end

    local renamed, renameError = filesystem.rename(tempPath, targetPath)
    if not renamed then
        filesystem.remove(tempPath)
        error("无法完成 " .. relativePath .. " 的暂存：" .. tostring(renameError))
    end
end

local function loadConfig(content, sourceName)
    local chunk, loadError = load(content, "@" .. sourceName, "t", _G)
    if not chunk then
        error(sourceName .. " 语法错误：" .. tostring(loadError))
    end
    local ok, config = pcall(chunk)
    if not ok then
        error(sourceName .. " 执行失败：" .. tostring(config))
    end
    if type(config) ~= "table" then
        error(sourceName .. " 没有返回配置表")
    end
    return config
end

local function prepareExistingConfig(sourcePath, stagedPath)
    local original = readAllChecked(sourcePath)
    local config = loadConfig(original, sourcePath)
    local staged = original

    if config.worldAccelerator_mode ~= "fixed" then
        staged = table.concat({
            "-- BeeMasterXXL installer wrapper: preserve existing settings and force fixed WA mode.",
            "local config = (function()",
            original,
            "end)()",
            "config.worldAccelerator_mode = \"fixed\"",
            "return config",
            ""
        }, "\n")
    end

    writeAllChecked(stagedPath, staged)
    local verified = loadConfig(readAllChecked(stagedPath), stagedPath)
    if verified.worldAccelerator_mode ~= "fixed" then
        error("无法保证config.lua使用fixed世界加速器模式")
    end
end

local function validateStagedFiles()
    local version = tonumber((_VERSION or ""):match("Lua (%d+%.%d+)")) or 5.2
    for _, relativePath in ipairs(files) do
        local path = filesystem.concat(stageRoot, relativePath)
        if not filesystem.exists(path) or filesystem.size(path) <= 0 then
            error("暂存文件缺失或为空：" .. relativePath)
        end

        if relativePath == "config.lua" then
            local config = loadConfig(readAllChecked(path), relativePath)
            if config.worldAccelerator_mode ~= "fixed" then
                error("暂存config.lua没有启用fixed模式")
            end
        elseif relativePath:sub(-4) == ".lua"
            and not (relativePath == "lib/inflate-bwo.lua" and version < 5.3) then
            local content = readAllChecked(path)
            local chunk, loadError = load(content, "@" .. relativePath, "t", _G)
            if not chunk then
                error(relativePath .. " 语法错误：" .. tostring(loadError))
            end
        end
    end
end

local function createHumanConfigBackup(configPath)
    if not filesystem.exists(configPath) then
        return nil
    end
    local backupPath = configPath .. ".before-fixed-wa.bak"
    if filesystem.exists(backupPath) then
        return backupPath
    end
    local tempPath = backupPath .. ".new"
    copyChecked(configPath, tempPath)
    local renamed, reason = filesystem.rename(tempPath, backupPath)
    if not renamed then
        filesystem.remove(tempPath)
        error("无法保存config.lua人工备份：" .. tostring(reason))
    end
    return backupPath
end

local function backupCurrentFiles()
    removeTree(rollbackRoot)
    ensureDirectory(rollbackRoot)
    ensureDirectory(filesystem.concat(rollbackRoot, "lib"))

    for _, relativePath in ipairs(files) do
        local currentPath = filesystem.concat(targetRoot, relativePath)
        if filesystem.exists(currentPath) then
            if filesystem.isDirectory(currentPath) then
                error("目标路径不是文件：" .. currentPath)
            end
            copyChecked(currentPath, filesystem.concat(rollbackRoot, relativePath))
        end
    end
    writeAllChecked(rollbackMarker, "BeeMasterXXL install in progress\n")
end

local function restoreRollback()
    local errors = {}
    for _, relativePath in ipairs(files) do
        local currentPath = filesystem.concat(targetRoot, relativePath)
        local backupPath = filesystem.concat(rollbackRoot, relativePath)
        local restorePath = currentPath .. ".restore"

        local restored, restoreError = pcall(function()
            if filesystem.exists(restorePath) then
                removeTree(restorePath)
            end

            if filesystem.exists(backupPath) then
                --始终复制，保留rollback中的完整备份，使恢复可重复执行。
                copyChecked(backupPath, restorePath)
                if filesystem.exists(currentPath) then
                    local removed, removeError = filesystem.remove(currentPath)
                    if not removed then
                        error("无法删除当前文件：" .. tostring(removeError))
                    end
                end
                local renamed, renameError = filesystem.rename(restorePath, currentPath)
                if not renamed then
                    error("无法启用恢复文件：" .. tostring(renameError))
                end
            elseif filesystem.exists(currentPath) then
                --没有备份表示安装前不存在该文件。
                local removed, removeError = filesystem.remove(currentPath)
                if not removed then
                    error("无法删除新增文件：" .. tostring(removeError))
                end
            end
        end)
        if not restored then
            table.insert(errors, "恢复 " .. currentPath .. " 失败：" .. tostring(restoreError))
        end
    end
    return errors
end

local function clearRollbackState()
    if filesystem.exists(rollbackMarker) then
        local removed, reason = filesystem.remove(rollbackMarker)
        if not removed then
            error("无法清除回滚标记：" .. tostring(reason))
        end
    end
    removeTree(rollbackRoot)
    removeTree(stageRoot)
end

local function recoverInterruptedInstall()
    if filesystem.exists(rollbackMarker) then
        print("检测到未完成的上次安装，正在恢复旧文件...")
        local errors = restoreRollback()
        if #errors > 0 then
            error(table.concat(errors, "\n"))
        end
        clearRollbackState()
        return
    end
    removeTree(rollbackRoot)
    removeTree(stageRoot)
end

local function promoteStagedFiles()
    backupCurrentFiles()

    local promoted, promoteError = pcall(function()
        for _, relativePath in ipairs(files) do
            local stagedPath = filesystem.concat(stageRoot, relativePath)
            local targetPath = filesystem.concat(targetRoot, relativePath)
            if filesystem.exists(targetPath) then
                local removed, removeError = filesystem.remove(targetPath)
                if not removed then
                    error("无法替换 " .. targetPath .. "：" .. tostring(removeError))
                end
            end
            local renamed, renameError = filesystem.rename(stagedPath, targetPath)
            if not renamed then
                error("无法启用 " .. targetPath .. "：" .. tostring(renameError))
            end
        end
    end)

    if not promoted then
        local rollbackErrors = restoreRollback()
        local message = "安装替换失败，已尝试恢复旧文件：" .. tostring(promoteError)
        if #rollbackErrors > 0 then
            message = message .. "\n回滚错误：\n" .. table.concat(rollbackErrors, "\n")
        else
            local cleaned, cleanupError = pcall(clearRollbackState)
            if not cleaned then
                message = message .. "\n旧文件已恢复，但回滚状态清理失败：" .. tostring(cleanupError)
            end
        end
        error(message)
    end

    local markerRemoved, markerError = filesystem.remove(rollbackMarker)
    if not markerRemoved then
        local rollbackErrors = restoreRollback()
        local message = "无法提交安装状态，已尝试回滚：" .. tostring(markerError)
        if #rollbackErrors > 0 then
            message = message .. "\n回滚错误：\n" .. table.concat(rollbackErrors, "\n")
        else
            local cleaned, cleanupError = pcall(clearRollbackState)
            if not cleaned then
                message = message .. "\n旧文件已恢复，但回滚状态清理失败：" .. tostring(cleanupError)
            end
        end
        error(message)
    end
    local cleaned, cleanupError = pcall(function()
        removeTree(rollbackRoot)
        removeTree(stageRoot)
    end)
    if not cleaned then
        io.stderr:write("警告：安装已提交，但临时目录清理失败；下次运行会重试："
            .. tostring(cleanupError) .. "\n")
    end
end

local function main()
    ensureDirectory(targetRoot)
    ensureDirectory(filesystem.concat(targetRoot, "lib"))
    recoverInterruptedInstall()

    if not component.isAvailable("internet") then
        error("需要Internet Card")
    end
    if not component.internet.isHttpEnabled() then
        error("服务器已禁用Internet Card的HTTP请求")
    end

    ensureDirectory(stageRoot)
    ensureDirectory(filesystem.concat(stageRoot, "lib"))

    local configPath = filesystem.concat(targetRoot, "config.lua")
    print("从版本 " .. releaseTag .. " 安装到：" .. targetRoot)
    for _, relativePath in ipairs(files) do
        local stagedPath = filesystem.concat(stageRoot, relativePath)
        if relativePath == "config.lua" and filesystem.exists(configPath) then
            io.write("保留并校验现有config.lua ... ")
            prepareExistingConfig(configPath, stagedPath)
            print("完成")
        else
            io.write("下载 " .. relativePath .. " ... ")
            download(relativePath, stagedPath)
            print("完成")
        end
    end

    validateStagedFiles()
    local humanBackup = createHumanConfigBackup(configPath)
    promoteStagedFiles()

    print("")
    print("BeeMasterXXL修改版安装完成。")
    if humanBackup then
        print("原配置备份：" .. humanBackup)
    end
    print("运行：")
    print("  cd " .. targetRoot)
    print("  bee")
end

local ok, reason = pcall(main)
if not ok then
    io.stderr:write("安装失败：" .. tostring(reason) .. "\n")
    os.exit(1)
end
