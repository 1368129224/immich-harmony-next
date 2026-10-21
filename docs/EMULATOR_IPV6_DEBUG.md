# Windows HarmonyOS 模拟器访问 IPv6-only Immich

## 已确认的问题

- 测试服务器域名只有 AAAA 记录，没有 IPv4 A 记录。
- Windows 主机可以通过 IPv6 正常访问，`POST /api/auth/login` 返回 HTTP 201。
- 当前模拟器解析该域名失败，IPv6 地址连通性测试也未成功。不能将此类失败提示为密码错误。
- `ImmichApiService` 现保留 HarmonyOS BusinessError 的错误码和可读提示，不再输出 `[object Object]`。

## 临时调试桥

仅用于当前可信 Windows 主机及模拟器的本地开发，不是生产环境方案。

在项目根目录的终端运行（保持该终端打开）：

```powershell
node scripts/immich_emulator_proxy.cjs
```

在另一个 PowerShell 终端创建设备到主机的端口转发：

```powershell
& 'F:\Programs\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' rport tcp:15941 tcp:15941
```

在模拟器登录页手动设置服务器地址为：

```text
http://127.0.0.1:15941
```

然后使用正常账号登录。不要将密码或令牌写到脚本或配置文件中。

### 安全边界

- 转发脚本只监听 Windows `127.0.0.1:15941`，不监听局域网网卡。
- 上游固定为指定 Immich 服务器，只允许 `/api/` 路径，不是开放代理。
- 主机到服务器使用 HTTPS，保留证书与主机名校验，不关闭 TLS 验证。
- 模拟器到本机桥使用 HTTP，经 HDC 本地调试通道传输；仅适用于可信开发环境。
- 脚本不记录请求体、请求头、密码或令牌。退出前台脚本使用 Ctrl+C。
- 模拟器/主机或 HDC 连接重启后，需要重新启动脚本并建立端口转发。
- 不修改应用默认服务器地址，也不自动重写任意用户服务器地址。

## 正式环境

为服务器提供可用的双栈 HTTPS 地址（A + AAAA），或使用已具备 IPv6 网络的真机直接连接原始 HTTPS 地址。不要为解决连通性问题禁用证书校验。

## 图片缓存修正

HarmonyOS `mkdirSync(path, true)` 对已存在目录仍可能抛出 `File exists`。
图片下载现在先检查目录是否存在，并在并发创建竞争时再次确认目录已创建，避免第二张及后续缩略图失败。

回归测试：

```powershell
node --test scripts/test_timeline.cjs
```
