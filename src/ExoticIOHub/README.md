# 磁物质与简并夸克胶子等离子体：IO Hub + 九重输入仓方案

适用版本：GTNH 2.8.4、Programmable Hatches `0.1.3p57`、OpenComputers
`1.11.20-GTNH`。磁物质和简并夸克胶子仍使用两个独立入口，共用控制模块。

## 文件、配置与运行

安装器会把全部文件放入 OpenOS 的 `/home/`，配置也默认从 `/home/` 读取：

- `exotic_iohub_common.lua`：共享状态机与 GUI。
- `exotic_zh_cn.lua`：游戏中文流体名表。
- `exotic_quark_iohub.lua`、`exotic_magmatter_iohub.lua`：完整入口。
- `quark.lua`、`magmatter.lua`：最短命令入口。
- `exotic_quark.cfg`、`exotic_magmatter.cfg`：配置。

配置完成后直接运行：

```sh
quark
magmatter
```

地址必须来自 `components -l`。一个 OC 网络中存在多个同类组件时不要把地址留空。

## 硬件拓扑

```text
机器物品输出总线 ──物品管道──┐
机器流体输出仓   ──流体管道──┼──> [ IO Hub ] ──紧贴──> [ 九重输入仓 ] ──机器结构输入位
主网 AE 线       ────────────┤
OC 服务器/线缆   ────────────┘
```

- 九重输入仓必须直接贴在 IO Hub 的一个面上；`inputHatchSide` 是“从 IO Hub 看向九重仓”的方向。
- 九重输入仓是普通 GT 流体输入仓，不需要 OC 线缆或 AE 频道。
- IO Hub 同时连接主网 AE 和 OC 网络，占一个 AE 频道。
- 输出管道把提示物和最终产物送入 IO Hub 自带的 32 个物品槽、8 个流体槽。
- 不再使用 `DualInputHachOC`、进阶存储输入仓、物质聚合器、转运器、主网 ME 接口、
  合成监控器或外部大型缓存。

示例方向配置：

```lua
local sides = require("sides")
return {
  ioHubAddress = "98b2668d",
  inputHatchSide = sides.east,
  databaseAddress = "c97bd88e",
  gtMachineAddress = "2c8acdee"
}
```

脚本会确认指定方向恰好暴露 9 个流体槽；如果方向错误、没有贴住九重仓或贴到其他
流体容器，会在自检阶段给出中文错误。

## 工作流程

状态机为：

```text
自检 → 等待样板 → 回送样板 → 补充合成 → 库存复核
     → 逐种注入九重仓 → 等待开机 → 等待完成
```

提示物全部返回 AE 主网，不再销毁。IO Hub 清空提示物时会在一个状态机步骤中处理
当前全部槽位；随后只等待一次 `recycleQuietSeconds`，到期才重扫整个 IO Hub。
它不会再为了“静默 N 次”重复扫描 32+8 个槽位，因此检测与回送间隔明显缩短。

默认快速参数：

```lua
pollInterval = 0.2
craftPollInterval = 0.5
stableSamples = 1
recycleQuietSeconds = 1
```

如果机器输出提示物跨越较长时间，可以把 `recycleQuietSeconds` 调到 `2` 或 `3`；
这只增加整批提示物的收集窗口，不会给每个格子单独加延迟。

## AE 合成与九重仓注入

主网必须能合成所有可能出现的等离子体。脚本用 AE2FC 流体液滴的 `name + label`
寻找加工样板；真正取流体时，数据库槽位会生成带
`{Fluid:{FluidName,Amount=1000}}` NBT 的 `IC2:itemFluidCell` 描述。

每一种流体依次执行：

1. `requestFluids(database, slot, amount)` 从 AE 精确提取到 IO Hub 当前内部流体槽。
2. `fillRobot(inputHatchSide, amount)` 直接注入相邻九重输入仓。
3. 核对返回的实际传输量；容量不足或只传入一部分都会停止后续注入。

脚本不调用 `setWorkAllowed`。机器在逐种注入过程中保持原有工作状态，九重输入仓
满足完整配方后由 GT 机器自行识别并启动。注入完成但机器尚未消费时，脚本会按
流体名和数量复核九重仓；机器已经开始并清空输入仓时则直接进入等待完成阶段。

## 两种模式

简并夸克胶子模式要求总计 7 种提示物：

- 流体提示转换为对应等离子体，需求为提示量 × 1000 L。
- 粉末提示转换为对应等离子体，需求为物品数 × 1296 L。
- 全部提示物回到 AE，最多 7 种等离子体逐种进入九重仓。

磁物质模式只接受一个粉末、时间流体和空间流体：

- 等离子体需求为 `(空间流体量 - 时间流体量) × 144 L`。
- 粉末、时间流体和空间流体先全部回到 AE。
- 时间流体、空间流体和目标等离子体再逐种进入同一个九重输入仓。

粉末解析兼容 GregTech、GT++、BartWorks/Lanth，并优先使用运行环境返回的矿辞。
缺失样板名称优先使用中文翻译表，其次使用服务器中文 `label`，最后回退到内部流体名。

## 故障与恢复

- 启动时九重仓存在但没有本脚本周期日志：锁定故障，不自动覆盖或抽走。
- 注入中断且机器尚未启动：脚本只回收本轮已知流体。它先清空 IO Hub 本轮残留，
  再用 `drainRobot` 从九重仓抽回并通过 `sendFluids` 返回 AE。
- 九重仓出现本轮需求之外的流体：拒绝自动回收，保留现场。
- 机器启动超时：尝试把九重仓中的本轮原料完整回送 AE；回送失败时保持故障锁定。
- 机器已经启动：不抽取、不打断，只等待完成。

快捷键：

- `Space`：暂停/继续状态机，不改变机器工作许可。
- `R`：安全恢复并尝试回送本轮已知残留。
- `Q` / `Esc`：退出并保留周期日志。

## 上机自检

```lua
local component = require("component")
local io = component.proxy(component.list("iohub", true)())
for name in pairs(component.methods(io.address)) do print(name) end
```

至少应看到：`requestFluids`、`sendFluids`、`fillRobot`、`drainRobot`、
`getTankCount`、`getTankLevel`、`getTankCapacity`、`getFluidInTank`。

首次投产前确认：

- `inputHatchSide` 指向紧贴 IO Hub 的九重输入仓。
- 九重仓为空，且单槽容量大于本轮最大单种流体需求。
- 数据库至少有 9 个槽位。
- AE 流体存储有足够库存和回收空间。
- 两种模式各完成一轮，核对九重仓在开机前装满、开机后清空，AE 账目无复制或吞料。

## 离线测试

```powershell
npx -y --package fengari-node-cli fengari tests/ExoticIOHub/exotic_iohub_common_test.lua
npx -y --package fengari-node-cli fengari tests/ExoticIOHub/exotic_runtime_smoke_test.lua
```

模拟测试覆盖两种完整配方、×1000/×1296/×144 换算、延迟提示物累计、九重仓脏启动、
AE 提取失败、部分注入、自动回送失败、启动超时、运行超时、中文 GUI 和 80×25/120×35。
