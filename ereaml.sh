#!/bin/bash

# ==============================================================================
# E-Realm 管理面板
# ==============================================================================
PANEL_VERSION="1.1.2"
REALM_VERSION="2.9.2"
UPDATE_LOG="v1.1.2: 修复修改规则时无法正确获取原值及端口检测冲突的Bug."
# ==============================================================================

REALM_URL="https://github.com/zhboner/realm/releases/download/v${REALM_VERSION}/realm-x86_64-unknown-linux-gnu.tar.gz"
CONFIG_DIR="/etc/realm"
CONFIG_FILE="$CONFIG_DIR/config.toml"
BACKUP_DIR="/opt/realm_backups"
SERVICE_FILE="/etc/systemd/system/realm.service"
CRON_FILE="/etc/cron.d/realm_monitor"

# 获取主机名
HOSTNAME=$(hostname -s 2>/dev/null || echo "unknown")

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[1;35m'  # 加粗紫色
NC='\033[0m' # 无颜色

# 检查并安装依赖
check_dependencies() {
    # 增加 ss (iproute2) 作为依赖
    local deps=("curl" "wget" "cron" "iproute2")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v $dep &> /dev/null; then
            if [[ "$dep" == "iproute2" ]] && command -v ss &> /dev/null; then
                continue
            fi
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${YELLOW}缺少依赖: ${missing_deps[*]}${NC}"
        echo "正在安装依赖..."
        
        if [ -x "$(command -v apt-get)" ]; then
            apt-get update
            apt-get install -y "${missing_deps[@]}"
        elif [ -x "$(command -v yum)" ]; then
            yum install -y "${missing_deps[@]}"
        else
            echo -e "${RED}无法自动安装依赖，请手动安装: ${missing_deps[*]}${NC}"
            exit 1
        fi
    fi
}

# 获取服务状态
get_service_status() {
    if systemctl is-active --quiet realm; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi
}

# 显示主菜单
show_main_menu() {
    clear
    local rule_count=$(grep -c "\[\[endpoints\]\]" "$CONFIG_FILE" 2>/dev/null || echo "0")
    local status=$(get_service_status)
    
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}                E-Realm 转发面板${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo -e "面板版本:  ${GREEN}v${PANEL_VERSION}${NC}"
    echo -e "Realm版本: ${GREEN}v${REALM_VERSION}${NC}"
    echo -e "更新日志:  ${YELLOW}${UPDATE_LOG}${NC}"
    echo -e "${CYAN}--------------------------------------------------${NC}"
    echo -e "服务状态: $status"
    echo -e "转发规则: ${GREEN}$rule_count 条${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo "1. 安装 Realm"
    echo "2. 卸载 Realm"
    echo "3. 转发规则管理"
    echo "4. 服务管理"
    echo "5. 备份与恢复"
    echo "6. 查看服务状态"
    echo "00. 退出"
    echo -e "${CYAN}==================================================${NC}"
    echo -n "请选择操作: "
}

# 显示转发规则管理菜单
show_rule_menu() {
    clear
    local rule_count=$(grep -c "\[\[endpoints\]\]" "$CONFIG_FILE" 2>/dev/null || echo "0")
    
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}                 转发规则管理${NC}"
    echo -e "${CYAN}                  规则数量: $rule_count 条${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo "1. 添加转发规则"
    echo "2. 查看转发规则"
    echo "3. 删除转发规则"
    echo "4. 修改转发规则"
    echo "00. 返回主菜单"
    echo -e "${CYAN}==================================================${NC}"
    echo -n "请选择操作: "
}

# 显示服务管理菜单
show_service_menu() {
    clear
    local status=$(get_service_status)
    local enabled_status=$(systemctl is-enabled realm 2>/dev/null || echo "unknown")
    
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}                 服务管理${NC}"
    echo -e "${CYAN}                服务状态: $status${NC}"
    if [[ $enabled_status == "enabled" ]]; then
        echo -e "${CYAN}                开机启动: ${GREEN}已启用${NC}"
    else
        echo -e "${CYAN}                开机启动: ${RED}未启用${NC}"
    fi
    echo -e "${CYAN}==================================================${NC}"
    echo "1. 启动服务"
    echo "2. 停止服务"
    echo "3. 重启服务"
    echo "4. 启用开机启动"
    echo "5. 禁用开机启动"
    echo "00. 返回主菜单"
    echo -e "${CYAN}==================================================${NC}"
    echo -n "请选择操作: "
}

# 显示备份与恢复菜单
show_backup_menu() {
    clear
    local backup_count=$(ls -1 "$BACKUP_DIR"/*.toml 2>/dev/null | wc -l)
    
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}                 备份与恢复${NC}"
    echo -e "${CYAN}                备份数量: $backup_count 个${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo "1. 备份配置"
    echo "2. 恢复备份"
    echo "00. 返回主菜单"
    echo -e "${CYAN}==================================================${NC}"
    echo -n "请选择操作: "
}

# 修复服务配置
fix_service_config() {
    echo -e "${GREEN}修复服务配置...${NC}"
    
    # 停止服务
    systemctl stop realm 2>/dev/null
    
    # 删除旧的服务文件
    rm -f "$SERVICE_FILE"
    
    # 创建新的服务文件
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Realm Port Forwarding
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/realm -c "$CONFIG_FILE"
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    
    # 重新加载系统服务
    systemctl daemon-reload
    systemctl enable realm
    
    echo -e "${GREEN}服务配置已修复!${NC}"
}

# 安装 Realm
install_realm() {
    echo -e "${GREEN}正在安装 Realm v${REALM_VERSION}...${NC}"
    
    # 检查是否已安装
    if [ -f /usr/local/bin/realm ]; then
        echo -e "${YELLOW}Realm 已经安装，是否需要重新安装? (y/n): ${NC}"
        read reinstall
        if [[ $reinstall != "y" && $reinstall != "Y" ]]; then
            return
        fi
    fi
    
    # 创建配置目录
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$BACKUP_DIR"
    
    # 下载并安装 Realm
    cd /tmp
    wget "$REALM_URL" -O realm.tar.gz
    tar -xzf realm.tar.gz
    mv realm /usr/local/bin/
    chmod +x /usr/local/bin/realm
    
    # 删除旧的JSON配置文件
    rm -f "$CONFIG_DIR/config.json"
    
    # 创建初始配置文件 (TOML格式)
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << 'EOF'
[log]
level = "warn"

[dns]
# mode = "ipv6_then_ipv4" # ipv4_then_ipv6, ipv6_then_ipv4
mode = "ipv4_then_ipv6"

[network]
no_tcp = false
use_udp = true
send_mptcp = true
accept_mptcp = false
EOF
    fi
    
    # 修复服务配置
    fix_service_config
    
    # 创建监控脚本 (改为20分钟检测一次)
    cat > /opt/realm_monitor.sh << 'EOF'
#!/bin/bash
if ! pgrep -x "realm" > /dev/null; then
    systemctl start realm
    echo "$(date): Realm was not running, restarted." >> /var/log/realm_monitor.log
fi
EOF
    
    chmod +x /opt/realm_monitor.sh
    
    # 设置定时任务检查活性 (改为20分钟一次)
    echo "*/20 * * * * root /opt/realm_monitor.sh" > "$CRON_FILE"
    
    # 启动服务
    systemctl start realm
    
    echo -e "${GREEN}Realm 安装完成!${NC}"
    sleep 2
}

# 卸载 Realm
uninstall_realm() {
    echo -e "${RED}正在卸载 Realm...${NC}"
    
    # 确认卸载
    read -p "确定要卸载 Realm 吗? 此操作不可逆! (y/n): " confirm
    if [[ $confirm != "y" && $confirm != "Y" ]]; then
        echo "取消卸载"
        return
    fi
    
    # 停止服务
    systemctl stop realm
    systemctl disable realm
    
    # 删除文件
    rm -f /usr/local/bin/realm
    rm -f "$SERVICE_FILE"
    rm -f "$CRON_FILE"
    rm -f /opt/realm_monitor.sh
    
    # 重新加载系统服务
    systemctl daemon-reload
    
    echo -e "${GREEN}Realm 已卸载!${NC}"
    echo -e "${YELLOW}配置文件 $CONFIG_FILE 和备份文件 $BACKUP_DIR 未被删除，如需完全清除请手动删除。${NC}"
    echo -e "\n按任意键返回主菜单..."
    read -n 1 -s
}

# 添加转发规则
add_rule() {
    echo -e "${GREEN}添加转发规则${NC}"
    
    while true; do
        read -p "请输入本地监听端口 (输入 0 返回): " local_port

        # 允许用户输入0返回
        if [[ "$local_port" == "0" ]]; then
            return
        fi
        
        # 验证输入是否为1-65535之间的数字
        if ! [[ $local_port =~ ^[0-9]+$ ]] || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
            echo -e "${RED}错误: 端口无效! 必须是1-65535之间的数字，请重新输入。${NC}"
            continue
        fi
        
        # 使用ss命令检测端口是否被系统其他程序占用 (TCP或UDP)
        if ss -tln | grep -q ":$local_port " || ss -uln | grep -q ":$local_port "; then
            echo -e "${RED}错误: 端口 $local_port 正在被其他程序占用，请重新输入!${NC}"
            continue
        fi
        
        # 检查配置文件中是否已存在相同监听端口的规则
        if grep -q "listen = \"0.0.0.0:$local_port\"" "$CONFIG_FILE"; then
            echo -e "${RED}错误: 本地端口 $local_port 已被其他转发规则占用，请重新输入!${NC}"
            continue
        fi

        # 如果所有检查都通过，则跳出循环
        echo -e "${GREEN}端口 $local_port 可用，请继续...${NC}"
        break
    done
    
    read -p "请输入远程服务器地址: " remote_addr
    read -p "请输入远程服务器端口: " remote_port
    read -p "请输入规则备注(可选，直接回车跳过): " comment
    
    # 验证远程端口输入
    if ! [[ $remote_port =~ ^[0-9]+$ ]] || [ "$remote_port" -lt 1 ] || [ "$remote_port" -gt 65535 ]; then
        echo -e "${RED}错误: 远程端口无效! 添加失败，原因: 端口必须是1-65535之间的数字。${NC}"
        sleep 2
        return 1
    fi
    
    # 添加新规则到配置文件
    cat >> "$CONFIG_FILE" <<EOF

[[endpoints]]
listen = "0.0.0.0:$local_port"
remote = "$remote_addr:$remote_port"
EOF
    
    # 添加备注（如果有）
    if [ -n "$comment" ]; then
        sed -i "\$a\# $comment" "$CONFIG_FILE"
    fi
    
    echo -e "${GREEN}规则添加成功!${NC}"
    
    # 询问是否重启服务
    read -p "是否立即重启服务使配置生效? (y/n): " restart
    if [[ $restart == "y" || $restart == "Y" ]]; then
        systemctl restart realm
        echo -e "${GREEN}服务已重启!${NC}"
    fi
    sleep 1
}


# 查看转发规则
view_rules() {
    echo -e "${GREEN}当前转发规则:${NC}"
    local rule_count=$(grep -c "\[\[endpoints\]\]" "$CONFIG_FILE" 2>/dev/null || echo "0")
    
    if [ $rule_count -eq 0 ]; then
        echo "暂无转发规则"
    else
        # 提取并显示所有规则（包括备注）
        awk -F'"' '
        /\[\[endpoints\]\]/ {
            rule_num++
            getline
            listen = $2
            getline
            remote = $2
            # 检查是否有备注
            comment = ""
            getline
            if ($0 ~ /^# /) {
                comment = substr($0, 3)
                getline
            }
            printf "%-4d: 本地: %s -> 远程: %s", rule_num, listen, remote
            if (comment != "") {
                printf " (备注: %s)", comment
            }
            printf "\n"
        }' "$CONFIG_FILE"
    fi
    echo -e "\n按回车键返回..."
    read
}

# 删除转发规则
delete_rule() {
    echo -e "${GREEN}删除转发规则${NC}"
    
    local rule_count=$(grep -c "\[\[endpoints\]\]" "$CONFIG_FILE" 2>/dev/null || echo "0")
    if [ "$rule_count" -eq 0 ]; then
        echo "暂无转发规则可删除"
        sleep 1
        return
    fi
    
    echo "当前规则:"
    # 显示所有规则及其编号
    awk -F'"' '
    /\[\[endpoints\]\]/ {
        rule_num++
        getline
        listen = $2
        getline
        remote = $2
        # 检查是否有备注
        comment = ""
        getline
        if ($0 ~ /^# /) {
            comment = substr($0, 3)
            getline
        }
        printf "%-4d: 本地: %s -> 远程: %s", rule_num, listen, remote
        if (comment != "") {
            printf " (备注: %s)", comment
        }
        printf "\n"
    }' "$CONFIG_FILE"
    
    echo
    echo -e "${YELLOW}请输入要删除的规则编号，多个编号用空格分隔 (如: 1 2 3 或 1 3):${NC}"
    read -p "请输入: " rule_ids
    
    # 验证输入是否为空
    if [ -z "$rule_ids" ]; then
        echo -e "${RED}未输入任何规则编号!${NC}"
        sleep 1
        return
    fi
    
    # 将输入转换为数组并排序（从大到小排序，这样删除时不会影响索引）
    local sorted_rule_ids=($(echo $rule_ids | tr ' ' '\n' | sort -nr | uniq))
    
    # 验证每个规则编号是否有效
    for rule_id in "${sorted_rule_ids[@]}"; do
        if ! [[ $rule_id =~ ^[0-9]+$ ]] || [ "$rule_id" -lt 1 ] || [ "$rule_id" -gt "$rule_count" ]; then
            echo -e "${RED}无效的规则编号: $rule_id${NC}"
            sleep 1
            return
        fi
    done
    
    # 创建临时文件
    local temp_file=$(mktemp)
    
    # 使用awk删除指定规则（从大到小删除，避免索引变化问题）
    for rule_id in "${sorted_rule_ids[@]}"; do
        # 计算要删除的规则的行范围（包括备注）
        local start_line=$(awk -v target="$rule_id" '
        BEGIN { count = 0 }
        /\[\[endpoints\]\]/ {
            count++
            if (count == target) {
                print NR
                exit
            }
        }' "$CONFIG_FILE")
        
        if [ -z "$start_line" ]; then
            echo -e "${RED}找不到规则 $rule_id${NC}"
            continue
        fi
        
        # 查找结束行（下一个规则开始或文件结束）
        local end_line=$(awk -v start="$start_line" '
        NR > start && /\[\[endpoints\]\]/ {
            print NR - 1
            exit
        }
        END {
            if (NR >= start) print NR
        }' "$CONFIG_FILE")
        
        # 删除规则块（包括备注）
        sed "${start_line},${end_line}d" "$CONFIG_FILE" > "$temp_file"
        mv "$temp_file" "$CONFIG_FILE"
        temp_file=$(mktemp)
        cp "$CONFIG_FILE" "$temp_file"
    done
    
    # 清理临时文件
    rm -f "$temp_file"
    
    echo -e "${GREEN}规则删除成功!${NC}"
    
    # 询问是否重启服务
    read -p "是否立即重启服务使配置生效? (y/n): " restart
    if [[ $restart == "y" || $restart == "Y" ]]; then
        systemctl restart realm
        echo -e "${GREEN}服务已重启!${NC}"
    fi
    sleep 1
}

# 修改转发规则
edit_rule() {
    echo -e "${GREEN}修改转发规则${NC}"
    
    local rule_count=$(grep -c "\[\[endpoints\]\]" "$CONFIG_FILE" 2>/dev/null || echo "0")
    if [ "$rule_count" -eq 0 ]; then
        echo "暂无转发规则可修改"
        sleep 1
        return
    fi
    
    echo "当前规则:"
    # 显示所有规则及其编号
    awk -F'"' '
    /\[\[endpoints\]\]/ {
        rule_num++
        getline
        listen = $2
        getline
        remote = $2
        # 检查是否有备注
        comment = ""
        getline
        if ($0 ~ /^# /) {
            comment = substr($0, 3)
            getline
        }
        printf "%-4d: 本地: %s -> 远程: %s", rule_num, listen, remote
        if (comment != "") {
            printf " (备注: %s)", comment
        }
        printf "\n"
    }' "$CONFIG_FILE"
    
    echo
    read -p "请输入要修改的规则编号: " rule_id
    
    if ! [[ $rule_id =~ ^[0-9]+$ ]] || [ "$rule_id" -lt 1 ] || [ "$rule_id" -gt "$rule_count" ]; then
        echo -e "${RED}无效的规则编号!${NC}"
        sleep 1
        return
    fi
    
    # BUG FIX: Switched to AWK with -F'"' to correctly parse values inside quotes.
    local current_values=$(awk -F'"' -v target="$rule_id" '
    BEGIN { count = 0 }
    /\[\[endpoints\]\]/ {
        count++
        if (count == target) {
            getline; listen=$2;
            getline; remote=$2;
            # Hold the current position
            current_pos = RSTART + RLENGTH
            getline; comment="";
            if ($0 ~ /^# /) { comment=substr($0, 3) }
            print listen "|" remote "|" comment
            exit
        }
    }' "$CONFIG_FILE")

    local current_listen=$(echo "$current_values" | cut -d'|' -f1)
    local current_remote=$(echo "$current_values" | cut -d'|' -f2)
    local current_comment=$(echo "$current_values" | cut -d'|' -f3)
    
    local current_local_port=$(echo "$current_listen" | cut -d':' -f2)
    local current_remote_addr=$(echo "$current_remote" | cut -d':' -f1)
    local current_remote_port=$(echo "$current_remote" | cut -d':' -f2)

    echo -e "${CYAN}--------------------------------------------------${NC}"
    echo "正在修改规则 #${rule_id}. 请输入新值, 或按 Enter 保留当前值."
    
    # 获取新的本地端口
    while true; do
        read -p "新本地监听端口 [当前: $current_local_port]: " new_local_port
        new_local_port=${new_local_port:-$current_local_port}
        
        if ! [[ $new_local_port =~ ^[0-9]+$ ]] || [ "$new_local_port" -lt 1 ] || [ "$new_local_port" -gt 65535 ]; then
            echo -e "${RED}错误: 端口无效! 必须是1-65535之间的数字。${NC}"
            continue
        fi
        
        # BUG FIX: This check now only runs if the port is actually changed.
        if [ "$new_local_port" != "$current_local_port" ]; then
            if ss -tln | grep -q ":$new_local_port " || ss -uln | grep -q ":$new_local_port "; then
                echo -e "${RED}错误: 端口 $new_local_port 正在被其他程序占用!${NC}"
                continue
            fi
            if grep -q "listen = \"0.0.0.0:$new_local_port\"" "$CONFIG_FILE"; then
                echo -e "${RED}错误: 本地端口 $new_local_port 已被其他转发规则占用!${NC}"
                continue
            fi
        fi
        break
    done

    # 获取新的远程地址
    read -p "新远程服务器地址 [当前: $current_remote_addr]: " new_remote_addr
    new_remote_addr=${new_remote_addr:-$current_remote_addr}
    
    # 获取新的远程端口
    while true; do
        read -p "新远程服务器端口 [当前: $current_remote_port]: " new_remote_port
        new_remote_port=${new_remote_port:-$current_remote_port}
        if ! [[ $new_remote_port =~ ^[0-9]+$ ]] || [ "$new_remote_port" -lt 1 ] || [ "$new_remote_port" -gt 65535 ]; then
            echo -e "${RED}错误: 远程端口无效! 必须是1-65535之间的数字。${NC}"
            continue
        fi
        break
    done
    
    # 获取新的备注
    read -p "新规则备注 [当前: $current_comment]: " new_comment
    new_comment=${new_comment:-$current_comment}
    echo -e "${CYAN}--------------------------------------------------${NC}"

    # 查找规则的起始行
    local start_line=$(awk -v target="$rule_id" 'BEGIN {c=0} /\[\[endpoints\]\]/{c++; if(c==target){print NR; exit}}' "$CONFIG_FILE")
    local listen_line=$((start_line + 1))
    local remote_line=$((start_line + 2))

    # 查找可能存在的备注行
    local comment_line=$(awk -v start="$start_line" '
    NR > start + 2 && /^# / { print NR; exit }
    NR > start + 2 && /\[\[endpoints\]\]/ { exit }' "$CONFIG_FILE")

    # 应用修改
    sed -i "${listen_line}s/.*/listen = \"0.0.0.0:$new_local_port\"/" "$CONFIG_FILE"
    sed -i "${remote_line}s/.*/remote = \"$new_remote_addr:$new_remote_port\"/" "$CONFIG_FILE"

    # 处理备注
    if [ -n "$comment_line" ]; then
        if [ -z "$new_comment" ]; then
            sed -i "${comment_line}d" "$CONFIG_FILE"
        else
            sed -i "${comment_line}s/.*/# $new_comment/" "$CONFIG_FILE"
        fi
    else
        if [ -n "$new_comment" ]; then
            sed -i "${remote_line}a# $new_comment" "$CONFIG_FILE"
        fi
    fi

    echo -e "${GREEN}规则 #${rule_id} 更新成功!${NC}"
    
    read -p "是否立即重启服务使配置生效? (y/n): " restart
    if [[ $restart == "y" || $restart == "Y" ]]; then
        systemctl restart realm
        echo -e "${GREEN}服务已重启!${NC}"
    fi
    sleep 1
}

# 服务管理
service_control() {
    local action=$1
    systemctl $action realm
    echo -e "${GREEN}服务已${action}${NC}"
    sleep 1
}

# 启用/禁用开机启动
toggle_autostart() {
    local action=$1
    
    if [[ $action == "enable" ]]; then
        systemctl enable realm
        echo -e "${GREEN}已启用开机启动!${NC}"
    else
        systemctl disable realm
        echo -e "${GREEN}已禁用开机启动!${NC}"
    fi
    sleep 1
}

# 备份配置
backup_config() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$BACKUP_DIR/${HOSTNAME}_backup_$timestamp.toml"
    
    mkdir -p "$BACKUP_DIR"
    cp "$CONFIG_FILE" "$backup_file"
    echo -e "${PURPLE}==================================================${NC}"
    echo -e "${PURPLE}                 备份完成!${NC}"
    echo -e "${PURPLE}    备份文件路径: $backup_file${NC}"
    echo -e "${PURPLE}==================================================${NC}"
    echo -e "\n按任意键返回..."
    read -n 1 -s
}

# 恢复备份
restore_backup() {
    echo -e "${GREEN}可用的备份文件:${NC}"
    mkdir -p "$BACKUP_DIR"
    local backups=($(ls -1 "$BACKUP_DIR"/*.toml 2>/dev/null))
    
    if [ ${#backups[@]} -eq 0 ]; then
        echo "暂无备份文件"
        sleep 1
        return
    fi
    
    for i in "${!backups[@]}"; do
        echo "$i: ${backups[$i]}"
    done
    
    echo
    read -p "请选择要恢复的备份编号: " backup_id
    
    if ! [[ $backup_id =~ ^[0-9]+$ ]] || [ $backup_id -ge ${#backups[@]} ]; then
        echo -e "${RED}无效的备份编号!${NC}"
        sleep 1
        return
    fi
    
    cp "${backups[$backup_id]}" "$CONFIG_FILE"
    echo -e "${GREEN}配置已从 ${backups[$backup_id]} 恢复${NC}"
    
    # 询问是否重启服务
    read -p "是否立即重启服务使配置生效? (y/n): " restart
    if [[ $restart == "y" || $restart == "Y" ]]; then
        systemctl restart realm
        echo -e "${GREEN}服务已重启!${NC}"
    fi
    sleep 1
}

# 查看服务状态
view_status() {
    echo -e "${GREEN}服务状态信息:${NC}"
    systemctl status realm --no-pager -l
    echo -e "\n按回车键返回..."
    read
}

# 主程序
main() {
    # 检查root权限
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请使用root权限运行此脚本!${NC}"
        exit 1
    fi
    
    # 检查依赖
    check_dependencies
    
    # 检查服务配置是否正确
    if [ -f "$SERVICE_FILE" ] && grep -q "config.json" "$SERVICE_FILE" 2>/dev/null; then
        echo -e "${YELLOW}检测到旧的服务配置，正在修复...${NC}"
        fix_service_config
    fi
    
    # 主循环
    while true; do
        show_main_menu
        read choice
        
        case $choice in
            1) install_realm ;;
            2) uninstall_realm ;;
            3) 
                while true; do
                    show_rule_menu
                    read rule_choice
                    case $rule_choice in
                        1) add_rule ;;
                        2) view_rules ;;
                        3) delete_rule ;;
                        4) edit_rule ;;
                        00) break ;;
                        *) echo -e "${RED}无效选择!${NC}"; sleep 1 ;;
                    esac
                done
                ;;
            4) 
                while true; do
                    show_service_menu
                    read service_choice
                    case $service_choice in
                        1) service_control start ;;
                        2) service_control stop ;;
                        3) service_control restart ;;
                        4) toggle_autostart enable ;;
                        5) toggle_autostart disable ;;
                        00) break ;;
                        *) echo -e "${RED}无效选择!${NC}"; sleep 1 ;;
                    esac
                done
                ;;
            5) 
                while true; do
                    show_backup_menu
                    read backup_choice
                    case $backup_choice in
                        1) backup_config ;;
                        2) restore_backup ;;
                        00) break ;;
                        *) echo -e "${RED}无效选择!${NC}"; sleep 1 ;;
                    esac
                done
                ;;
            6) view_status ;;
            00) echo -e "${GREEN}再见!${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选择!${NC}"; sleep 1 ;;
        esac
    done
}

# 启动主程序
main
