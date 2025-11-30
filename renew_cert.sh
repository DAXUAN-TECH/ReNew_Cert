#!/bin/bash

# Let's Encrypt 限制每个域名每周只能签发5次重复证书

# 设置错误处理
# -u: 使用未定义变量时报错（提高代码质量，防止使用未定义变量）
# 注意：不使用 -e，因为脚本需要在某些错误时继续执行（如证书申请失败时继续处理下一个域名）
# 注意：不使用 -o pipefail，因为某些管道的失败是预期的（如 grep 未找到匹配时）
set -u

# 定义脚本所在目录（兼容各种调用方式）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 解析命令行参数
SCRIPT_MODE="normal"  # 默认模式：正常执行证书申请和配置更新
if [ $# -gt 0 ]; then
    case "$1" in
        resetconf)
            SCRIPT_MODE="resetconf"
            ;;
        -h|--help|help)
            echo "用法: $0 [resetconf]"
            echo ""
            echo "参数说明:"
            echo "  无参数        - 正常执行：申请/续签证书并更新Nginx配置"
            echo "  resetconf     - 仅更新模式：只更新Nginx/OpenResty配置文件中的SSL证书路径"
            echo "  -h, --help    - 显示此帮助信息"
            echo ""
            echo "示例:"
            echo "  $0              # 正常执行证书申请和配置更新"
            echo "  $0 resetconf    # 仅更新Nginx配置文件中的SSL证书路径"
            exit 0
            ;;
        *)
            echo "错误: 未知参数: $1"
            echo "使用 '$0 --help' 查看帮助信息"
            exit 1
            ;;
    esac
fi

# 临时文件列表（用于清理）
TEMP_FILES=()

# 清理函数：删除所有临时文件
cleanup_temp_files() {
    local file
    # 检查数组是否为空（兼容 set -u 模式）
    if [ ${#TEMP_FILES[@]} -gt 0 ]; then
        for file in "${TEMP_FILES[@]}"; do
            if [ -n "$file" ] && [ -f "$file" ]; then
                rm -f "$file" 2>/dev/null || true
            fi
        done
    fi
    # 清空临时文件数组
    TEMP_FILES=()
}

# 注册退出时清理临时文件
trap cleanup_temp_files EXIT INT TERM

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

# 函数：带倒计时的交互式输入（30秒超时，默认返回y）
# 参数：
#   $1: 提示信息
#   $2: 超时时间（秒，默认30）
#   $3: 默认值（默认y）
# 返回值：
#   通过全局变量 READ_TIMEOUT_ANSWER 返回用户输入或默认值
read_with_timeout() {
    local prompt="$1"
    local timeout="${2:-30}"
    local default_value="${3:-y}"
    
    # 如果不在交互式环境，直接返回默认值
    if [ ! -t 0 ]; then
        READ_TIMEOUT_ANSWER="$default_value"
        return 0
    fi
    
    local answer=""
    local countdown=$timeout
    
    # 在后台显示倒计时（使用文件描述符3避免干扰stdin/stdout）
    (
        while [ $countdown -gt 0 ]; do
            # 使用 \r 和 \033[K 来在同一行更新倒计时
            # 输出到stderr，避免干扰stdin
            printf "\r\033[K%s (默认: %s, 剩余: %d秒): " "$prompt" "$default_value" "$countdown" >&2
            sleep 1
            countdown=$((countdown - 1))
        done
        # 倒计时结束，显示默认值
        printf "\r\033[K%s (默认: %s, 已超时，使用默认值)\n" "$prompt" "$default_value" >&2
    ) &
    local countdown_pid=$!
    
    # 读取用户输入（带超时）
    # 注意：不使用 -p 参数，因为提示信息已经在倒计时中显示
    # 从标准输入读取，超时时间由 -t 参数指定
    if read -t "$timeout" answer 2>/dev/null; then
        # 用户输入了内容（包括直接按回车），停止倒计时进程
        kill $countdown_pid 2>/dev/null || true
        wait $countdown_pid 2>/dev/null || true
        # 清除倒计时行并换行
        printf "\r\033[K" >&2
        # 如果用户输入为空（直接按回车），使用默认值
        if [ -z "$answer" ]; then
            READ_TIMEOUT_ANSWER="$default_value"
            log_and_echo "用户按回车键，使用默认值: $default_value"
        else
            READ_TIMEOUT_ANSWER="$answer"
        fi
    else
        # 超时或读取失败，停止倒计时进程
        kill $countdown_pid 2>/dev/null || true
        wait $countdown_pid 2>/dev/null || true
        # 使用默认值
        READ_TIMEOUT_ANSWER="$default_value"
    fi
    
    return 0
}

# 函数：安装acme.sh
install_acme() {
    log_and_echo "开始安装 acme.sh..."
    echo "正在安装 acme.sh，请稍候..." >&2
    
    # 使用官方安装脚本，同时输出到控制台和日志
    if curl -s https://get.acme.sh | sh 2>&1 | tee -a "$LOG_FILE"; then
        log_and_echo "acme.sh 安装成功"
        
        # 重新加载shell配置（如果存在）
        if [ -f "$HOME/.bashrc" ]; then
            source "$HOME/.bashrc" >/dev/null 2>&1 || true
        fi
        if [ -f "$HOME/.profile" ]; then
            source "$HOME/.profile" >/dev/null 2>&1 || true
        fi
        
        return 0
    else
        log_and_echo "错误: acme.sh 安装失败"
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
        read_with_timeout "是否现在安装 acme.sh? (y/n)" 30 "y"
        answer="$READ_TIMEOUT_ANSWER"
        log_and_echo "用户选择: $answer"
        
        case "$answer" in
            [Yy]|[Yy][Ee][Ss])
                return 0
                ;;
            *)
                log_and_echo "用户选择不安装 acme.sh，脚本退出"
                echo "用户选择不安装，脚本退出" >&2
                return 1
                ;;
        esac
    else
        # 非交互式环境，记录日志并退出
        log_and_echo "错误: 系统未安装 acme.sh，且当前为非交互式环境，无法询问用户"
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

# 函数：验证域名格式是否正确
# 支持的格式：
# 1. 通配符格式：
#    *.example.com, *.v1.example.com, *.api.v1.example.com
#    *.test.api.v1.example.com, *.dev.test.api.v1.example.com（支持任意层级）
# 2. 单域名格式（支持任意层级，支持子域名带数字）：
#    二级域名：example.com, example123.com
#    三级域名：www.example.com, www123.example.com, api.v1.example.com
#    四级域名：api.v1.example.com, test.api.v1.example.com, api123.v1.example.com
#    五级域名：dev.test.api.v1.example.com, test123.api.v1.example.com
#    六级域名：prod.dev.test.api.v1.example.com（支持任意层级）
# 说明：
#   - 子域名部分（非TLD）可以包含数字，如 example123.com, www123.example.com
#   - 子域名部分可以包含下划线，如 example_test.com, api_v1.example.com
#   - TLD（最后一个部分）必须是纯字母，支持所有TLD（包括新TLD）
#   - 支持的TLD示例：.com, .org, .cn, .vip, .tech, .ren, .me 等所有纯字母TLD
#   - 支持任意层级的域名（二级、三级、四级、五级、六级等）
#   - 注意：下划线在域名中虽然被允许，但可能不被某些CA（如Let's Encrypt）支持，建议谨慎使用
# 返回值：
#   0: 格式正确
#   1: 格式错误
validate_domain_format() {
    local domain="$1"
    
    # 检查域名是否为空
    if [ -z "$domain" ]; then
        return 1
    fi
    
    # 检查是否包含 .conf 后缀（不允许）
    if [[ "$domain" =~ \.conf$ ]]; then
        return 1
    fi
    
    # 检查是否包含非法字符（只允许字母、数字、点、连字符、下划线、星号）
    # 注意：下划线虽然被允许，但可能不被某些CA支持，建议谨慎使用
    if [[ ! "$domain" =~ ^[a-zA-Z0-9._\*-]+$ ]]; then
        return 1
    fi
    
    # 检查通配符格式
    if [[ "$domain" =~ ^\*\. ]]; then
        # 通配符格式（支持任意层级，支持所有TLD）：
        # *.example.com, *.v1.example.com, *.api.v1.example.com
        # *.test.api.v1.example.com, *.dev.test.api.v1.example.com（支持任意层级）
        # *.example.vip, *.example.tech, *.example.ren, *.example.me（支持所有TLD）
        # 提取主域名部分（去掉 *. 前缀）
        local main_part=$(echo "$domain" | sed 's/^\*\.//')
        
        # 验证主域名部分
        if [ -z "$main_part" ]; then
            return 1
        fi
        
        # 主域名不能以点开头或结尾
        if [[ "$main_part" =~ ^\. ]] || [[ "$main_part" =~ \.$ ]]; then
            return 1
        fi
        
        # 主域名不能包含连续的点
        if [[ "$main_part" =~ \.\. ]]; then
            return 1
        fi
        
        # 主域名必须至少包含一个点（至少是二级域名）
        if [[ ! "$main_part" =~ \. ]]; then
            return 1
        fi
        
        # 主域名各部分长度检查（每个部分1-63个字符）
        local IFS='.'
        local parts=($main_part)
        for part in "${parts[@]}"; do
            if [ ${#part} -eq 0 ] || [ ${#part} -gt 63 ]; then
                return 1
            fi
            # 每个部分不能以连字符开头或结尾
            if [[ "$part" =~ ^- ]] || [[ "$part" =~ -$ ]]; then
                return 1
            fi
        done
        
        return 0
    else
        # 单域名格式（支持任意层级，支持子域名带数字和下划线，支持所有TLD）：
        # example.com, example123.com, example_test.com, example.vip, example.tech
        # www.example.com, www123.example.com, api_v1.example.com, www.example.ren
        # api.v1.example.com, api123.v1.example.com, test_api.v1.example.com, api.v1.example.me
        # dev.test.api.v1.example.com, prod.dev.test.api.v1.example.com（支持任意层级）
        # 域名不能以点开头或结尾
        if [[ "$domain" =~ ^\. ]] || [[ "$domain" =~ \.$ ]]; then
            return 1
        fi
        
        # 域名不能包含连续的点
        if [[ "$domain" =~ \.\. ]]; then
            return 1
        fi
        
        # 域名必须至少包含一个点（至少是二级域名）
        if [[ ! "$domain" =~ \. ]]; then
            return 1
        fi
        
        # 域名各部分长度检查（每个部分1-63个字符）
        local IFS='.'
        local parts=($domain)
        local parts_count=${#parts[@]}
        local part_index=0
        for part in "${parts[@]}"; do
            if [ ${#part} -eq 0 ] || [ ${#part} -gt 63 ]; then
                return 1
            fi
            # 每个部分不能以连字符开头或结尾
            if [[ "$part" =~ ^- ]] || [[ "$part" =~ -$ ]]; then
                return 1
            fi
            # 最后一个部分（TLD）必须是纯字母（不能包含数字、下划线、连字符）
            # 支持所有TLD：.com, .org, .cn, .vip, .tech, .ren, .me 等
            if [ $part_index -eq $((parts_count - 1)) ]; then
                if [[ ! "$part" =~ ^[a-zA-Z]+$ ]]; then
                    return 1
                fi
            fi
            part_index=$((part_index + 1))
        done
        
        return 0
    fi
}

# 函数：从域名中提取主域名（用于生成证书文件名）
# 支持两种格式和多级域名（支持任意层级，支持子域名带数字和下划线，支持所有TLD）：
# 1. 通配符格式：
#    *.example.com -> example.com
#    *.v1.example.com -> v1.example.com
#    *.api.v1.example.com -> api.v1.example.com
#    *.test.api.v1.example.com -> test.api.v1.example.com（支持任意层级）
#    *.example.vip -> example.vip, *.example.tech -> example.tech（支持所有TLD）
# 2. 单域名格式（支持任意层级，支持子域名带数字和下划线，支持所有TLD）：
#    二级域名：example.com -> example.com, example123.com -> example123.com
#              example_test.com -> example_test.com, example.vip -> example.vip
#    三级域名：www.example.com -> www.example.com, www123.example.com -> www123.example.com
#              api_v1.example.com -> api_v1.example.com, www.example.tech -> www.example.tech
#    四级域名：api.v1.example.com -> api.v1.example.com, api123.v1.example.com -> api123.v1.example.com
#              test_api.v1.example.com -> test_api.v1.example.com, api.v1.example.ren -> api.v1.example.ren
#    五级及以上：dev.test.api.v1.example.com -> dev.test.api.v1.example.com（支持任意层级）
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

# 函数：同时输出到控制台和日志文件
log_and_echo() {
    local message="$1"
    # 输出到控制台
    echo "$message"
    # 确保日志目录存在
    if [ -n "$LOG_DIR" ] && [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR" 2>/dev/null || true
    fi
    # 同时追加到日志文件（如果目录存在）
    if [ -n "$LOG_FILE" ] && [ -d "$LOG_DIR" ]; then
        echo "$message" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

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

# 如果是resetconf模式，跳过acme.sh检查（不需要acme.sh）
if [ "$SCRIPT_MODE" != "resetconf" ]; then
    # 检查并安装acme.sh
    ACME_SH_PATH=""
    if ! ACME_SH_PATH=$(check_acme_installed); then
        log_and_echo "检测到系统未安装 acme.sh"
        if ask_install_acme; then
            if install_acme; then
                # 安装后重新检查路径
                if ! ACME_SH_PATH=$(check_acme_installed); then
                    log_and_echo "错误: acme.sh 安装后仍无法找到，请手动检查"
                    echo "错误: acme.sh 安装后仍无法找到，请手动检查" >&2
                    exit 1
                fi
            else
                log_and_echo "错误: acme.sh 安装失败，脚本退出"
                exit 1
            fi
        else
            exit 1
        fi
    else
        log_and_echo "检测到 acme.sh 已安装: $ACME_SH_PATH"
    fi
    
    # 验证acme.sh可执行性
    if [ ! -x "$ACME_SH_PATH" ]; then
        log_and_echo "错误: acme.sh 文件不可执行: $ACME_SH_PATH"
        echo "错误: acme.sh 文件不可执行: $ACME_SH_PATH" >&2
        exit 1
    fi
fi

# 检查配置文件是否存在
if [ ! -f "$CONFIG_FILE" ]; then
    log_and_echo "错误: 配置文件 $CONFIG_FILE 不存在"
    log_and_echo "请创建配置文件，每行一个域名（支持通配符，如 *.example.com）"
    exit 1
fi

# 从配置文件中读取配置项
NGINX_CONF_DIR=""
CA_PROVIDER="letsencrypt"  # 默认值：Let's Encrypt
DNS_CREDENTIALS_FILE="dns_credentials"  # 默认值：脚本同级目录下的dns_credentials文件
DNS_SLEEP=300  # 默认值：300秒（5分钟）

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
    
    # 检查是否是DNS_SLEEP配置
    if [[ "$line" =~ ^DNS_SLEEP= ]]; then
        DNS_SLEEP=$(echo "$line" | sed 's/^DNS_SLEEP=//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        # 验证DNS_SLEEP是否为有效数字
        if ! [[ "$DNS_SLEEP" =~ ^[0-9]+$ ]] || [ "$DNS_SLEEP" -lt 0 ]; then
            log_and_echo "警告: DNS_SLEEP配置无效: $DNS_SLEEP，使用默认值: 300"
            DNS_SLEEP=300
        fi
        continue
    fi
done < "$CONFIG_FILE"

# 处理DNS凭证文件路径（如果是相对路径，转换为绝对路径）
if [[ ! "$DNS_CREDENTIALS_FILE" =~ ^/ ]]; then
    DNS_CREDENTIALS_FILE="${SCRIPT_DIR}/${DNS_CREDENTIALS_FILE}"
fi

# 函数：加载DNS API凭证（默认账号）
load_dns_credentials() {
    local cred_file="$1"
    
    if [ ! -f "$cred_file" ]; then
        log_and_echo "警告: DNS凭证文件不存在: $cred_file"
        log_and_echo "提示: 请复制 dns_credentials.example 为 $cred_file 并填写您的API密钥"
        return 1
    fi
    
    # 检查文件是否可读
    if [ ! -r "$cred_file" ]; then
        log_and_echo "错误: DNS凭证文件不可读: $cred_file"
        return 1
    fi
    
    # 读取凭证文件并导出环境变量
    # 只处理未注释的export语句（默认账号，不带账号标识的）
    local found_credentials=0
    while IFS= read -r line || [ -n "$line" ]; do
        # 跳过空行和注释行
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -z "$line" ] || [[ "$line" =~ ^# ]]; then
            continue
        fi
        
        # 如果是export语句，且不包含账号标识（不包含 _account 或 _ 后缀的账号标识），执行它
        # 排除格式：_accountXXX 或 _XXX（其中XXX是账号标识，如 _account1, _account2 等）
        if [[ "$line" =~ ^export[[:space:]]+ ]]; then
            # 提取变量名
            local var_name=$(echo "$line" | sed 's/^export[[:space:]]*//' | cut -d'=' -f1)
            
            # 检查是否是默认账号变量（不包含账号标识后缀）
            # 排除：_accountXXX 格式（标准格式）
            if [[ "$var_name" =~ _account[0-9a-zA-Z_]+$ ]]; then
                continue
            fi
            
            # 排除：_XXX 格式（简化格式，如 _account1, _account2）
            # 如果变量名以 _ 加字母数字下划线组合结尾，且不是标准DNS变量名，则可能是账号标识
            # 标准DNS变量名通常以 Key, Secret, Token, Id 等结尾，不应该有额外的下划线后缀
            # 例如：Ali_Key_account1 应该被排除，但 Ali_Key 应该被包含
            # 注意：某些标准变量名本身可能包含下划线（如 AWS_ACCESS_KEY_ID），这些应该被包含
            
            # 检查是否是简化格式的账号标识：变量名以 _字母数字组合结尾
            # 但需要排除标准变量名（如 Ali_Key, GD_Key 等）
            # 如果变量名匹配模式：VAR_XXX（其中XXX是字母数字组合，且不是标准变量名的一部分）
            if [[ "$var_name" =~ _[a-zA-Z0-9_]+$ ]]; then
                # 检查是否是标准DNS变量名（这些应该被包含）
                # 标准变量名通常以 Key, Secret, Token, Id, Email, Username, Password 等结尾
                local is_standard_var=0
                if [[ "$var_name" =~ (Key|Secret|Token|Id|Email|Username|Password|Region|API_KEY|SECRET_KEY|ACCESS_KEY|SECRET_ACCESS_KEY)$ ]]; then
                    # 可能是标准变量名，但需要进一步检查
                    # 如果变量名是 Ali_Key, GD_Key 等标准格式，则包含
                    # 如果变量名是 Ali_Key_account1 等带账号标识的格式，则排除
                    # 我们通过检查变量名是否以已知的标准前缀开头来判断
                    if [[ "$var_name" =~ ^(Ali_|GD_|CF_|DP_|AWS_|Tencent_|HE_|DO_|LINODE_|OVH_|VULTR_|PORKBUN_|ME_|NAMECHEAP_|CLOUDSDK_) ]]; then
                        # 检查是否还有额外的下划线后缀（可能是账号标识）
                        # 例如：Ali_Key_account1 应该被排除，但 Ali_Key 应该被包含
                        # 标准变量名格式通常是：前缀_后缀（如 Ali_Key），不应该有第三个下划线分隔的部分
                        local underscore_count=$(echo "$var_name" | grep -o '_' | wc -l)
                        if [ $underscore_count -gt 1 ]; then
                            # 有多个下划线，可能是带账号标识的变量（如 Ali_Key_account1），排除
                            continue
                        fi
                        is_standard_var=1
                    fi
                fi
                
                # 如果不是标准变量名，且以 _字母数字组合结尾，则可能是账号标识，排除
                if [ $is_standard_var -eq 0 ]; then
                    continue
                fi
            fi
            
            # 安全地执行export语句
            # 验证格式：export VAR_NAME="value" 或 export VAR_NAME='value' 或 export VAR_NAME=value
            if [[ "$line" =~ ^export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*= ]]; then
                eval "$line" 2>/dev/null || {
                    log_and_echo "警告: 无法加载环境变量: $line"
                }
                found_credentials=1
            else
                log_and_echo "警告: 环境变量格式不正确，跳过: $line"
            fi
        fi
    done < "$cred_file"
    
    if [ $found_credentials -eq 0 ]; then
        return 1
    fi
    
    return 0
}

# 函数：加载指定账号的DNS API凭证
load_dns_credentials_for_account() {
    local cred_file="$1"
    local dns_provider="$2"
    local account_id="$3"
    
    if [ -z "$account_id" ]; then
        # 如果没有指定账号标识，使用默认账号（已经在脚本开始时加载）
        return 0
    fi
    
    if [ ! -f "$cred_file" ]; then
        log_and_echo "警告: DNS凭证文件不存在: $cred_file"
        return 1
    fi
    
    # 检查文件是否可读
    if [ ! -r "$cred_file" ]; then
        log_and_echo "错误: DNS凭证文件不可读: $cred_file"
        return 1
    fi
    
    # 根据DNS提供商确定环境变量前缀
    local var_prefix=""
    case "$dns_provider" in
        dns_ali)
            var_prefix="Ali_"
            ;;
        dns_gd)
            var_prefix="GD_"
            ;;
        dns_cf)
            var_prefix="CF_"
            ;;
        dns_dp)
            var_prefix="DP_"
            ;;
        dns_aws)
            var_prefix="AWS_"
            ;;
        dns_tencent)
            var_prefix="Tencent_"
            ;;
        dns_he)
            var_prefix="HE_"
            ;;
        *)
            # 对于其他DNS提供商，尝试使用通用格式
            var_prefix=""
            ;;
    esac
    
    # 如果无法确定前缀，尝试从文件中查找
    if [ -z "$var_prefix" ]; then
        log_and_echo "警告: 无法确定DNS提供商 $dns_provider 的环境变量前缀，尝试自动检测"
    fi
    
    # 读取凭证文件，查找指定账号的凭证
    # 根据DNS提供商确定需要查找的环境变量名
    local var_patterns=()
    case "$dns_provider" in
        dns_ali)
            var_patterns=("Ali_Key_account${account_id}" "Ali_Secret_account${account_id}")
            ;;
        dns_gd)
            var_patterns=("GD_Key_account${account_id}" "GD_Secret_account${account_id}")
            ;;
        dns_cf)
            var_patterns=("CF_Token_account${account_id}" "CF_Account_ID_account${account_id}" "CF_Key_account${account_id}" "CF_Email_account${account_id}")
            ;;
        dns_dp)
            var_patterns=("DP_Id_account${account_id}" "DP_Key_account${account_id}")
            ;;
        dns_aws)
            var_patterns=("AWS_ACCESS_KEY_ID_account${account_id}" "AWS_SECRET_ACCESS_KEY_account${account_id}" "AWS_DEFAULT_REGION_account${account_id}")
            ;;
        dns_tencent)
            var_patterns=("Tencent_SecretId_account${account_id}" "Tencent_SecretKey_account${account_id}")
            ;;
        dns_he)
            var_patterns=("HE_Username_account${account_id}" "HE_Password_account${account_id}")
            ;;
        *)
            # 对于其他DNS提供商，尝试通用模式
            var_patterns=(".*_account${account_id}")
            ;;
    esac
    
    # 读取凭证文件，查找并加载指定账号的凭证
    local found_vars=0
    
    while IFS= read -r line || [ -n "$line" ]; do
        # 跳过空行和注释行
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -z "$line" ] || [[ "$line" =~ ^# ]]; then
            continue
        fi
        
        # 查找包含账号标识的export语句
        # 支持两种格式：
        # 1. _account${account_id} (如 _accountaccount1) - 标准格式
        # 2. _${account_id} (如 _account1) - 简化格式
        local matched=0
        local standard_var=""
        
        if [[ "$line" =~ ^export[[:space:]]+ ]]; then
            # 提取变量名（去掉export）
            local var_with_account=$(echo "$line" | sed 's/^export[[:space:]]*//' | cut -d'=' -f1)
            
            # 验证变量名格式（只允许字母、数字、下划线）
            if [[ ! "$var_with_account" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                continue
            fi
            
            # 尝试匹配 _account${account_id} 格式
            if [[ "$var_with_account" =~ _account${account_id}$ ]]; then
                standard_var=$(echo "$var_with_account" | sed "s/_account${account_id}$//")
                matched=1
            # 尝试匹配 _${account_id} 格式
            elif [[ "$var_with_account" =~ _${account_id}$ ]]; then
                standard_var=$(echo "$var_with_account" | sed "s/_${account_id}$//")
                matched=1
            fi
            
            # 如果匹配成功，验证标准变量名格式
            if [ $matched -eq 1 ]; then
                if [[ ! "$standard_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                    log_and_echo "警告: 标准变量名格式不正确，跳过: $standard_var"
                    continue
                fi
            else
                # 没有匹配到账号标识，跳过
                continue
            fi
            
            # 提取变量值（安全地处理引号）
            local var_value=$(echo "$line" | sed 's/^export[[:space:]]*[^=]*=//' | sed 's/^["'\'']//;s/["'\'']$//')
            # 验证变量值不包含危险字符（防止命令注入）
            if [[ "$var_value" =~ [\`\$\(\)\;] ]]; then
                log_and_echo "警告: 变量值包含危险字符，跳过: $standard_var"
                continue
            fi
            
            # 导出为标准环境变量名（使用printf避免命令注入）
            printf -v "$standard_var" "%s" "$var_value"
            export "$standard_var" 2>/dev/null || {
                log_and_echo "警告: 无法设置环境变量: $standard_var"
            }
            found_vars=$((found_vars + 1))
        fi
    done < "$cred_file"
    
    if [ $found_vars -gt 0 ]; then
        return 0
    else
        return 1
    fi
}

# 函数：为指定域名加载DNS凭证（实现新的逻辑）
# 参数：
#   $1: DNS凭证文件路径
#   $2: DNS提供商（如 dns_ali, dns_gd）
#   $3: 账号标识（可选，如 account1）
# 返回值：
#   0: 成功加载（至少加载了一种凭证）
#   1: 失败（两种凭证都未找到）
load_dns_credentials_for_domain() {
    local cred_file="$1"
    local dns_provider="$2"
    local account_id="$3"
    
    local default_loaded=0
    local account_loaded=0
    
    # 步骤1: 先尝试加载默认账号凭证（不带账号标识的DNS key）
    if load_dns_credentials "$cred_file" >/dev/null 2>&1; then
        default_loaded=1
    fi
    
    # 步骤2: 如果指定了账号标识，再尝试加载指定账号标识的凭证
    if [ -n "$account_id" ]; then
        if load_dns_credentials_for_account "$cred_file" "$dns_provider" "$account_id" >/dev/null 2>&1; then
            account_loaded=1
        fi
    fi
    
    # 步骤3: 根据结果输出并决定是否继续
    if [ $default_loaded -eq 1 ] && [ $account_loaded -eq 1 ]; then
        # 两者都成功
        log_and_echo "已加载默认账号和账号 $account_id 的DNS凭证，都加载成功"
        return 0
    elif [ $default_loaded -eq 1 ]; then
        # 仅默认成功
        if [ -n "$account_id" ]; then
            log_and_echo "已加载默认账号DNS凭证，加载成功（未找到账号 $account_id 的DNS凭证）"
        else
            log_and_echo "已加载默认账号DNS凭证，加载成功"
        fi
        return 0
    elif [ $account_loaded -eq 1 ]; then
        # 仅指定账号成功
        log_and_echo "已加载账号 $account_id 的DNS凭证，加载成功（未找到默认账号DNS凭证）"
        return 0
    else
        # 两者都失败
        if [ -n "$account_id" ]; then
            log_and_echo "错误: DNS凭证加载失败（默认账号和账号 $account_id 都未找到）"
        else
            log_and_echo "错误: DNS凭证加载失败（未找到默认账号DNS凭证）"
        fi
        return 1
    fi
}

# 函数：根据域名找到对应的nginx配置文件
# 支持通配符和单域名（包括多级域名）的配置文件查找
find_nginx_conf_files() {
    local domain="$1"
    local main_domain=$(extract_main_domain "$domain")
    local conf_files=()
    
    # 如果nginx配置目录未配置或不存在，返回空
    if [ -z "$NGINX_CONF_DIR" ]; then
        return 1
    fi
    
    if [ ! -d "$NGINX_CONF_DIR" ]; then
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
        log_and_echo "提示: 配置文件不包含SSL配置，跳过: $conf_file"
        return 0
    fi
    
    # 先检查路径是否正确
    if check_ssl_cert_path "$conf_file" "$new_cert_path" "$new_key_path"; then
        log_and_echo "提示: SSL证书路径已正确，无需修改: $conf_file"
        return 0
    fi
    
    # 创建备份目录（在nginx配置目录下）
    local backup_dir="${NGINX_CONF_DIR}/backup"
    if [ ! -d "$backup_dir" ]; then
        mkdir -p "$backup_dir" || {
            log_and_echo "错误: 无法创建备份目录: $backup_dir"
            return 1
        }
        log_and_echo "已创建备份目录: $backup_dir"
    fi
    
    # 提取配置文件名（不含路径）
    local conf_filename=$(basename "$conf_file")
    
    # 创建备份文件（放在backup目录下）
    local backup_file="${backup_dir}/${conf_filename}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$conf_file" "$backup_file" || {
        log_and_echo "错误: 无法创建备份文件: $backup_file"
        return 1
    }
    
    # 创建临时文件
    local temp_file="${conf_file}.tmp.$$"
    cp "$conf_file" "$temp_file" || {
        log_and_echo "错误: 无法创建临时文件: $conf_file"
        rm -f "$backup_file" 2>/dev/null
        return 1
    }
    
    # 验证路径格式（防止路径注入）
    if [[ "$new_cert_path" =~ [\`\$\(\)\;] ]] || [[ "$new_key_path" =~ [\`\$\(\)\;] ]]; then
        log_and_echo "错误: 证书路径包含危险字符，跳过更新: $conf_file"
        rm -f "$temp_file" "$backup_file" 2>/dev/null
        return 1
    fi
    
    # 替换ssl_certificate路径（匹配各种格式）
    # 兼容macOS和Linux：macOS的sed需要 -i ''，Linux的sed需要 -i
    # 使用单引号保护路径变量，避免特殊字符被解释
    local sed_cert_pattern="ssl_certificate ${new_cert_path};"
    local sed_key_pattern="ssl_certificate_key ${new_key_path};"
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' -E "s|^\s*ssl_certificate\s+[^;]+;|${sed_cert_pattern}|g" "$temp_file" 2>/dev/null
        sed -i '' -E "s|^\s*ssl_certificate_key\s+[^;]+;|${sed_key_pattern}|g" "$temp_file" 2>/dev/null
    else
        sed -i -E "s|^\s*ssl_certificate\s+[^;]+;|${sed_cert_pattern}|g" "$temp_file" 2>/dev/null
        sed -i -E "s|^\s*ssl_certificate_key\s+[^;]+;|${sed_key_pattern}|g" "$temp_file" 2>/dev/null
    fi
    
    # 检查是否有修改
    if ! cmp -s "$conf_file" "$temp_file" 2>/dev/null; then
        modified=1
        mv "$temp_file" "$conf_file" || {
            log_and_echo "错误: 无法更新配置文件: $conf_file"
            rm -f "$temp_file" "$backup_file" 2>/dev/null
            return 1
        }
        log_and_echo "已更新Nginx配置文件: $conf_file (备份: $backup_file)"
        log_and_echo "  - 新证书路径: ${new_cert_path}"
        log_and_echo "  - 新私钥路径: ${new_key_path}"
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
    
    log_and_echo "开始查找域名 $domain 对应的Nginx配置文件..."
    
    # 判断域名类型（用于错误提示）
    local is_wildcard_local=0
    if validate_wildcard_domain "$domain"; then
        is_wildcard_local=1
    fi
    
    # 查找所有匹配的conf文件
    local conf_files
    conf_files=$(find_nginx_conf_files "$domain")
    local find_result=$?
    
    if [ $find_result -ne 0 ] || [ -z "$conf_files" ]; then
        log_and_echo "警告: 未找到域名 $domain 对应的Nginx配置文件"
        if [ -z "$NGINX_CONF_DIR" ]; then
            log_and_echo "提示: 未配置NGINX_CONF_DIR，请在config文件中配置"
        else
            log_and_echo "提示: 在目录 $NGINX_CONF_DIR 中未找到匹配的配置文件"
            log_and_echo "查找规则:"
            if [ $is_wildcard_local -eq 1 ]; then
                log_and_echo "  通配符域名 $domain -> 主域名 $main_domain"
                log_and_echo "  匹配规则: 文件名以 .$main_domain 结尾或等于 $main_domain"
            else
                log_and_echo "  单域名 $domain"
                log_and_echo "  匹配规则: 文件名等于 $domain 或以 .$main_domain 结尾"
            fi
            # 列出目录中的所有.conf文件，帮助用户调试
            local all_confs=$(find "$NGINX_CONF_DIR" -type f -name "*.conf" 2>/dev/null | head -10)
            if [ -n "$all_confs" ]; then
                log_and_echo "目录中的配置文件示例（前10个）:"
                while IFS= read -r conf; do
                    if [ -n "$conf" ]; then
                        log_and_echo "  - $(basename "$conf")"
                    fi
                done <<< "$all_confs"
            fi
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
    
    log_and_echo "Nginx配置更新完成: 共找到 $total_count 个配置文件，更新 $updated_count 个"
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
            log_and_echo "警告: 无法识别web服务器类型: $server_type，跳过配置测试"
            return 1
            ;;
    esac
    
    log_and_echo "正在测试 $server_type 配置文件..."
    # 安全地执行测试命令（不使用eval，直接执行）
    case "$server_type" in
        openresty)
            if openresty -t 2>&1 | tee -a "$LOG_FILE"; then
                log_and_echo "$server_type 配置文件测试通过"
                return 0
            else
                log_and_echo "错误: $server_type 配置文件测试失败"
                log_and_echo "请检查配置文件是否有错误，修复后再执行reload"
                return 1
            fi
            ;;
        nginx)
            if nginx -t 2>&1 | tee -a "$LOG_FILE"; then
                log_and_echo "$server_type 配置文件测试通过"
                return 0
            else
                log_and_echo "错误: $server_type 配置文件测试失败"
                log_and_echo "请检查配置文件是否有错误，修复后再执行reload"
                return 1
            fi
            ;;
        *)
            log_and_echo "错误: 无法识别web服务器类型: $server_type"
            return 1
            ;;
    esac
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
            log_and_echo "警告: 无法识别web服务器类型: $server_type，跳过reload"
            return 1
            ;;
    esac
    
    # 先测试配置文件
    if ! test_web_server_config "$server_type"; then
        log_and_echo "错误: 配置文件测试失败，跳过reload操作"
        return 1
    fi
    
    # 配置文件测试通过，执行reload
    log_and_echo "正在执行 $server_type reload..."
    # 安全地执行reload命令（不使用eval，直接执行）
    case "$server_type" in
        openresty)
            if openresty -s reload 2>&1 | tee -a "$LOG_FILE"; then
                log_and_echo "$server_type reload 成功"
                return 0
            else
                log_and_echo "错误: $server_type reload 失败"
                return 1
            fi
            ;;
        nginx)
            if nginx -s reload 2>&1 | tee -a "$LOG_FILE"; then
                log_and_echo "$server_type reload 成功"
                return 0
            else
                log_and_echo "错误: $server_type reload 失败"
                return 1
            fi
            ;;
        *)
            log_and_echo "错误: 无法识别web服务器类型: $server_type"
            return 1
            ;;
    esac
}

# 函数：交互式询问是否更新nginx配置
ask_update_nginx_config() {
    local domain="$1"
    local main_domain="$2"
    
    # 检查是否配置了nginx目录
    if [ -z "$NGINX_CONF_DIR" ]; then
        log_and_echo "提示: Nginx配置目录未配置，跳过配置更新"
        log_and_echo "请在config文件中配置 NGINX_CONF_DIR，例如：NGINX_CONF_DIR=/data/conf.d/"
        return 1
    fi
    
    if [ ! -d "$NGINX_CONF_DIR" ]; then
        log_and_echo "提示: Nginx配置目录不存在，跳过配置更新"
        log_and_echo "配置的路径: $NGINX_CONF_DIR"
        log_and_echo "请检查路径是否正确，或修改config文件中的 NGINX_CONF_DIR 配置"
        return 1
    fi
    
    # 检查是否能找到对应的配置文件
    local conf_files
    conf_files=$(find_nginx_conf_files "$domain")
    if [ $? -ne 0 ] || [ -z "$conf_files" ]; then
        log_and_echo "提示: 未找到域名 $domain 对应的配置文件，跳过配置更新"
        return 1
    fi
    
    # 显示找到的配置文件
    log_and_echo ""
    log_and_echo "找到以下Nginx配置文件需要更新:"
    while IFS= read -r conf_file; do
        if [ -n "$conf_file" ]; then
            log_and_echo "  - $conf_file"
        fi
    done <<< "$conf_files"
    
    # 交互式询问（同时输出到日志和终端）
    log_and_echo ""
    log_and_echo "是否将证书配置到OpenResty的server配置文件中? (y/n): "
    
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
        read_with_timeout "是否将证书配置到OpenResty的server配置文件中? (y/n)" 30 "y"
        answer="$READ_TIMEOUT_ANSWER"
        log_and_echo "用户输入: $answer"
        
        case "$answer" in
            [Yy]|[Yy][Ee][Ss])
                update_domain_nginx_configs "$domain" "$main_domain"
                return 0
                ;;
            *)
                log_and_echo "用户选择跳过配置更新"
                return 1
                ;;
        esac
    else
        # 非交互式环境，默认跳过
        log_and_echo "非交互式环境，跳过配置更新"
        return 1
    fi
}

# 函数：resetconf模式 - 仅更新Nginx配置文件中的SSL证书路径
resetconf_mode() {
    # 需要先加载配置（NGINX_CONF_DIR, CERT_DIR等）
    # 定义默认值
    local nginx_conf_dir=""
    local cert_dir="${SCRIPT_DIR}/cert"
    
    # 检查配置文件是否存在
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "错误: 配置文件 $CONFIG_FILE 不存在" >&2
        exit 1
    fi
    
    # 从配置文件中读取NGINX_CONF_DIR
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -z "$line" ] || [[ "$line" =~ ^# ]]; then
            continue
        fi
        if [[ "$line" =~ ^NGINX_CONF_DIR= ]]; then
            nginx_conf_dir=$(echo "$line" | sed 's/^NGINX_CONF_DIR=//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ ! "$nginx_conf_dir" =~ ^/ ]]; then
                nginx_conf_dir="${SCRIPT_DIR}/${nginx_conf_dir}"
            fi
            nginx_conf_dir="${nginx_conf_dir%/}"
            break
        fi
    done < "$CONFIG_FILE"
    
    # 设置全局变量（供其他函数使用）
    NGINX_CONF_DIR="$nginx_conf_dir"
    CERT_DIR="$cert_dir"
    
    log_and_echo "============================================================="
    log_and_echo "Nginx配置更新模式"
    log_and_echo "任务开始时间: $(date)"
    log_and_echo "脚本目录: $SCRIPT_DIR"
    log_and_echo "日志文件: $LOG_FILE"
    log_and_echo "证书目录: $CERT_DIR"
    log_and_echo "配置文件: $CONFIG_FILE"
    
    # 检查Nginx配置目录
    if [ -z "$NGINX_CONF_DIR" ]; then
        log_and_echo "错误: Nginx配置目录未配置"
        log_and_echo "请在config文件中配置 NGINX_CONF_DIR，例如：NGINX_CONF_DIR=/data/conf.d/"
        exit 1
    fi
    
    if [ ! -d "$NGINX_CONF_DIR" ]; then
        log_and_echo "错误: Nginx配置目录不存在: $NGINX_CONF_DIR"
        log_and_echo "请检查路径是否正确，或修改config文件中的 NGINX_CONF_DIR 配置"
        exit 1
    fi
    
    log_and_echo "Nginx配置目录: $NGINX_CONF_DIR"
    log_and_echo "-------------------------------------------------------------"
    
    # 从配置文件中读取域名列表
    local domains_to_update=()
    while IFS= read -r domain_line || [ -n "$domain_line" ]; do
        domain_line=$(echo "$domain_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        # 跳过空行、注释行和配置行
        if [ -z "$domain_line" ] || [[ "$domain_line" =~ ^# ]] || \
           [[ "$domain_line" =~ ^NGINX_CONF_DIR= ]] || \
           [[ "$domain_line" =~ ^DNS_PROVIDER= ]] || \
           [[ "$domain_line" =~ ^CA_PROVIDER= ]] || \
           [[ "$domain_line" =~ ^DNS_CREDENTIALS_FILE= ]] || \
           [[ "$domain_line" =~ ^DNS_SLEEP= ]]; then
            continue
        fi
        
        # 解析域名（格式：域名|DNS提供商 或 域名|DNS提供商|账号标识）
        local domain=""
        if [[ "$domain_line" =~ \| ]]; then
            domain=$(echo "$domain_line" | cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        else
            # 如果没有DNS提供商，也尝试使用（兼容旧配置）
            domain="$domain_line"
        fi
        
        # 验证域名不为空
        if [ -z "$domain" ]; then
            continue
        fi
        
        # 验证域名格式
        if ! validate_domain_format "$domain"; then
            log_and_echo "警告: 域名格式不正确，跳过: $domain"
            continue
        fi
        
        # 提取主域名
        local main_domain=$(extract_main_domain "$domain")
        
        # 检查证书文件是否存在
        local cert_file="${CERT_DIR}/${main_domain}.pem"
        local key_file="${CERT_DIR}/${main_domain}.key"
        
        if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
            log_and_echo "警告: 证书文件不存在，跳过域名 $domain"
            log_and_echo "  证书文件: $cert_file"
            log_and_echo "  私钥文件: $key_file"
            continue
        fi
        
        # 添加到更新列表
        domains_to_update+=("$domain|$main_domain")
    done < "$CONFIG_FILE"
    
    if [ ${#domains_to_update[@]} -eq 0 ]; then
        log_and_echo "错误: 未找到有效的域名配置或证书文件"
        log_and_echo "请检查config文件中的域名配置和证书目录中的证书文件"
        exit 1
    fi
    
    log_and_echo "共找到 ${#domains_to_update[@]} 个域名需要更新配置"
    log_and_echo "-------------------------------------------------------------"
    
    # 更新每个域名的配置
    local updated_count=0
    for domain_info in "${domains_to_update[@]}"; do
        IFS='|' read -r domain main_domain <<< "$domain_info"
        log_and_echo ""
        log_and_echo "处理域名: $domain"
        log_and_echo "主域名: $main_domain"
        
        if update_domain_nginx_configs "$domain" "$main_domain"; then
            updated_count=$((updated_count + 1))
        fi
    done
    
    log_and_echo ""
    log_and_echo "-------------------------------------------------------------"
    log_and_echo "配置更新完成: 共处理 ${#domains_to_update[@]} 个域名，成功更新 $updated_count 个"
    
    # 执行web服务器reload
    if [ $updated_count -gt 0 ]; then
        log_and_echo ""
        log_and_echo "-------------------------------------------------------------"
        log_and_echo "开始检测web服务器类型并执行reload..."
        
        # 检测web服务器类型
        WEB_SERVER_TYPE=$(detect_web_server)
        if [ "$WEB_SERVER_TYPE" != "unknown" ]; then
            log_and_echo "检测到web服务器: $WEB_SERVER_TYPE"
            
            # 执行reload
            if reload_web_server "$WEB_SERVER_TYPE"; then
                log_and_echo "$WEB_SERVER_TYPE reload 执行成功"
            else
                log_and_echo "警告: $WEB_SERVER_TYPE reload 执行失败，请手动检查"
            fi
        else
            log_and_echo "警告: 无法检测到web服务器（nginx或openresty），跳过reload"
            log_and_echo "提示: 请确保已安装nginx或openresty，或手动执行reload"
        fi
    fi
    
    log_and_echo ""
    log_and_echo "-------------------------------------------------------------"
    log_and_echo "任务结束时间: $(date)"
    log_and_echo "============================================================="
}

# 如果是resetconf模式，执行配置更新并退出
# 注意：需要在变量初始化之后检查，所以放在这里
if [ "$SCRIPT_MODE" = "resetconf" ]; then
    # 执行resetconf模式（函数内部会读取配置）
    resetconf_mode
    exit 0
fi

# 正常模式：执行证书申请和配置更新流程
log_and_echo "============================================================="
log_and_echo "任务开始时间: $(date)"
log_and_echo "脚本目录: $SCRIPT_DIR"
log_and_echo "日志文件: $LOG_FILE"
log_and_echo "证书目录: $CERT_DIR"
log_and_echo "配置文件: $CONFIG_FILE"
if [ -n "$ACME_SH_PATH" ]; then
    log_and_echo "acme.sh 路径: $ACME_SH_PATH"
fi
log_and_echo "CA提供商: $CA_PROVIDER"
log_and_echo "DNS凭证文件: $DNS_CREDENTIALS_FILE"
log_and_echo "DNS等待时间: ${DNS_SLEEP}秒"
log_and_echo "注意: 每个域名必须明确指定DNS提供商（格式: 域名|DNS提供商）"
if [ -n "$NGINX_CONF_DIR" ] && [ -d "$NGINX_CONF_DIR" ]; then
    log_and_echo "Nginx配置目录: $NGINX_CONF_DIR"
else
    if [ -z "$NGINX_CONF_DIR" ]; then
        log_and_echo "提示: Nginx配置目录未配置"
        log_and_echo "请在config文件中配置 NGINX_CONF_DIR，例如：NGINX_CONF_DIR=/data/conf.d/"
    else
        log_and_echo "提示: Nginx配置目录不存在"
        log_and_echo "配置的路径: $NGINX_CONF_DIR"
        log_and_echo "请检查路径是否正确，或修改config文件中的 NGINX_CONF_DIR 配置"
        # 尝试检测常见的nginx配置目录
        common_dirs=(
            "/data/conf.d"
            "/data/openresty/nginx/conf/vhost"
            "/etc/nginx/conf.d"
            "/usr/local/nginx/conf/vhost"
            "/usr/local/openresty/nginx/conf/vhost"
        )
        log_and_echo "常见的Nginx配置目录："
        for dir in "${common_dirs[@]}"; do
            if [ -d "$dir" ]; then
                log_and_echo "  ✓ $dir (存在)"
            else
                log_and_echo "  ✗ $dir (不存在)"
            fi
        done
    fi
fi

# 1. 升级 acme.sh
log_and_echo "正在检查更新 acme.sh..."
"$ACME_SH_PATH" --upgrade 2>&1 | tee -a "$LOG_FILE"

# 2. 设置默认 CA（使用配置的CA提供商）
log_and_echo "设置CA提供商: $CA_PROVIDER"
"$ACME_SH_PATH" --set-default-ca --server "$CA_PROVIDER" 2>&1 | tee -a "$LOG_FILE"

# 3. 统计域名总数并检查DNS提供商配置
TOTAL_DOMAINS=$(grep -v '^[[:space:]]*$' "$CONFIG_FILE" | grep -v '^#' | grep -v '^NGINX_CONF_DIR=' | grep -v '^DNS_PROVIDER=' | grep -v '^CA_PROVIDER=' | grep -v '^DNS_CREDENTIALS_FILE=' | grep -v '^DNS_SLEEP=' | wc -l)
CURRENT_DOMAIN=0
SUCCESSFUL_DOMAINS=()

log_and_echo "共发现 $TOTAL_DOMAINS 个域名需要处理"

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
       [[ "$domain_line" =~ ^DNS_CREDENTIALS_FILE= ]] || \
       [[ "$domain_line" =~ ^DNS_SLEEP= ]]; then
        continue
    fi
    
    # 检查是否指定了DNS提供商
    # 支持格式：域名|DNS提供商 或 域名|DNS提供商|账号标识
    if [[ "$domain_line" =~ \| ]]; then
        domain=$(echo "$domain_line" | cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        dns_provider=$(echo "$domain_line" | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        account_id=$(echo "$domain_line" | cut -d'|' -f3 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        if [ -n "$domain" ] && [ -n "$dns_provider" ]; then
            # 如果有账号标识，添加到记录中
            if [ -n "$account_id" ]; then
                DOMAINS_WITH_DNS+=("$domain|$dns_provider|$account_id")
            else
                DOMAINS_WITH_DNS+=("$domain|$dns_provider")
            fi
            # 记录使用的DNS提供商（去重）
            # 检查数组是否为空（兼容 set -u 模式）
            local provider_exists=0
            if [ ${#DNS_PROVIDERS_USED[@]} -gt 0 ]; then
                for existing_provider in "${DNS_PROVIDERS_USED[@]}"; do
                    if [ "$existing_provider" = "$dns_provider" ]; then
                        provider_exists=1
                        break
                    fi
                done
            fi
            if [ $provider_exists -eq 0 ]; then
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
    log_and_echo ""
    log_and_echo "❌ 错误: 发现 ${#DOMAINS_WITHOUT_DNS[@]} 个域名未指定DNS提供商！"
    log_and_echo "未指定DNS提供商的域名:"
    for domain in "${DOMAINS_WITHOUT_DNS[@]}"; do
        log_and_echo "  - $domain"
    done
    log_and_echo ""
    log_and_echo "❌ 错误: 必须为每个域名明确指定DNS提供商！"
    log_and_echo "格式: 域名|DNS提供商 或 域名|DNS提供商|账号标识"
    log_and_echo "示例: *.example.com|dns_gd"
    log_and_echo "示例: www.example.com|dns_ali"
    log_and_echo "示例: *.example.com|dns_ali|account1 （使用账号标识account1）"
    log_and_echo ""
    log_and_echo "请修改配置文件，为所有域名明确指定DNS提供商后重试。"
    
    exit 1
fi

log_and_echo "-------------------------------------------------------------"

# 4. 循环处理每个域名
while IFS= read -r domain_line || [ -n "$domain_line" ]; do
    # 跳过空行、注释行和配置行
    domain_line=$(echo "$domain_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -z "$domain_line" ] || [[ "$domain_line" =~ ^# ]] || \
       [[ "$domain_line" =~ ^NGINX_CONF_DIR= ]] || \
       [[ "$domain_line" =~ ^DNS_PROVIDER= ]] || \
       [[ "$domain_line" =~ ^CA_PROVIDER= ]] || \
       [[ "$domain_line" =~ ^DNS_CREDENTIALS_FILE= ]] || \
       [[ "$domain_line" =~ ^DNS_SLEEP= ]]; then
        continue
    fi
    
    CURRENT_DOMAIN=$((CURRENT_DOMAIN + 1))
    
    # 解析域名和DNS提供商
    # 格式：域名|DNS提供商 或 域名|DNS提供商|账号标识
    DOMAIN_DNS_PROVIDER=""
    DOMAIN_ACCOUNT_ID=""
    if [[ "$domain_line" =~ \| ]]; then
        # 包含 | 分隔符，提取域名、DNS提供商和可选的账号标识
        domain=$(echo "$domain_line" | cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        DOMAIN_DNS_PROVIDER=$(echo "$domain_line" | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        DOMAIN_ACCOUNT_ID=$(echo "$domain_line" | cut -d'|' -f3 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    else
        # 不包含 | 分隔符，这是不允许的，应该在前面的检查中已经被捕获
        # 但为了安全，这里再次检查并报错
        log_and_echo "❌ 错误: 域名未指定DNS提供商: $domain_line"
        log_and_echo "格式: 域名|DNS提供商 或 域名|DNS提供商|账号标识"
        log_and_echo "示例: *.example.com|dns_gd 或 *.example.com|dns_ali|account1"
        log_and_echo "跳过此域名"
        continue
    fi
    
    # 验证域名不为空
    if [ -z "$domain" ]; then
        log_and_echo "❌ 错误: 域名不能为空: $domain_line"
        log_and_echo "脚本终止：域名格式错误"
        exit 1
    fi
    
    # 验证域名格式
    if ! validate_domain_format "$domain"; then
        log_and_echo "❌ 错误: 域名格式不正确: $domain"
        log_and_echo "支持的格式："
        log_and_echo "  - 通配符格式: *.example.com, *.v1.example.com, *.api.v1.example.com（支持任意层级）"
        log_and_echo "  - 单域名格式（支持任意层级，支持子域名带数字）："
        log_and_echo "    * 二级域名: example.com, example123.com"
        log_and_echo "    * 三级域名: www.example.com, www123.example.com, api.v1.example.com"
        log_and_echo "    * 四级域名: api.v1.example.com, test.api.v1.example.com, api123.v1.example.com"
        log_and_echo "    * 五级域名: dev.test.api.v1.example.com, test123.api.v1.example.com"
        log_and_echo "    * 六级及以上: prod.dev.test.api.v1.example.com（支持任意层级）"
        log_and_echo "  - 说明:"
        log_and_echo "    * 子域名部分可以包含数字，如 example123.com, www123.example.com"
        log_and_echo "    * 子域名部分可以包含下划线，如 example_test.com, api_v1.example.com"
        log_and_echo "    * TLD（最后一个部分）必须是纯字母，支持所有TLD：.com, .org, .cn, .vip, .tech, .ren, .me 等"
        log_and_echo "    * 注意：下划线在域名中虽然被允许，但可能不被某些CA（如Let's Encrypt）支持，建议谨慎使用"
        log_and_echo "错误说明："
        if [[ "$domain" =~ \.conf$ ]]; then
            log_and_echo "  - 域名不能包含 .conf 后缀"
        fi
        if [[ ! "$domain" =~ ^[a-zA-Z0-9._\*-]+$ ]]; then
            log_and_echo "  - 域名包含非法字符（只允许字母、数字、点、连字符、下划线、星号）"
        fi
        if [[ "$domain" =~ \.\. ]]; then
            log_and_echo "  - 域名不能包含连续的点"
        fi
        if [[ ! "$domain" =~ \. ]]; then
            log_and_echo "  - 域名必须至少包含一个点（至少是二级域名）"
        fi
        log_and_echo "脚本终止：域名格式错误"
        exit 1
    fi
    
    # 验证DNS提供商不为空（强制要求）
    if [ -z "$DOMAIN_DNS_PROVIDER" ]; then
        log_and_echo "❌ 错误: 域名 $domain 未指定DNS提供商！"
        log_and_echo "格式: 域名|DNS提供商"
        log_and_echo "示例: $domain|dns_gd"
        log_and_echo "跳过此域名"
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
    
    log_and_echo ""
    log_and_echo "[$CURRENT_DOMAIN/$TOTAL_DOMAINS] 正在处理域名: $domain"
    log_and_echo "证书类型: $CERT_TYPE"
    log_and_echo "使用域名: $domain"
    log_and_echo "主域名: $MAIN_DOMAIN"
    log_and_echo "DNS提供商: $DOMAIN_DNS_PROVIDER"
    log_and_echo "-------------------------------------------------------------"
    
    # 4.1 申请/续签证书
    # 注意：--dnssleep 参数会让程序内部等待指定秒数，等待DNS记录传播完成
    # 使用域名指定的DNS提供商和原始域名格式申请证书（支持通配符和单域名）
    log_and_echo "开始申请/续签证书: $domain ($CERT_TYPE)"
    log_and_echo "DNS提供商: $DOMAIN_DNS_PROVIDER"
    if [ -n "$DOMAIN_ACCOUNT_ID" ]; then
        log_and_echo "账号标识: $DOMAIN_ACCOUNT_ID"
    else
        log_and_echo "账号标识: 默认账号"
    fi
    log_and_echo "CA提供商: $CA_PROVIDER"
    log_and_echo "DNS等待时间: ${DNS_SLEEP}秒"
    
    # 验证DNS提供商格式（应该以 dns_ 开头）
    if [[ ! "$DOMAIN_DNS_PROVIDER" =~ ^dns_ ]]; then
        log_and_echo "错误: DNS提供商格式不正确: $DOMAIN_DNS_PROVIDER，应为 dns_xxx 格式"
        log_and_echo "跳过域名: $domain"
        continue
    fi
    
    # 加载DNS凭证（实现新逻辑：先查找默认账号，再查找指定账号）
    log_and_echo "正在加载DNS凭证..."
    if ! load_dns_credentials_for_domain "$DNS_CREDENTIALS_FILE" "$DOMAIN_DNS_PROVIDER" "$DOMAIN_ACCOUNT_ID"; then
        log_and_echo "跳过域名: $domain"
        log_and_echo "脚本终止：DNS凭证加载失败"
        exit 1
    fi
    
    log_and_echo "正在执行证书申请命令..."
    # 使用临时文件保存输出，以便检查错误信息和退出码
    issue_output=$(mktemp) || {
        log_and_echo "错误: 无法创建临时文件"
        continue
    }
    TEMP_FILES+=("$issue_output")
    issue_status=0
    
    if "$ACME_SH_PATH" --issue --dns "$DOMAIN_DNS_PROVIDER" \
        -d "$domain" \
        --dnssleep "$DNS_SLEEP" > "$issue_output" 2>&1; then
        issue_status=0
    else
        issue_status=$?
    fi
    
    # 同时输出到控制台和日志
    cat "$issue_output" | tee -a "$LOG_FILE"
    
    # 检查输出中是否包含错误信息
    has_error=0
    if grep -qiE "(error|failed|失败|错误)" "$issue_output" 2>/dev/null; then
        has_error=1
    fi
    
    # 检查退出码和错误信息
    if [ $issue_status -ne 0 ] || [ $has_error -eq 1 ]; then
        log_and_echo "警告: 证书申请/续签失败: $domain，DNS提供商: $DOMAIN_DNS_PROVIDER，跳过安装步骤"
        log_and_echo "提示: 请检查DNS提供商是否正确，以及对应的API凭证是否已配置"
        # 临时文件会在脚本退出时自动清理
        continue
    fi
    
    # 验证证书是否真的存在（检查acme.sh的证书目录）
    # acme.sh的证书目录命名规则：
    # - 通配符证书 *.example.com -> *.example.com_ecc
    # - 单域名证书 example.com -> example.com_ecc
    cert_dir="$HOME/.acme.sh/${domain}_ecc"
    
    if [ ! -d "$cert_dir" ]; then
        log_and_echo "警告: 证书申请失败，证书目录不存在: $cert_dir，跳过安装步骤"
        log_and_echo "提示: 请检查DNS验证是否成功，以及证书是否真的申请成功"
        # 临时文件会在脚本退出时自动清理
        continue
    fi
    
    # 检查证书文件是否存在
    if [ ! -f "$cert_dir/fullchain.cer" ] || [ ! -f "$cert_dir/${domain}.key" ]; then
        log_and_echo "警告: 证书申请失败，证书文件不存在: $cert_dir，跳过安装步骤"
        log_and_echo "提示: 请检查DNS验证是否成功，以及证书是否真的申请成功"
        # 临时文件会在脚本退出时自动清理
        continue
    fi
    log_and_echo "证书申请/续签成功: $domain ($CERT_TYPE)"
    
    # 4.2 安装证书
    # 注意：不在安装时执行reload，将在所有操作完成后统一执行
    log_and_echo "开始安装证书: $domain"
    
    log_and_echo "正在执行证书安装命令..."
    # 使用临时文件保存输出，以便检查错误信息和退出码
    install_output=$(mktemp) || {
        log_and_echo "错误: 无法创建临时文件"
        continue
    }
    TEMP_FILES+=("$install_output")
    install_status=0
    
    if "$ACME_SH_PATH" --install-cert \
        -d "$domain" \
        --key-file "${CERT_DIR}/${MAIN_DOMAIN}.key" \
        --fullchain-file "${CERT_DIR}/${MAIN_DOMAIN}.pem" > "$install_output" 2>&1; then
        install_status=0
    else
        install_status=$?
    fi
    
    # 同时输出到控制台和日志
    cat "$install_output" | tee -a "$LOG_FILE"
    
    # 检查输出中是否包含错误信息
    has_install_error=0
    if grep -qiE "(error|failed|失败|错误|没有那个文件)" "$install_output" 2>/dev/null; then
        has_install_error=1
    fi
    
    # 检查退出码和错误信息
    if [ $install_status -ne 0 ] || [ $has_install_error -eq 1 ]; then
        log_and_echo "错误: 证书安装失败: $domain"
        # 临时文件会在脚本退出时自动清理
        continue
    fi
    
    # 验证安装后的证书文件是否存在且不为空
    if [ ! -f "${CERT_DIR}/${MAIN_DOMAIN}.key" ] || [ ! -s "${CERT_DIR}/${MAIN_DOMAIN}.key" ]; then
        log_and_echo "错误: 证书私钥文件不存在或为空: ${CERT_DIR}/${MAIN_DOMAIN}.key"
        # 临时文件会在脚本退出时自动清理
        continue
    fi
    
    if [ ! -f "${CERT_DIR}/${MAIN_DOMAIN}.pem" ] || [ ! -s "${CERT_DIR}/${MAIN_DOMAIN}.pem" ]; then
        log_and_echo "错误: 证书文件不存在或为空: ${CERT_DIR}/${MAIN_DOMAIN}.pem"
        # 临时文件会在脚本退出时自动清理
        continue
    fi
    log_and_echo "证书安装成功: $domain"
    log_and_echo "证书文件: ${CERT_DIR}/${MAIN_DOMAIN}.pem"
    log_and_echo "私钥文件: ${CERT_DIR}/${MAIN_DOMAIN}.key"
    SUCCESSFUL_DOMAINS+=("$domain|$MAIN_DOMAIN")
    
done < "$CONFIG_FILE"

# 5. 证书生成完毕后，询问是否更新nginx配置
NGINX_CONFIG_UPDATED=0
if [ ${#SUCCESSFUL_DOMAINS[@]} -gt 0 ]; then
    log_and_echo ""
    log_and_echo "-------------------------------------------------------------"
    log_and_echo "证书生成完成，共成功生成 ${#SUCCESSFUL_DOMAINS[@]} 个证书"
    log_and_echo "开始处理Nginx配置更新..."
    log_and_echo "-------------------------------------------------------------"
    
    for domain_info in "${SUCCESSFUL_DOMAINS[@]}"; do
        IFS='|' read -r domain main_domain <<< "$domain_info"
        log_and_echo ""
        log_and_echo "处理域名: $domain"
        if ask_update_nginx_config "$domain" "$main_domain"; then
            # 如果更新了配置，记录标志
            NGINX_CONFIG_UPDATED=1
        fi
    done
fi

# 6. 所有操作完成后，统一执行web服务器reload
# 只有在证书安装成功且nginx配置更新成功的情况下才执行reload
if [ ${#SUCCESSFUL_DOMAINS[@]} -gt 0 ]; then
    log_and_echo ""
    log_and_echo "-------------------------------------------------------------"
    log_and_echo "开始检测web服务器类型并执行reload..."
    
    # 检测web服务器类型
    WEB_SERVER_TYPE=$(detect_web_server)
    if [ "$WEB_SERVER_TYPE" != "unknown" ]; then
        log_and_echo "检测到web服务器: $WEB_SERVER_TYPE"
        
        # 执行reload
        if reload_web_server "$WEB_SERVER_TYPE"; then
            log_and_echo "$WEB_SERVER_TYPE reload 执行成功"
        else
            log_and_echo "警告: $WEB_SERVER_TYPE reload 执行失败，请手动检查"
        fi
    else
        log_and_echo "警告: 无法检测到web服务器（nginx或openresty），跳过reload"
        log_and_echo "提示: 请确保已安装nginx或openresty，或手动执行reload"
    fi
fi

log_and_echo ""
log_and_echo "-------------------------------------------------------------"
log_and_echo "任务结束时间: $(date)"
log_and_echo "============================================================="