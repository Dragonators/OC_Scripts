-- Transactional installer for the Forge of Gods Exotic IO Hub automation.
-- The payload is pinned to an immutable Git tag.

local component = require("component")
local filesystem = require("filesystem")
local internet = require("internet")
local shell = require("shell")

local releaseTag = "exotic-iohub-v5"
local baseUrl = "https://raw.githubusercontent.com/Dragonators/OC_Scripts/"
    .. releaseTag .. "/src/ExoticIOHub/"
local targetRoot = shell.resolve((...) or "/home")
local stageRoot = filesystem.concat(targetRoot, ".exotic-iohub-install-stage")
local rollbackRoot = filesystem.concat(targetRoot, ".exotic-iohub-install-rollback")
local rollbackMarker = filesystem.concat(rollbackRoot, "ACTIVE")

local files = {
    { source = "exotic_iohub_common.lua", target = "exotic_iohub_common.lua", lua = true },
    { source = "exotic_zh_cn.lua", target = "exotic_zh_cn.lua", lua = true },
    { source = "exotic_quark_iohub.lua", target = "exotic_quark_iohub.lua", lua = true },
    { source = "exotic_magmatter_iohub.lua", target = "exotic_magmatter_iohub.lua", lua = true },
    { source = "quark.lua", target = "quark.lua", lua = true },
    { source = "magmatter.lua", target = "magmatter.lua", lua = true },
    { source = "exotic_quark.cfg", target = "exotic_quark.cfg", config = true, preserve = true },
    { source = "exotic_magmatter.cfg", target = "exotic_magmatter.cfg", config = true, preserve = true },
    { source = "README.md", target = "EXOTIC_IOHUB.md" },
    { source = "install.lua", target = "exotic_iohub_install.lua", lua = true }
}

local function ensureDirectory(path)
    if filesystem.exists(path) then
        if not filesystem.isDirectory(path) then
            error(path .. " 已存在但不是目录")
        end
        return
    end
    local ok, reason = filesystem.makeDirectory(path)
    if not ok then error("无法创建目录 " .. path .. "：" .. tostring(reason)) end
end

local function removeTree(path)
    if not filesystem.exists(path) then return end
    if filesystem.isDirectory(path) then
        local iterator, reason = filesystem.list(path)
        if not iterator then error("无法读取目录 " .. path .. "：" .. tostring(reason)) end
        for name in iterator do removeTree(filesystem.concat(path, name)) end
    end
    local ok, reason = filesystem.remove(path)
    if not ok then error("无法删除 " .. path .. "：" .. tostring(reason)) end
end

local function finishOutput(file, path)
    local flushed, flushError = file:flush()
    if not flushed then
        pcall(function() file:close() end)
        error("刷新 " .. path .. " 失败：" .. tostring(flushError))
    end
    local closed, closeError = pcall(function() file:close() end)
    if not closed then error("关闭 " .. path .. " 失败：" .. tostring(closeError)) end
end

local function copyChecked(sourcePath, targetPath)
    local input, inputError = io.open(sourcePath, "rb")
    if not input then error("无法读取 " .. sourcePath .. "：" .. tostring(inputError)) end
    local output, outputError = io.open(targetPath, "wb")
    if not output then
        input:close()
        error("无法写入 " .. targetPath .. "：" .. tostring(outputError))
    end

    local copied, copyError = pcall(function()
        while true do
            local chunk, readError = input:read(8192)
            if chunk == nil then
                if readError then error(readError) end
                break
            end
            local written, writeError = output:write(chunk)
            if not written then error(writeError or "unknown write error") end
        end
        finishOutput(output, targetPath)
        output = nil
        input:close()
        input = nil
    end)

    if output then output:close() end
    if input then input:close() end
    if not copied then
        filesystem.remove(targetPath)
        error("复制 " .. sourcePath .. " 失败：" .. tostring(copyError))
    end
end

local function download(relativePath, targetPath)
    local tempPath = targetPath .. ".download"
    if filesystem.exists(tempPath) then removeTree(tempPath) end

    local requestOk, response = pcall(internet.request, baseUrl .. relativePath)
    if not requestOk then error("下载 " .. relativePath .. " 失败：" .. tostring(response)) end

    local output, openError = io.open(tempPath, "wb")
    if not output then error("无法写入 " .. tempPath .. "：" .. tostring(openError)) end
    local streamed, streamError = pcall(function()
        for chunk in response do
            local written, writeError = output:write(chunk)
            if not written then error(writeError or "unknown write error") end
        end
        finishOutput(output, tempPath)
        output = nil
    end)

    if output then output:close() end
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
        error("无法暂存 " .. relativePath .. "：" .. tostring(renameError))
    end
end

local function readAll(path)
    local input, reason = io.open(path, "rb")
    if not input then error("无法读取 " .. path .. "：" .. tostring(reason)) end
    local content, readError = input:read("*a")
    input:close()
    if content == nil then error("读取 " .. path .. " 失败：" .. tostring(readError)) end
    return content
end

local function validateConfig(path)
    local content = readAll(path)
    local chunk, loadError = load(content, "@" .. path, "t", _G)
    if not chunk then error(path .. " 语法错误：" .. tostring(loadError)) end
    local ok, config = pcall(chunk)
    if not ok then error(path .. " 执行失败：" .. tostring(config)) end
    if type(config) ~= "table" then error(path .. " 没有返回配置表") end
end

local function validateStage()
    for _, spec in ipairs(files) do
        local path = filesystem.concat(stageRoot, spec.target)
        if not filesystem.exists(path) or filesystem.size(path) <= 0 then
            error("暂存文件缺失或为空：" .. spec.target)
        end
        if spec.config then
            validateConfig(path)
        elseif spec.lua then
            local chunk, loadError = load(readAll(path), "@" .. spec.target, "t", _G)
            if not chunk then error(spec.target .. " 语法错误：" .. tostring(loadError)) end
        end
    end
end

local function backupCurrentFiles()
    removeTree(rollbackRoot)
    ensureDirectory(rollbackRoot)
    for _, spec in ipairs(files) do
        local currentPath = filesystem.concat(targetRoot, spec.target)
        if filesystem.exists(currentPath) then
            if filesystem.isDirectory(currentPath) then error("目标路径不是文件：" .. currentPath) end
            copyChecked(currentPath, filesystem.concat(rollbackRoot, spec.target))
        end
    end
    local marker = assert(io.open(rollbackMarker, "wb"))
    marker:write("Exotic IO Hub install in progress\n")
    finishOutput(marker, rollbackMarker)
end

local function restoreRollback()
    local errors = {}
    for _, spec in ipairs(files) do
        local currentPath = filesystem.concat(targetRoot, spec.target)
        local backupPath = filesystem.concat(rollbackRoot, spec.target)
        local restored, restoreError = pcall(function()
            if filesystem.exists(currentPath) then removeTree(currentPath) end
            if filesystem.exists(backupPath) then copyChecked(backupPath, currentPath) end
        end)
        if not restored then errors[#errors + 1] = tostring(restoreError) end
    end
    return errors
end

local function clearTemporaryState()
    removeTree(rollbackRoot)
    removeTree(stageRoot)
end

local function recoverInterruptedInstall()
    if filesystem.exists(rollbackMarker) then
        print("检测到未完成的上次安装，正在恢复旧文件...")
        local errors = restoreRollback()
        if #errors > 0 then error(table.concat(errors, "\n")) end
    end
    clearTemporaryState()
end

local function promoteStage()
    backupCurrentFiles()
    local promoted, promoteError = pcall(function()
        for _, spec in ipairs(files) do
            local stagedPath = filesystem.concat(stageRoot, spec.target)
            local targetPath = filesystem.concat(targetRoot, spec.target)
            if filesystem.exists(targetPath) then removeTree(targetPath) end
            local renamed, renameError = filesystem.rename(stagedPath, targetPath)
            if not renamed then error("无法启用 " .. spec.target .. "：" .. tostring(renameError)) end
        end
    end)

    if not promoted then
        local rollbackErrors = restoreRollback()
        local message = "安装失败，已尝试恢复旧文件：" .. tostring(promoteError)
        if #rollbackErrors > 0 then message = message .. "\n" .. table.concat(rollbackErrors, "\n") end
        error(message)
    end
    clearTemporaryState()
end

local function main()
    ensureDirectory(targetRoot)
    recoverInterruptedInstall()

    if not component.isAvailable("internet") then error("需要 Internet Card") end
    if not component.internet.isHttpEnabled() then error("服务器已禁用 Internet Card 的 HTTP 请求") end

    ensureDirectory(stageRoot)
    print("从版本 " .. releaseTag .. " 安装到：" .. targetRoot)
    for _, spec in ipairs(files) do
        local currentPath = filesystem.concat(targetRoot, spec.target)
        local stagedPath = filesystem.concat(stageRoot, spec.target)
        if spec.preserve and filesystem.exists(currentPath) then
            io.write("保留现有 " .. spec.target .. " ... ")
            copyChecked(currentPath, stagedPath)
            print("完成")
        else
            io.write("下载 " .. spec.source .. " ... ")
            download(spec.source, stagedPath)
            print("完成")
        end
    end

    validateStage()
    promoteStage()

    package.loaded.exotic_iohub_common = nil
    package.loaded.exotic_zh_cn = nil
    print("")
    print("诸神之锻炉 IO Hub 自动化安装完成。")
    print("首次使用请编辑：")
    print("  edit " .. filesystem.concat(targetRoot, "exotic_quark.cfg"))
    print("  edit " .. filesystem.concat(targetRoot, "exotic_magmatter.cfg"))
    print("运行：")
    print("  cd " .. targetRoot)
    print("  quark")
    print("  magmatter")
end

local ok, reason = pcall(main)
if not ok then
    io.stderr:write("安装失败：" .. tostring(reason) .. "\n")
    os.exit(1)
end
