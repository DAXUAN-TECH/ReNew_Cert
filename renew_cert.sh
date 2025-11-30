#!/bin/bash

# Let's Encrypt 限制每个域名每周只能签发5次重复证书

# 定义脚本所在目录（兼容各种调用方式）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 函数：检查acme.sh是否已安装
check_acme_installed() {
    local acme_paths=(
        "$HOME/.acme.sh/acme.sh"
        "/root/.acme.sh/acme.sh"
        "$(which acme.sh 2>/dev/null)"
    )
    
    for path in "${acme_paths[@]}"; do
        if [ -n "$path" ] && [ -f "$path" ] && [ -x "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    
    return 1
}

# 函数：安装acme.sh
install_acme() {
    echo "开始安装 acme.sh..." >> "$LOG_FILE"
    echo "正在安装 acme.sh，请稍候..." >&2
    
    # 使用官方安装脚本
    if curl -s https://get.acme.sh | sh >> "$LOG_FILE" 2>&1; then
        echo "acme.sh 安装成功" >> "$LOG_FILE"
        echo "acme.sh 安装成功" >&2
        
        # 重新加载shell配置（如果存在）
        if [ -f "$HOME/.bashrc" ]; then
            source "$HOME/.bashrc" >/dev/null 2>&1 || true
        fi
        if [ -f "$HOME/.profile" ]; then
            source "$HOME/.profile" >/dev/null 2>&1 || true
        fi
        
        return 0
    else
        echo "错误: acme.sh 安装失败" >> "$LOG_FILE"
        echo "错误: acme.sh 安装失败，请检查网络连接和权限" >&2
        return 1
    fi
}

# 函数：询问用户是否安装acme.sh
ask_install_acme() {
    if [ -t 0 ]; then
        echo "" >&2
        echo "检测到系统未安装 acme.sh" >&2
        echo "acme.sh 是用于自动申请和续签SSL证书的工具" >&2
        echo "" >&2
        read -p "是否现在安装 acme.sh? (y/n): " answer
        echo "用户选择: $answer" >> "$LOG_FILE"
        
        case "$answer" in
            [Yy]|[Yy][Ee][Ss])
                return 0
                ;;
            *)
                echo "用户选择不安装 acme.sh，脚本退出" >> "$LOG_FILE"
                echo "用户选择不安装，脚本退出" >&2
                return 1
                ;;
        esac
    else
        # 非交互式环境，记录日志并退出
        echo "错误: 系统未安装 acme.sh，且当前为非交互式环境，无法询问用户" >> "$LOG_FILE"
        echo "错误: 请先安装 acme.sh: curl https://get.acme.sh | sh" >&2
        return 1
    fi
}

# 函数：验证域名格式是否为通配符格式
validate_wildcard_domain() {
    local domain="$1"
    
    # 检查是否以 *. 开头
    if [[ "$domain" =~ ^\*\. ]]; then
        return 0
    else
        return 1
    fi
}

# 函数：从域名中提取主域名（用于生成证书文件名）
# 支持两种格式和多级域名：
# 1. 通配符格式：
#    *.example.com -> example.com
#    *.v1.example.com -> v1.example.com
# 2. 单域名格式（支持任意层级）：
#    example.com -> example.com
#    www.example.com -> www.example.com
#    api.v1.example.com -> api.v1.example.com
#    api.v1.test.example.com -> api.v1.test.example.com
extract_main_domain() {
    local domain="$1"
    
    # 如果是通配符格式，移除 *. 前缀
    if validate_wildcard_domain "$domain"; then
        echo "$domain" | sed 's/^\*\.//'
    else
        # 单域名格式（支持多级域名），直接返回完整域名
        echo "$domain"
    fi
}

# 定义配置文件位置（相对于脚本所在目录）
CONFIG_FILE="${SCRIPT_DIR}/config"

# 定义日志文件位置（脚本同级目录下的 logs 文件夹）
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/renew_cert.log"

# 定义证书存放目录（脚本同级目录下的 cert 文件夹）
CERT_DIR="${SCRIPT_DIR}/cert" 

# 创建必要的目录（logs 和 cert）
for dir in "$LOG_DIR" "$CERT_DIR"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" || {
            echo "错误: 无法创建目录 $dir" >&2
            exit 1
        }
        echo "已创建目录: $dir" >&2
    fi
done

# 检查并安装acme.sh
ACME_SH_PATH=""
if ! ACME_SH_PATH=$(check_acme_installed); then
    echo "检测到系统未安装 acme.sh" >> "$LOG_FILE"
    if ask_install_acme; then
        if install_acme; then
            # 安装后重新检查路径
            if ! ACME_SH_PATH=$(check_acme_installed); then
                echo "错误: acme.sh 安装后仍无法找到，请手动检查" >> "$LOG_FILE"
                echo "错误: acme.sh 安装后仍无法找到，请手动检查" >&2
                exit 1
            fi
        else
            echo "错误: acme.sh 安装失败，脚本退出" >> "$LOG_FILE"
            exit 1
        fi
    else
        exit 1
    fi
else
    echo "检测到 acme.sh 已安装: $ACME_SH_PATH" >> "$LOG_FILE"
fi

# 验证acme.sh可执行性
if [ ! -x "$ACME_SH_PATH" ]; then
    echo "错误: acme.sh 文件不可执行: $ACME_SH_PATH" >> "$LOG_FILE"
    echo "错误: acme.sh 文件不可执行: $ACME_SH_PATH" >&2
    exit 1
fi

# 检查配置文件是否存在
if [ ! -f "$CONFIG_FILE" ]; then
    echo "错误: 配置文件 $CONFIG_FILE 不存在" >> "$LOG_FILE"
    echo "请创建配置文件，每行一个域名（支持通配符，如 *.example.com）" >> "$LOG_FILE"
    exit 1
fi

# 从配置文件中读取配置项
NGINX_CONF_DIR=""
CA_PROVIDER="letsencrypt"  # 默认值：Let's Encrypt
DNS_CREDENTIALS_FILE="dns_credentials"  # 默认值：脚本同级目录下的dns_credentials文件

while IFS= read -r line || [ -n "$line" ]; do
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    # 跳过空行和注释行
    if [ -z "$line" ] || [[ "$line" =~ ^# ]]; then
        continue
    fi
    
    # 检查是否是NGINX_CONF_DIR配置
    if [[ "$line" =~ ^NGINX_CONF_DIR= ]]; then
        NGINX_CONF_DIR=$(echo "$line" | sed 's/^NGINX_CONF_DIR=//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        # 如果是相对路径，转换为绝对路径（相对于脚本目录）
        if [[ ! "$NGINX_CONF_DIR" =~ ^/ ]]; then
            NGINX_CONF_DIR="${SCRIPT_DIR}/${NGINX_CONF_DIR}"
        fi
        # 移除末尾的斜杠（如果有）
        NGINX_CONF_DIR="${NGINX_CONF_DIR%/}"
        continue
    fi
    
    # 跳过DNS_PROVIDER配置（已废弃，保留过滤逻辑以兼容旧配置文件）
    if [[ "$line" =~ ^DNS_PROVIDER= ]]; then
        continue
    fi
    
    # 检查是否是CA_PROVIDER配置
    if [[ "$line" =~ ^CA_PROVIDER= ]]; then
        CA_PROVIDER=$(echo "$line" | sed 's/^CA_PROVIDER=//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        continue
    fi
    
    # 检查是否是DNS_CREDENTIALS_FILE配置
    if [[ "$line" =~ ^DNS_CREDENTIALS_FILE= ]]; then
        DNS_CREDENTIALS_FILE=$(echo "$line" | sed 's/^DNS_CREDENTIALS_FILE=//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        continue
    fi
done < "$CONFIG_FILE"

# 处理DNS凭证文件路径（如果是相对路径，转换为绝对路径）
if [[ ! "$DNS_CREDENTIALS_FILE" =~ ^/ ]]; then
    DNS_CREDENTIALS_FILE="${SCRIPT_DIR}/${DNS_CREDENTIALS_FILE}"
fi

# 函数：加载DNS API凭证
load_dns_credentials() {
    local cred_file="$1"
    
    if [ ! -f "$cred_file" ]; then
        echo "警告: DNS凭证文件不存在: $cred_file" >> "$LOG_FILE"
        echo "提示: 请复制 dns_credentials.example 为 $cred_file 并填写您的API密钥" >> "$LOG_FILE"
        return 1
    fi
    
    # 检查文件是否可读
    if [ ! -r "$cred_file" ]; then
        echo "错误: DNS凭证文件不可读: $cred_file" >> "$LOG_FILE"
        return 1
    fi
    
    # 读取凭证文件并导出环境变量
    # 只处理未注释的export语句
    while IFS= read -r line || [ -n "$line" ]; do
        # 跳过空行和注释行
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -z "$line" ] || [[ "$line" =~ ^# ]]; then
            continue
        fi
        
        # 如果是export语句，执行它
        if [[ "$line" =~ ^export[[:space:]]+ ]]; then
            # 安全地执行export语句
            eval "$line" 2>/dev/null || {
                echo "警告: 无法加载环境变量: $line" >> "$LOG_FILE"
            }
        fi
    done < "$cred_file"
    
    echo "DNS凭证文件已加载: $cred_file" >> "$LOG_FILE"
    return 0
}

# 函数：根据域名找到对应的nginx配置文件
# 支持通配符和单域名（包括多级域名）的配置文件查找
find_nginx_conf_files() {
    local domain="$1"
    local main_domain=$(extract_main_domain "$domain")
    local conf_files=()
    
    # 如果nginx配置目录未配置，返回空
    if [ -z "$NGINX_CONF_DIR" ] || [ ! -d "$NGINX_CONF_DIR" ]; then
        return 1
    fi
    
    # 判断是否为通配符域名
    local is_wildcard=0
    if validate_wildcard_domain "$domain"; then
        is_wildcard=1
    fi
    
    # 转义主域名中的点，用于正则匹配
    local escaped_domain=$(echo "$main_domain" | sed 's/\./\\./g')
    
    while IFS= read -r -d '' conf_file; do
        # 提取文件名（不含路径和扩展名）
        local filename=$(basename "$conf_file" .conf)
        
        if [ $is_wildcard -eq 1 ]; then
            # 通配符域名匹配规则：
            # *.example.com -> 匹配所有以 .example.com 结尾的配置文件
            # 例如：cn.example.com.conf, en.example.com.conf, api.v1.example.com.conf
            if [[ "$filename" =~ \.${escaped_domain}$ ]] || [[ "$filename" == "$main_domain" ]]; then
                conf_files+=("$conf_file")
            fi
        else
            # 单域名匹配规则（支持多级域名）：
            # 完全匹配：api.v1.example.com -> api.v1.example.com.conf
            # 或者匹配以该域名结尾的配置文件
            if [[ "$filename" == "$main_domain" ]] || [[ "$filename" =~ \.${escaped_domain}$ ]]; then
                conf_files+=("$conf_file")
            fi
        fi
    done < <(find "$NGINX_CONF_DIR" -type f -name "*.conf" -print0 2>/dev/null)
    
    # 输出找到的文件（通过echo，调用者使用命令替换获取）
    if [ ${#conf_files[@]} -gt 0 ]; then
        printf '%s\n' "${conf_files[@]}"
        return 0
    else
        return 1
    fi
}

# 函数：检查nginx配置文件中的SSL证书路径是否正确
check_ssl_cert_path() {
    local conf_file="$1"
    local expected_cert_path="$2"
    local expected_key_path="$3"
    local cert_path=""
    local key_path=""
    
    # 提取当前的ssl_certificate路径（只取第一行，去除首尾空格和引号）
    cert_path=$(grep -E "^\s*ssl_certificate\s+" "$conf_file" 2>/dev/null | head -n1 | sed -E 's/^\s*ssl_certificate\s+([^;]+);.*/\1/' | sed "s/^[[:space:]]*['\"]*//;s/['\"]*[[:space:]]*$//")
    
    # 提取当前的ssl_certificate_key路径（只取第一行，去除首尾空格和引号）
    key_path=$(grep -E "^\s*ssl_certificate_key\s+" "$conf_file" 2>/dev/null | head -n1 | sed -E 's/^\s*ssl_certificate_key\s+([^;]+);.*/\1/' | sed "s/^[[:space:]]*['\"]*//;s/['\"]*[[:space:]]*$//")
    
    # 比较路径（规范化路径进行比较）
    if [ -n "$cert_path" ] && [ -n "$key_path" ]; then
        # 规范化路径（移除末尾斜杠，去除首尾空格）
        local norm_cert_path=$(echo "$cert_path" | sed 's|/$||' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        local norm_key_path=$(echo "$key_path" | sed 's|/$||' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        local norm_expected_cert=$(echo "$expected_cert_path" | sed 's|/$||' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        local norm_expected_key=$(echo "$expected_key_path" | sed 's|/$||' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # 如果路径相同，返回0（正确）
        if [ "$norm_cert_path" = "$norm_expected_cert" ] && [ "$norm_key_path" = "$norm_expected_key" ]; then
            return 0
        fi
    fi
    
    # 路径不正确或不存在，返回1
    return 1
}

# 函数：更新单个nginx配置文件中的SSL证书路径
update_nginx_ssl_cert() {
    local conf_file="$1"
    local new_cert_path="$2"
    local new_key_path="$3"
    local modified=0
    
    # 检查文件是否包含SSL配置
    if ! grep -qE "^\s*ssl_certificate\s+" "$conf_file" 2>/dev/null && \
       ! grep -qE "^\s*ssl_certificate_key\s+" "$conf_file" 2>/dev/null; then
        echo "提示: 配置文件不包含SSL配置，跳过: $conf_file" >> "$LOG_FILE"
        return 0
    fi
    
    # 先检查路径是否正确
    if check_ssl_cert_path "$conf_file" "$new_cert_path" "$new_key_path"; then
        echo "提示: SSL证书路径已正确，无需修改: $conf_file" >> "$LOG_FILE"
        return 0
    fi
    
    # 创建备份文件
    local backup_file="${conf_file}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$conf_file" "$backup_file" || {
        echo "错误: 无法创建备份文件: $conf_file" >> "$LOG_FILE"
        return 1
    }
    
    # 创建临时文件
    local temp_file="${conf_file}.tmp.$$"
    cp "$conf_file" "$temp_file" || {
        echo "错误: 无法创建临时文件: $conf_file" >> "$LOG_FILE"
        rm -f "$backup_file" 2>/dev/null
        return 1
    }
    
    # 替换ssl_certificate路径（匹配各种格式）
    sed -i -E "s|^\s*ssl_certificate\s+[^;]+;|ssl_certificate ${new_cert_path};|g" "$temp_file" 2>/dev/null
    
    # 替换ssl_certificate_key路径
    sed -i -E "s|^\s*ssl_certificate_key\s+[^;]+;|ssl_certificate_key ${new_key_path};|g" "$temp_file" 2>/dev/null
    
    # 检查是否有修改
    if ! cmp -s "$conf_file" "$temp_file" 2>/dev/null; then
        modified=1
        mv "$temp_file" "$conf_file" || {
            echo "错误: 无法更新配置文件: $conf_file" >> "$LOG_FILE"
            rm -f "$temp_file" "$backup_file" 2>/dev/null
            return 1
        }
        echo "已更新Nginx配置文件: $conf_file (备份: $backup_file)" >> "$LOG_FILE"
        echo "  - 新证书路径: ${new_cert_path}" >> "$LOG_FILE"
        echo "  - 新私钥路径: ${new_key_path}" >> "$LOG_FILE"
    else
        rm -f "$temp_file" 2>/dev/null
    fi
    
    # 如果没有实际修改，删除备份
    if [ $modified -eq 0 ]; then
        rm -f "$backup_file" 2>/dev/null
    fi
    
    return $modified
}

# 函数：批量更新域名对应的所有nginx配置文件
update_domain_nginx_configs() {
    local domain="$1"
    local main_domain="$2"
    local new_cert_path="${CERT_DIR}/${main_domain}.pem"
    local new_key_path="${CERT_DIR}/${main_domain}.key"
    local updated_count=0
    local total_count=0
    
    echo "开始查找域名 $domain 对应的Nginx配置文件..." >> "$LOG_FILE"
    
    # 查找所有匹配的conf文件
    local conf_files
    conf_files=$(find_nginx_conf_files "$domain")
    local find_result=$?
    
    if [ $find_result -ne 0 ] || [ -z "$conf_files" ]; then
        echo "警告: 未找到域名 $domain 对应的Nginx配置文件" >> "$LOG_FILE"
        if [ -z "$NGINX_CONF_DIR" ]; then
            echo "提示: 未配置NGINX_CONF_DIR，请在config文件中配置" >> "$LOG_FILE"
        else
            echo "提示: 在目录 $NGINX_CONF_DIR 中未找到匹配的配置文件" >> "$LOG_FILE"
        fi
        return 1
    fi
    
    # 处理每个找到的配置文件
    while IFS= read -r conf_file; do
        if [ -z "$conf_file" ]; then
            continue
        fi
        total_count=$((total_count + 1))
        if update_nginx_ssl_cert "$conf_file" "$new_cert_path" "$new_key_path"; then
            updated_count=$((updated_count + 1))
        fi
    done <<< "$conf_files"
    
    echo "Nginx配置更新完成: 共找到 $total_count 个配置文件，更新 $updated_count 个" >> "$LOG_FILE"
    return 0
}

# 函数：检测系统安装的是nginx还是openresty
detect_web_server() {
    # 检测OpenResty
    if command -v openresty >/dev/null 2>&1; then
        echo "openresty"
        return 0
    fi
    
    # 检测nginx
    if command -v nginx >/dev/null 2>&1; then
        echo "nginx"
        return 0
    fi
    
    # 如果都检测不到，尝试通过进程检测
    if pgrep -x openresty >/dev/null 2>&1; then
        echo "openresty"
        return 0
    fi
    
    if pgrep -x nginx >/dev/null 2>&1; then
        echo "nginx"
        return 0
    fi
    
    # 都检测不到
    echo "unknown"
    return 1
}

# 函数：测试web服务器配置文件
test_web_server_config() {
    local server_type="$1"
    local test_cmd=""
    
    case "$server_type" in
        openresty)
            test_cmd="openresty -t"
            ;;
        nginx)
            test_cmd="nginx -t"
            ;;
        *)
            echo "警告: 无法识别web服务器类型: $server_type，跳过配置测试" >> "$LOG_FILE"
            return 1
            ;;
    esac
    
    echo "正在测试 $server_type 配置文件..." >> "$LOG_FILE"
    if eval "$test_cmd" >> "$LOG_FILE" 2>&1; then
        echo "$server_type 配置文件测试通过" >> "$LOG_FILE"
        return 0
    else
        echo "错误: $server_type 配置文件测试失败" >> "$LOG_FILE"
        echo "请检查配置文件是否有错误，修复后再执行reload" >> "$LOG_FILE"
        return 1
    fi
}

# 函数：执行web服务器reload
reload_web_server() {
    local server_type="$1"
    local reload_cmd=""
    
    case "$server_type" in
        openresty)
            reload_cmd="openresty -s reload"
            ;;
        nginx)
            reload_cmd="nginx -s reload"
            ;;
        *)
            echo "警告: 无法识别web服务器类型: $server_type，跳过reload" >> "$LOG_FILE"
            return 1
            ;;
    esac
    
    # 先测试配置文件
    if ! test_web_server_config "$server_type"; then
        echo "错误: 配置文件测试失败，跳过reload操作" >> "$LOG_FILE"
        return 1
    fi
    
    # 配置文件测试通过，执行reload
    echo "正在执行 $server_type reload..." >> "$LOG_FILE"
    if eval "$reload_cmd" >> "$LOG_FILE" 2>&1; then
        echo "$server_type reload 成功" >> "$LOG_FILE"
        return 0
    else
        echo "错误: $server_type reload 失败" >> "$LOG_FILE"
        return 1
    fi
}

# 函数：交互式询问是否更新nginx配置
ask_update_nginx_config() {
    local domain="$1"
    local main_domain="$2"
    
    # 检查是否配置了nginx目录
    if [ -z "$NGINX_CONF_DIR" ] || [ ! -d "$NGINX_CONF_DIR" ]; then
        echo "提示: 未配置或Nginx配置目录不存在，跳过配置更新" >> "$LOG_FILE"
        return 1
    fi
    
    # 检查是否能找到对应的配置文件
    local conf_files
    conf_files=$(find_nginx_conf_files "$domain")
    if [ $? -ne 0 ] || [ -z "$conf_files" ]; then
        echo "提示: 未找到域名 $domain 对应的配置文件，跳过配置更新" >> "$LOG_FILE"
        return 1
    fi
    
    # 显示找到的配置文件
    echo "" >> "$LOG_FILE"
    echo "找到以下Nginx配置文件需要更新:" >> "$LOG_FILE"
    while IFS= read -r conf_file; do
        if [ -n "$conf_file" ]; then
            echo "  - $conf_file" >> "$LOG_FILE"
        fi
    done <<< "$conf_files"
    
    # 交互式询问（同时输出到日志和终端）
    echo "" >> "$LOG_FILE"
    echo "是否将证书配置到OpenResty的server配置文件中? (y/n): " >> "$LOG_FILE"
    
    # 从终端读取用户输入（如果脚本在交互式环境中运行）
    if [ -t 0 ]; then
        echo ""
        echo "找到以下Nginx配置文件需要更新:"
        while IFS= read -r conf_file; do
            if [ -n "$conf_file" ]; then
                echo "  - $conf_file"
            fi
        done <<< "$conf_files"
        echo ""
        read -p "是否将证书配置到OpenResty的server配置文件中? (y/n): " answer
        echo "用户输入: $answer" >> "$LOG_FILE"
        
        case "$answer" in
            [Yy]|[Yy][Ee][Ss])
                update_domain_nginx_configs "$domain" "$main_domain"
                return 0
                ;;
            *)
                echo "用户选择跳过配置更新" >> "$LOG_FILE"
                return 1
                ;;
        esac
    else
        # 非交互式环境，默认跳过
        echo "非交互式环境，跳过配置更新" >> "$LOG_FILE"
        return 1
    fi
}

echo "=============================================================" >> "$LOG_FILE"
echo "任务开始时间: $(date)" >> "$LOG_FILE"
echo "脚本目录: $SCRIPT_DIR" >> "$LOG_FILE"
echo "日志文件: $LOG_FILE" >> "$LOG_FILE"
echo "证书目录: $CERT_DIR" >> "$LOG_FILE"
echo "配置文件: $CONFIG_FILE" >> "$LOG_FILE"
echo "acme.sh 路径: $ACME_SH_PATH" >> "$LOG_FILE"
echo "CA提供商: $CA_PROVIDER" >> "$LOG_FILE"
echo "DNS凭证文件: $DNS_CREDENTIALS_FILE" >> "$LOG_FILE"
echo "注意: 每个域名必须明确指定DNS提供商（格式: 域名|DNS提供商）" >> "$LOG_FILE"
if [ -n "$NGINX_CONF_DIR" ] && [ -d "$NGINX_CONF_DIR" ]; then
    echo "Nginx配置目录: $NGINX_CONF_DIR" >> "$LOG_FILE"
else
    echo "提示: Nginx配置目录未配置或不存在" >> "$LOG_FILE"
fi

# 1. 升级 acme.sh
echo "正在检查更新 acme.sh..." >> "$LOG_FILE"
"$ACME_SH_PATH" --upgrade >> "$LOG_FILE" 2>&1

# 2. 设置默认 CA（使用配置的CA提供商）
echo "设置CA提供商: $CA_PROVIDER" >> "$LOG_FILE"
"$ACME_SH_PATH" --set-default-ca --server "$CA_PROVIDER" >> "$LOG_FILE" 2>&1

# 加载DNS API凭证
echo "正在加载DNS API凭证..." >> "$LOG_FILE"
if ! load_dns_credentials "$DNS_CREDENTIALS_FILE"; then
    echo "警告: DNS凭证加载失败，证书申请可能会失败" >> "$LOG_FILE"
    echo "请确保已正确配置DNS API凭证" >> "$LOG_FILE"
fi

# 3. 统计域名总数并检查DNS提供商配置
TOTAL_DOMAINS=$(grep -v '^[[:space:]]*$' "$CONFIG_FILE" | grep -v '^#' | grep -v '^NGINX_CONF_DIR=' | grep -v '^DNS_PROVIDER=' | grep -v '^CA_PROVIDER=' | grep -v '^DNS_CREDENTIALS_FILE=' | wc -l)
CURRENT_DOMAIN=0
SUCCESSFUL_DOMAINS=()

echo "共发现 $TOTAL_DOMAINS 个域名需要处理" >> "$LOG_FILE"

# 3.1 检查域名DNS提供商配置情况
DOMAINS_WITHOUT_DNS=()
DOMAINS_WITH_DNS=()
DNS_PROVIDERS_USED=()

while IFS= read -r domain_line || [ -n "$domain_line" ]; do
    domain_line=$(echo "$domain_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    # 跳过空行、注释行和配置行
    if [ -z "$domain_line" ] || [[ "$domain_line" =~ ^# ]] || \
       [[ "$domain_line" =~ ^NGINX_CONF_DIR= ]] || \
       [[ "$domain_line" =~ ^DNS_PROVIDER= ]] || \
       [[ "$domain_line" =~ ^CA_PROVIDER= ]] || \
       [[ "$domain_line" =~ ^DNS_CREDENTIALS_FILE= ]]; then
        continue
    fi
    
    # 检查是否指定了DNS提供商
    if [[ "$domain_line" =~ \| ]]; then
        domain=$(echo "$domain_line" | cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        dns_provider=$(echo "$domain_line" | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -n "$domain" ] && [ -n "$dns_provider" ]; then
            DOMAINS_WITH_DNS+=("$domain|$dns_provider")
            # 记录使用的DNS提供商（去重）
            if [[ ! " ${DNS_PROVIDERS_USED[@]} " =~ " ${dns_provider} " ]]; then
                DNS_PROVIDERS_USED+=("$dns_provider")
            fi
        fi
    else
        # 未指定DNS提供商，将使用默认值
        if [ -n "$domain_line" ]; then
            DOMAINS_WITHOUT_DNS+=("$domain_line")
        fi
    fi
done < "$CONFIG_FILE"

# 3.2 强制检查：如果发现未指定DNS提供商的域名，直接报错退出
if [ ${#DOMAINS_WITHOUT_DNS[@]} -gt 0 ]; then
    echo "" >> "$LOG_FILE"
    echo "❌ 错误: 发现 ${#DOMAINS_WITHOUT_DNS[@]} 个域名未指定DNS提供商！" >> "$LOG_FILE"
    echo "未指定DNS提供商的域名:" >> "$LOG_FILE"
    for domain in "${DOMAINS_WITHOUT_DNS[@]}"; do
        echo "  - $domain" >> "$LOG_FILE"
    done
    echo "" >> "$LOG_FILE"
    echo "❌ 错误: 必须为每个域名明确指定DNS提供商！" >> "$LOG_FILE"
    echo "格式: 域名|DNS提供商" >> "$LOG_FILE"
    echo "示例: *.example.com|dns_gd" >> "$LOG_FILE"
    echo "示例: www.example.com|dns_ali" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
    echo "请修改配置文件，为所有域名明确指定DNS提供商后重试。" >> "$LOG_FILE"
    
    # 输出错误信息到终端
    echo ""
    echo "❌ 错误: 发现未指定DNS提供商的域名！"
    echo "未指定DNS提供商的域名:"
    for domain in "${DOMAINS_WITHOUT_DNS[@]}"; do
        echo "  - $domain"
    done
    echo ""
    echo "❌ 必须为每个域名明确指定DNS提供商！"
    echo "格式: 域名|DNS提供商"
    echo "示例: *.example.com|dns_gd"
    echo "示例: www.example.com|dns_ali"
    echo ""
    echo "请修改配置文件后重试。"
    
    exit 1
fi

echo "-------------------------------------------------------------" >> "$LOG_FILE"

# 4. 循环处理每个域名
while IFS= read -r domain_line || [ -n "$domain_line" ]; do
    # 跳过空行、注释行和配置行
    domain_line=$(echo "$domain_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -z "$domain_line" ] || [[ "$domain_line" =~ ^# ]] || \
       [[ "$domain_line" =~ ^NGINX_CONF_DIR= ]] || \
       [[ "$domain_line" =~ ^DNS_PROVIDER= ]] || \
       [[ "$domain_line" =~ ^CA_PROVIDER= ]] || \
       [[ "$domain_line" =~ ^DNS_CREDENTIALS_FILE= ]]; then
        continue
    fi
    
    CURRENT_DOMAIN=$((CURRENT_DOMAIN + 1))
    
    # 解析域名和DNS提供商
    # 格式：域名|DNS提供商（强制要求）
    DOMAIN_DNS_PROVIDER=""
    if [[ "$domain_line" =~ \| ]]; then
        # 包含 | 分隔符，提取域名和DNS提供商
        domain=$(echo "$domain_line" | cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        DOMAIN_DNS_PROVIDER=$(echo "$domain_line" | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    else
        # 不包含 | 分隔符，这是不允许的，应该在前面的检查中已经被捕获
        # 但为了安全，这里再次检查并报错
        echo "❌ 错误: 域名未指定DNS提供商: $domain_line" >> "$LOG_FILE"
        echo "格式: 域名|DNS提供商" >> "$LOG_FILE"
        echo "示例: *.example.com|dns_gd" >> "$LOG_FILE"
        echo "跳过此域名" >> "$LOG_FILE"
        continue
    fi
    
    # 验证域名不为空
    if [ -z "$domain" ]; then
        echo "警告: 跳过空域名行: $domain_line" >> "$LOG_FILE"
        continue
    fi
    
    # 验证DNS提供商不为空（强制要求）
    if [ -z "$DOMAIN_DNS_PROVIDER" ]; then
        echo "❌ 错误: 域名 $domain 未指定DNS提供商！" >> "$LOG_FILE"
        echo "格式: 域名|DNS提供商" >> "$LOG_FILE"
        echo "示例: $domain|dns_gd" >> "$LOG_FILE"
        echo "跳过此域名" >> "$LOG_FILE"
        continue
    fi
    
    # 判断域名类型（通配符或单域名）
    IS_WILDCARD=0
    if validate_wildcard_domain "$domain"; then
        IS_WILDCARD=1
    fi
    
    # 从域名中提取主域名（用于生成证书文件名）
    MAIN_DOMAIN=$(extract_main_domain "$domain")
    
    # 确定证书类型描述
    if [ $IS_WILDCARD -eq 1 ]; then
        CERT_TYPE="通配符证书"
    else
        CERT_TYPE="单域名证书"
    fi
    
    echo "" >> "$LOG_FILE"
    echo "[$CURRENT_DOMAIN/$TOTAL_DOMAINS] 正在处理域名: $domain" >> "$LOG_FILE"
    echo "证书类型: $CERT_TYPE" >> "$LOG_FILE"
    echo "使用域名: $domain" >> "$LOG_FILE"
    echo "主域名: $MAIN_DOMAIN" >> "$LOG_FILE"
    echo "DNS提供商: $DOMAIN_DNS_PROVIDER" >> "$LOG_FILE"
    echo "-------------------------------------------------------------" >> "$LOG_FILE"
    
    # 4.1 申请/续签证书
    # 注意：--dnssleep 300 参数会让程序内部等待300秒
    # 使用域名指定的DNS提供商和原始域名格式申请证书（支持通配符和单域名）
    echo "开始申请/续签证书: $domain ($CERT_TYPE)" >> "$LOG_FILE"
    echo "DNS提供商: $DOMAIN_DNS_PROVIDER" >> "$LOG_FILE"
    echo "CA提供商: $CA_PROVIDER" >> "$LOG_FILE"
    
    # 验证DNS提供商格式（应该以 dns_ 开头）
    if [[ ! "$DOMAIN_DNS_PROVIDER" =~ ^dns_ ]]; then
        echo "错误: DNS提供商格式不正确: $DOMAIN_DNS_PROVIDER，应为 dns_xxx 格式" >> "$LOG_FILE"
        echo "跳过域名: $domain" >> "$LOG_FILE"
        continue
    fi
    
    if "$ACME_SH_PATH" --issue --dns "$DOMAIN_DNS_PROVIDER" \
        -d "$domain" \
        --dnssleep 300 >> "$LOG_FILE" 2>&1; then
        echo "证书申请/续签成功: $domain ($CERT_TYPE)" >> "$LOG_FILE"
    else
        echo "警告: 证书申请/续签失败: $domain，DNS提供商: $DOMAIN_DNS_PROVIDER，跳过安装步骤" >> "$LOG_FILE"
        echo "提示: 请检查DNS提供商是否正确，以及对应的API凭证是否已配置" >> "$LOG_FILE"
        continue
    fi
    
    # 4.2 安装证书
    # 注意：不在安装时执行reload，将在所有操作完成后统一执行
    echo "开始安装证书: $domain" >> "$LOG_FILE"
    
    if "$ACME_SH_PATH" --install-cert \
        -d "$domain" \
        --key-file "${CERT_DIR}/${MAIN_DOMAIN}.key" \
        --fullchain-file "${CERT_DIR}/${MAIN_DOMAIN}.pem" >> "$LOG_FILE" 2>&1; then
        echo "证书安装成功: $domain" >> "$LOG_FILE"
        SUCCESSFUL_DOMAINS+=("$domain|$MAIN_DOMAIN")
    else
        echo "错误: 证书安装失败: $domain" >> "$LOG_FILE"
    fi
    
done < "$CONFIG_FILE"

# 5. 证书生成完毕后，询问是否更新nginx配置
NGINX_CONFIG_UPDATED=0
if [ ${#SUCCESSFUL_DOMAINS[@]} -gt 0 ]; then
    echo "" >> "$LOG_FILE"
    echo "-------------------------------------------------------------" >> "$LOG_FILE"
    echo "证书生成完成，共成功生成 ${#SUCCESSFUL_DOMAINS[@]} 个证书" >> "$LOG_FILE"
    echo "开始处理Nginx配置更新..." >> "$LOG_FILE"
    echo "-------------------------------------------------------------" >> "$LOG_FILE"
    
    for domain_info in "${SUCCESSFUL_DOMAINS[@]}"; do
        IFS='|' read -r domain main_domain <<< "$domain_info"
        echo "" >> "$LOG_FILE"
        echo "处理域名: $domain" >> "$LOG_FILE"
        if ask_update_nginx_config "$domain" "$main_domain"; then
            # 如果更新了配置，记录标志
            NGINX_CONFIG_UPDATED=1
        fi
    done
fi

# 6. 所有操作完成后，统一执行web服务器reload
# 只有在证书安装成功且nginx配置更新成功的情况下才执行reload
if [ ${#SUCCESSFUL_DOMAINS[@]} -gt 0 ]; then
    echo "" >> "$LOG_FILE"
    echo "-------------------------------------------------------------" >> "$LOG_FILE"
    echo "开始检测web服务器类型并执行reload..." >> "$LOG_FILE"
    
    # 检测web服务器类型
    WEB_SERVER_TYPE=$(detect_web_server)
    if [ "$WEB_SERVER_TYPE" != "unknown" ]; then
        echo "检测到web服务器: $WEB_SERVER_TYPE" >> "$LOG_FILE"
        
        # 执行reload
        if reload_web_server "$WEB_SERVER_TYPE"; then
            echo "$WEB_SERVER_TYPE reload 执行成功" >> "$LOG_FILE"
        else
            echo "警告: $WEB_SERVER_TYPE reload 执行失败，请手动检查" >> "$LOG_FILE"
        fi
    else
        echo "警告: 无法检测到web服务器（nginx或openresty），跳过reload" >> "$LOG_FILE"
        echo "提示: 请确保已安装nginx或openresty，或手动执行reload" >> "$LOG_FILE"
    fi
fi

echo "" >> "$LOG_FILE"
echo "-------------------------------------------------------------" >> "$LOG_FILE"
echo "任务结束时间: $(date)" >> "$LOG_FILE"
echo "=============================================================" >> "$LOG_FILE"