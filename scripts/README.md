# 项目脚本

从仓库根目录执行。Swift 工具建议使用完整 Xcode：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## 构建与发布

- `package_dmg.sh`：构建 release 应用、收集 libmpv/ffmpeg/ffprobe 及动态库、签名、校验后发布 `dist/MediaLib.dmg`。终端的 `APP=` 是临时应用路径，不是 `dist` 下的长期产物。使用 `MEDIALIB_PACKAGE_INSTANCE` 隔离构建目录，发布仍由同一把锁串行保护。
- `check_bundle_runtime.sh <app> <架构>`：按入口可执行文件和 `LC_RPATH` 链检查应用架构与动态库闭包；打包自动调用，也可独立运行。
- `check_bundle_launch.sh <app>`：在清除本机 DYLD 覆盖后执行包内 Server、ffmpeg、ffprobe，并让 MediaLIB 主程序实际加载 bundled libmpv；在签名后及只读镜像挂载后运行。
- `publish_verified_dmg.sh`：打包内部的候选镜像发布助手。
- `release_metadata.py --check`：检查 `config/release.json` 与生成版本信息；修改版本后运行 `release_metadata.py --write` 同步生成文件。
- `check_dependency_inventory.py`：签名后生成并校验运行时文件哈希；对暂存 App、镜像布局和只读挂载产物逐文件验证。
- `generate_build_manifest.swift`：生成 DMG 根目录的构建清单；清单与依赖 inventory 放在已签名 App 外，避免修改 App 资源造成签名/哈希循环。
- `generate_dmg_background.swift`、`write_dmg_ds_store.py`、`vendor/`：生成安装镜像布局，由打包脚本调用。
- `generate_icon.swift`：手动从 `Resources/AppIconSource.png` 生成图标。打包使用已有图标，不自动改写源资源。

打包不依赖 `doc`、系统页面 HTML 或视觉参考件。默认进行本地签名；具体签名与公证状态以本次实际验证为准。

## 检查与诊断

- `check_cargon2_vendor.sh`、`check_swift_conflict_copies.sh`：供应源码完整性与 Swift 重复文件检查，CI 使用。
- `generate_media_matrix.sh`：生成媒体测试样本；需要 ffmpeg。
- `run_web_playback_acceptance.sh --browser <chromium|webkit> --viewport <宽>x<高> --out-dir <目录>`：从零准备隔离样本库和服务实例，使用口令文件运行浏览器播放验收，只输出可上传的 JSON、样本 manifest 与 ffmpeg 版本。输出目录必须为空，防止上传旧的未脱敏文件。若普通 `.build/repositories` 存在，会只预置 bare 依赖仓库，不复用编译产物。
- `web_playback_baseline.mjs`：Web 播放基线测试，参数见脚本开头示例。
- `debug_title_icons.sh [输出目录]`：构建并运行原生标题图标诊断，默认写入 `/private/tmp/MediaLib-title-icons`。
- `shelf_shot.sh [文件名.png] [调试参数...]`、`shelf_winid.swift`：运行调试窗口并截图，需要图形桌面与屏幕录制权限。只关闭本次启动的进程；日志目录由终端输出。
- `probe_music_player_rss.sh [持续秒数] [间隔秒数]`：采样 MediaLib 与 WindowServer RSS；适用于只运行一个 MediaLib 实例的观察，不代表泄漏诊断。
- `setup_lan_https_proxy.sh --help`：生成可选反向代理配置与本地证书，不启动服务或修改系统设置。
- `test_support/`：脚本测试替身，不是应用运行时依赖。

日常运行使用 `swift run MediaLib`；无需先制作 DMG。已移除依赖缺失参考 HTML 的字符串检查、旧 DOCX 生成器、重复截图脚本、全局杀进程的启动包装和未使用的证书初始化脚本。

浏览器验收依赖由根目录 `package.json` / `package-lock.json` 固定；CI 使用 Node 22.23.2 和 Playwright 1.63.0。`node_modules` 仅为开发/CI 工具，不属于产品运行时或安装包。
