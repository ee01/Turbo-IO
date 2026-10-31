# 记忆同步接收器

手机上的 Turbo IO 扩展把官方最终文字先写入本机 SQLite，再以 JSONL 批次推到这台 Mac。下游（包括 Personal AI）只读归档目录，不直接连手机。

## 目录

```text
~/Memory/io-glasses/
  manifest.json
  state/receiver.sqlite
  inbox/<sourceId>/<batchId>.jsonl
  events/<YYYY>/<YYYY-MM-DD>.jsonl
  daily/<YYYY>/<YYYY-MM-DD>.md
```

`events/` 每行一个修订版本，带单调递增的 `seq`。读取方按 `seq` 续传，不要用文件修改时间。`daily/` 只保留当天最新修订，给人读。`inbox/` 是收到的原始字节，下游不要读。日期按 Mac 本地时区解释 `receivedAt`。

`sessionId` 就是计划里的来源会话（sourceEpoch）。同一句话的新修订使用同一个 `eventId` 和更大的 `revision`。

## 运行

默认只监听 `127.0.0.1:8765`，拒绝 `0.0.0.0`。跨网络时用 Tailscale：本机继续听 loopback，由 `tailscale serve` 或 `tailscale cert` 提供公信 HTTPS。不要让接收端返回重定向。

```bash
cd memory-sync-service
uv sync --group dev
uv run memory-sync init --root ~/Memory/io-glasses
uv run memory-sync pair --root ~/Memory/io-glasses --source-id <手机显示的来源> --out ~/Memory/io-glasses/phone.token
uv run memory-sync serve --root ~/Memory/io-glasses
uv run memory-sync status --root ~/Memory/io-glasses
uv run memory-sync export --root ~/Memory/io-glasses
uv run memory-sync revoke --root ~/Memory/io-glasses --token-file ~/Memory/io-glasses/phone.token
```

配对令牌只写入 `--out` 新文件，权限 `0600`，不会打印到终端。LaunchAgent 模板在 `launchd/io.turboio.memory-sync.plist`，把里面的路径换成自己的解释器和归档目录后再放到 `~/Library/LaunchAgents/`。

## 协议

`POST /v1/memory/batches`，正文是 JSONL 文件字节。`payloadHash` 是这串字节的 SHA-256，放在请求头里，不写进文件。

- `Authorization: Bearer <token>`
- `X-Memory-Source-Id`
- `X-Memory-Batch-Id`
- `X-Memory-Payload-Hash`

第一行是 `type=batch` 的头，后面每行一个事件，单批最多 100 条、512 KiB。同一 `batchId` 且哈希相同会返回原来的 ACK；哈希不同返回 409。新的 `batchId` 若包含已经入库的同一修订，复用原来的 `seq`，不为这一行再分配序号。同一修订、不同正文返回 409，整批回滚。较旧的 `revision` 会留下，但不会覆盖更新的当前视图。

ACK 含 `schemaVersion`、`sourceId`、`batchId`、`payloadHash`、`committedAt` 和 `events[].seq`。HTTP 200 本身不够，手机还要核对这几项。没有按批次查询回执的接口；未知路径的 404 不表示可以删除手机队列。

健康检查是 `GET /v1/memory/health`，不返回正文。日志只记来源、批次、状态码、条数和字节数。

数据库使用事务，`synchronous=FULL`。投影写失败时 ACK 仍然有效，`memory-sync export` 可以按数据库重写 `events/` 和 `daily/`。

## 手机侧行为

标准构建编入 `official-addon/memory-sync/`。保存和上传是两次同意。关闭保存会挡住之后才进入队列的回调；已经进入队列的可以写完。暂停上传不再创建新的传输任务，已授权的待传项还在。换一台 Mac 不会把旧队列改派到新目标。

来源 ID 是这次安装自己生成的，不是雷鸟账号。账号切换无法在当前代码里可靠识别，所以未配对时不会上传。FOCUS 构建还没有接这套模块。

后台使用固定的 `NSURLSession` 标识 `io.turboio.memory.sync.upload`。打开 App 会补传。URL 只有 `turboio-memory://sync-now`（不能带查询、正文或令牌）会触发已授权同步。本版没有做 BGTaskScheduler 和 App Intent。

## 尚未在真机上验证

签名安装、官方登录和智记、后台 session 是否真能交给扩展、Tailscale 上的锁屏上传、强退和重启，都还需要在官方宿主 1.0.5（201）上实测。这里的测试覆盖协议、崩溃边界和进程内重启，不能代替那部分。
