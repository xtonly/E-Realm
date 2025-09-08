#!/bin/bash

# ==============================================================================
# E-Realm 管理面板
# ==============================================================================
PANEL_VERSION="1.1.6" # 版本号提升
REALM_VERSION="2.9.2"
UPDATE_LOG="v1.1.6: 增强备份管理,增加删除备份和操作可中断逻辑. 优化修改规则流程,允许中途取消."
# ==============================================================================

REALM_URL="https://20.205.243.166/zhboner/realm/releases/download/v${REALM_VERSION}/realm-x86_64-unknown-linux-gnu.tar.gz"
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
    local deps=("curl" "wget" "cron" "iproute2" "awk")
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
    echo "0. 退出"
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
    echo "0. 返回主菜单"
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
    echo "0. 返回主菜单"
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
    echo "3. 删除备份"
    echo "0. 返回主菜单"
    echo -e "${CYAN}==================================================${NC}"
    echo -n "请选择操作: "
}

# 修复服务配置
fix_service_config() {
    echo -e "${GREEN}修复服务配置...${NC}"
    
    systemctl stop realm 2>/dev/null
    rm -f "$SERVICE_FILE"
    
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
    
    systemctl daemon-reload
    systemctl enable realm
    
    echo -e "${GREEN}服务配置已修复!${NC}"
}

# 安装 Realm
install_realm() {
    echo -e "${GREEN}正在安装 Realm v${REALM_VERSION}...${NC}"
    
    if [ -f /usr/local/bin/realm ]; then
        echo -e "${YELLOW}Realm 已经安装，是否需要重新安装? (y/n): ${NC}"
        read reinstall
        if [[ $reinstall != "y" && $reinstall != "Y" ]]; then
            return
        fi
    fi
    
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$BACKUP_DIR"
    
    cd /tmp
    wget "$REALM_URL" -O realm.tar.gz
    tar -xzf realm.tar.gz
    mv realm /usr/local/bin/
    chmod +x /usr/local/bin/realm
    
    rm -f "$CONFIG_DIR/config.json"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << 'EOF'
[log]
level = "warn"

[dns]
mode = "ipv4_then_ipv6"

[network]
no_tcp = false
use_udp = true
send_mptcp = true
accept_mptcp = false
EOF
    fi
    
    fix_service_config
    
    cat > /opt/realm_monitor.sh << 'EOF'
#!/bin/bash
if ! pgrep -x "realm" > /dev/null; then
    systemctl start realm
    echo "$(date): Realm was not running, restarted." >> /var/log/realm_monitor.log
fi
EOF
    
    chmod +x /opt/realm_monitor.sh
    echo "*/20 * * * * root /opt/realm_monitor.sh" > "$CRON_FILE"
    systemctl start realm
    
    echo -e "${GREEN}Realm 安装完成!${NC}"
    sleep 2
}

# 卸载 Realm
uninstall_realm() {
    echo -e "${RED}正在卸载 Realm...${NC}"
    
    read -p "确定要卸载 Realm 吗? 此操作不可逆! (y/n): " confirm
    if [[ $confirm != "y" && $confirm != "Y" ]]; then
        echo "取消卸载"
        return
    fi
    
    systemctl stop realm
    systemctl disable realm
    
    rm -f /usr/local/bin/realm "$SERVICE_FILE" "$CRON_FILE" /opt/realm_monitor.sh
    
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
        if [[ "$local_port" == "0" ]]; then return; fi
        
        if ! [[ $local_port =~ ^[0-9]+$ ]] || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
            echo -e "${RED}错误: 端口无效! 必须是1-65535之间的数字。${NC}"
            continue
        fi
        if ss -tln | grep -q ":$local_port " || ss -uln | grep -q ":$local_port "; then
            echo -e "${RED}错误: 端口 $local_port 正在被其他程序占用!${NC}"
            continue
        fi
        if grep -q "listen = \"0.0.0.0:$local_port\"" "$CONFIG_FILE"; then
            echo -e "${RED}错误: 本地端口 $local_port 已被其他转发规则占用!${NC}"
            continue
        fi
        echo -e "${GREEN}端口 $local_port 可用。${NC}"
        break
    done
    
    read -p "请输入远程服务器地址: " remote_addr
    read -p "请输入远程服务器端口: " remote_port
    read -p "请输入规则备注(可选): " comment
    
    if ! [[ $remote_port =~ ^[0-9]+$ ]] || [ "$remote_port" -lt 1 ] || [ "$remote_port" -gt 65535 ]; then
        echo -e "${RED}错误: 远程端口无效! 添加失败。${NC}"
        sleep 2; return 1
    fi
    
    if [ -s "$CONFIG_FILE" ] && [ "$(tail -c 1 "$CONFIG_FILE")" != "" ]; then echo "" >> "$CONFIG_FILE"; fi
    
    cat >> "$CONFIG_FILE" <<EOF

[[endpoints]]
listen = "0.0.0.0:$local_port"
remote = "$remote_addr:$remote_port"
EOF
    
    if [ -n "$comment" ]; then echo "# $comment" >> "$CONFIG_FILE"; fi
    
    echo -e "${GREEN}规则添加成功!${NC}"
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
    
    if [ "$rule_count" -eq 0 ]; then
        echo "暂无转发规则"
    else
        awk -F'"' '
        /\[\[endpoints\]\]/ {
            rule_num++
            getline; listen = $2
            getline; remote = $2
            comment = ""
            if (getline > 0 && $0 ~ /^# /) { comment = substr($0, 3) }
            printf "%-4d: 本地: %s -> 远程: %s", rule_num, listen, remote
            if (comment != "") { printf " (备注: %s)", comment }
            printf "\n"
        }' "$CONFIG_FILE"
    fi

    if [[ "$1" == "wait" ]]; then
        echo -e "\n按回车键返回..."
        read
    fi
}

# 删除转发规则
delete_rule() {
    echo -e "${GREEN}删除转发规则${NC}"
    local rule_count=$(grep -c "\[\[endpoints\]\]" "$CONFIG_FILE" 2>/dev/null || echo "0")
    if [ "$rule_count" -eq 0 ]; then echo "暂无转发规则可删除"; sleep 1; return; fi
    
    view_rules
    echo
    echo -e "${YELLOW}请输入要删除的规则编号，多个用空格分隔 (输入 0 返回):${NC}"
    read -p "请输入: " rule_ids
    
    if [[ -z "$rule_ids" || "$rule_ids" == "0" ]]; then echo "操作取消"; sleep 1; return; fi
    
    for id in $rule_ids; do
        if ! [[ $id =~ ^[0-9]+$ ]]; then echo -e "${RED}错误: 输入 '$id' 不是有效编号。${NC}"; sleep 2; return; fi
    done
    
    local delete_list=" $(echo "$rule_ids" | tr ' ' '\n' | sort -n | uniq | tr '\n' ' ') "
    local temp_file=$(mktemp)
    
    awk -v delete_list="$delete_list" '
    BEGIN { rule_counter=0; buffer=""; in_block=0 }
    function flush_buffer() { if (in_block && delete_list !~ " " rule_counter " ") { printf "%s", buffer } buffer=""; in_block=0 }
    /^\[\[endpoints\]\]/ { flush_buffer(); rule_counter++; in_block=1 }
    { if (in_block) { buffer=buffer $0 "\n" } else { print } }
    END { flush_buffer() }
    ' "$CONFIG_FILE" > "$temp_file"
    
    if [ ! -s "$temp_file" ] && [ "$rule_count" -gt 0 ] && [ ${#rule_ids} -lt $rule_count ]; then
        echo -e "${RED}错误：处理后配置文件为空！已中止删除操作。${NC}"; rm -f "$temp_file"; sleep 2; return
    fi
    
    mv "$temp_file" "$CONFIG_FILE"
    echo -e "${GREEN}选择的规则已成功删除!${NC}"
    read -p "是否立即重启服务使配置生效? (y/n): " restart
    if [[ $restart == "y" || $restart == "Y" ]]; then systemctl restart realm; echo -e "${GREEN}服务已重启!${NC}"; fi
    sleep 1
}

# 修改转发规则
edit_rule() {
    echo -e "${GREEN}修改转发规则${NC}"
    local rule_count=$(grep -c "\[\[endpoints\]\]" "$CONFIG_FILE" 2>/dev/null || echo "0")
    if [ "$rule_count" -eq 0 ]; then echo "暂无转发规则可修改"; sleep 1; return; fi
    
    view_rules
    echo
    read -p "请输入要修改的规则编号 (输入 0 返回): " rule_id
    if [[ "$rule_id" == "0" ]]; then return; fi

    if ! [[ $rule_id =~ ^[0-9]+$ ]] || [ "$rule_id" -lt 1 ] || [ "$rule_id" -gt "$rule_count" ]; then
        echo -e "${RED}无效的规则编号!${NC}"; sleep 1; return
    fi
    
    local rule_block=$(awk -v target="$rule_id" '
        BEGIN { count=0; printing=0 }
        /^\[\[endpoints\]\]/ { if (printing) exit; count++; if (count == target) printing=1 }
        printing { print }' "$CONFIG_FILE")

    if [ -z "$rule_block" ]; then echo -e "${RED}错误：无法提取规则 #${rule_id} 信息。${NC}"; sleep 2; return; fi
    
    local current_listen=$(echo -e "$rule_block" | grep 'listen' | awk -F'"' '{print $2}')
    local current_remote=$(echo -e "$rule_block" | grep 'remote' | awk -F'"' '{print $2}')
    local current_comment=$(echo -e "$rule_block" | grep '^#' | sed 's/^# //')
    local current_local_port=$(echo "$current_listen" | cut -d':' -f2)
    local current_remote_addr=$(echo "$current_remote" | cut -d':' -f1)
    local current_remote_port=$(echo "$current_remote" | cut -d':' -f2)

    echo -e "${CYAN}--------------------------------------------------${NC}"
    echo "正在修改规则 #${rule_id}. 请输入新值, 或按 Enter 保留当前值."
    
    while true; do
        read -p "新本地监听端口 [当前: $current_local_port] (输入0取消): " new_local_port
        if [[ "$new_local_port" == "0" ]]; then echo -e "${YELLOW}操作已取消。${NC}"; sleep 1; return; fi
        new_local_port=${new_local_port:-$current_local_port}
        if ! [[ $new_local_port =~ ^[0-9]+$ ]] || [ "$new_local_port" -lt 1 ] || [ "$new_local_port" -gt 65535 ]; then
            echo -e "${RED}错误: 端口无效!${NC}"; continue
        fi
        if [ "$new_local_port" != "$current_local_port" ]; then
            if ss -tln | grep -q ":$new_local_port " || ss -uln | grep -q ":$new_local_port "; then
                echo -e "${RED}错误: 端口 $new_local_port 被其他程序占用!${NC}"; continue
            fi
            if grep -q "listen = \"0.0.0.0:$new_local_port\"" "$CONFIG_FILE"; then
                echo -e "${RED}错误: 本地端口 $new_local_port 已被其他规则占用!${NC}"; continue
            fi
        fi
        break
    done

    read -p "新远程服务器地址 [当前: $current_remote_addr] (输入0取消): " new_remote_addr
    if [[ "$new_remote_addr" == "0" ]]; then echo -e "${YELLOW}操作已取消。${NC}"; sleep 1; return; fi
    new_remote_addr=${new_remote_addr:-$current_remote_addr}
    
    while true; do
        read -p "新远程服务器端口 [当前: $current_remote_port] (输入0取消): " new_remote_port
        if [[ "$new_remote_port" == "0" ]]; then echo -e "${YELLOW}操作已取消。${NC}"; sleep 1; return; fi
        new_remote_port=${new_remote_port:-$current_remote_port}
        if ! [[ $new_remote_port =~ ^[0-9]+$ ]] || [ "$new_remote_port" -lt 1 ] || [ "$new_remote_port" -gt 65535 ]; then
            echo -e "${RED}错误: 远程端口无效!${NC}"; continue
        fi
        break
    done
    
    read -p "新规则备注 [当前: $current_comment] (输入0取消): " new_comment
    if [[ "$new_comment" == "0" ]]; then echo -e "${YELLOW}操作已取消。${NC}"; sleep 1; return; fi
    new_comment=${new_comment:-$current_comment}
    echo -e "${CYAN}--------------------------------------------------${NC}"
    
    local new_rule_content="[[endpoints]]\nlisten = \"0.0.0.0:$new_local_port\"\nremote = \"$new_remote_addr:$new_remote_port\""
    if [ -n "$new_comment" ]; then new_rule_content+="\n# $new_comment"; fi

    local temp_file=$(mktemp)
    awk -v target="$rule_id" -v new_content="$new_rule_content" '
        BEGIN { rule_counter=0; in_block=0; skip_print=0; buffer="" }
        /^\[\[endpoints\]\]/ {
            if (in_block) { if (!skip_print) printf "%s", buffer }
            buffer=""; in_block=1; skip_print=0; rule_counter++;
            if (rule_counter == target) { print new_content; skip_print=1 }
        }
        { if (in_block && !skip_print) buffer = buffer $0 ORS; else if (!in_block) print }
        END { if (in_block && !skip_print) printf "%s", buffer }
    ' "$CONFIG_FILE" > "$temp_file"

    mv "$temp_file" "$CONFIG_FILE"
    echo -e "${GREEN}规则 #${rule_id} 更新成功!${NC}"
    
    read -p "是否立即重启服务使配置生效? (y/n): " restart
    if [[ $restart == "y" || $restart == "Y" ]]; then systemctl restart realm; echo -e "${GREEN}服务已重启!${NC}"; fi
    sleep 1
}

# 服务管理
service_control() {
    systemctl $1 realm
    echo -e "${GREEN}服务已$1!${NC}"
    sleep 1
}

# 启用/禁用开机启动
toggle_autostart() {
    if [[ $1 == "enable" ]]; then
        systemctl enable realm; echo -e "${GREEN}已启用开机启动!${NC}"
    else
        systemctl disable realm; echo -e "${GREEN}已禁用开机启动!${NC}"
    fi
    sleep 1
}

# 备份配置
backup_config() {
    read -p "确定要创建新备份吗? (y/n, 默认y, 输入0取消): " confirm
    if [[ "$confirm" == "0" ]]; then
        echo -e "${YELLOW}操作已取消。${NC}"; sleep 1; return
    elif [[ -n "$confirm" && "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}操作已取消。${NC}"; sleep 1; return
    fi

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
    echo -e "${GREEN}可用的备份文件 (编号从1开始):${NC}"
    mkdir -p "$BACKUP_DIR"
    local backups=("$BACKUP_DIR"/*.toml)
    
    if [ ! -f "${backups[0]}" ]; then echo "暂无备份文件"; sleep 1; return; fi
    
    for i in "${!backups[@]}"; do
        echo "$((i+1)): $(basename "${backups[$i]}")"
    done
    
    echo
    read -p "请选择要恢复的备份编号 (输入 0 返回): " backup_id
    
    if [[ "$backup_id" == "0" ]]; then echo "操作取消"; return; fi
    
    if ! [[ $backup_id =~ ^[0-9]+$ ]] || [ "$backup_id" -lt 1 ] || [ "$backup_id" -gt ${#backups[@]} ]; then
        echo -e "${RED}无效的备份编号!${NC}"; sleep 1; return
    fi
    
    local target_backup_file=${backups[$((backup_id-1))]}
    cp "$target_backup_file" "$CONFIG_FILE"
    echo -e "${GREEN}配置已从 $(basename "$target_backup_file") 恢复${NC}"
    
    read -p "是否立即重启服务使配置生效? (y/n): " restart
    if [[ $restart == "y" || $restart == "Y" ]]; then
        systemctl restart realm
        echo -e "${GREEN}服务已重启!${NC}"
    fi
    sleep 1
}

# 删除备份
delete_backup() {
    echo -e "${GREEN}可用的备份文件 (编号从1开始):${NC}"
    mkdir -p "$BACKUP_DIR"
    local backups=("$BACKUP_DIR"/*.toml)
    
    if [ ! -f "${backups[0]}" ]; then echo "暂无备份文件"; sleep 1; return; fi
    
    for i in "${!backups[@]}"; do
        echo "$((i+1)): $(basename "${backups[$i]}")"
    done
    
    echo
    read -p "请输入要删除的备份编号，多个用空格分隔 (输入 0 返回): " backup_ids
    
    if [[ -z "$backup_ids" || "$backup_ids" == "0" ]]; then echo "操作取消"; sleep 1; return; fi
    
    local files_to_delete=()
    local invalid_ids=()
    
    for id in $backup_ids; do
        if [[ $id =~ ^[0-9]+$ ]] && [ "$id" -ge 1 ] && [ "$id" -le ${#backups[@]} ]; then
            files_to_delete+=("${backups[$((id-1))]}")
        else
            invalid_ids+=("$id")
        fi
    done
    
    if [ ${#invalid_ids[@]} -ne 0 ]; then
        echo -e "${RED}以下为无效编号: ${invalid_ids[*]}${NC}"
    fi
    
    if [ ${#files_to_delete[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有有效的备份文件被选中删除。${NC}"; sleep 2; return
    fi
    
    echo -e "${YELLOW}你确定要删除以下 ${#files_to_delete[@]} 个备份文件吗?${NC}"
    for file in "${files_to_delete[@]}"; do
        echo " - $(basename "$file")"
    done
    
    read -p "此操作不可逆! (y/n): " confirm
    if [[ $confirm != "y" && $confirm != "Y" ]]; then
        echo -e "${YELLOW}删除操作已取消。${NC}"; sleep 1; return
    fi
    
    for file in "${files_to_delete[@]}"; do
        rm -f "$file"
        echo -e "${GREEN}已删除: $(basename "$file")${NC}"
    done
    
    echo -e "\n按任意键返回..."
    read -n 1 -s
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
    if [ "$EUID" -ne 0 ]; then echo -e "${RED}请使用root权限运行此脚本!${NC}"; exit 1; fi
    
    check_dependencies
    
    if [ -f "$SERVICE_FILE" ] && grep -q "config.json" "$SERVICE_FILE" 2>/dev/null; then
        echo -e "${YELLOW}检测到旧的服务配置，正在修复...${NC}"; fix_service_config
    fi
    
    while true; do
        show_main_menu
        read choice
        
        case $choice in
            1) install_realm ;;
            2) uninstall_realm ;;
            3) 
                while true; do
                    show_rule_menu; read rule_choice
                    case $rule_choice in
                        1) add_rule ;;
                        2) view_rules "wait" ;;
                        3) delete_rule ;;
                        4) edit_rule ;;
                        0) break ;;
                        *) echo -e "${RED}无效选择!${NC}"; sleep 1 ;;
                    esac
                done ;;
            4) 
                while true; do
                    show_service_menu; read service_choice
                    case $service_choice in
                        1) service_control start ;;
                        2) service_control stop ;;
                        3) service_control restart ;;
                        4) toggle_autostart enable ;;
                        5) toggle_autostart disable ;;
                        0) break ;;
                        *) echo -e "${RED}无效选择!${NC}"; sleep 1 ;;
                    esac
                done ;;
            5) 
                while true; do
                    show_backup_menu; read backup_choice
                    case $backup_choice in
                        1) backup_config ;;
                        2) restore_backup ;;
                        3) delete_backup ;;
                        0) break ;;
                        *) echo -e "${RED}无效选择!${NC}"; sleep 1 ;;
                    esac
                done ;;
            6) view_status ;;
            0) echo -e "${GREEN}再见!${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选择!${NC}"; sleep 1 ;;
        esac
    done
}

main
