# FOG 奇异模块 OC 自动化（全新重写）

本目录与仓库中既有的 `magmatter.lua`、`quark.lua`、`exotic_*` 文件完全独立；新版没有读取、调用或覆盖旧脚本。

## 适用环境

- GT New Horizons `2.8.4`
- GregTech `5.09.51.482`
- OpenComputers `1.11.20-GTNH`
- AE2 Fluid Crafting Rework `1.4.120-gtnh`
- OpenOS / Lua 5.2

脚本一台电脑控制一个模块：在配置中把 `mode` 设为 `quark`（简并夸克胶子等离子体）或 `magmatter`（磁物质）。两台模块应分别部署两份配置。

## 相邻布局

转运器必须同时贴住：

1. FOG 模块的专用缓存输入仓/输入仓；
2. 连接主 AE 网络的“二合一 ME 接口”。

二合一 ME 接口同时承担两项工作：接收整批提示物返回主网，以及按数据库液滴配置输出目标流体。**不再需要物质聚合器，也没有任何物质聚合器侧面配置。**

电脑网络中需要：转运器、数据库升级、显卡和屏幕、二合一 ME 接口；推荐再连接机器控制适配器所暴露的 `gt_machine`。数据库至少需要 8 个槽位。

## 安装

发布 `exotic-iohub-v9` 标签后，可在装有 Internet Card 的 OpenOS 电脑上直接替换 v8：

```sh
wget -f https://raw.githubusercontent.com/Dragonators/OC_Scripts/exotic-iohub-v9/src/ExoticIOHub/install.lua /tmp/fog-exotic-install.lua
lua /tmp/fog-exotic-install.lua /home
```

安装器使用暂存目录并在替换失败时回滚；已存在的新版 `fog_quark.cfg` 和
`fog_magmatter.cfg` 会被保留。旧 v8 配置不会迁移，因为两代脚本的配置结构不同。
安装完成后，原有 `quark` / `magmatter` 命令会指向全新脚本；旧 `exotic_*` 文件不再被
调用，但安装器不会擅自删除它们。

离线手动安装也可以把本目录文件放到 OpenOS：

```sh
cp fog_exotic.lua /home/fog_exotic.lua
cp fog_quark.cfg /home/fog_quark.cfg
cp fog_magmatter.cfg /home/fog_magmatter.cfg
cp quark.lua /home/quark.lua
cp magmatter.lua /home/magmatter.lua
```

确认两个 side 和组件地址前缀，然后运行：

```sh
quark
magmatter
```

可先在 OpenOS 里核对实际组件：

```lua
for address, kind in component.list() do print(address, kind) end
for name in pairs(component.methods("二合一接口地址")) do print(name) end
```

二合一接口的方法列表必须同时包含 `getCraftables` 与 `setFluidInterfaceConfiguration`。

## 新工作流

1. 等待完整提示，并连续扫描两次确认提示内容稳定。
2. 按实际 GT 代码计算目标流体：
   - 夸克：粉尘数量 × `1296 mB`；流体提示数量 × `1000 mB`。
   - 磁物质：原量取回时间/空间流体；材料等离子体为 `(空间数量 - 时间数量) × 144 mB`。
3. 清空二合一接口配置，将缓存中的**所有提示物品与提示流体作为同一批次返回主 AE 网络**。
4. 逐种配置液滴、从主网取流体；主网不足时才请求一次对应液滴样板。
5. 样板缺失时在 GUI 中显示由 GTNH `zh_CN` 语言键得到的中文名称，例如“铁等离子体液滴”，并定期重查。

脚本不会取消 AE CPU 中的任务。合成超过警戒时间时只提示并继续等待，避免误取消其他玩家或其他自动化的订单。接口残留、返网受阻或缓存无法接收时也会暂停，而不会把物料改送到其他容器。

运行期意外错误也不会让脚本把已经送入一部分的批次当成新提示：本批的“提示是否已返网”和每种流体的已送入量会保留在内存中，清理接口后从剩余量继续重试。

## 首次上线检查

- 先禁用机器，确认 GUI 显示“机器已禁用”。
- 用少量安全物品/流体确认 `cache` 和 `main` 方向没有写反。
- 启用机器并观察第一批：GUI 应依次显示“确认提示 → 整批返主网 → 补给中 → 本批完成”。
- 故意移除一个等离子体液滴样板，确认 GUI 给出正确中文液滴名称；恢复样板后应自动继续。

参考流程来自灰机 Wiki 的“基于 OC 的磁物质与夸克胶子自动化”，但状态机、返网路径、GUI、错误处理和映射均按本地安装的实际源码重新实现。
