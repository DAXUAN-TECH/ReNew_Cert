# SSL 证书自动申请与续签脚本

## 概述

本脚本是一个基于 `acme.sh` 的 SSL/TLS 证书自动申请与续签工具，支持批量处理多个域名，自动更新 Nginx/OpenResty 配置文件，并智能检测和重载 Web 服务器。

### 核心特性

- ✅ **批量处理**：支持一次性处理多个域名的证书申请和续签
- ✅ **多 DNS 提供商支持**：每个域名可指定不同的 DNS 提供商（GoDaddy、Cloudflare、阿里云、DNSPod 等）
- ✅ **多账号支持**：支持同一 DNS 提供商的多个账号（如多个阿里云账号、多个 GoDaddy 账号）
- ✅ **通配符证书支持**：支持通配符证书（`*.example.com`）和单域名证书
- ✅ **多级域名支持**：支持任意层级的子域名（如 `api.v1.example.com`、`prod.dev.test.api.v1.example.com`）
- ✅ **新 TLD 支持**：支持所有新顶级域名（.vip、.tech、.ren、.me 等所有纯字母 TLD）
- ✅ **下划线域名支持**：支持子域名中包含下划线（如 `example_test.com`、`api_v1.example.com`）
- ✅ **数字子域名支持**：支持子域名中包含数字（如 `example123.com`、`www123.example.com`）
- ✅ **自动配置更新**：自动更新 Nginx/OpenResty 配置文件中的 SSL 证书路径
- ✅ **智能 Web 服务器检测**：自动检测系统安装的是 Nginx 还是 OpenResty
- ✅ **配置验证**：在执行 reload 前自动测试配置文件，确保配置正确
- ✅ **安全可靠**：配置文件修改前自动创建备份，支持回滚
- ✅ **定时任务友好**：交互式输入支持 30 秒超时，默认自动确认，适合定时任务执行
- ✅ **配置更新独立模式**：支持 `resetconf` 参数，可单独执行配置更新，不申请证书

### 支持的 Web 服务器

- **Nginx**：标准 Nginx Web 服务器
- **OpenResty**：基于 Nginx 的 Web 平台

> ⚠️ **注意**：本脚本仅支持 Nginx 和 OpenResty，不支持其他 Web 服务器。

## 系统要求

- **操作系统**：主流 Linux 发行版（CentOS、Ubuntu、Debian 等）和 macOS
- **Shell**：Bash 4.0+
- **必需工具**：
  - `curl`：用于下载和安装 acme.sh
  - `acme.sh`：SSL 证书申请工具（脚本可自动安装）
  - `nginx` 或 `openresty`：Web 服务器（用于证书部署）
- **权限要求**：
  - 执行脚本的用户需要有 sudo 权限（用于 reload Web 服务器）
  - 对 Nginx 配置目录有读写权限

## 安装与配置

### 1. 获取脚本

将脚本文件 `renew_cert.sh` 放置到您希望的位置，例如：

```bash
mkdir -p /opt/ssl-cert-manager
cd /opt/ssl-cert-manager
# 将 renew_cert.sh 复制到此目录
```

### 2. 设置执行权限

```bash
chmod +x renew_cert.sh
```

### 3. 配置文件设置

#### 3.1 主配置文件（config）

在脚本同级目录创建 `config` 文件，配置以下内容：

```bash
# Nginx配置文件目录路径
NGINX_CONF_DIR=/data/openresty/nginx/conf/vhost/

# DNS API凭证配置文件路径（相对于脚本目录）
DNS_CREDENTIALS_FILE=dns_credentials

# CA证书厂商配置
CA_PROVIDER=letsencrypt

# DNS验证等待时间（秒）
# 建议值：
#   - 快速DNS提供商（如Cloudflare）：60-120秒
#   - 普通DNS提供商（如GoDaddy、阿里云）：180-300秒
#   - 慢速DNS提供商：300-600秒
DNS_SLEEP=300

# 域名列表（必须格式：域名|DNS提供商 或 域名|DNS提供商|账号标识）
*.example.com|dns_gd
example.com|dns_dp
www.example.com|dns_ali
api.v1.example.com|dns_cf
*.test.com|dns_ali|account1
```

**配置说明**：

- **NGINX_CONF_DIR**：Nginx/OpenResty 配置文件目录，支持绝对路径或相对路径
- **DNS_CREDENTIALS_FILE**：DNS API 凭证文件路径，相对于脚本目录
- **CA_PROVIDER**：SSL 证书颁发机构，可选值：
  - `letsencrypt`：Let's Encrypt（免费，90 天有效期，推荐）
  - `zerossl`：ZeroSSL（免费，90 天有效期）
  - `buypass`：BuyPass（免费，180 天有效期）
- **DNS_SLEEP**：DNS 验证等待时间（秒），不同 DNS 提供商的传播速度不同，可根据实际情况调整
- **域名列表**：每行一个域名，格式为 `域名|DNS提供商` 或 `域名|DNS提供商|账号标识`
  - 通配符格式：`*.example.com|dns_gd`
  - 单域名格式：`example.com|dns_dp`
  - 多级域名：`api.v1.example.com|dns_cf`
  - 多账号格式：`*.test.com|dns_ali|account1`

> ⚠️ **重要**：每个域名必须明确指定 DNS 提供商，格式为 `域名|DNS提供商`。如果未指定，脚本将直接报错退出。

#### 3.2 DNS API 凭证配置

1. 复制模板文件：

```bash
cp dns_credentials.example dns_credentials
```

2. 编辑 `dns_credentials` 文件，取消注释并填写您使用的 DNS 提供商的 API 密钥：

**默认账号配置**：

```bash
# 例如：使用 GoDaddy（默认账号）
export GD_Key="your_godaddy_api_key"
export GD_Secret="your_godaddy_api_secret"

# 例如：使用阿里云（默认账号）
export Ali_Key="your_aliyun_access_key_id"
export Ali_Secret="your_aliyun_access_key_secret"
```

**多账号配置**：

如果您有多个相同 DNS 提供商的账号，可以使用账号标识来区分：

```bash
# 默认账号（不带账号标识）
export Ali_Key="default_account_key"
export Ali_Secret="default_account_secret"

# account1 账号（使用 _account1 后缀）
export Ali_Key_account1="account1_key"
export Ali_Secret_account1="account1_secret"

# account2 账号（使用 _account2 后缀）
export Ali_Key_account2="account2_key"
export Ali_Secret_account2="account2_secret"
```

**支持的账号标识格式**：

- 标准格式：`变量名_account标识`（如 `Ali_Key_account1`）
- 简化格式：`变量名_标识`（如 `Ali_Key_wp`）

详细的 DNS 提供商配置说明请参考 `dns_credentials.example` 文件。

### 4. 目录结构

脚本运行后会自动创建以下目录结构：

```
/opt/ssl-cert-manager/
├── renew_cert.sh          # 主脚本
├── config                  # 配置文件
├── dns_credentials         # DNS API 凭证文件（需手动创建）
├── dns_credentials.example # DNS 凭证模板文件
├── logs/                   # 日志目录（自动创建）
│   └── renew_cert.log     # 执行日志
└── cert/                   # 证书存放目录（自动创建）
    ├── example.com.pem    # 证书文件
    └── example.com.key    # 私钥文件

# Nginx配置目录结构（示例）
/data/conf.d/               # Nginx配置目录（在config中配置）
├── example.com.conf        # 配置文件
├── www.example.com.conf    # 配置文件
└── backup/                 # 备份目录（自动创建）
    ├── example.com.conf.backup.20250101_120000
    └── www.example.com.conf.backup.20250101_120000
```

## 使用方法

### 基本使用

**正常模式**（申请/续签证书并更新配置）：
```bash
./renew_cert.sh
```

**仅更新配置模式**（只更新Nginx/OpenResty配置文件中的SSL证书路径）：
```bash
./renew_cert.sh resetconf
```

**查看帮助信息**：
```bash
./renew_cert.sh --help
# 或
./renew_cert.sh -h
```

### 模式说明

#### 正常模式（默认）
- 执行完整的证书申请/续签流程
- 申请成功后自动更新Nginx配置
- 最后执行Web服务器reload

#### resetconf 模式
- **仅更新Nginx/OpenResty配置文件中的SSL证书路径**
- 不执行证书申请/续签
- 从 `config` 文件读取域名列表
- 检查证书文件是否存在（`cert/主域名.pem` 和 `cert/主域名.key`）
- 自动查找匹配的配置文件并更新SSL路径
- 更新完成后执行Web服务器reload

**使用场景**：
- 证书文件已存在，只需要更新配置文件
- 手动更新了证书文件，需要同步更新配置
- 配置文件路径错误，需要重新更新

### 执行流程

脚本执行时会按以下流程进行：

1. **环境检查**
   - 检查 acme.sh 是否已安装，如未安装会提示安装（30 秒超时，默认自动确认）
   - 检查配置文件是否存在
   - 创建必要的目录（logs、cert）

2. **配置加载**
   - 读取配置文件（config）
   - 加载 DNS API 凭证（支持默认账号和多账号）
   - 验证域名配置（检查是否所有域名都指定了 DNS 提供商）

3. **证书申请与安装**
   - 升级 acme.sh 到最新版本
   - 设置 CA 提供商
   - 循环处理每个域名：
     - 加载对应的 DNS 凭证（默认账号或指定账号）
     - 申请/续签证书
     - 验证证书是否成功生成
     - 安装证书到指定目录

4. **配置更新**（可选）
   - 询问用户是否更新 Nginx/OpenResty 配置文件（30 秒超时，默认自动确认）
   - 自动查找匹配的配置文件
   - 更新 SSL 证书路径

5. **Web 服务器重载**
   - 自动检测 Web 服务器类型（Nginx 或 OpenResty）
   - 测试配置文件（`nginx -t` 或 `openresty -t`）
   - 配置测试通过后执行 reload

### 日志查看

所有操作日志都会记录到 `logs/renew_cert.log` 文件中：

```bash
tail -f logs/renew_cert.log
```

## 功能详解

### 1. 域名格式支持

#### 通配符证书

- **格式**：`*.example.com`
- **说明**：申请通配符证书，覆盖所有二级域名
- **示例**：
  - `*.example.com` → 覆盖 `www.example.com`、`api.example.com` 等
  - `*.v1.example.com` → 覆盖 `api.v1.example.com`、`test.v1.example.com` 等
  - `*.api.v1.example.com` → 覆盖 `test.api.v1.example.com`、`dev.api.v1.example.com` 等
  - **支持任意层级**：`*.prod.dev.test.api.v1.example.com`

#### 单域名证书

- **格式**：标准域名格式
- **说明**：申请单域名证书，仅覆盖指定域名
- **示例**：
  - **二级域名**：`example.com`、`example123.com`、`example_test.com`、`example.vip`
  - **三级域名**：`www.example.com`、`www123.example.com`、`api_v1.example.com`、`www.example.tech`
  - **四级域名**：`api.v1.example.com`、`api123.v1.example.com`、`test_api.v1.example.com`、`api.v1.example.ren`
  - **五级及以上**：`dev.test.api.v1.example.com`、`prod.dev.test.api.v1.example.com`（支持任意层级）

#### 特殊字符支持

- **数字支持**：子域名部分可以包含数字
  - 示例：`example123.com`、`www123.example.com`、`api123.v1.example.com`
- **下划线支持**：子域名部分可以包含下划线
  - 示例：`example_test.com`、`api_v1.example.com`、`test_api.v1.example.com`
  - ⚠️ **注意**：下划线在域名中虽然被允许，但可能不被某些 CA（如 Let's Encrypt）支持，建议谨慎使用
- **新 TLD 支持**：支持所有新顶级域名（纯字母 TLD）
  - 示例：`.com`、`.org`、`.cn`、`.vip`、`.tech`、`.ren`、`.me` 等所有纯字母 TLD

### 2. DNS 提供商支持

脚本支持所有 acme.sh 官方支持的 DNS 提供商，包括但不限于：

- **GoDaddy** (`dns_gd`)
- **Cloudflare** (`dns_cf`)
- **阿里云** (`dns_ali`)
- **DNSPod/腾讯云** (`dns_dp`)
- **AWS Route 53** (`dns_aws`)
- **腾讯云** (`dns_tencent`)
- **Hurricane Electric** (`dns_he`)

更多支持的 DNS 提供商请参考：[acme.sh DNS API 文档](https://github.com/acmesh-official/acme.sh/wiki/dnsapi)

### 3. 多账号 DNS 提供商支持

如果您有多个相同 DNS 提供商的账号（如多个阿里云账号、多个 GoDaddy 账号），可以使用账号标识来区分：

**配置示例**：

```bash
# config 文件
*.example1.com|dns_ali          # 使用默认账号
*.example2.com|dns_ali|account1  # 使用 account1 账号
*.example3.com|dns_ali|account2  # 使用 account2 账号
```

**dns_credentials 文件**：

```bash
# 默认账号
export Ali_Key="default_key"
export Ali_Secret="default_secret"

# account1 账号
export Ali_Key_account1="account1_key"
export Ali_Secret_account1="account1_secret"

# account2 账号
export Ali_Key_account2="account2_key"
export Ali_Secret_account2="account2_secret"
```

**账号标识格式**：

- 标准格式：`变量名_account标识`（如 `Ali_Key_account1`）
- 简化格式：`变量名_标识`（如 `Ali_Key_wp`）

**凭证加载逻辑**：

1. 如果域名未指定账号标识：仅加载默认账号凭证
2. 如果域名指定了账号标识：
   - 先尝试加载默认账号凭证
   - 再尝试加载指定账号凭证
   - 如果两者都成功，同时使用；如果只有一种成功，使用成功的凭证；如果都失败，脚本退出

### 4. Nginx 配置文件匹配规则

脚本会根据域名自动查找匹配的 Nginx 配置文件：

#### 通配符域名匹配

- `*.example.com` 会匹配所有以 `.example.com` 结尾的配置文件
- 例如：`cn.example.com.conf`、`en.example.com.conf`、`api.v1.example.com.conf`

#### 单域名匹配

- 完全匹配：`api.v1.example.com` → `api.v1.example.com.conf`
- 后缀匹配：`api.v1.example.com` → `*.api.v1.example.com.conf`

### 5. 配置文件更新机制

- **自动备份**：修改配置文件前会自动创建备份文件
  - 备份文件位置：`${NGINX_CONF_DIR}/backup/原文件名.backup.时间戳`
  - 备份目录会自动创建（如果不存在）
  - 备份文件格式：`配置文件名.backup.YYYYMMDD_HHMMSS`
  - 示例：`/data/conf.d/backup/example.com.conf.backup.20250101_120000`
- **路径检查**：更新前会检查当前证书路径是否正确，避免重复更新
- **安全更新**：使用临时文件进行修改，确保原子性操作
- **备份管理**：如果配置文件未实际修改，备份文件会被自动删除

### 6. Web 服务器检测与重载

#### 检测顺序

1. 优先检测命令：使用 `command -v` 检测 `openresty` 或 `nginx` 命令
2. 进程检测：如果命令检测不到，通过 `pgrep` 检测运行中的进程
3. 优先级：OpenResty 优先于 Nginx

#### 重载流程

1. **配置测试**：执行 `nginx -t` 或 `openresty -t` 测试配置文件
2. **测试通过**：配置测试通过后执行 reload
3. **测试失败**：配置测试失败时跳过 reload，记录错误日志

### 7. 定时任务支持

脚本支持定时任务执行，交互式输入会自动超时并默认确认：

- **超时时间**：30 秒
- **默认值**：`y`（自动确认）
- **行为**：
  - 如果 30 秒内无输入，自动使用默认值 `y`
  - 如果直接按回车，也使用默认值 `y`
  - 适合在 cron 等定时任务中使用

## 错误处理

脚本包含完善的错误处理机制：

- **配置验证**：启动时验证配置文件格式和必需配置项
- **域名格式验证**：严格验证域名格式，包括 TLD、下划线、数字等
- **DNS 提供商验证**：检查 DNS 提供商格式是否正确（必须以 `dns_` 开头）
- **DNS 凭证验证**：检查 DNS 凭证是否加载成功，失败时退出
- **证书申请失败**：单个域名申请失败不影响其他域名的处理
- **证书验证**：申请后验证证书文件是否存在，确保证书真的生成成功
- **配置更新失败**：配置文件更新失败会记录错误，但不中断脚本执行
- **Web 服务器检测失败**：检测不到 Web 服务器时会记录警告，但不中断脚本执行

## 常见问题

### Q1: 脚本提示 "未指定DNS提供商"

**原因**：配置文件中存在未指定 DNS 提供商的域名。

**解决方法**：确保所有域名都使用 `域名|DNS提供商` 格式，例如：

```bash
# 错误格式
example.com

# 正确格式
example.com|dns_gd
```

### Q2: resetconf 模式提示证书文件不存在

**原因**：resetconf 模式需要证书文件已存在，如果证书文件不存在，该域名会被跳过。

**解决方法**：
1. 确保证书文件已存在：`cert/主域名.pem` 和 `cert/主域名.key`
2. 如果证书文件不存在，先使用正常模式申请证书：`./renew_cert.sh`
3. 或者手动将证书文件复制到 `cert/` 目录

### Q3: 证书申请失败

**可能原因**：
1. DNS API 凭证配置错误
2. DNS 提供商不支持该域名
3. 网络连接问题
4. DNS 记录传播时间不足

**解决方法**：
1. 检查 `dns_credentials` 文件中的 API 密钥是否正确
2. 确认域名在对应的 DNS 提供商管理
3. 检查网络连接和防火墙设置
4. 增加 `DNS_SLEEP` 配置值，给 DNS 记录更多传播时间

### Q3: 找不到 Nginx 配置文件

**原因**：`NGINX_CONF_DIR` 配置不正确或配置文件命名不匹配。

**解决方法**：
1. 检查 `NGINX_CONF_DIR` 配置是否正确
2. 确认配置文件命名符合匹配规则
3. 检查配置文件权限

### Q4: Web 服务器 reload 失败

**可能原因**：
1. 配置文件有语法错误
2. 没有执行权限
3. Web 服务器未运行

**解决方法**：
1. 查看日志文件中的错误信息
2. 手动执行 `nginx -t` 或 `openresty -t` 检查配置
3. 确认 Web 服务器正在运行

### Q5: DNS 凭证加载失败

**可能原因**：
1. `dns_credentials` 文件不存在或路径不正确
2. 账号标识配置错误
3. 环境变量格式不正确

**解决方法**：
1. 确认 `dns_credentials` 文件存在且路径正确
2. 检查账号标识格式（标准格式：`_account标识` 或简化格式：`_标识`）
3. 确认环境变量格式为 `export VAR_NAME="value"`

### Q6: 域名格式验证失败

**可能原因**：
1. 域名包含 `.conf` 后缀（不允许）
2. 域名包含非法字符
3. TLD 格式不正确

**解决方法**：
1. 确保域名不包含 `.conf` 后缀
2. 检查域名是否包含非法字符（只允许字母、数字、点、连字符、下划线、星号）
3. 确认 TLD 是纯字母（如 `.com`、`.vip`、`.tech` 等）

## 安全建议

1. **文件权限**：
   - `dns_credentials` 文件应设置严格的权限（建议 600）
   ```bash
   chmod 600 dns_credentials
   ```

2. **API 密钥安全**：
   - 使用最小权限的 API 密钥
   - 定期轮换 API 密钥
   - 不要将 `dns_credentials` 文件提交到版本控制系统

3. **日志文件**：
   - 定期清理日志文件，避免占用过多磁盘空间
   - 日志文件可能包含敏感信息，注意保护

## 定时任务设置

建议设置定时任务自动执行证书续签，例如每周执行一次：

```bash
# 编辑 crontab
crontab -e

# 添加以下行（每周一凌晨 2 点执行）
0 2 * * 1 /opt/ssl-cert-manager/renew_cert.sh >> /opt/ssl-cert-manager/logs/cron.log 2>&1
```

**定时任务说明**：

- 脚本支持非交互式执行，交互式输入会自动超时并默认确认
- 所有输出会同时记录到日志文件和标准输出
- 建议定期检查日志文件，确保证书续签正常

## 技术规范

### 符合 acme.sh 官方文档要求

本脚本严格按照 [acme.sh 官方文档](https://github.com/acmesh-official/acme.sh/wiki/dnsapi) 的要求实现：

- ✅ 使用 `--issue --dns dns_provider -d domain --dnssleep seconds` 申请证书
- ✅ 使用 `--install-cert -d domain --key-file ... --fullchain-file ...` 安装证书
- ✅ DNS 提供商格式验证（必须以 `dns_` 开头）
- ✅ 环境变量加载方式符合官方要求
- ✅ 支持所有官方支持的 DNS 提供商

### 代码质量

- ✅ **逻辑闭环**：所有功能都有完整的错误处理和退出机制
- ✅ **功能闭环**：从配置读取到证书安装到配置更新的完整流程
- ✅ **语法正确**：通过 Bash 语法检查（`bash -n`）
- ✅ **兼容性**：兼容主流 Linux 发行版和 macOS
- ✅ **安全性**：临时文件自动清理，防止命令注入，路径验证

### 域名格式验证

脚本实现了严格的域名格式验证，符合 RFC 标准：

- ✅ 支持通配符格式（`*.example.com`）
- ✅ 支持单域名格式（`example.com`）
- ✅ 支持多级域名（任意层级）
- ✅ 支持数字子域名（`example123.com`）
- ✅ 支持下划线子域名（`example_test.com`）
- ✅ 支持所有新 TLD（`.vip`、`.tech`、`.ren`、`.me` 等）
- ✅ 严格验证 TLD 格式（必须是纯字母）
- ✅ 严格验证域名各部分长度（1-63 个字符）

## 版本历史

- **v1.0**：初始版本
  - 支持批量域名证书申请
  - 支持多 DNS 提供商
  - 支持 Nginx/OpenResty 配置自动更新
  - 支持通配符和单域名证书

- **v1.1**：功能增强
  - 支持多账号 DNS 提供商（同一 DNS 提供商的多个账号）
  - 支持新 TLD（`.vip`、`.tech`、`.ren`、`.me` 等）
  - 支持下划线域名（`example_test.com`）
  - 支持数字子域名（`example123.com`）
  - 支持任意层级的多级域名
  - 支持定时任务（交互式输入 30 秒超时，默认自动确认）
  - 可配置 DNS 验证等待时间（`DNS_SLEEP`）
  - 增强错误处理和证书验证
  - 改进日志输出（同时输出到控制台和日志文件）

- **v1.2**：配置更新独立模式
  - 新增 `resetconf` 模式：可单独执行配置更新，不申请证书
  - 支持命令行参数：`./renew_cert.sh resetconf`
  - 支持帮助信息：`./renew_cert.sh --help`
  - resetconf 模式自动检查证书文件是否存在
  - resetconf 模式自动更新所有匹配的配置文件
  - resetconf 模式适合手动更新证书后同步配置的场景

- **v1.3**：修复和优化
  - 修复 `set -u` 模式下空数组访问错误（`TEMP_FILES[@]` 和 `DNS_PROVIDERS_USED[@]`）
  - 改进数组访问安全性，兼容严格模式（`set -u`）
  - 优化备份文件存储位置：备份文件保存在 `${NGINX_CONF_DIR}/backup/` 目录下
  - 备份文件格式：`配置文件名.backup.YYYYMMDD_HHMMSS`
  - 备份目录自动创建（如果不存在）

## 许可证

本脚本遵循 MIT 许可证。

## 参考资源

- [acme.sh 官方文档](https://github.com/acmesh-official/acme.sh)
- [acme.sh DNS API 文档](https://github.com/acmesh-official/acme.sh/wiki/dnsapi)
- [Nginx 官方文档](https://nginx.org/en/docs/)
- [OpenResty 官方文档](https://openresty.org/)

## 支持与反馈

如有问题或建议，请查看日志文件 `logs/renew_cert.log` 获取详细错误信息。

---

**最后更新**：2024年12月
