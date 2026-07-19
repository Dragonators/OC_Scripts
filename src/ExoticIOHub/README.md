# 磁物质与简并夸克胶子等离子体：ME 接口 + 转运器方案

适用版本：GTNH 2.8.4、Programmable Hatches `0.1.3p57`、OpenComputers
`1.11.20-GTNH`。磁物质与简并夸克胶子继续使用两个独立入口，共用状态机、GUI、
中文液滴名、AE 合成与故障恢复模块。

本版完整恢复 Wiki OC 脚本的核心硬件路径：进阶存储输入仓作为提示物缓存和机器配方
输入，ME 二合一接口动态输出流体，转运器负责识别、回送和精确搬运。物质聚合器不
恢复；所有物品与流体提示物都经 ME 接口返回主网。IO Hub 和九重输入仓均不再需要。

目录名和部分 Lua 文件名保留 `ExoticIOHub`/`exotic_iohub_common.lua`，只是为了让
旧安装命令与 `/home` 入口继续兼容；运行逻辑已经不使用 IO Hub。

## 安装与运行

在装有 Internet Card 的 OpenOS 电脑上运行：

```sh
wget -f https://raw.githubusercontent.com/Dragonators/OC_Scripts/exotic-iohub-v8/src/ExoticIOHub/install.lua /tmp/exotic-install.lua
lua /tmp/exotic-install.lua /home
```

安装器把全部文件放在 `/home`，配置固定从 `/home/exotic_quark.cfg` 和
`/home/exotic_magmatter.cfg` 读取。配置完成后的最短启动命令：

```sh
quark
magmatter
```

升级时会保留已有配置。由 v7 或更早版本升级后，必须补上
`interfaceAddress`、`transposerAddress`、`interfaceSide`，并把
`inputHatchSide` 改成“从转运器看向进阶存储输入仓”的方向；旧的
`ioHubAddress` 会被忽略。

## 硬件拓扑

```text
机器物品输出总线 ──物品管道──┐
机器流体输出仓   ──流体管道──┼──> [ 进阶存储输入仓 ] ──机器结构输入位
                              │             ▲
                              └──────[ 转运器 ]
                                           │
                                           ▼
主网 AE ──频道──> [ ME 二合一接口 ] <──适配器/OC 网络──> OC 服务器
```

转运器必须同时贴住进阶存储输入仓和方块式 ME 二合一接口。两个方向都从转运器
视角填写：

- `inputHatchSide`：转运器 → 进阶存储输入仓。
- `interfaceSide`：转运器 → ME 二合一接口。

ME 二合一接口必须连接主网 AE 并取得频道，同时通过适配器加入 OC 网络。脚本要求
同一个 `me_interface` 组件同时暴露 `setFluidInterfaceConfiguration`、
`getFluidsInNetwork`、`getCraftables` 和 `getCpus`。普通 ME 接口没有前一个流体回调。

不再需要 IO Hub、九重输入仓、`DualInputHachOC`、物质聚合器或外部大型缓存。
Wiki 图中用于传递频道的 ME 仓室仍可按原布局保留；它不受脚本直接控制。

## 配置

地址前缀来自 `components -l`。同类组件多于一个时必须填写足以唯一匹配的前缀。

```lua
local sides = require("sides")
return {
  interfaceAddress = "ME二合一接口地址前缀",
  transposerAddress = "转运器地址前缀",
  interfaceSide = sides.down,
  inputHatchSide = sides.east,
  databaseAddress = "c97bd88e",
  gtMachineAddress = "2c8acdee"
}
```

其余常用参数：

- `pollInterval`：主循环间隔，默认 `0.2` 秒。
- `recycleQuietSeconds`：整批提示物回送后的静默确认，默认 `1` 秒。
- `interfaceFillTimeout`：等待 ME 接口补入当前流体的超时，默认 `15` 秒。
- `craftTimeout`：单次 AE 合成超时，默认 `600` 秒。
- `dispatchTimeout`：全部流体发配后等待机器开机的超时，默认 `30` 秒。
- `recipeTimeout`：机器运行超时，默认 `900` 秒。
- `cpuName`：可选专用合成 CPU 名；留空表示不限定。

## 工作流程

```text
自检 → 等待进阶存储输入仓中的提示物 → 稳定采样 → 解析需求
     → 全部提示物经转运器送回 ME 接口/AE → 补充合成 → 库存复核
     → ME 接口逐种供液 → 转运器精确注入同一输入仓
     → 等待开机 → 等待完成
```

每种需求流体的供液过程：

1. 在数据库写入对应的 AE2FC 流体液滴。
2. 调用 `setFluidInterfaceConfiguration(0, database, slot)` 标记接口第一个流体槽。
3. 等待接口从主网补入该流体。
4. 调用 `transferFluid(interfaceSide, inputHatchSide, amount, 0)`；超过接口缓存时循环搬运。
5. 清除接口配置，等待未使用余量自动返回 AE，再处理下一种流体。

机器不会被脚本锁住；全部原料满足后自行识别配方。OpenComputers 当前默认转运器
流体速率为 `16000 L/s`，组件回调会按实际搬运量产生相应暂停。

## 两种模式

简并夸克胶子模式要求总计 7 种提示物：

- 流体提示转换为对应等离子体，需求量为提示量 × `1000 L`。
- 粉末提示转换为对应等离子体，需求量为物品数 × `1296 L`。
- 兼容 GregTech、GT++、BartWorks/Lanth 映射。

磁物质模式只接受一个粉末、时间流体和空间流体：

- 等离子体需求为 `(空间流体量 - 时间流体量) × 144 L`。
- 三种提示物先全部回到 AE。
- 时间流体、空间流体和目标等离子体随后进入同一个进阶存储输入仓。

## 故障恢复

- 启动时如果输入仓内容能构成当前模式的完整提示物，脚本会正常接管。
- 启动时存在非本模式残留：锁定，不自动抽走。
- 接口等待超时、转运器部分传输或装载中断：先清除接口配置，再把输入仓中本轮
  已知流体经转运器送入 ME 接口，直接返回 AE。
- 输入仓出现本轮之外的流体：拒绝自动回收，保留现场。
- 机器已经启动：不抽取、不打断，只等待完成。
- `Space` 暂停/继续，`R` 安全恢复/回送，`Q` 或 `Esc` 退出。

## 上机自检

```lua
local component = require("component")
for address in component.list("me_interface", true) do
  local m = component.methods(address)
  if m.setFluidInterfaceConfiguration and m.getCraftables then print("ME", address) end
end
for address in component.list("transposer", true) do print("TP", address) end
```

若找不到同时具有流体配置和 AE 网络回调的 `me_interface`，通常是适配器贴错方块、
接口未连入 OC/AE 网络，或拿成了普通 ME 接口。

## 离线测试

```powershell
npx -y --package fengari-node-cli fengari tests/ExoticIOHub/exotic_iohub_common_test.lua
npx -y --package fengari-node-cli fengari tests/ExoticIOHub/exotic_runtime_smoke_test.lua
npx -y --package fengari-node-cli fengari tests/ExoticIOHub/install_smoke_test.lua
```

模拟测试覆盖两种完整配方、×1000/×1296/×144 换算、整批提示物回送、超过
16000 L 的接口重复补液、接口余量回网、部分转运、退款失败、脏启动、AE 断线、
合成超时、运行超时和两种 GUI 分辨率。
