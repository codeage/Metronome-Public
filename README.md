# ByteReset Metronome

SwiftUI 工程支持 iOS 17 及以上，使用 Swift 6 严格并发检查。新安装默认 120 BPM、4/4，已有安装继续使用保存的设置。BPM 以拍号分母所代表的音符为一拍。标准速度范围为 30–250 BPM，专业模式为 20–300 BPM；自定义拍号默认最多 16 拍，扩展后最多 32 拍，分母支持 2、4、8、16、32、64。

## 操作

- 拖动圆环或用加减键调速。加减键可长按，点按测速连续点 3–4 次。外接键盘在主屏按空格开始或停止。
- 点拍号打开十个预设及自定义选择器。点拍点在强音、次强音、弱音、静音之间循环。
- 设置中可调整混音、音量、声道平衡和输出延迟，开启渐快训练、间歇静音、拍点闪烁或在支持的设备上使用触觉。
- 人声音色使用系统中文语音生成并缓存数字。缓存未就绪或系统语音不可用时，对应拍点用木鱼声。
- 曲目预设保存速度、拍号、细分、每拍重音和音色。载入需要专业速度或扩展拍号的曲目时，会启用所需范围。

## 音频与显示

`MetronomeRenderer.c` 按采样帧累加拍点位置，在拍点处理细分、训练和间歇静音。主线程通过无锁原子快照更新参数，`AVAudioSourceNode` 的实时回调不生成波形资源、不访问文件，也不调度 UI 或触觉。

`CADisplayLink` 用音频拍点的主机时钟更新画面。系统输出延迟加手动毫秒补偿用于对齐视觉和触觉提示。触觉在支持的设备上随前台拍点播放。切到后台时释放防息屏状态并暂停显示更新，背景音频继续使用采样时钟。

### 机械和木鱼的普通拍试听

同一份源码可以构建两版。默认构建为 A 版，普通拍系数为 0.57，沿用原衰减。B 版普通拍系数为 0.50，只延长机械和木鱼普通拍的衰减。构建 B 版时，在下方的 Release 命令中用不同的 `-derivedDataPath`，并在 `build` 前加入 `GCC_PREPROCESSOR_DEFINITIONS='$(inherited) METRONOME_COMPARE_LONGER_CLICK=1'`。

两版使用同一 App 标识，可以在同一台 iPhone 上先后覆盖安装。记录同一首曲目、系统音量和 App 滑块，分别边弹钢琴边听。再用 300 BPM 十六分音符检查铃声与短鼓的尾音，并确认关闭首拍加重后第一拍只响「嗒」。

## Siri 和灵动岛

首次打开 App 后，可以直接跟 Siri 说使用 App 名称启动、停止节拍器，或设置速度和拍号。速度可以回答每分钟多少拍，拍号可以回答「四四拍」等常用拍号。两个设置动作分别修改自己的参数。

快捷指令可通过下面的 URL 动作启动、停止或调整节拍器。省略的参数沿用当前设置，`accent` 使用 1 或 0，`subdivision` 兼容原来的 1–4 等分。

- 启动 `bytereset-metronome://start`
- 停止 `bytereset-metronome://stop`
- 以 80 BPM、3/4、二等分和首拍重音播放 `bytereset-metronome://start?bpm=80&beats=3&unit=4&subdivision=2&accent=1`
- 只调整参数 `bytereset-metronome://settings?bpm=72&beats=6&unit=8`

播放时，灵动岛与锁屏显示速度和拍号。长按灵动岛可展开查看细分和首拍重音。停止后关闭实时活动。

## 构建与验证

使用带 Swift 6 编译器的 Xcode。编译 Release 应用与灵动岛扩展：

```sh
xcodebuild -project PianoMetronome.xcodeproj -scheme PianoMetronome \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/xcode-device CODE_SIGNING_ALLOWED=NO build
```

共享 Scheme 也可在 iOS 模拟器运行 XCTest。先用 `xcrun simctl list devices available` 查出当前可用的设备名。

```sh
xcodebuild -project PianoMetronome.xcodeproj -scheme PianoMetronome \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

在 macOS 运行可重复的核心逻辑检查，直接执行与应用相同的 C 渲染器和 Swift 状态模型：

```sh
mkdir -p build/core-checks
xcrun clang -std=c11 -Wall -Wextra -Werror -O2 \
  -c PianoMetronome/MetronomeRenderer.c -o build/core-checks/renderer.o
xcrun swiftc -swift-version 6 -strict-concurrency=complete -O \
  -import-objc-header PianoMetronome/Metronome-Bridging-Header.h \
  PianoMetronome/BeatSettings.swift Tests/MetronomeCoreChecks.swift \
  build/core-checks/renderer.o -o build/core-checks/metronome-checks
build/core-checks/metronome-checks
```

核心检查覆盖默认值、旧设置迁移、预设编解码、点按测速、采样帧误差、播放中变速、渐快、静音小节和声道平衡。设备验收还需要检查扬声器和蓝牙延迟、音频中断与恢复、后台播放、触觉、VoiceOver、键盘焦点以及 iPhone 横屏和 iPad 布局。

在 GitHub Actions 手动运行 Build Metronome for iOS 可下载未签名的 IPA。装机测试和 TestFlight 上传需要在本地使用自己的 Apple 开发者团队签名。
