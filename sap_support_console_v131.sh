#!/usr/bin/env bash
# ============================================================================
# SAP SUPPORT CONSOLE V1.3
# Autor       : Eduardo Esteves
# Versao      : 1.3
# Data        : 2026
# Finalidade  : Diagnostico e suporte operacional SAP
# Ambiente    : Linux / SAP Business One / SAP HANA
#
# HISTORICO DE VERSOES
# 1.0 - Primeiro prototipo controlado baseado nas KBs SAP fornecidas.
#       Health check, consultas, reinicios auditados e limpeza restrita.
# 1.1 - Limpeza controlada de log_backup do HANA, com retencao minima de
#       24 horas, descoberta de diretorios e relatorio antes/depois.
# 1.2 - Consulta dos relatorios de limpeza diretamente pelo console, com
#       resumo destacado de ticket, contexto, espaco e resultado.
# 1.3 - Redesign compacto com identidade visual Wevy, navegacao padronizada,
#       largura adaptativa e modo sem cores para terminais incompativeis.
#
# PRINCIPIOS
# - Consultas nao alteram o ambiente.
# - Acoes administrativas exigem root, ticket, contexto, autorizacao e SIM.
# - O retorno zero de um comando nao substitui a validacao do estado real.
# - Nenhuma exclusao automatica e feita em /hana/log, /backup ou /home.
# - Em backup/log, somente arquivos log_backup_* homologados podem ser
#   removidos, sempre com ticket, contexto, confirmacao SIM e relatorio.
# ============================================================================

set -u
set -o pipefail

readonly OSC_NAME="SAP SUPPORT CONSOLE"
readonly OSC_VERSION="1.3"
readonly OSC_AUTHOR="Eduardo Esteves"
readonly HANA_USER="${OSC_SAP_HANA_USER:-ndbadm}"
readonly HANA_SID="${OSC_SAP_HANA_SID:-NDB}"
readonly HANA_INSTANCE="${OSC_SAP_HANA_INSTANCE:-00}"
readonly HANA_LOG_RETENTION_HOURS="${OSC_SAP_HANA_LOG_RETENTION_HOURS:-24}"
readonly POLL_INTERVAL="${OSC_SAP_POLL_INTERVAL:-5}"
readonly POLL_ATTEMPTS="${OSC_SAP_POLL_ATTEMPTS:-12}"

case "$HANA_INSTANCE" in
    ''|*[!0-9]*) printf 'ERRO: OSC_SAP_HANA_INSTANCE deve conter somente numeros.\n' >&2; exit 2;;
esac
case "$HANA_SID" in
    ''|*[!A-Za-z0-9_]*) printf 'ERRO: OSC_SAP_HANA_SID contem caracteres invalidos.\n' >&2; exit 2;;
esac
case "$HANA_LOG_RETENTION_HOURS" in
    ''|*[!0-9]*) printf 'ERRO: OSC_SAP_HANA_LOG_RETENTION_HOURS deve ser numerico.\n' >&2; exit 2;;
esac
if (( HANA_LOG_RETENTION_HOURS < 24 )); then
    printf 'ERRO: a retencao dos logs HANA nao pode ser menor que 24 horas.\n' >&2
    exit 2
fi
readonly HANA_LOG_RETENTION_MINUTES=$((HANA_LOG_RETENTION_HOURS * 60))

if [[ -n "${OSC_SAP_LOG_FILE:-}" ]]; then
    LOG_FILE="$OSC_SAP_LOG_FILE"
elif [[ -w /var/log ]]; then
    LOG_FILE="/var/log/sap-support-console.log"
else
    LOG_FILE="/tmp/sap-support-console-${USER:-unknown}.log"
fi

if [[ -n "${OSC_SAP_REPORT_DIR:-}" ]]; then
    REPORT_DIR="$OSC_SAP_REPORT_DIR"
elif [[ -w /var/log ]]; then
    REPORT_DIR="/var/log/sap-support-console-reports"
else
    REPORT_DIR="/tmp/sap-support-console-reports-${USER:-unknown}"
fi

readonly SLD_UNIT="sapb1servertools.service"
readonly SLD_LEGACY="/etc/init.d/sapb1servertools"
readonly AUTH_SERVICE="sapb1servertools-authentication"
readonly EDS_UNIT="sapb1edfbacked.service"
readonly SL_MODERN="/usr/sap/SAPBusinessOne/ServiceLayer/b1s"
readonly SL_LEGACY="/etc/init.d/b1s"
readonly WEBCLIENT_DIR="/usr/sap/SAPBusiness/WebClient"
readonly WEBCLIENT_SCRIPT="$WEBCLIENT_DIR/startup.sh"
readonly CATALINA_LOG="/usr/sap/SAPBusinessOne/Common/tomcat/logs/catalina.out"
readonly HANA_SHARED_LOG="/hana/shared/${HANA_SID}/HDB${HANA_INSTANCE}/backup/log"
readonly HANA_WYSTORAGE_ROOT="/hana/wystorage/log"

OSC_NO_COLOR=0
for cli_arg in "$@"; do
    [[ "$cli_arg" == "--no-color" ]] && OSC_NO_COLOR=1
done
if [[ ! -t 1 || -n "${NO_COLOR:-}" || "${TERM:-dumb}" == "dumb" || \
      "${OSC_SAP_NO_COLOR:-0}" == "1" ]]; then
    OSC_NO_COLOR=1
fi

if (( OSC_NO_COLOR )); then
    CLR_RESET=''
    CLR_RED=''
    CLR_YELLOW=''
    CLR_GREEN=''
    CLR_BLUE=''
    CLR_CYAN=''
    CLR_PURPLE=''
    CLR_GRAY=''
    CLR_BOLD=''
else
    CLR_RESET='\033[0m'
    CLR_RED='\033[1;31m'
    CLR_YELLOW='\033[1;33m'
    CLR_GREEN='\033[1;32m'
    CLR_BLUE='\033[1;34m'
    CLR_CYAN='\033[1;36m'
    CLR_PURPLE='\033[1;35m'
    CLR_GRAY='\033[0;37m'
    CLR_BOLD='\033[1m'
fi

UI_WIDTH="$(tput cols 2>/dev/null || printf '64')"
case "$UI_WIDTH" in ''|*[!0-9]*) UI_WIDTH=64;; esac
(( UI_WIDTH < 54 )) && UI_WIDTH=54
(( UI_WIDTH > 72 )) && UI_WIDTH=72
readonly UI_WIDTH

declare -a HANA_LOG_DIRS=()
declare -a HANA_REPORT_FILES=()

status_ok()       { printf "%bOK%b       %s\n" "$CLR_GREEN" "$CLR_RESET" "$*"; }
status_high()     { printf "%bHIGH%b     %s\n" "$CLR_YELLOW" "$CLR_RESET" "$*"; }
status_critical() { printf "%bCRITICO%b  %s\n" "$CLR_RED" "$CLR_RESET" "$*"; }
status_info()     { printf "%bINFO%b     %s\n" "$CLR_BLUE" "$CLR_RESET" "$*"; }

separator() { printf '%*s\n' "$UI_WIDTH" '' | tr ' ' '='; }
thin_separator() { printf '%*s\n' "$UI_WIDTH" '' | tr ' ' '-'; }

section_title() {
    local title="$*" fill
    fill=$((UI_WIDTH - ${#title} - 2))
    (( fill < 3 )) && fill=3
    printf '\n%b%s%b ' "$CLR_PURPLE" "$title" "$CLR_RESET"
    printf '%*s\n' "$fill" '' | tr ' ' '-'
}

screen_title() {
    printf '%b%s%b\n' "$CLR_BOLD" "$*" "$CLR_RESET"
    thin_separator
}

menu_item() {
    local number="$1"
    shift
    printf '%b%s)%b %s\n' "$CLR_BLUE" "$number" "$CLR_RESET" "$*"
}

menu_back() {
    printf '%b0)%b Voltar\n' "$CLR_GRAY" "$CLR_RESET"
}
pause_screen() {
    printf '\nPressione ENTER para continuar...'
    read -r _ || true
}

safe_field() {
    local value="${1:-}"
    value="${value//$'\n'/ }"
    value="${value//|/\/}"
    printf '%s' "$value"
}

write_log() {
    local ticket="$1" service="$2" action="$3" before="$4"
    local after="$5" command="$6" result="$7"
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S%z')|$(hostname -f 2>/dev/null || hostname)|$(id -un)|$(safe_field "$ticket")|$(safe_field "$service")|$(safe_field "$action")|$(safe_field "$before")|$(safe_field "$after")|$(safe_field "$command")|$(safe_field "$result")"
    if ! printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null; then
        printf '%bAVISO:%b nao foi possivel gravar em %s.\n' "$CLR_YELLOW" "$CLR_RESET" "$LOG_FILE" >&2
    fi
}

require_root() {
    if (( EUID != 0 )); then
        status_critical "Esta acao exige execucao como root."
        return 1
    fi
}

confirm_admin_action() {
    local service="$1" action="$2" command="$3" downtime="${4:-yes}"
    local ticket context authorized confirm

    require_root || return 1
    separator
    screen_title "CONFIRMACAO DE ACAO ADMINISTRATIVA"
    printf 'Servico : %s\nAcao    : %s\nComando : %s\n' "$service" "$action" "$command"
    if [[ "$downtime" == "yes" ]]; then
        printf '\n%bATENCAO:%b Esta operacao pode causar indisponibilidade.\n' "$CLR_RED" "$CLR_RESET"
        printf 'A autorizacao do cliente deve estar registrada no ticket informado.\n'
    fi
    read -r -p 'Numero do ticket: ' ticket
    [[ -n "$ticket" ]] || { status_critical "Ticket obrigatorio."; return 1; }
    read -r -p 'Contexto/motivo da acao: ' context
    [[ -n "$context" ]] || { status_critical "Contexto obrigatorio."; return 1; }
    if [[ "$downtime" == "yes" ]]; then
        read -r -p 'A autorizacao do cliente esta registrada no ticket? (SIM/NAO): ' authorized
        [[ "$authorized" == "SIM" ]] || { status_high "Acao cancelada: autorizacao nao confirmada."; return 1; }
    fi
    read -r -p 'Digite SIM para executar: ' confirm
    [[ "$confirm" == "SIM" ]] || { status_high "Acao cancelada."; return 1; }
    ADMIN_TICKET="$ticket"
    ADMIN_CONTEXT="$context"
    return 0
}

unit_exists() {
    systemctl list-unit-files "$1" --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "$1"
}

unit_state() {
    systemctl is-active "$1" 2>/dev/null || true
}

show_unit_status() {
    local unit="$1" label="$2" state
    if ! command -v systemctl >/dev/null 2>&1; then
        status_high "$label: systemctl indisponivel."
    elif ! unit_exists "$unit"; then
        status_info "$label: componente nao instalado neste servidor."
    else
        state="$(unit_state "$unit")"
        case "$state" in
            active) status_ok "$label: active" ;;
            activating|deactivating) status_high "$label: $state" ;;
            *) status_critical "$label: ${state:-desconhecido}" ;;
        esac
    fi
}

show_sld_status() {
    if command -v systemctl >/dev/null 2>&1 && unit_exists "$SLD_UNIT"; then
        show_unit_status "$SLD_UNIT" "SLD / Server Tools"
    elif [[ -x "$SLD_LEGACY" ]]; then
        status_high "SLD: instalacao legada detectada em $SLD_LEGACY; a KB nao definiu um status homologado."
    else
        status_critical "SLD: nem $SLD_UNIT nem $SLD_LEGACY foram encontrados."
    fi
}

poll_unit() {
    local unit="$1" expected="$2" attempt state
    for ((attempt=1; attempt<=POLL_ATTEMPTS; attempt++)); do
        state="$(unit_state "$unit")"
        [[ "$state" == "$expected" ]] && { printf '%s' "$state"; return 0; }
        sleep "$POLL_INTERVAL"
    done
    printf '%s' "${state:-desconhecido}"
    return 1
}

admin_systemd_action() {
    local unit="$1" label="$2" action="$3" expected before after rc result
    expected="active"
    [[ "$action" == "stop" ]] && expected="inactive"
    before="$(unit_state "$unit")"
    if ! unit_exists "$unit"; then
        status_critical "Unidade exata nao encontrada: $unit"
        write_log "-" "$label" "$action" "$before" "nao encontrado" "systemctl $action $unit" "BLOQUEADO"
        return 1
    fi
    confirm_admin_action "$label" "$action" "systemctl $action $unit" yes || return 1
    systemctl "$action" "$unit"
    rc=$?
    if (( rc != 0 )); then
        after="$(unit_state "$unit")"
        result="FAILED rc=$rc contexto=$ADMIN_CONTEXT"
        write_log "$ADMIN_TICKET" "$label" "$action" "$before" "$after" "systemctl $action $unit" "$result"
        status_critical "$label: comando falhou (rc=$rc)."
        return "$rc"
    fi
    if after="$(poll_unit "$unit" "$expected")"; then
        result="SUCCESS contexto=$ADMIN_CONTEXT"
        status_ok "$label: estado validado como $after."
    else
        result="FAILED_VALIDATION contexto=$ADMIN_CONTEXT"
        status_critical "$label: estado final $after; esperado $expected."
    fi
    write_log "$ADMIN_TICKET" "$label" "$action" "$before" "$after" "systemctl $action $unit" "$result"
    [[ "$after" == "$expected" ]]
}

sld_action() {
    local action="$1" before after rc result command_text
    if command -v systemctl >/dev/null 2>&1 && unit_exists "$SLD_UNIT"; then
        admin_systemd_action "$SLD_UNIT" "SLD / Server Tools" "$action"
        return $?
    fi
    if [[ ! -x "$SLD_LEGACY" ]]; then
        status_critical "Nenhum mecanismo SLD homologado foi encontrado."
        return 1
    fi
    if [[ "$action" != "restart" ]]; then
        status_high "Na KB legada SUSE 11 somente o restart foi homologado: $SLD_LEGACY restart"
        return 1
    fi
    command_text="$SLD_LEGACY restart"
    before="status legado nao homologado pela KB"
    confirm_admin_action "SLD / Server Tools (SUSE 11)" "$action" "$command_text" yes || return 1
    "$SLD_LEGACY" restart; rc=$?
    if (( rc == 0 )); then
        after="restart rc=0; validacao funcional Control Center pendente"
        result="COMMAND_OK_MANUAL_VALIDATION contexto=$ADMIN_CONTEXT"
        status_high "Restart legado concluido. Validar https://SERVIDOR:40000/ControlCenter."
    else
        after="restart falhou rc=$rc"
        result="FAILED rc=$rc contexto=$ADMIN_CONTEXT"
        status_critical "Restart legado do SLD falhou."
    fi
    write_log "$ADMIN_TICKET" "SLD / Server Tools (SUSE 11)" "$action" "$before" "$after" "$command_text" "$result"
    (( rc == 0 ))
}

check_uptime() {
    local seconds days
    seconds="$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || printf 0)"
    days=$(( seconds / 86400 ))
    if (( days > 100 )); then
        status_high "Uptime: ${days} dias. Avaliar reboot com alinhamento e janela."
    else
        status_ok "Uptime: ${days} dias."
    fi
}

check_disks() {
    local filesystem size used avail pct mount numeric found=0
    while read -r filesystem size used avail pct mount; do
        case "$pct" in *%) ;; *) continue ;; esac
        numeric="${pct%%%}"
        (( found=1 ))
        if (( numeric >= 95 )); then
            status_critical "Disco $mount: $pct utilizado ($avail livre)."
        elif (( numeric >= 90 )); then
            status_high "Disco $mount: $pct utilizado ($avail livre)."
        fi
    done < <(df -P -h -x tmpfs -x devtmpfs 2>/dev/null | tail -n +2)
    (( found == 1 )) || status_high "Nao foi possivel consultar os filesystems."
    if ! df -P -x tmpfs -x devtmpfs 2>/dev/null | awk 'NR>1 {gsub(/%/,"",$5); if ($5>=90) exit 1}'; then
        return 1
    fi
    status_ok "Filesystems abaixo de 90% de utilizacao."
}

check_swap() {
    local total used
    read -r total used < <(free -m 2>/dev/null | awk '/Swap:/ {print $2, $3}')
    if [[ -z "${total:-}" ]]; then
        status_high "Swap: consulta indisponivel."
    elif (( total == 0 )); then
        status_info "Swap: nao configurada. Nenhum tamanho padrao SAP foi definido nas KBs."
    else
        status_info "Swap: ${used} MiB utilizados de ${total} MiB. Sem limite homologado para alerta."
    fi
}

hana_info_raw() {
    su - "$HANA_USER" -c 'HDB info' 2>&1
}

sapcontrol_raw() {
    su - "$HANA_USER" -c "sapcontrol -nr '$HANA_INSTANCE' -function GetProcessList" 2>&1
}

poll_hana_sapcontrol() {
    local attempt output
    for ((attempt=1; attempt<=POLL_ATTEMPTS; attempt++)); do
        output="$(sapcontrol_raw)" || true
        if grep -q 'GREEN' <<<"$output" && ! grep -Eq 'YELLOW|RED' <<<"$output"; then
            printf '%s' "$output"
            return 0
        fi
        if grep -q 'RED' <<<"$output"; then
            printf '%s' "$output"
            return 2
        fi
        sleep "$POLL_INTERVAL"
    done
    printf '%s' "$output"
    return 1
}

check_hana() {
    local output rc daemon=0 nameserver=0 indexserver=0
    if ! getent passwd "$HANA_USER" >/dev/null 2>&1; then
        status_critical "HANA: usuario $HANA_USER nao encontrado."
        return 1
    fi
    output="$(hana_info_raw)"; rc=$?
    grep -qi 'hdbdaemon' <<<"$output" && daemon=1
    grep -qi 'hdbnameserver' <<<"$output" && nameserver=1
    grep -qi 'hdbindexserver' <<<"$output" && indexserver=1
    if grep -qi 'command not found' <<<"$output"; then
        status_critical "HANA: HDB nao encontrado no perfil de $HANA_USER; nao concluir DOWN sem corrigir usuario/perfil."
        return 1
    elif (( daemon && nameserver && indexserver )); then
        status_ok "HANA: hdbdaemon, hdbnameserver e hdbindexserver presentes."
    elif (( daemon || nameserver || indexserver )); then
        status_high "HANA: somente parte dos processos principais foi encontrada."
        return 1
    else
        status_critical "HANA: processos principais nao encontrados; banco possivelmente DOWN."
        return 1
    fi
}

show_hana_details() {
    separator
    screen_title "PROCESSOS E ESTADO DO HANA"
    section_title "PROCESSOS HANA (EVIDENCIA COMPLEMENTAR)"
    ps -ef 2>/dev/null | grep -i '[h]db' || true
    section_title "HDB INFO COMO $HANA_USER"
    hana_info_raw || true
    section_title "SAPCONTROL - INSTANCIA $HANA_INSTANCE"
    sapcontrol_raw || status_critical "Falha ao executar sapcontrol pelo perfil de $HANA_USER."
}

check_cron_automation() {
    local cron active
    separator
    screen_title "AUTOMACOES SAP NO CRONTAB DO ROOT"
    cron="$(crontab -l 2>&1)" || true
    printf '%s\n' "$cron" | grep -Ei 'servicesSAP\.sh|Restart Automatico.*(SLD|SL|HANA)' || status_info "Nenhuma linha SAP correspondente encontrada."
    active="$(printf '%s\n' "$cron" | awk '!/[[:space:]]*#/ && /servicesSAP\.sh|Restart Automatico.*(SLD|SL|HANA)/')"
    if [[ -n "$active" ]]; then
        status_high "Automacao SAP ativa detectada. Nao editar automaticamente; alinhar antes de reinicios manuais."
    else
        status_ok "Nenhuma automacao SAP ativa detectada pelo padrao da KB."
    fi
}

select_service_layer_script() {
    local modern=0 legacy=0 choice
    [[ -x "$SL_MODERN" ]] && modern=1
    [[ -x "$SL_LEGACY" ]] && legacy=1
    if (( modern && legacy )); then
        status_high "Foram encontrados dois scripts b1s; escolha explicitamente."
        printf '1) %s\n2) %s\n' "$SL_MODERN" "$SL_LEGACY"
        read -r -p 'Opcao: ' choice
        case "$choice" in 1) printf '%s' "$SL_MODERN";; 2) printf '%s' "$SL_LEGACY";; *) return 1;; esac
    elif (( modern )); then
        printf '%s' "$SL_MODERN"
    elif (( legacy )); then
        printf '%s' "$SL_LEGACY"
    else
        status_critical "Nenhum script Service Layer homologado foi encontrado."
        return 1
    fi
}

service_layer_action() {
    local action="$1" script before after rc output result command_text
    script="$(select_service_layer_script)" || return 1
    command_text="cd $(dirname "$script") && ./$(basename "$script") $action"
    before="nao disponibilizado pela KB"
    confirm_admin_action "Service Layer" "$action" "$command_text" yes || return 1
    output="$(cd "$(dirname "$script")" && "./$(basename "$script")" "$action" 2>&1)"; rc=$?
    printf '%s\n' "$output"
    if (( rc == 0 )) && grep -Eqi 'Restarted|Started|Stopped' <<<"$output"; then
        after="comando concluiu; validacao funcional externa pendente"
        result="COMMAND_OK_MANUAL_VALIDATION contexto=$ADMIN_CONTEXT"
        status_high "Comando concluido. Validar URL, nos, portas e integracao do cliente."
    else
        after="falha ou resposta nao reconhecida"
        result="FAILED rc=$rc contexto=$ADMIN_CONTEXT"
        status_critical "Service Layer nao apresentou confirmacao esperada."
    fi
    write_log "$ADMIN_TICKET" "Service Layer" "$action" "$before" "$after" "$command_text" "$result"
    (( rc == 0 ))
}

webclient_restart() {
    local before after rc_stop rc_start result command_text
    if [[ ! -x "$WEBCLIENT_SCRIPT" ]]; then
        status_critical "Script nao encontrado ou sem execucao: $WEBCLIENT_SCRIPT"
        return 1
    fi
    command_text="cd $WEBCLIENT_DIR && ./startup.sh stop webclient && ./startup.sh start webclient"
    confirm_admin_action "SAP WebClient" "restart" "$command_text" yes || return 1
    before="nao disponibilizado pela KB"
    (cd "$WEBCLIENT_DIR" && ./startup.sh stop webclient); rc_stop=$?
    if (( rc_stop != 0 )); then
        result="FAILED_STOP rc=$rc_stop contexto=$ADMIN_CONTEXT"
        write_log "$ADMIN_TICKET" "SAP WebClient" "restart" "$before" "stop falhou" "$command_text" "$result"
        status_critical "Stop do WebClient falhou; start nao executado."
        return "$rc_stop"
    fi
    (cd "$WEBCLIENT_DIR" && ./startup.sh start webclient); rc_start=$?
    if (( rc_start == 0 )); then
        after="start retornou rc=0; validacao funcional manual pendente"
        result="COMMAND_OK_MANUAL_VALIDATION contexto=$ADMIN_CONTEXT"
        status_high "WebClient iniciado. Validar acesso funcional do cliente."
    else
        after="start falhou rc=$rc_start"
        result="FAILED_START rc=$rc_start contexto=$ADMIN_CONTEXT"
        status_critical "Start do WebClient falhou."
    fi
    write_log "$ADMIN_TICKET" "SAP WebClient" "restart" "$before" "$after" "$command_text" "$result"
    (( rc_start == 0 ))
}

auth_restart() {
    local before after rc result
    command -v service >/dev/null 2>&1 || { status_critical "Comando service indisponivel."; return 1; }
    before="status nao homologado pela KB"
    confirm_admin_action "SAP Authenticator" "restart" "service $AUTH_SERVICE restart" yes || return 1
    service "$AUTH_SERVICE" restart; rc=$?
    if (( rc == 0 )); then
        after="restart rc=0; validar https://SERVIDOR:40020/auth"
        result="COMMAND_OK_MANUAL_VALIDATION contexto=$ADMIN_CONTEXT"
        status_high "Restart concluido; validar endpoint /auth."
    else
        after="restart falhou rc=$rc"; result="FAILED rc=$rc contexto=$ADMIN_CONTEXT"
        status_critical "Restart do Authenticator falhou."
    fi
    write_log "$ADMIN_TICKET" "SAP Authenticator" "restart" "$before" "$after" "service $AUTH_SERVICE restart" "$result"
    (( rc == 0 ))
}

hana_restart() {
    local before after rc output sap_output sap_rc result command_text
    command_text="systemctl stop $SLD_UNIT; su - $HANA_USER; HDB stop; HDB start; sapcontrol -nr $HANA_INSTANCE -function GetProcessList; systemctl start $SLD_UNIT"
    [[ -x "$(command -v systemctl 2>/dev/null || true)" ]] || { status_critical "systemctl indisponivel."; return 1; }
    unit_exists "$SLD_UNIT" || { status_critical "Unidade $SLD_UNIT nao encontrada."; return 1; }
    getent passwd "$HANA_USER" >/dev/null || { status_critical "Usuario $HANA_USER nao encontrado."; return 1; }
    before="SLD=$(unit_state "$SLD_UNIT"); HANA=$(check_hana >/dev/null 2>&1 && echo UP || echo INDEFINIDO/DOWN)"
    confirm_admin_action "SAP HANA + SLD" "restart controlado" "$command_text" yes || return 1

    systemctl stop "$SLD_UNIT" || {
        write_log "$ADMIN_TICKET" "SAP HANA + SLD" "restart" "$before" "falha stop SLD" "$command_text" "ABORTED contexto=$ADMIN_CONTEXT"
        status_critical "Falha ao parar SLD; sequencia abortada."
        return 1
    }
    poll_unit "$SLD_UNIT" inactive >/dev/null || {
        write_log "$ADMIN_TICKET" "SAP HANA + SLD" "restart" "$before" "SLD nao parou" "$command_text" "ABORTED_VALIDATION contexto=$ADMIN_CONTEXT"
        status_critical "SLD nao atingiu inactive; sequencia abortada."
        return 1
    }
    su - "$HANA_USER" -c 'HDB stop' || {
        write_log "$ADMIN_TICKET" "SAP HANA + SLD" "restart" "$before" "falha HDB stop" "$command_text" "ABORTED contexto=$ADMIN_CONTEXT"
        status_critical "HDB stop falhou; HDB start nao sera executado cegamente."
        return 1
    }
    su - "$HANA_USER" -c 'HDB start' || {
        write_log "$ADMIN_TICKET" "SAP HANA + SLD" "restart" "$before" "falha HDB start" "$command_text" "FAILED contexto=$ADMIN_CONTEXT"
        status_critical "HDB start falhou; SLD nao sera marcado como saudavel. Escalar."
        return 1
    }
    sleep "$POLL_INTERVAL"
    output="$(hana_info_raw)"; rc=$?
    if (( rc != 0 )) || ! grep -qi 'hdbnameserver' <<<"$output" || ! grep -qi 'hdbindexserver' <<<"$output"; then
        printf '%s\n' "$output"
        write_log "$ADMIN_TICKET" "SAP HANA + SLD" "restart" "$before" "HANA sem processos principais" "$command_text" "FAILED_VALIDATION contexto=$ADMIN_CONTEXT"
        status_critical "HANA nao validado; nao iniciar SLD como se o ambiente estivesse saudavel."
        return 1
    fi
    sap_output="$(poll_hana_sapcontrol)"; sap_rc=$?
    printf '%s\n' "$sap_output"
    case "$sap_rc" in
        0) status_ok "SAPControl: processos da instancia $HANA_INSTANCE em GREEN.";;
        2)
            write_log "$ADMIN_TICKET" "SAP HANA + SLD" "restart" "$before" "SAPControl RED" "$command_text" "FAILED_VALIDATION contexto=$ADMIN_CONTEXT"
            status_critical "SAPControl retornou RED; nao iniciar SLD como se o HANA estivesse saudavel."
            return 1
            ;;
        *)
            write_log "$ADMIN_TICKET" "SAP HANA + SLD" "restart" "$before" "SAPControl nao atingiu GREEN" "$command_text" "FAILED_VALIDATION contexto=$ADMIN_CONTEXT"
            status_critical "SAPControl nao atingiu GREEN no limite de polling."
            return 1
            ;;
    esac
    systemctl start "$SLD_UNIT"; rc=$?
    after="SLD=$(unit_state "$SLD_UNIT"); HANA=UP"
    if (( rc == 0 )) && [[ "$(poll_unit "$SLD_UNIT" active)" == "active" ]]; then
        result="SUCCESS contexto=$ADMIN_CONTEXT"
        status_ok "HANA e SLD validados. Validacao final no SAP/cliente ainda necessaria."
    else
        result="FAILED_SLD_START contexto=$ADMIN_CONTEXT"
        status_critical "HANA iniciou, mas o SLD nao ficou active."
    fi
    write_log "$ADMIN_TICKET" "SAP HANA + SLD" "restart" "$before" "$after" "$command_text" "$result"
    [[ "$result" == SUCCESS* ]]
}

disk_offenders() {
    separator
    printf '%bFILESYSTEMS%b\n' "$CLR_BOLD" "$CLR_RESET"
    df -h -x tmpfs -x devtmpfs 2>/dev/null || true
    printf '\n%bMAIORES DIRETORIOS EM /usr/sap%b\n' "$CLR_BOLD" "$CLR_RESET"
    if [[ -d /usr/sap ]]; then
        du -sch /usr/sap/* --one-file-system 2>/dev/null | sort -rh | head -n 15
    else
        status_info "/usr/sap nao existe neste servidor."
    fi
    printf '\n%bESCALONAMENTO OBRIGATORIO%b\n' "$CLR_BOLD" "$CLR_RESET"
    status_critical "/backup, /hana/log e /home: encaminhar para a fila ERP SAP."
}

truncate_catalina() {
    local before after command_text result
    [[ -f "$CATALINA_LOG" ]] || { status_critical "Arquivo nao encontrado: $CATALINA_LOG"; return 1; }
    before="$(stat -c '%s bytes' "$CATALINA_LOG" 2>/dev/null || echo desconhecido)"
    command_text="cat /dev/null > $CATALINA_LOG"
    confirm_admin_action "Tomcat catalina.out" "zerar log" "$command_text" no || return 1
    if : > "$CATALINA_LOG"; then
        after="$(stat -c '%s bytes' "$CATALINA_LOG" 2>/dev/null || echo desconhecido)"
        if [[ "$after" == "0 bytes" ]]; then
            result="SUCCESS contexto=$ADMIN_CONTEXT"; status_ok "catalina.out preservado e zerado."
        else
            result="FAILED_VALIDATION contexto=$ADMIN_CONTEXT"; status_critical "Tamanho final inesperado: $after"
        fi
    else
        after="inalterado"; result="FAILED contexto=$ADMIN_CONTEXT"; status_critical "Falha ao zerar catalina.out."
    fi
    write_log "$ADMIN_TICKET" "Tomcat catalina.out" "truncate" "$before" "$after" "$command_text" "$result"
    [[ "$result" == SUCCESS* ]]
}

is_allowed_hana_log_dir() {
    local path="$1" base relative
    for base in "$HANA_SHARED_LOG" "$HANA_WYSTORAGE_ROOT"; do
        [[ "$path" == "$base" ]] && return 0
        if [[ "$path" == "$base/"* ]]; then
            relative="${path#"$base/"}"
            [[ -n "$relative" && "$relative" != */* ]] && return 0
        fi
    done
    return 1
}

canonical_hana_log_dir() {
    local dir="$1" real
    [[ -d "$dir" ]] || return 1
    [[ ! -L "$dir" ]] || return 1
    real="$(readlink -f -- "$dir" 2>/dev/null)" || return 1
    is_allowed_hana_log_dir "$real" || return 1
    printf '%s' "$real"
}

hana_log_count() {
    local dir="$1" scope="${2:-all}" age
    case "$scope" in
        eligible)
            age="+$HANA_LOG_RETENTION_MINUTES"
            find "$dir" -xdev -maxdepth 1 -type f \
                \( -name 'log_backup_*' -o -name '.log_backup_*' \) \
                -mmin "$age" -printf '.' 2>/dev/null | wc -c
            ;;
        all)
            find "$dir" -xdev -maxdepth 1 -type f \
                \( -name 'log_backup_*' -o -name '.log_backup_*' \) \
                -printf '.' 2>/dev/null | wc -c
            ;;
        *) return 2;;
    esac
}

hana_log_bytes() {
    local dir="$1" scope="${2:-eligible}" age
    case "$scope" in
        eligible)
            age="+$HANA_LOG_RETENTION_MINUTES"
            find "$dir" -xdev -maxdepth 1 -type f \
                \( -name 'log_backup_*' -o -name '.log_backup_*' \) \
                -mmin "$age" -printf '%s\n' 2>/dev/null
            ;;
        all)
            find "$dir" -xdev -maxdepth 1 -type f \
                \( -name 'log_backup_*' -o -name '.log_backup_*' \) \
                -printf '%s\n' 2>/dev/null
            ;;
        *) return 2;;
    esac | awk '{total += $1} END {printf "%.0f", total + 0}'
}

human_bytes() {
    awk -v bytes="${1:-0}" 'BEGIN {
        split("B KiB MiB GiB TiB", unit, " "); idx=1;
        while (bytes >= 1024 && idx < 5) {bytes /= 1024; idx++}
        printf "%.2f %s", bytes, unit[idx]
    }'
}

filesystem_snapshot() {
    local dir="$1"
    df -P -h -- "$dir" 2>/dev/null | awk 'NR==2 {
        printf "filesystem=%s tamanho=%s usado=%s livre=%s uso=%s montagem=%s", $1, $2, $3, $4, $5, $6
    }'
}

add_hana_log_dir() {
    local dir="$1" real total
    real="$(canonical_hana_log_dir "$dir")" || return 0
    total="$(hana_log_count "$real" all)"
    (( total > 0 )) || return 0
    HANA_LOG_DIRS+=("$real")
}

collect_hana_log_dirs() {
    local base child
    HANA_LOG_DIRS=()
    for base in "$HANA_SHARED_LOG" "$HANA_WYSTORAGE_ROOT"; do
        [[ -d "$base" && ! -L "$base" ]] || continue
        add_hana_log_dir "$base"
        while IFS= read -r -d '' child; do
            add_hana_log_dir "$child"
        done < <(find "$base" -xdev -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    done
}

show_hana_log_dir_summary() {
    local number="$1" dir="$2" total eligible protected bytes
    total="$(hana_log_count "$dir" all)"
    eligible="$(hana_log_count "$dir" eligible)"
    protected=$((total - eligible))
    bytes="$(hana_log_bytes "$dir" eligible)"
    printf '\n[%s] %s\n' "$number" "$dir"
    printf '    Total encontrado       : %s arquivos\n' "$total"
    printf '    Elegiveis (+%sh)       : %s arquivos\n' "$HANA_LOG_RETENTION_HOURS" "$eligible"
    printf '    Preservados (ultimas %sh): %s arquivos\n' "$HANA_LOG_RETENTION_HOURS" "$protected"
    printf '    Espaco recuperavel     : %s\n' "$(human_bytes "$bytes")"
}

preview_hana_backup_logs() {
    local index
    separator
    screen_title "ANALISE DE LOGS DE BACKUP HANA - SOMENTE LEITURA"
    printf 'SID: %s | Instancia: %s | Retencao minima: %s horas\n' \
        "$HANA_SID" "$HANA_INSTANCE" "$HANA_LOG_RETENTION_HOURS"
    collect_hana_log_dirs
    if (( ${#HANA_LOG_DIRS[@]} == 0 )); then
        status_info "Nenhum arquivo log_backup_* ou .log_backup_* encontrado nos caminhos autorizados."
        printf 'Caminhos verificados:\n- %s\n- %s\n' "$HANA_SHARED_LOG" "$HANA_WYSTORAGE_ROOT"
        return 0
    fi
    for index in "${!HANA_LOG_DIRS[@]}"; do
        show_hana_log_dir_summary "$((index + 1))" "${HANA_LOG_DIRS[$index]}"
    done
    printf '\n'
    status_info "Esta consulta nao removeu nenhum arquivo."
}

show_hana_log_samples() {
    local dir="$1" age
    age="+$HANA_LOG_RETENTION_MINUTES"
    section_title "AMOSTRA DOS PRIMEIROS CANDIDATOS (MAXIMO 15)"
    find "$dir" -xdev -maxdepth 1 -type f \
        \( -name 'log_backup_*' -o -name '.log_backup_*' \) \
        -mmin "$age" -printf '%TY-%Tm-%Td %TH:%TM | %10s bytes | %p\n' 2>/dev/null \
        | sort | head -n 15 || true
}

delete_eligible_hana_logs() {
    local dir="$1" age
    age="+$HANA_LOG_RETENTION_MINUTES"
    find "$dir" -xdev -maxdepth 1 -type f \
        \( -name 'log_backup_*' -o -name '.log_backup_*' \) \
        -mmin "$age" -delete
}

safe_filename() {
    local value
    value="$(printf '%s' "${1:-sem-ticket}" | tr -cd '[:alnum:]_.-')"
    printf '%s' "${value:-sem-ticket}"
}

render_hana_cleanup_report() {
    separator
    printf 'RELATORIO DE LIMPEZA DE LOGS DE BACKUP HANA\n'
    separator
    printf 'Console          : %s V%s\n' "$OSC_NAME" "$OSC_VERSION"
    printf 'Data             : %s\n' "$REPORT_DATE"
    printf 'Servidor         : %s\n' "$REPORT_HOST"
    printf 'Usuario          : %s\n' "$REPORT_USER"
    printf 'Ticket           : %s\n' "$ADMIN_TICKET"
    printf 'Contexto         : %s\n' "$(safe_field "$ADMIN_CONTEXT")"
    printf 'SID / Instancia  : %s / %s\n' "$HANA_SID" "$HANA_INSTANCE"
    printf 'Diretorio        : %s\n' "$REPORT_TARGET"
    printf 'Retencao         : %s horas (arquivos recentes preservados)\n' "$HANA_LOG_RETENTION_HOURS"
    printf 'Padroes          : log_backup_* e .log_backup_*\n'
    printf '\nANTES\n'
    printf 'Filesystem       : %s\n' "$REPORT_FS_BEFORE"
    printf 'Total            : %s arquivos\n' "$REPORT_TOTAL_BEFORE"
    printf 'Elegiveis        : %s arquivos\n' "$REPORT_ELIGIBLE_BEFORE"
    printf 'Preservados      : %s arquivos\n' "$REPORT_PROTECTED_BEFORE"
    printf 'Espaco previsto  : %s\n' "$(human_bytes "$REPORT_BYTES_BEFORE")"
    printf '\nDEPOIS\n'
    printf 'Filesystem       : %s\n' "$REPORT_FS_AFTER"
    printf 'Total            : %s arquivos\n' "$REPORT_TOTAL_AFTER"
    printf 'Elegiveis        : %s arquivos\n' "$REPORT_ELIGIBLE_AFTER"
    printf 'Preservados      : %s arquivos\n' "$REPORT_PROTECTED_AFTER"
    printf 'Arquivos removidos: %s\n' "$REPORT_REMOVED"
    printf 'Espaco selecionado removido: %s\n' "$(human_bytes "$REPORT_BYTES_REMOVED")"
    printf 'Resultado        : %s\n' "$REPORT_RESULT"
    separator
}

cleanup_hana_backup_logs() {
    local index choice selected real command_text rc result report_file ticket_file
    local before_total before_eligible before_protected before_bytes before_fs
    local after_total after_eligible after_protected after_bytes after_fs removed bytes_removed

    require_root || return 1
    preview_hana_backup_logs
    (( ${#HANA_LOG_DIRS[@]} > 0 )) || return 0
    printf '\nEscolha somente um diretorio para a limpeza controlada.\n'
    read -r -p 'Numero do diretorio (0 cancela): ' choice
    [[ "$choice" == "0" ]] && { status_info "Limpeza cancelada."; return 0; }
    case "$choice" in ''|*[!0-9]*) status_high "Opcao invalida."; return 1;; esac
    (( choice >= 1 && choice <= ${#HANA_LOG_DIRS[@]} )) || { status_high "Opcao invalida."; return 1; }

    selected="${HANA_LOG_DIRS[$((choice - 1))]}"
    real="$(canonical_hana_log_dir "$selected")" || {
        status_critical "Diretorio recusado pela lista de caminhos autorizados: $selected"
        return 1
    }
    before_total="$(hana_log_count "$real" all)"
    before_eligible="$(hana_log_count "$real" eligible)"
    before_protected=$((before_total - before_eligible))
    before_bytes="$(hana_log_bytes "$real" eligible)"
    before_fs="$(filesystem_snapshot "$real")"
    if (( before_eligible == 0 )); then
        status_info "Nenhum arquivo com mais de $HANA_LOG_RETENTION_HOURS horas nesse diretorio."
        return 0
    fi

    show_hana_log_samples "$real"
    command_text="find '$real' -xdev -maxdepth 1 -type f (log_backup_* ou .log_backup_*) -mmin +$HANA_LOG_RETENTION_MINUTES -delete"
    section_title "RESUMO DA ACAO PROPOSTA"
    printf 'Diretorio          : %s\n' "$real"
    printf 'Arquivos elegiveis : %s\n' "$before_eligible"
    printf 'Arquivos protegidos: %s\n' "$before_protected"
    printf 'Espaco estimado    : %s\n' "$(human_bytes "$before_bytes")"
    confirm_admin_action "Logs de backup HANA" \
        "excluir arquivos com mais de $HANA_LOG_RETENTION_HOURS horas" "$command_text" no || return 1

    delete_eligible_hana_logs "$real"; rc=$?
    after_total="$(hana_log_count "$real" all)"
    after_eligible="$(hana_log_count "$real" eligible)"
    after_protected=$((after_total - after_eligible))
    after_bytes="$(hana_log_bytes "$real" eligible)"
    after_fs="$(filesystem_snapshot "$real")"
    removed=$((before_total - after_total))
    (( removed < 0 )) && removed=0
    bytes_removed=$((before_bytes - after_bytes))
    (( bytes_removed < 0 )) && bytes_removed=0

    if (( rc == 0 && after_eligible == 0 )); then
        result="SUCCESS"
        status_ok "Limpeza concluida: $removed arquivos removidos; $(human_bytes "$bytes_removed") selecionados."
    elif (( removed > 0 )); then
        result="PARTIAL rc=$rc restantes=$after_eligible"
        status_high "Limpeza parcial: $removed removidos e $after_eligible elegiveis restantes."
    else
        result="FAILED rc=$rc restantes=$after_eligible"
        status_critical "Nenhum candidato foi removido; verificar permissoes e filesystem."
    fi

    REPORT_DATE="$(date '+%d/%m/%Y %H:%M:%S %Z')"
    REPORT_HOST="$(hostname -f 2>/dev/null || hostname)"
    REPORT_USER="$(id -un)"
    REPORT_TARGET="$real"
    REPORT_FS_BEFORE="$before_fs"
    REPORT_TOTAL_BEFORE="$before_total"
    REPORT_ELIGIBLE_BEFORE="$before_eligible"
    REPORT_PROTECTED_BEFORE="$before_protected"
    REPORT_BYTES_BEFORE="$before_bytes"
    REPORT_FS_AFTER="$after_fs"
    REPORT_TOTAL_AFTER="$after_total"
    REPORT_ELIGIBLE_AFTER="$after_eligible"
    REPORT_PROTECTED_AFTER="$after_protected"
    REPORT_REMOVED="$removed"
    REPORT_BYTES_REMOVED="$bytes_removed"
    REPORT_RESULT="$result"

    ticket_file="$(safe_filename "$ADMIN_TICKET")"
    report_file="$REPORT_DIR/hana-cleanup-$(date '+%Y%m%d-%H%M%S')-${ticket_file}.txt"
    if mkdir -p -- "$REPORT_DIR" 2>/dev/null && chmod 0750 "$REPORT_DIR" 2>/dev/null \
        && render_hana_cleanup_report > "$report_file" 2>/dev/null; then
        chmod 0640 "$report_file" 2>/dev/null || true
        printf '\n'
        cat "$report_file"
        status_ok "Relatorio salvo em: $report_file"
    else
        status_high "Nao foi possivel salvar o relatorio em $REPORT_DIR; exibindo somente na tela."
        render_hana_cleanup_report
        report_file="nao salvo"
    fi

    write_log "$ADMIN_TICKET" "Logs de backup HANA" "cleanup" \
        "dir=$real total=$before_total elegiveis=$before_eligible protegidos=$before_protected fs=[$before_fs]" \
        "total=$after_total elegiveis=$after_eligible protegidos=$after_protected removidos=$removed fs=[$after_fs]" \
        "$command_text" "$result contexto=$ADMIN_CONTEXT relatorio=$report_file"
    [[ "$result" == "SUCCESS" ]]
}

canonical_hana_report() {
    local file="$1" root real name
    [[ -d "$REPORT_DIR" ]] || return 1
    [[ -f "$file" && ! -L "$file" && -r "$file" ]] || return 1
    root="$(readlink -f -- "$REPORT_DIR" 2>/dev/null)" || return 1
    real="$(readlink -f -- "$file" 2>/dev/null)" || return 1
    [[ "$(dirname -- "$real")" == "$root" ]] || return 1
    name="$(basename -- "$real")"
    [[ "$name" == hana-cleanup-*.txt ]] || return 1
    printf '%s' "$real"
}

collect_hana_reports() {
    local candidate real
    HANA_REPORT_FILES=()
    [[ -d "$REPORT_DIR" && ! -L "$REPORT_DIR" ]] || return 0
    while IFS= read -r candidate; do
        real="$(canonical_hana_report "$candidate")" || continue
        HANA_REPORT_FILES+=("$real")
    done < <(
        find "$REPORT_DIR" -xdev -maxdepth 1 -type f -name 'hana-cleanup-*.txt' \
            -printf '%T@|%p\n' 2>/dev/null \
            | sort -t '|' -k1,1nr | head -n 20 | cut -d '|' -f2-
    )
}

report_value() {
    local file="$1" key="$2"
    awk -v key="$key" '
        index($0, key) == 1 && $0 ~ /:/ {
            value=$0
            sub(/^[^:]*:[[:space:]]*/, "", value)
            print value
            exit
        }
    ' "$file" 2>/dev/null
}

report_section_value() {
    local file="$1" section="$2" key="$3"
    awk -v section="$section" -v key="$key" '
        $0 == section {inside=1; next}
        inside && index($0, key) == 1 && $0 ~ /:/ {
            value=$0
            sub(/^[^:]*:[[:space:]]*/, "", value)
            print value
            exit
        }
    ' "$file" 2>/dev/null
}

report_fs_metric() {
    local snapshot="$1" metric="$2"
    awk -v snapshot="$snapshot" -v metric="$metric" 'BEGIN {
        count=split(snapshot, field, /[[:space:]]+/)
        prefix=metric "="
        for (i=1; i<=count; i++) {
            if (index(field[i], prefix) == 1) {
                sub("^" prefix, "", field[i])
                print field[i]
                exit
            }
        }
    }'
}

value_or_na() {
    [[ -n "${1:-}" ]] && printf '%s' "$1" || printf 'nao informado'
}

show_hana_report_summary() {
    local file="$1" report_date ticket context target retention
    local fs_before fs_after use_before free_before use_after free_after
    local predicted removed files_removed protected result result_color

    report_date="$(report_value "$file" "Data")"
    ticket="$(report_value "$file" "Ticket")"
    context="$(report_value "$file" "Contexto")"
    target="$(report_value "$file" "Diretorio")"
    retention="$(report_value "$file" "Retencao")"
    fs_before="$(report_section_value "$file" "ANTES" "Filesystem")"
    fs_after="$(report_section_value "$file" "DEPOIS" "Filesystem")"
    use_before="$(report_fs_metric "$fs_before" "uso")"
    free_before="$(report_fs_metric "$fs_before" "livre")"
    use_after="$(report_fs_metric "$fs_after" "uso")"
    free_after="$(report_fs_metric "$fs_after" "livre")"
    predicted="$(report_section_value "$file" "ANTES" "Espaco previsto")"
    removed="$(report_section_value "$file" "DEPOIS" "Espaco selecionado removido")"
    files_removed="$(report_section_value "$file" "DEPOIS" "Arquivos removidos")"
    protected="$(report_section_value "$file" "DEPOIS" "Preservados")"
    result="$(report_section_value "$file" "DEPOIS" "Resultado")"

    case "$result" in
        SUCCESS) result_color="$CLR_GREEN";;
        PARTIAL*) result_color="$CLR_YELLOW";;
        *) result_color="$CLR_RED";;
    esac

    separator
    screen_title "RESUMO DO RELATORIO DE LIMPEZA HANA"
    printf 'Data             : %s\n' "$(value_or_na "$report_date")"
    printf 'Ticket           : %b%s%b\n' "$CLR_BLUE" "$(value_or_na "$ticket")" "$CLR_RESET"
    printf 'Contexto         : %b%s%b\n' "$CLR_BLUE" "$(value_or_na "$context")" "$CLR_RESET"
    printf 'Diretorio        : %s\n' "$(value_or_na "$target")"
    printf 'Retencao         : %s\n' "$(value_or_na "$retention")"
    printf '\nANTES\n'
    printf 'Uso do disco     : %s\n' "$(value_or_na "$use_before")"
    printf 'Espaco livre     : %s\n' "$(value_or_na "$free_before")"
    printf 'Espaco previsto  : %b%s%b\n' "$CLR_YELLOW" "$(value_or_na "$predicted")" "$CLR_RESET"
    printf '\nDEPOIS\n'
    printf 'Uso do disco     : %s\n' "$(value_or_na "$use_after")"
    printf 'Espaco livre     : %s\n' "$(value_or_na "$free_after")"
    printf 'Espaco removido  : %b%s%b\n' "$CLR_GREEN" "$(value_or_na "$removed")" "$CLR_RESET"
    printf 'Arquivos removidos: %s\n' "$(value_or_na "$files_removed")"
    printf 'Arquivos preservados: %s\n' "$(value_or_na "$protected")"
    printf 'Resultado        : %b%s%b\n' "$result_color" "$(value_or_na "$result")" "$CLR_RESET"
    printf 'Arquivo          : %s\n' "$file"
    separator
}

view_hana_cleanup_reports() {
    local index choice selected real answer report_date ticket result removed
    separator
    screen_title "RELATORIOS DE LIMPEZA HANA"
    collect_hana_reports
    if (( ${#HANA_REPORT_FILES[@]} == 0 )); then
        status_info "Nenhum relatorio hana-cleanup-*.txt encontrado em $REPORT_DIR."
        return 0
    fi

    printf 'Ultimos relatorios encontrados (maximo 20):\n\n'
    for index in "${!HANA_REPORT_FILES[@]}"; do
        report_date="$(report_value "${HANA_REPORT_FILES[$index]}" "Data")"
        ticket="$(report_value "${HANA_REPORT_FILES[$index]}" "Ticket")"
        result="$(report_section_value "${HANA_REPORT_FILES[$index]}" "DEPOIS" "Resultado")"
        removed="$(report_section_value "${HANA_REPORT_FILES[$index]}" "DEPOIS" "Espaco selecionado removido")"
        printf '[%s] %s | Ticket: %s | %s | Removido: %s\n' \
            "$((index + 1))" "$(value_or_na "$report_date")" \
            "$(value_or_na "$ticket")" "$(value_or_na "$result")" "$(value_or_na "$removed")"
    done

    printf '\n'
    read -r -p 'Numero do relatorio (0 volta): ' choice
    [[ "$choice" == "0" ]] && return 0
    case "$choice" in ''|*[!0-9]*) status_high "Opcao invalida."; return 1;; esac
    (( choice >= 1 && choice <= ${#HANA_REPORT_FILES[@]} )) || {
        status_high "Opcao invalida."
        return 1
    }
    selected="${HANA_REPORT_FILES[$((choice - 1))]}"
    real="$(canonical_hana_report "$selected")" || {
        status_critical "Relatorio recusado pelo controle de caminho: $selected"
        return 1
    }

    show_hana_report_summary "$real"
    read -r -p 'Deseja visualizar o relatorio completo? (S/N): ' answer
    case "$answer" in
        S|s|SIM|sim)
            printf '\n'
            cat -- "$real"
            ;;
    esac
}

show_admin_urls() {
    separator
    screen_title "URLS ADMINISTRATIVAS"
    cat <<'EOF'
SLD Control Center : https://SERVIDOR:40000/ControlCenter
Authenticator      : https://SERVIDOR:40020/auth
Service Layer      : https://SERVIDOR:50000
SL Controller      : https://SERVIDOR:PORTA/ServiceLayerController
Balancer Manager   : https://SERVIDOR:PORTA/balancer-manager
Integration Frame. : https://SERVIDOR:PORTA/B1iXcellerator/index.htm

Substitua SERVIDOR e PORTA pelos dados homologados do cliente.
O console nao armazena credenciais nem acessa essas paginas automaticamente.
EOF
}

show_windows_checklist() {
    separator
    screen_title "VALIDACAO EXTERNA - SERVIDOR WINDOWS / APP"
    cat <<'EOF'
Se o Integration Framework/Xcellerator estiver indisponivel, validar/reiniciar
manualmente, conforme o ambiente e a autorizacao do ticket:

- SAP Business One DI Proxy (pode haver mais de uma instancia)
- SAP Business One DI Server
- SAP Business One Event Sender
- SAP Business One Integration / Apache Tomcat

Depois, validar:
https://SERVIDOR:PORTA/B1iXcellerator/index.htm

Esta Console Linux nao executa comandos remotos no Windows.
EOF
}

show_blocked_procedures() {
    separator
    screen_title "PROCEDIMENTOS BLOQUEADOS OU ORIENTADOS"
    cat <<'EOF'
- Reboot completo do servidor HANA:
  exige snapshot previo, retencao minima de 24h, janela, autorizacao e
  validacao posterior no APP. A Console nao cria snapshot nem executa reboot.

- drop_caches:
  o comando "echo 3 > /proc/sys/vm/drop_caches" limpa caches do kernel,
  nao limpa swap. Nao sera apresentado como correcao de swap.

- Limpeza generica com find/rm em /usr/sap:
  bloqueada enquanto o diretorio-base e o tipo exato dos objetos nao forem
  homologados. O caminho /user/sap recebido tambem precisa ser confirmado.

- /hana/log, /backup e /home:
  somente diagnostico; encaminhar para a fila ERP SAP.

- Limpeza em /hana/shared e /hana/wystorage:
  permitida somente nos caminhos backup/log autorizados e somente para os
  padroes log_backup_* e .log_backup_* com mais de 24 horas. A operacao exige
  root, ticket, contexto, confirmacao SIM e gera relatorio antes/depois.
EOF
}

health_check() {
    separator
    screen_title "HEALTH CHECK CONSOLIDADO"
    check_uptime
    check_disks || true
    check_swap
    show_sld_status
    show_unit_status "$EDS_UNIT" "EDS ($EDS_UNIT)"
    check_hana || true
}

header() {
    local page="${1:-MENU PRINCIPAL}" host user now
    host="$(hostname -f 2>/dev/null || hostname)"
    user="$(id -un)"
    now="$(date '+%d/%m/%Y %H:%M:%S %Z')"
    clear 2>/dev/null || true
    separator
    printf '  %bwe%b%bv%b%by%b  %b</ future-proof cloud >%b\n' \
        "$CLR_CYAN" "$CLR_RESET" "$CLR_GRAY" "$CLR_RESET" \
        "$CLR_PURPLE" "$CLR_RESET" "$CLR_GRAY" "$CLR_RESET"
    printf '  %b%s V%s%b\n' "$CLR_BOLD" "$OSC_NAME" "$OSC_VERSION" "$CLR_RESET"
    separator
    printf '%bNavegacao%b : %s\n' "$CLR_BLUE" "$CLR_RESET" "$page"
    printf '%bServidor%b  : %s | %bUsuario%b: %s\n' \
        "$CLR_GRAY" "$CLR_RESET" "$host" "$CLR_GRAY" "$CLR_RESET" "$user"
    printf '%bData%b      : %s\n' "$CLR_GRAY" "$CLR_RESET" "$now"
    printf '%bLog%b       : %s\n' "$CLR_GRAY" "$CLR_RESET" "$LOG_FILE"
}

monitoring_menu() {
    local option
    while true; do
        header "INICIO > DIAGNOSTICO"
        section_title "DIAGNOSTICO E HEALTH CHECK"
        menu_item 1 "Health Check consolidado"
        menu_item 2 "Processos e estado detalhado do HANA"
        menu_item 3 "Status detalhado do SLD"
        menu_item 4 "Verificar automacoes SAP no crontab"
        menu_item 5 "Analisar utilizacao de disco"
        menu_item 6 "Analise de logs de backup HANA (somente leitura)"
        menu_item 7 "URLs administrativas"
        menu_item 8 "Checklist externo Windows / APP"
        menu_item 9 "Procedimentos bloqueados/orientados na V1.3"
        menu_back
        read -r -p 'Opcao: ' option
        case "$option" in
            1) health_check; pause_screen;;
            2) show_hana_details; pause_screen;;
            3)
                if command -v systemctl >/dev/null 2>&1 && unit_exists "$SLD_UNIT"; then
                    systemctl status "$SLD_UNIT" --no-pager 2>&1 || true
                else
                    show_sld_status
                fi
                pause_screen
                ;;
            4) check_cron_automation; pause_screen;;
            5) disk_offenders; pause_screen;;
            6) preview_hana_backup_logs; pause_screen;;
            7) show_admin_urls; pause_screen;;
            8) show_windows_checklist; pause_screen;;
            9) show_blocked_procedures; pause_screen;;
            0) return;;
            *) status_high "Opcao invalida."; sleep 1;;
        esac
    done
}

actions_menu() {
    local option
    while true; do
        header "INICIO > OPERACOES"
        section_title "OPERACOES ADMINISTRATIVAS CONTROLADAS"
        menu_item 1 "SLD - restart"
        menu_item 2 "SLD - stop"
        menu_item 3 "SLD - start"
        menu_item 4 "Authenticator - restart"
        menu_item 5 "EDS - restart"
        menu_item 6 "Service Layer - restart"
        menu_item 7 "Service Layer - stop"
        menu_item 8 "Service Layer - start"
        menu_item 9 "WebClient - restart controlado"
        menu_item 10 "HANA + SLD - restart controlado"
        menu_item 11 "Zerar catalina.out"
        menu_item 12 "Limpeza controlada de logs de backup HANA"
        menu_back
        read -r -p 'Opcao: ' option
        case "$option" in
            1) sld_action restart; pause_screen;;
            2) sld_action stop; pause_screen;;
            3) sld_action start; pause_screen;;
            4) auth_restart; pause_screen;;
            5) admin_systemd_action "$EDS_UNIT" "EDS" restart; pause_screen;;
            6) service_layer_action restart; pause_screen;;
            7) service_layer_action stop; pause_screen;;
            8) service_layer_action start; pause_screen;;
            9) webclient_restart; pause_screen;;
            10) hana_restart; pause_screen;;
            11) truncate_catalina; pause_screen;;
            12) cleanup_hana_backup_logs; pause_screen;;
            0) return;;
            *) status_high "Opcao invalida."; sleep 1;;
        esac
    done
}

view_log() {
    separator
    screen_title "LOG DE OPERACOES"
    if [[ -r "$LOG_FILE" ]]; then
        tail -n 100 "$LOG_FILE"
    else
        status_info "Log ainda nao existe ou nao pode ser lido: $LOG_FILE"
    fi
}

main_menu() {
    local option
    while true; do
        header "INICIO"
        section_title "STATUS DO AMBIENTE"
        check_uptime
        show_sld_status
        show_unit_status "$EDS_UNIT" "EDS"
        section_title "MENU PRINCIPAL"
        printf '%b1)%b Diagnostico e Health Check\n' "$CLR_BLUE" "$CLR_RESET"
        printf '%b2)%b Operacoes administrativas controladas\n' "$CLR_BLUE" "$CLR_RESET"
        printf '%b3)%b Ver log de operacoes\n' "$CLR_BLUE" "$CLR_RESET"
        printf '%b4)%b Relatorios de limpeza HANA\n' "$CLR_BLUE" "$CLR_RESET"
        printf '%b0)%b Sair\n' "$CLR_GRAY" "$CLR_RESET"
        read -r -p 'Opcao: ' option
        case "$option" in
            1) monitoring_menu;;
            2) actions_menu;;
            3) view_log; pause_screen;;
            4) view_hana_cleanup_reports; pause_screen;;
            0) printf 'Encerrando %s.\n' "$OSC_NAME"; return;;
            *) status_high "Opcao invalida."; sleep 1;;
        esac
    done
}

show_help() {
    cat <<EOF
$OSC_NAME V$OSC_VERSION

Uso:
  $0             Abre o menu interativo
  $0 --health    Executa somente o Health Check
  $0 --hana      Mostra HDB info e processos HANA
  $0 --hana-logs Analisa logs de backup HANA sem remover arquivos
  $0 --reports   Consulta os relatorios recentes de limpeza HANA
  $0 --no-color  Desativa cores ANSI (pode ser combinado com outra opcao)
  $0 --help      Mostra esta ajuda

Variaveis opcionais:
  OSC_SAP_HANA_USER                 Padrao: ndbadm
  OSC_SAP_HANA_SID                  Padrao: NDB
  OSC_SAP_HANA_INSTANCE             Padrao: 00
  OSC_SAP_HANA_LOG_RETENTION_HOURS  Padrao/minimo: 24
  OSC_SAP_LOG_FILE                  Caminho alternativo do log
  OSC_SAP_REPORT_DIR                Diretorio alternativo dos relatorios
  OSC_SAP_POLL_INTERVAL             Padrao: 5 segundos
  OSC_SAP_POLL_ATTEMPTS             Padrao: 12 tentativas
  OSC_SAP_NO_COLOR                  Use 1 para desativar cores ANSI
EOF
}

# Remove a opcao visual antes de processar o comando principal.
declare -a CLI_ARGS=()
for cli_arg in "$@"; do
    [[ "$cli_arg" == "--no-color" ]] || CLI_ARGS+=("$cli_arg")
done
set -- "${CLI_ARGS[@]}"

case "${1:-}" in
    --health) health_check;;
    --hana) show_hana_details;;
    --hana-logs) preview_hana_backup_logs;;
    --reports) view_hana_cleanup_reports;;
    --help|-h) show_help;;
    "") main_menu;;
    *) show_help; exit 2;;
esac
