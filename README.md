# AniTV

AniTV 是 tvOS 平台的 Bangumi 第三方客户端。除了支持管理 Bangumi 追番与观看记录以外，还支持在线自定义数据源、局域网本地媒体服务器（WebDAV / Emby / Jellyfin）、开源多平台弹幕、OP/ED 智能跳过与 Apple TV 顶部展示栏（Top Shelf），让你在 Apple TV 上获得完整的追番与大屏播放体验。

> 本仓库基于 [moyuwangP/AniTV](https://github.com/moyuwangP/AniTV) 二次开发维护。

## 屏幕截图

<table>
  <tr>
    <td><img alt="首页" src="Screenshots/Home.png"></td>
    <td><img alt="时间线" src="Screenshots/Schedule.png"></td>
    <td><img alt="收藏" src="Screenshots/Collection.png"></td>
  </tr>
  <tr>
    <td><img alt="继续观看" src="Screenshots/Continue.png"></td>
    <td><img alt="番剧详情" src="Screenshots/Anime Detail.png"></td>
    <td><img alt="播放器" src="Screenshots/Player.png"></td>
  </tr>
</table>

## 功能特性

- **首页与追番管理**：热门番剧轮播、「继续观看」进度同步、Bangumi 收藏状态管理（在看 / 想看 / 看过 / 搁置 / 抛弃）与局域网扫码登录。
- **排行榜与多维筛选**：内置 Bangumi 动画排行榜，支持按 **时间 / 分类 / 来源 / 类型 / 地区 / 受众** 六大维度组合筛选，以及 **排名 / 评分 / 热度** 排序与分页浏览。
- **番剧搜索与详情**：支持番剧关键词及 BGM ID 直达搜索；详情页支持分集剧照、角色与声优、制作人员列表（顶部对齐防头部裁剪）与番剧吐槽箱。
- **高性能时间线**：按周展示前后 15 天放送时间表，采用懒加载、后台解析与封面降采样，流畅无卡顿。
- **增强型播放器**：
  - 支持多线路换源（毛玻璃悬浮选源面板、默认视频源与简中线路优先排序）、本地进度断点续播与「接下来」快速选集。
  - **片头/片尾跳过**：优先接入 AniSkip 精准 OP/ED 区间，未命中时提供安全兜底跳过提示与每部番剧自定义片头记忆。
  - **开源弹幕源（`huangxd-/danmu_api`）**：无需商业版弹弹 play 密钥，支持在设置中配置自建 `danmu_api` 地址与 Token、一键测试连接与记住弹幕开关/显示区域。
- **本地媒体源**：支持添加并直连局域网 WebDAV（如 Alist / NAS）、Emby 与 Jellyfin 媒体库。
- **Apple TV Top Shelf 与分层图标**：支持桌面顶部栏展示「继续播放」（含观看进度条）与「推荐的项目」，点击直达详情、按播放键直达续播，并配备 tvOS 3D 视差分层应用图标。

## Road Map

- [x] 番剧目录
- [x] 番剧时间表（含滚动性能优化）
- [x] 动画排行榜（时间 / 分类 / 来源 / 类型 / 地区 / 受众筛选）
- [x] 视频播放器（含 AniSkip + 兜底跳过 OP/ED、换源面板与断点续播）
- [x] 自定义视频源（默认源与简中优先排序）
- [x] 收藏列表
- [x] 历史记录
- [x] 番剧弹幕（已切换为开源 `huangxd-/danmu_api`）
- [x] 用户设置
- [x] 番剧搜索
- [x] 本地媒体源（WebDAV / Emby / Jellyfin）
- [x] 番剧吐槽
- [x] 番剧演职员查看
- [x] Apple TV Top Shelf（「继续播放」与「推荐的项目」）与 3D 分层应用图标

## 使用与安装

通过本项目 [Releases](https://github.com/TDHXNP/AniTV/releases) 下载未签名 IPA，并使用侧载工具重签安装到 Apple TV：

- [atvloadly](https://github.com/bitxeno/atvloadly)
- [Sideloadly](https://sideloadly.io/index.html)

### 弹幕与 Top Shelf 提示

1. **弹幕服务**：可在 **设置 → 播放器与弹幕 → 弹幕服务 (danmu_api)** 中配置你自部署的 [huangxd-/danmu_api](https://github.com/huangxd-/danmu_api) 地址与 Token，并点击「测试连接」验证。
2. **Top Shelf**：将 AniTV 放在 Apple TV 桌面第一行即可在顶部栏查看「继续播放」与「推荐的项目」；自签安装时建议同时重签内嵌扩展 `PlugIns/AniTVTopShelf.appex` 并为主 App 与扩展配置相同的 App Group。

### GitHub Actions 自动编译与发布

仓库已配置 [release.yml](.github/workflows/release.yml) 工作流：

- **自动发布**：推送 `v*` 格式标签（例如 `git tag v0.2.2 && git push origin v0.2.2`）将自动编译未签名 tvOS Release IPA、生成 SHA-256 校验文件并创建 GitHub Release。
- **手动触发**：可在 GitHub 仓库的 **Actions → Release tvOS IPA → Run workflow** 中手动触发构建（支持仅导出 Artifact 或直接发布 Release）。
- **密钥注入（可选）**：在仓库 **Settings → Secrets and variables → Actions** 中配置以下 Secrets（未配置亦可正常编译）：
  - `BANGUMI_OAUTH_CLIENT_ID`
  - `BANGUMI_OAUTH_CLIENT_SECRET`
  - `TMDB_API_KEY`
  - （或直接上传 base64 编码的 `SECRETS_PLIST_BASE64`）

## 致谢

- [[AniTV Upstream]](https://github.com/moyuwangP/AniTV) 原项目作者与基础架构
- [[Animeko]](https://github.com/open-ani/animeko) 开源追番平台，为本项目提供灵感
- [[danmu_api]](https://github.com/huangxd-/danmu_api) 开源多平台弹幕 API 实现
- [[AniSkip]](https://api.aniskip.com/) 提供动漫 OP/ED 区间数据
- [[bangumi-data]](https://github.com/bangumi-data/bangumi-data) 番组数据索引
- [[bangumi-api]](https://github.com/bangumi/api) Bangumi 官方接口
- [[TMDB]](https://www.themoviedb.org/) 提供高质量 Backdrop 与剧集剧照
- [[AniList]](https://anilist.co/) 提供准确的节目时间表

## 免责

- 本项目所有数据信息均来自各种公开网站与第三方接口，不提供任何形式的媒体下载、直接播放和修改功能
- 本项目承诺不保存任何第三方用户信息
- 本项目代码仅供学习交流，不得用于商业用途，若侵权请联系
