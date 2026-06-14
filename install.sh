#!/usr/bin/env bash
set -Eeuo pipefail

# gokaskad for Ubuntu 24.04
# Persistent DNAT/MASQUERADE cascade rules with systemd restore.

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BLUE='\033[0;34m'
NC='\033[0m'

APP_NAME='gokaskad'
INSTALL_PATH='/usr/local/bin/gokaskad'
CONFIG_DIR='/etc/gokaskad'
RULES_FILE='/etc/gokaskad/rules.tsv'
SYSCTL_FILE='/etc/sysctl.d/99-gokaskad.conf'
SERVICE_FILE='/etc/systemd/system/gokaskad-restore.service'

CHAIN_DNAT='GOKASKAD_DNAT'
CHAIN_SNAT='GOKASKAD_SNAT'
CHAIN_INPUT='GOKASKAD_INPUT'
CHAIN_FORWARD='GOKASKAD_FORWARD'

IPT='iptables'

log() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
info() { echo -e "${CYAN}[*]${NC} $*"; }

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err 'Запустите скрипт с правами root: sudo ./install.sh'
        exit 1
    fi
}

pause() { read -r -p 'Нажмите Enter...' _ || true; }

ensure_ubuntu24() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        if [[ "${ID:-}" != 'ubuntu' || "${VERSION_ID:-}" != '24.04' ]]; then
            warn "Скрипт оптимизирован под Ubuntu 24.04, текущая ОС: ${PRETTY_NAME:-unknown}. Продолжаю."
        fi
    fi
}

select_iptables() {
    # Ubuntu 24.04 normally uses iptables-nft. Do not force legacy backend.
    if command -v iptables >/dev/null 2>&1; then
        IPT="$(command -v iptables)"
    elif [[ -x /usr/sbin/iptables-nft ]]; then
        IPT='/usr/sbin/iptables-nft'
    elif [[ -x /usr/sbin/iptables ]]; then
        IPT='/usr/sbin/iptables'
    else
        err 'iptables не найден'
        exit 1
    fi
}

apt_install() {
    export DEBIAN_FRONTEND=noninteractive
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections || true
    echo iptables-persistent iptables-persistent/autosave_v6 boolean false | debconf-set-selections || true
    apt-get update -y >/dev/null
    apt-get install -y --no-install-recommends \
        iptables iproute2 netfilter-persistent iptables-persistent ca-certificates >/dev/null
}

configure_sysctl() {
    mkdir -p /etc/sysctl.d
    cat > "$SYSCTL_FILE" <<'EOF_SYSCTL'
# Managed by gokaskad
net.ipv4.ip_forward=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF_SYSCTL
    sysctl --system >/dev/null || sysctl -p "$SYSCTL_FILE" >/dev/null || true
}

install_self() {
    mkdir -p "$CONFIG_DIR"
    touch "$RULES_FILE"
    chmod 600 "$RULES_FILE"

    if [[ "$(readlink -f "$0")" != "$INSTALL_PATH" ]]; then
        cp -f "$0" "$INSTALL_PATH"
        chmod 0755 "$INSTALL_PATH"
    else
        chmod 0755 "$INSTALL_PATH"
    fi
}

install_systemd() {
    cat > "$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=Restore gokaskad cascade iptables rules
Documentation=man:iptables(8)
Wants=network-online.target
After=network-online.target netfilter-persistent.service

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE
    systemctl daemon-reload
    systemctl enable gokaskad-restore.service >/dev/null
}

prepare_system() {
    ensure_ubuntu24
    select_iptables
    if ! dpkg -s iptables-persistent netfilter-persistent >/dev/null 2>&1; then
        info 'Установка зависимостей для Ubuntu 24.04...'
        apt_install
    fi
    select_iptables
    configure_sysctl
    install_self
    install_systemd
}

validate_proto() {
    [[ "$1" == 'tcp' || "$1" == 'udp' ]]
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

validate_ipv4() {
    local ip=$1 o
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a o <<< "$ip"
    for n in "${o[@]}"; do
        [[ "$n" =~ ^[0-9]+$ ]] || return 1
        (( 0 <= 10#$n && 10#$n <= 255 )) || return 1
    done
}

get_default_iface() {
    local target=${1:-8.8.8.8}
    ip route get "$target" 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

ensure_chain() {
    local table=$1 chain=$2
    if ! "$IPT" -t "$table" -L "$chain" -n >/dev/null 2>&1; then
        "$IPT" -t "$table" -N "$chain"
    fi
}

ensure_jump_top() {
    local table=$1 base=$2 target=$3
    if ! "$IPT" -t "$table" -C "$base" -j "$target" >/dev/null 2>&1; then
        "$IPT" -t "$table" -I "$base" 1 -j "$target"
    fi
}

ensure_managed_chains() {
    ensure_chain nat "$CHAIN_DNAT"
    ensure_chain nat "$CHAIN_SNAT"
    ensure_chain filter "$CHAIN_INPUT"
    ensure_chain filter "$CHAIN_FORWARD"

    ensure_jump_top nat PREROUTING "$CHAIN_DNAT"
    ensure_jump_top nat POSTROUTING "$CHAIN_SNAT"
    ensure_jump_top filter INPUT "$CHAIN_INPUT"
    ensure_jump_top filter FORWARD "$CHAIN_FORWARD"
}

flush_managed_chains() {
    ensure_managed_chains
    "$IPT" -t nat -F "$CHAIN_DNAT" || true
    "$IPT" -t nat -F "$CHAIN_SNAT" || true
    "$IPT" -t filter -F "$CHAIN_INPUT" || true
    "$IPT" -t filter -F "$CHAIN_FORWARD" || true
}

apply_one_rule_to_chains() {
    local proto=$1 in_port=$2 out_port=$3 target_ip=$4 name=${5:-Rule}
    local iface
    iface="$(get_default_iface "$target_ip")"
    if [[ -z "$iface" ]]; then
        iface="$(get_default_iface 8.8.8.8)"
    fi
    if [[ -z "$iface" ]]; then
        err 'Не удалось определить исходящий сетевой интерфейс'
        return 1
    fi

    "$IPT" -t filter -A "$CHAIN_INPUT" -p "$proto" --dport "$in_port" -m comment --comment "gokaskad:${proto}:${in_port}:${name}" -j ACCEPT
    "$IPT" -t nat -A "$CHAIN_DNAT" -p "$proto" --dport "$in_port" -m comment --comment "gokaskad:${proto}:${in_port}:${name}" -j DNAT --to-destination "${target_ip}:${out_port}"

    if ! "$IPT" -t nat -C "$CHAIN_SNAT" -o "$iface" -m comment --comment "gokaskad:masquerade:${iface}" -j MASQUERADE >/dev/null 2>&1; then
        "$IPT" -t nat -A "$CHAIN_SNAT" -o "$iface" -m comment --comment "gokaskad:masquerade:${iface}" -j MASQUERADE
    fi

    "$IPT" -t filter -A "$CHAIN_FORWARD" -p "$proto" -d "$target_ip" --dport "$out_port" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -m comment --comment "gokaskad:${proto}:${in_port}:forward-out" -j ACCEPT
    "$IPT" -t filter -A "$CHAIN_FORWARD" -p "$proto" -s "$target_ip" --sport "$out_port" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "gokaskad:${proto}:${in_port}:forward-in" -j ACCEPT
}

save_netfilter() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || true
    fi
}

restore_rules() {
    select_iptables
    configure_sysctl
    mkdir -p "$CONFIG_DIR"
    touch "$RULES_FILE"
    chmod 600 "$RULES_FILE"

    flush_managed_chains

    local proto in_port out_port target_ip name
    while IFS=$'\t' read -r proto in_port out_port target_ip name; do
        [[ -z "${proto:-}" || "$proto" =~ ^# ]] && continue
        if validate_proto "$proto" && validate_port "$in_port" && validate_port "$out_port" && validate_ipv4 "$target_ip"; then
            apply_one_rule_to_chains "$proto" "$in_port" "$out_port" "$target_ip" "${name:-Rule}"
        else
            warn "Пропускаю некорректную строку rules.tsv: $proto $in_port $out_port $target_ip"
        fi
    done < "$RULES_FILE"

    save_netfilter
    log 'Правила gokaskad восстановлены'
}

add_or_replace_state_rule() {
    local proto=$1 in_port=$2 out_port=$3 target_ip=$4 name=${5:-Rule}
    mkdir -p "$CONFIG_DIR"
    touch "$RULES_FILE"
    chmod 600 "$RULES_FILE"

    local tmp
    tmp="$(mktemp)"
    awk -F '\t' -v p="$proto" -v port="$in_port" 'BEGIN{OFS=FS} !($1==p && $2==port)' "$RULES_FILE" > "$tmp" || true
    printf '%s\t%s\t%s\t%s\t%s\n' "$proto" "$in_port" "$out_port" "$target_ip" "$name" >> "$tmp"
    mv "$tmp" "$RULES_FILE"
    chmod 600 "$RULES_FILE"
}

remove_state_rule_by_index() {
    local idx=$1 tmp
    tmp="$(mktemp)"
    awk -F '\t' -v n="$idx" 'BEGIN{c=0} /^#/ || NF<4 {print; next} {c++; if (c!=n) print}' "$RULES_FILE" > "$tmp" || true
    mv "$tmp" "$RULES_FILE"
    chmod 600 "$RULES_FILE"
}

configure_ufw_if_needed() {
    local proto=$1 in_port=$2 target_ip=$3 out_port=$4
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
        ufw allow "${in_port}/${proto}" >/dev/null || true
        ufw route allow proto "$proto" to "$target_ip" port "$out_port" >/dev/null || true
        if [[ -f /etc/default/ufw ]]; then
            sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
        fi
        ufw reload >/dev/null || true
    fi
}

apply_iptables_rules() {
    local proto=$1 in_port=$2 out_port=$3 target_ip=$4 name=${5:-Rule}

    if ! validate_proto "$proto"; then err 'Протокол должен быть tcp или udp'; return 1; fi
    if ! validate_port "$in_port" || ! validate_port "$out_port"; then err 'Порт должен быть 1..65535'; return 1; fi
    if ! validate_ipv4 "$target_ip"; then err 'IP назначения должен быть IPv4, например 1.2.3.4'; return 1; fi

    info 'Применение и сохранение правила...'
    add_or_replace_state_rule "$proto" "$in_port" "$out_port" "$target_ip" "$name"
    configure_ufw_if_needed "$proto" "$in_port" "$target_ip" "$out_port"
    restore_rules

    log "$name настроен и сохранён для автовосстановления после перезагрузки"
    echo -e "${WHITE}${proto}: вход ${in_port} -> ${target_ip}:${out_port}${NC}"
}

show_header() {
    clear
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║                    GOKASKAD Ubuntu 24.04                     ║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${CYAN}Каскад: клиент -> этот VPS -> целевой сервер.${NC}"
    echo -e "${YELLOW}Правила сохраняются в ${RULES_FILE} и восстанавливаются systemd-сервисом.${NC}"
    echo ''
}

show_instructions() {
    clear
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║              📚 ИНСТРУКЦИЯ: КАК НАСТРОИТЬ КАСКАД             ║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ''
    echo -e "${CYAN}1.${NC} Укажите IP целевого сервера и порт."
    echo -e "${CYAN}2.${NC} Скрипт создаст DNAT + MASQUERADE + FORWARD."
    echo -e "${CYAN}3.${NC} На клиенте замените Endpoint на IP этого VPS и входящий порт."
    echo -e "${CYAN}4.${NC} После reboot правила восстановит ${YELLOW}gokaskad-restore.service${NC}."
    echo ''
    echo -e "Проверка после reboot:"
    echo -e "${WHITE}sudo systemctl status gokaskad-restore --no-pager${NC}"
    echo -e "${WHITE}sudo gokaskad status${NC}"
    echo ''
    pause
}

read_target_ip() {
    local v
    while true; do
        read -r -p 'Введите IPv4 адрес назначения: ' v
        if validate_ipv4 "$v"; then echo "$v"; return 0; fi
        echo -e "${RED}Ошибка: введите IPv4, например 203.0.113.10${NC}"
    done
}

read_port() {
    local prompt=$1 v
    while true; do
        read -r -p "$prompt" v
        if validate_port "$v"; then echo "$v"; return 0; fi
        echo -e "${RED}Ошибка: порт должен быть числом 1..65535${NC}"
    done
}

configure_rule() {
    local proto=$1 name=$2 target_ip port
    echo -e "\n${CYAN}--- Настройка ${name} (${proto}) ---${NC}"
    target_ip="$(read_target_ip)"
    port="$(read_port 'Введите порт, одинаковый для входа и выхода: ')"
    apply_iptables_rules "$proto" "$port" "$port" "$target_ip" "$name"
    pause
}

configure_custom_rule() {
    local proto target_ip in_port out_port
    echo -e "\n${CYAN}--- Кастомное правило ---${NC}"
    while true; do
        read -r -p 'Выберите протокол tcp или udp: ' proto
        if validate_proto "$proto"; then break; fi
        echo -e "${RED}Ошибка: введите tcp или udp${NC}"
    done
    target_ip="$(read_target_ip)"
    in_port="$(read_port 'Введите ВХОДЯЩИЙ порт на этом VPS: ')"
    out_port="$(read_port 'Введите ИСХОДЯЩИЙ порт на целевом сервере: ')"
    apply_iptables_rules "$proto" "$in_port" "$out_port" "$target_ip" 'Custom Rule'
    pause
}

list_active_rules() {
    echo -e "\n${CYAN}--- Активные правила gokaskad ---${NC}"
    if [[ ! -s "$RULES_FILE" ]]; then
        echo -e "${YELLOW}Правил нет.${NC}"
    else
        printf "${MAGENTA}%-5s %-6s %-12s %-12s %-22s %s${NC}\n" '№' 'PROTO' 'IN_PORT' 'OUT_PORT' 'TARGET' 'NAME'
        local n=0 proto in_port out_port target_ip name
        while IFS=$'\t' read -r proto in_port out_port target_ip name; do
            [[ -z "${proto:-}" || "$proto" =~ ^# ]] && continue
            n=$((n+1))
            printf '%-5s %-6s %-12s %-12s %-22s %s\n' "$n" "$proto" "$in_port" "$out_port" "$target_ip" "${name:-Rule}"
        done < "$RULES_FILE"
    fi
    echo ''
    echo -e "${CYAN}iptables chains:${NC}"
    "$IPT" -t nat -S "$CHAIN_DNAT" 2>/dev/null || true
    "$IPT" -t nat -S "$CHAIN_SNAT" 2>/dev/null || true
}

status() {
    select_iptables
    echo -e "${CYAN}OS:${NC} $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
    echo -e "${CYAN}iptables:${NC} $($IPT --version 2>/dev/null || true)"
    echo -e "${CYAN}ip_forward:${NC} $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo unknown)"
    echo -e "${CYAN}service:${NC} $(systemctl is-enabled gokaskad-restore.service 2>/dev/null || echo disabled) / $(systemctl is-active gokaskad-restore.service 2>/dev/null || echo inactive)"
    list_active_rules
}

delete_single_rule() {
    list_active_rules
    echo ''
    read -r -p 'Номер правила для удаления, 0 отмена: ' rule_num
    [[ "$rule_num" == '0' || -z "$rule_num" ]] && return 0
    if ! [[ "$rule_num" =~ ^[0-9]+$ ]]; then
        err 'Введите номер правила'
        pause
        return 1
    fi
    remove_state_rule_by_index "$rule_num"
    restore_rules
    log 'Правило удалено и состояние сохранено'
    pause
}

flush_rules() {
    echo -e "\n${RED}Удалить ВСЕ правила gokaskad?${NC}"
    echo 'Это не очищает весь firewall сервера, только управляемые цепочки gokaskad.'
    read -r -p 'Вы уверены? (y/n): ' confirm
    if [[ "$confirm" == 'y' || "$confirm" == 'Y' ]]; then
        : > "$RULES_FILE"
        flush_managed_chains
        save_netfilter
        log 'Все правила gokaskad удалены'
    fi
    pause
}

show_menu() {
    while true; do
        show_header
        echo -e "1) Настроить ${CYAN}AmneziaWG / WireGuard${NC} (UDP)"
        echo -e "2) Настроить ${CYAN}VLESS / Xray${NC} (TCP)"
        echo -e "3) Настроить ${CYAN}TProxy / MTProto${NC} (TCP)"
        echo -e "4) 🛠 Создать ${YELLOW}кастомное правило${NC}"
        echo -e "5) Посмотреть активные правила"
        echo -e "6) ${RED}Удалить одно правило${NC}"
        echo -e "7) ${RED}Удалить все правила gokaskad${NC}"
        echo -e "8) Восстановить правила сейчас"
        echo -e "9) ${MAGENTA}Инструкция${NC}"
        echo -e "10) Статус"
        echo -e "0) Выход"
        echo '------------------------------------------------------'
        read -r -p 'Ваш выбор: ' choice
        case "$choice" in
            1) configure_rule 'udp' 'AmneziaWG' ;;
            2) configure_rule 'tcp' 'VLESS' ;;
            3) configure_rule 'tcp' 'MTProto/TProxy' ;;
            4) configure_custom_rule ;;
            5) list_active_rules; pause ;;
            6) delete_single_rule ;;
            7) flush_rules ;;
            8) restore_rules; pause ;;
            9) show_instructions ;;
            10) status; pause ;;
            0) exit 0 ;;
            *) ;;
        esac
    done
}

usage() {
    cat <<EOF_USAGE
Usage: $0 [install|menu|restore|status|flush]

install  Установить /usr/local/bin/gokaskad и systemd restore service
menu     Открыть меню
restore  Восстановить правила из $RULES_FILE
status   Показать статус и правила
flush    Удалить только правила gokaskad
EOF_USAGE
}

main() {
    local cmd=${1:-menu}
    check_root
    case "$cmd" in
        install)
            prepare_system
            restore_rules
            log 'Установка завершена. Запуск меню: sudo gokaskad'
            ;;
        menu)
            prepare_system
            show_menu
            ;;
        restore)
            select_iptables
            restore_rules
            ;;
        status)
            select_iptables
            status
            ;;
        flush)
            select_iptables
            : > "$RULES_FILE"
            flush_managed_chains
            save_netfilter
            log 'Правила gokaskad удалены'
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
