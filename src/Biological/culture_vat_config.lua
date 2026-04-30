-- 将本文件复制到 OpenOS 电脑，例如：
--   /etc/culture_vat_config.lua
--
-- 结构建议：
--   1. 一个 Adapter 接 ME 控制器或 ME 接口，用于读取 AE 网络物品/流体数量。
--   2. 电脑安装 Programmable Hatches 的 GT Redstone Card，用它直接读写 GT 无线红石频率。
--      每个机器组的 frequency 绑定无线控制覆盖版，用来开关一批培养缸。
--   3. 每台培养缸安装设备活跃探测无线覆盖版，把“机器正在工序中”的状态发到 GT 无线红石频率。
--   4. 每个放射仓旁放一个转运器，转运器一侧接放射仓，一侧接 AE 接口/箱子缓冲放射材料。
--
-- 样板模式：
--   group.pattern 指向 ME 接口里的编码处理样板。
--   程序读取样板第一个输出作为产物流体匹配目标。
--   程序读取样板最后一个输入；如果数量为 64，则视为放射仓材料，否则视为普通输入。
--   普通输入会作为原料门控：AE 中同名物品或同名流体数量足够，才允许启动/投放放射材料。
--
-- 注意：当前 OC 的样板转换器只能从样板中读到“显示名”和数量，所以样板推导依赖显示名匹配。
-- 首次部署时建议先运行 components -l，并观察程序 status 里的 product/radio 是否与 AE 显示名一致。

local sides = require("sides")

return {
  intervals = {
    product = 20, -- AE 产物流体阈值检测间隔，越大越省性能
    machine = 5,  -- 机器活跃信号与放射仓投料/回收检测间隔
    pattern = 60, -- 重新读取样板间隔；换样板后最多等待这个时间生效
    status = 10,  -- 状态输出间隔；设为 false 可关闭
    loop = 1
  },

  ae = {
    -- ME 控制器或 ME 接口组件地址前缀；nil 表示自动寻找唯一的 me_controller/me_interface。
    address = nil,
    preferredTypes = {"me_controller", "me_interface"}
  },

  defaults = {
    thresholds = {
      upper = 1000000, -- AE 中样板产物流体达到或超过该数量后停机；nil 表示不自动停机
      lower = 250000   -- AE 中样板产物流体达到或低于该数量后开机；nil 表示不自动开机
    },

    -- 原料门控需要的样板批次数。
    -- "machines" 表示按组内机器数量放大样板输入需求；也可以改成 1 或其他数字。
    inputBatches = "machines",

    -- 机器组控制信号。
    -- gt_wireless 使用 Programmable Hatches 的 gtredstone 组件：
    --   setWireless(frequency, signal, isPublic)
    -- 这会直接写入 GT 无线红石频率，适合无线控制覆盖版。
    -- gtredstone 组件通常唯一，不需要填写 address。
    control = {
      mode = "gt_wireless",
      frequency = nil,
      isPublic = true,
      on = 15,
      off = 0,
      inverted = false
    },

    -- 默认机器活跃探测信号。
    -- 通常在每个 group.active 中填写频率；只有需要单机覆盖时才写 machine.active。
    active = {
      mode = "gt_wireless",
      frequency = nil,
      isPublic = true,
      threshold = 0,
      inverted = false
    },

    hatch = {
      targetCount = 1,     -- 机器运行时放射仓内保持的目标数量
      removeOnStop = true, -- 机器关闭、不活跃或原料不足时是否把匹配材料移回 sourceSide
      sourceMin = 1,       -- sourceSide 至少有这么多才向放射仓投料
      exclusive = true     -- true 时，投料前会尝试清理放射仓内不匹配物品
    },

    work = {
      startGrace = 30,    -- 发出开机信号或重试投料后，允许机器在这段时间内变为活跃
      retryInterval = 60  -- 机器未活跃时，每隔多久重新短暂投放一次放射材料尝试启动
    }
  },

  -- 放射仓资源定义。
  -- transposer/sourceSide/hatchSide 是物理布线；放射材料名称由组样板最后一个 64 输入自动推导。
  hatches = {
    radio_a = {
      transposer = "CHANGE_ME_TP_A",
      sourceSide = sides.west,
      hatchSide = sides.east
    },
    radio_b = {
      transposer = "CHANGE_ME_TP_B",
      sourceSide = sides.west,
      hatchSide = sides.east
    }
  },

  groups = {
    {
      name = "vat_group_1",

      pattern = {
        address = "CHANGE_ME_INTERFACE", -- 放着编码处理样板的 ME 接口地址前缀
        slot = 1,
        outputIndex = 1 -- 默认使用第一个输出作为产物流体
      },

      thresholds = {
        upper = 1000000,
        lower = 250000
      },

      -- GT 无线红石频率：绑定这一组培养缸的无线控制覆盖版。
      control = {
        mode = "gt_wireless",
        frequency = 1234,
        isPublic = true,
        inverted = false
      },

      -- 组级活跃探测频率：绑定这一组培养缸的设备活跃探测无线覆盖版。
      -- 程序默认用这个信号判断组内机器是否正在工序中。
      active = {
        frequency = 2234,
        isPublic = true,
        threshold = 0,
        inverted = false
      },

      -- 如果一组有 N 台机器并且 group.hatches 也写了 N 个，默认按顺序一一对应。
      -- 如果多个机器共用同一个放射仓，可以让多个机器写同一个 hatch，或把 group.hatches 写成单个共享项。
      hatches = {"radio_a", "radio_b"},

      machines = {
        {
          name = "vat_1"
        },
        {
          name = "vat_2"
        }
      },

      -- true 时，如果组已开机但样板普通输入不足，会同时关闭组控制信号。
      -- false 时，只停止向放射仓投料，等待原料恢复后继续尝试。
      forceOffOnUnsafe = false
    }
  }
}
