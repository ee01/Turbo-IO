# 雷鸟 iO 眼镜导航 · 开发者使用教程

**当前实测环境：官方 iOS 雷鸟 AI App 1.0.5（Build 201）+ Strix OS 1.0.4.12，非越狱 iPhone Air。** App 版本和眼镜固件版本是两回事；1.0.4/1.0.2 是历史适配，不是本次使用的 App。

2026-09-22：手机导航后台生命周期已修复，实时路线按授权启用后台定位；模拟最多25秒短时后台测试。同源私用 iPhone Air 版收到初步正常反馈。**长期后台与公开版各显示通道仍待专项验收，旧字幕通道有独立前台保护；实验性、有风险，不用于行车决策。** 详见[后台导航设置与验收边界](NAVIGATION_BACKGROUND.md)。

这是 V2 官方 App 扩展的可选模块，不是 V1 独立客户端功能。本项目仅供开发者非商业研究，沿用根目录 PolyForm Noncommercial 许可；不提供已合并/预签名 IPA、签名证书、个人账号或 API Key。可用仓库 [原厂1.0.5（201）砸壳IPA](https://github.com/Turbo1123/Turbo-IO/releases/tag/rayneo-ios-1.0.5-201) 作为合并输入，它不含 Turbo IO 扩展。

**先选路线，不要混用两套显示方式：**

- **普通构建 / 原厂固件**：高德手机导航 + 原厂字幕模板；本页第2—5节的默认命令和“开启眼镜字幕显示”属于这条路线，仍有模拟/前台保护。
- **TNV1 实验固件 / 独立导航应用**：最新的应用级眼镜导航，手机发语义数据，眼镜 LVGL 本地画箭头与路线示意图，可从首页主动开启。需匹配的 **1.0.5（201）** 专用构建与高风险研究固件；请按 [TNV1 构建](../../../firmware-research/strix-1.0.4.12/native-navigation/BUILD.md) 和[升级/导航使用流程](../../../firmware-research/strix-1.0.4.12/native-navigation/USAGE.md) 操作，按钮是“开启眼镜原生导航”。**不要按普通构建命令编译后期待出现 TNV1。** Turbo Display 是传图测试工具，不是导航应用。

下面先介绍两条路线共享的地图能力，再说明普通字幕构建。

## 1. 能做什么，以及不能做什么

| 内容 | 当前实现 / 验证边界 |
| --- | --- |
| 手机地图与地点 | 高德关键词搜索（城市可选）、最近12个选择、单击/长按选点、中心选点、加减缩放、主动定位 |
| 路线 | 步行、骑行、驾车分别使用对应高德引擎；全览、分段详情、模拟/实时切换；先规划后开始，改起终点或出行方式使旧路线失效 |
| 普通构建镜片文字 | 高德模拟回调 → 转向/距离/道路/剩余信息 → 眼镜内置字幕UI；不是地图图片或屏幕镜像 |
| 普通字幕常亮 | 私用前身字幕驻留约2分钟获反馈，免操作官方字幕的导航显示获确认；不是无限常亮保证 |
| 普通字幕使用保护 | 首帧等待新会话ACK，3.2秒节流且只保留最新内容；4分钟/80帧上限，15秒数据断流停止；离开前台停止 |
| 本次交互修复 | 显式搜索、取消、城市变更作废旧查询、单击选点、真实缩放、固定模拟起点通过本机/模拟器检查；在线POI和真机手感仍需验收 |
| 实际出行 | 手机实时导航已接入后台定位（需权限与宿主location模式，匹配TNV1私用版已有用户反馈，长期运行待验）；**眼镜字幕只开放模拟，不开放真实出行指引，更不是安全导航设备** |

不要边开车边测试，不以实验镜片文字替代道路观察或成熟导航产品。地图及搜索依赖网络；本项目不提供离线地图、导航TTS接管或路线轨迹存储。锁屏持续GPS已接入配置但仍需真机验收，不能视为稳定可用保证。

## 2. 兼容性与高德依赖

- **当前官方 App：iOS 雷鸟 AI 眼镜 1.0.5 / Build 201**。普通扩展保留1.0.4（195）、1.0.2（67）的历史适配；**TNV1实验OTA仅适配1.0.5（201）**。精确二进制约束见[V2构建说明](../README.md#1-兼容性门槛)。未知版本不要跳过检查。
- **当前固件：Strix OS 1.0.4.12**。原厂升级后用户反馈正常，TNV1的固定AP修改版另有导航及后台实测反馈。见[1.0.5适配说明](COMPATIBILITY_105.md)和[TNV1验收边界](../../../firmware-research/strix-1.0.4.12/native-navigation/README.md)。早期协议研究基于1.0.3.15，1.0.4.8为历史升级验证。每次重新生成SID并等待眼镜ACK，不能外推全部模式/固件。
- Navi **11.2.100**（含地图），Foundation **1.9.1**（非IDFA包），Search **9.8.1**。使用静态库构建进扩展；不能再把相同SDK作为第二套动态库重复注入宿主。
- 官方来源：[导航SDK下载](https://developer.amap.com/api/ios-navi-sdk/download)、[地图/搜索SDK下载](https://lbs.amap.com/api/ios-sdk/download)。使用前阅读并遵循其许可、隐私及服务要求。本仓库不再分发这些SDK二进制。

在仓库根目录：

```sh
# 阅读官方条款后，显式同意下载固定依赖。不需要输入Key。
node official-addon/setup-amap.mjs --accept-sdk-terms

# 编译有真实高德地图的arm64扩展
TIO_AMAP_ENABLED=1 bash official-addon/build.sh embedded
```

输出 `official-addon/build/navigation/TurboIOPrivateAddon.dylib`。SDK保存在被Git忽略的 `official-addon/build/amap-sdk`，不得提交build目录。

获取脚本校验两份官方压缩包SHA256并展开指定子包，遇到下载链接更新导致哈希不一致就停止，不静默换SDK。已下载的同一批压缩包可放入绝对目录并追加 `--archives-dir /absolute/downloads`，文件名需为 `AMap_iOS_Navi_ALL.zip` 与 `search-9.8.1.zip`。离线导入同样校验哈希；已存在的SDK目录不覆盖。

默认 `bash official-addon/build.sh embedded` 不链接高德；适合基础扩展或零密钥预览，页面会明确提示缺SDK，不会伪造地图和搜索结果。

## 3. 在自己电脑合并、签名

先准备有权使用且符合[V2技术门槛](../README.md#1-兼容性门槛)的原始 `Runner.app` 和自己的签名材料。工具不下载应用、不解密、不绕过登录/付费限制。不要拿上一次带个人配置的私用包当公开输入。

```sh
node official-addon/package.mjs \
  --app /absolute/authorized/Payload/Runner.app \
  --addon /absolute/Turbo-IO/official-addon/build/navigation/TurboIOPrivateAddon.dylib \
  --amap-sdk-root /absolute/Turbo-IO/official-addon/build/amap-sdk \
  --profile /absolute/private/development.mobileprovision \
  --identity YOUR_CERTIFICATE_SHA1 \
  --device YOUR_DEVICE_ID \
  --out /absolute/private/new-navigation-output

xcrun devicectl device install app --device YOUR_DEVICE_ID \
  /absolute/private/new-navigation-output/Payload/Runner.app
```

`--amap-sdk-root` 将 `AMap.bundle`、`AMapNavi.bundle`、`AMapSearch.bundle` 复制到输出App，缺失/符号链接/已有同名资源会停止，避免混版本；必要时添加前台定位用途说明。Navi/Foundation/Search代码已静态链接进扩展，不复制framework到发布仓库。**导航构建不可漏掉这个参数，否则资源可能缺失。**

输入原App不修改；输出目录必须不存在。签名、IPA仅在本机生成，项目不上传也不提供这些产物。安装成功与App可启动、账号/蓝牙可用、镜片正确显示是分开的验收步骤。

## 4. 填自己的高德Key

1. 在高德控制台创建 **iOS平台Key**，绑定实际应用 Bundle ID；本适配目标为 `com.rayneo.venus.pub`。Web服务Key/TinyFish Key不能替代iOS Key。
2. 根据自己账号开通所需地图、搜索及导航服务；服务权限/额度由高德管理。
3. App内进入 **TurboIO → 资料 → 步行 / 骑行 / 驾车导航 → 右上角更多 → 高德 Key 设置**，粘贴自己的Key。
4. Key只存本机钥匙串，不回显旧值。源码、打包清单和日志都不写入Key。安装包里若有与当前 Bundle ID 匹配的 `TIOAMapPrivate.json`，首次打开导航页且钥匙串为空时会写入钥匙串；公开仓库不提供该文件。要换Key时先重启App，在初始化地图前修改。
5. 点击“开启地图”并阅读隐私说明后决定是否同意。拒绝时不初始化地图SDK。主动点“我的位置”或实时导航才请求定位；模拟不必使用真实位置。

## 5. 第一次运行建议用模拟

1. 在雷鸟App首页确认眼镜正常连接，结束录音、提词、字幕、智记和对话。V2在同一宿主内工作，不需要另开V1；不要为使用导航反复解绑。
2. 进入导航，先选择 **步行 / 骑行 / 驾车**，保留 **模拟验收**。点“去哪里？”输入地点、可选城市，再点 **搜索地点** 或键盘搜索。仅输入不会每字上传查询；搜索中可点取消。
3. 选择搜索结果，或在地图**单击**选择终点。拖动地图后点“将地图中心设为终点”也可以。
4. 模拟起点与终点独立。初始北京起点有明确标签；要测试其他地方，切换 **选模拟起点** 后点地图，或点“我的位置”使用本次手机位置。搜索/拖图不会自动改变起点。
5. 右侧 **＋ / －** 负责缩放，中央准星本身不是按钮。地图可拖动，单击/长按按当前角色选点。
6. 点 **规划路线**，核对所选出行方式的路线、距离和时间，再点 **开始模拟**。右上角更多有公开的北京演示路线，便于不使用私人位置验收。
7. 手机出现实时指引后，点 **开启眼镜字幕显示**，确认镜片首页无其他任务。等待新的会话ACK后开始发字。
8. 正常支持版本不必每次先去官方“实时字幕→预览→退出”。只恢复版式/配置，不恢复过期SID或假装蓝牙已连接。
9. **停止眼镜显示**保留手机模拟；**结束导航**停止本次任务。退出回执不明确时保留不确定状态；镜片没关闭可用实体按钮退出，不连续叠加会话。

修改已规划但尚未开始的起终点或出行方式会清掉旧路线，须重新规划。真正导航过程中先停止再更换目的地。字幕4分钟保护并非故障，不用自动重开循环规避保护。

### 三种方式的实现差异与验收边界

- 步行：`AMapNaviWalkManager`，起终点为坐标数组。
- 骑行：`AMapNaviRideManager`，起终点为单个坐标；不是复用步行算路。
- 驾车：`AMapNaviDriveManager`，当前使用单路线默认策略（0），不提供多路线选择、避收费/货车参数。
- 三种方式各有“固定模拟起点”和“手机当前位置”两个算路入口。SDK 拒绝或服务权限不足时明确失败，不悄悄退回步行。
- 高德引擎存在单例互斥要求；切换时仅释放本扩展拥有的旧引擎，不强行停止宿主其他导航。释放未完成会提示稍后再规划。
- 算路/导航中不能切模式，先结束；仅已规划未开始的路线可直接切换并重新规划。
- 公交和独立电动车模式尚未实现。骑行不能被当作电动车/摩托车法规适配。
- **本次新增模式已通过六接口参数 mock、UIKit 模式切换和真机架构编译，未完成骑行/驾车在线路线及眼镜实测。** 不用源码可编译替代真实验收，欢迎提交脱敏测试结果。

## 6. 常见问题

| 现象 | 检查 |
| --- | --- |
| 输入文字没结果 | 点“搜索地点”或键盘搜索；观察加载、无结果、错误码。城市填写后是城市限定查询 |
| 搜索失败但地图能加载 | 搜索服务权限、网络、Key绑定可能与地图不同；按错误码查，不认为地图能看就全部鉴权成功 |
| 提示离线预览/未链接SDK | 重新使用 `TIO_AMAP_ENABLED=1` 构建并带上资源参数；填Key不能补齐二进制依赖 |
| 起终点不足30米 | 重新选择起点或终点。只拖地图不会改变固定起点 |
| 眼镜显示按钮不可用 | 先开始真实高德模拟，等待新鲜导航回调；停止其他显示任务。不是实时导航模式，也不是离线夹具 |
| 显示仍要求格式/连接 | 首页确认当前连接；默认仅匹配支持版本。未知格式在更多的字幕检查中重新学习；不要重用旧会话 |
| 约4分钟后停止/离开前台停止 | 当前实验保护。户外/后台长运行尚未完成，不承诺始终常亮 |
| 重签安装但打不开 | 检查解锁、开发者模式、证书/描述文件、系统提示；不要靠清空唯一原App恢复 |

可查看本机 `Documents/TurboIOResearch/navigation/search.json` 的阶段、错误码、结果数量；它不包含搜索词/坐标/Key。不要提交完整App沙盒、账号日志或私人录音。

## 7. 架构与扩展点

```text
高德SDK：搜索 / Walk、Ride、Drive算路及导航回调
                 ↓
NavigationModes：选择正确引擎和参数，导航页面归一三种回调
                 ↓
NavigationCore：转向、距离、道路等统一文字状态
                 ↓
NavigationSubtitleHUD：最新帧、限频、断流/超时保护
                 ↓
SubtitleHUD + ProtocolContext：当前设备、新SID、ACK门槛
                 ↓
官方通信通道 → 雷鸟 iO 内置字幕页面
```

`NavigationWorkspace.inc`/`NavigationPlacePicker.m`负责手机交互，`NavigationTransport.m`保留通知与专用仪表盘卡备用通道，`NavigationTeleHUD.m`保留手动提词备用方案。通知和卡片会熄屏，提词器换稿有loading，不应当成无缝常亮主方案。

这是业务内容与受限组件协议研究，不是HTML、Canvas、像素截图或替换系统桌面。后续优先研究三种出行方式的真实场景安全验收、生命周期、长时间后台和异常恢复，而非先取消保护计时。

## 8. 无Key测试

<img src="navigation-search.png" width="280" alt="无账号无Key的模拟器搜索页：显式搜索与取消反馈，不是真实联网结果" />

上图是公开源码的UIKit模拟器截图，使用公开测试词演示取消状态，不是眼镜截图或真实搜索结果。

```sh
bash official-addon/test.sh
node --test official-addon/macho-embed.test.mjs official-addon/package.test.mjs official-addon/amap-resources.test.mjs
bash official-addon/preview/build.sh
xcrun simctl install booted official-addon/build/research-preview/ResearchPreview.app
xcrun simctl launch --terminate-running-process booted io.turboio.research.preview --navigation --navigation-modes-check --navigation-workspace-check
xcrun simctl launch --terminate-running-process booted io.turboio.research.preview --navigation --navigation-interaction-check
```

模拟器不联网、不链接高德，不把模拟器页面当镜片截图；测试结果也不代表真实地图服务可用。公开源码保留个人资料默认留空和模型/搜索Key自行配置，不内置维护者服务。
