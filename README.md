# LinkDesk

LinkDesk 是基于 RustDesk 开源协议和客户端代码演进的远程桌面产品。当前产品层统一使用
LinkDesk 名称，并增加独立的 OIDC 登录、账号设备绑定、数字设备 ID、连接票据和会员权益
控制。

## 仓库关系

```text
link-desk
  LinkDesk 客户端、被控端服务和 Flutter UI

link-desk-serve
  OIDC 登录、账号、设备、在线状态、数字 ID、连接票据和会员权益

linkdesk-rendezvous
  LinkDesk 信令和中继服务
```

完整运行链路：

```text
客户端启动
  -> OIDC 登录
  -> link-desk-serve 绑定设备并分配 9 位数字 ID
  -> 客户端保存 registration secret
  -> host 服务携带 registration secret 注册到 LinkDesk rendezvous
  -> 客户端定时 heartbeat，服务端维护在线状态

发起远控
  -> 输入目标 9 位数字 ID
  -> link-desk-serve 检查登录、在线状态和会员权益
  -> 签发一次性短期 ticket，并返回目标 rendezvous ID
  -> LinkDesk rendezvous 消费 ticket
  -> 建立直连或中继会话
```

客户端始终强制 OIDC 登录。未登录时不会绑定设备、发送 LinkDesk heartbeat、注册到
LinkDesk rendezvous 或发起远程连接。项目不提供关闭登录门禁的兼容开关。

## macOS 开发

先启动账号服务、Keycloak 和 rendezvous：

```bash
cd /Users/hui/work/WanxiangI/link-desk-serve
./scripts/start-linkdesk-dev.sh
```

再构建并启动客户端：

```bash
cd /Users/hui/work/WanxiangI/link-desk
./start-macos.sh
```

只构建不启动：

```bash
./start-macos.sh --no-run
```

本地 OIDC 测试账号由开发启动脚本创建：

```text
demo / demo123456
```

## 双客户端验证

先构建 Debug 应用，然后分别启动两个隔离配置的实例：

```bash
./scripts/run-macos-instance.sh a
./scripts/run-macos-instance.sh b
```

两个实例分别使用 `.instances/a` 和 `.instances/b`。OIDC 登录通过各自独立的
state 轮询账号服务，不注册或争抢本机自定义 URL handler。脚本默认注入
`LINKDESK_RENDEZVOUS_SERVER=127.0.0.1:22116`，可通过同名环境变量覆盖。

验证时必须确认两个客户端都完成登录、绑定和 heartbeat，然后使用其中一个客户端显示的
9 位数字 ID从另一个客户端发起连接。接口 smoke 通过不能代替真实远控画面、键鼠、文件
传输和端口转发验证。

## 测试

Flutter：

```bash
cd flutter
flutter test test
```

Rust workspace：

```bash
VCPKG_ROOT=/Users/hui/work/WanxiangI/vcpkg \
cargo test --workspace -- --test-threads=1
```

账号服务和 OIDC：

```bash
cd /Users/hui/work/WanxiangI/link-desk-serve
cargo test
LINK_DESK_BILLING_SECRET=dev-linkdesk-billing-secret ./scripts/smoke-linkdesk.sh
./scripts/smoke-oidc.sh
```

信令服务：

```bash
cd /Users/hui/work/WanxiangI/linkdesk-rendezvous
cargo test --workspace
```

## 项目结构

- `src/`：Rust 客户端和被控端服务
- `src/server/`：音频、剪贴板、输入、视频和网络连接
- `src/platform/`：平台相关实现
- `flutter/`：当前 Flutter UI
- `libs/base/`：客户端配置、消息和文件传输
- `libs/hbb_common/`：与信令服务共享的协议和网络基础
- `libs/scrap/`：屏幕捕获
- `libs/enigo/`：输入控制
- `libs/clipboard/`：剪贴板

## 上游与许可证

LinkDesk 基于 [RustDesk](https://github.com/rustdesk/rustdesk) 开源项目开发。底层协议字段、
内部 crate 名称、第三方补丁路径和兼容性测试中仍可能保留 RustDesk 技术标识，这些不作为
LinkDesk 的用户可见产品名称。

本项目继续遵循仓库中的 `LICENSE` 和各第三方依赖对应许可证。上游版权和许可证声明不得
删除或误写。
