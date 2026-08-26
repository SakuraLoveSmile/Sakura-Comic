# ComicApp — 平台应用壳

四个平台共享 `KomgaKit`，各自保留独立 UI / Navigation / Interaction Adapter。

当前为 Phase 0 骨架：目录占位 + XcodeGen 工程描述。
生成 Xcode 工程（需要安装 XcodeGen）：

```text
cd apple/ComicApp
xcodegen generate
```

平台目录：`iOS/` `macOS/` `tvOS/` `visionOS/`
