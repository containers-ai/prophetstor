#!/bin/bash
# The script collects nodes/controllers data and saves to .csv files for node utilization spreadsheet
# Versions:
#   1.0.1 - The first build.
#   1.0.2 - Add managed deployment maximum usage to csv
#   1.0.3 - Use user specified http or https protocol
#   1.0.4 - Add managed deployment avg/min usage; metainfo at the first line of csv
#   1.0.5 - Include sidecar containers' request/limit to the deployment's
#   1.0.6 - Precheck bash version and minor fixes
#   1.0.7 - Support new GCP node group affinity key name
#   1.0.8 - Use node group affinity key to match node labels
#   1.0.9 - Support maximum replica usage metrics/recommendations; fix build number processing errors
#
VER=1.0.9

# defines
KUBECTL="${KUBECTL:-kubectl}"
CURL=( curl -sS -k -X )
CONTROLLERS=( deployment statefulset )

CTLR_CUSTOM_COLUMNS="\
Name:.metadata.name,\
Namespace:.metadata.namespace,\
Replicas:.spec.replicas,\
CpuReq:.spec.template.spec.containers[*].resources.requests.cpu,\
MemReq:.spec.template.spec.containers[*].resources.requests.memory,\
CpuLim:.spec.template.spec.containers[*].resources.limits.cpu,\
MemLim:.spec.template.spec.containers[*].resources.limits.memory,\
NodeAffinityKey:.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key,\
NodeAffinityValue:.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values[0],\
Labels:.spec.template.metadata.labels"
declare -A CCC_IDX=( [F_NAME]=0 [F_NS]=1 [F_REPLICAS]=2 [F_CPUREQ]=3 [F_MEMREQ]=4 [F_CPULIM]=5 [F_MEMLIM]=6 [F_NAKEY]=7 [F_NAVALUE]=8 )

POD_CUSTOM_COLUMNS="\
Name:.metadata.name,\
CpuReq:.spec.containers[*].resources.requests.cpu,\
MemReq:.spec.containers[*].resources.requests.memory,\
CpuLim:.spec.containers[*].resources.limits.cpu,\
MemLim:.spec.containers[*].resources.limits.memory"
declare -A PCC_IDX=( [F_NAME]=0 [F_CREQ]=1 [F_MREQ]=2 [F_CLIM]=3 [F_MLIM]=4 )

NODE_CUSTOM_COLUMNS="\
Name:.metadata.name,\
CPU:.status.allocatable.cpu,\
MEM:.status.allocatable.memory,\
Label:.metadata.labels"
declare -A NCC_IDX=( [F_NAME]=0 [F_CPU]=1 [F_MEM]=2 [F_LABEL]=3 )

HTTPS="https"
FIFTEEN_MINS=900
NOW=$(date +"%s")
FIFTEEN_MINS_AGO=$((NOW-FIFTEEN_MINS))

DEPLOY_CSV="deployment-raw.csv"
NODE_CSV="node-raw.csv"
DEF_LOG_FILE="./k8s-resource-collect.log"

F8AI_VERSION="5.1.4"
F8AI_BUILD=2262

# configurable variables
declare -A vars
vars[kube_context]=""
vars[f8ai_host]="172.31.3.61:31012"
vars[f8ai_user]="admin"
vars[f8ai_pswd]=""
vars[f8ai_granularity]=21600
vars[target_cluster]=""
vars[csv_dir]="."
vars[resource_type]="both"
vars[log_path]="${DEF_LOG_FILE}"
vars[use_federatorai]="yes"
vars[past_period]=0

R=$(date "+%s")
RAND=$(expr ${R} + 0)
RANDOM=$((${RAND} % 10000))
SID=$((($RANDOM % 900 ) + 100))
SPF='['${SID}']'
output_msg="OK"
k8s_cluster=""

nodeDiskCapID=""
nodeDiskIOID=""
nodeTXID=""
nodeRXID=""

function lower_case()
{
    if [ "$1" != "" ]
    then
        echo "$1" | tr '[:upper:]' '[:lower:]'
    else
        echo ""
    fi
}

INFO=" INFO"
WARN=" WARN"
ERR="ERROR"
STAGE="STAGE"
STDOUT="STDOUT"

function logging()
{
    local stdout=""
    local level="${INFO}"
    if [ "$1" = "" ]
    then
        return 0
    fi
    if [ "$1" = "${STDOUT}" ]
    then
        stdout="$1"
        shift
    fi
    if [ "$1" = "${INFO}" -o "$1" = "${WARN}" -o "$1" = "${ERR}" -o "$1" = "${STAGE}" ]
    then
        level="$1"
        shift
    fi
    msg="$@"
    if [ "${msg}" = "" ]
    then
        return 0
    fi

    echo -e "${SPF} $(date '+%F %T') ${level}: ${msg}" >> ${vars[log_path]}

    if [ "${stdout}" = "${STDOUT}" ]
    then
        if [ "${level}" = "${INFO}" ]
        then
            echo -e "${msg}"
        else
            echo -e "${level}: ${msg}"
        fi
    fi
}

function write_logs()
{
    while read line
    do
        echo "${SPF} ${line}"
    done
}

function map_to_string()
{
    map="$1"
    if [ "${map:0:3}" = "map" ]
    then
        str=$( echo -n "${map:4:-1}" |tr ':' '=' |tr ' ' ',' )
    else
        str="${map}"
    fi
    echo ${str}
}

function trim_trailing_spaces()
{
    str="$1"
    while [ ${#str} -gt 0 ]
    do
        if [[ "${str:0-1}" == [[:space:]] ]]
        then
            str=${str:0:-1}
        else
            break
        fi
    done
    echo "${str}"
}

function precheck_architecture()
{
    machine_os=$( uname -mo )
    if [ "${machine_os}" != "x86_64 GNU/Linux" ]
    then
        output_msg="This script supports only Linux x86_64 architecture."
        return 1
    fi

    logging "Architecture: ${machine_os}"
}

function precheck_bash_version()
{
    major_ver=${BASH_VERSION:0:1}
    if [ "${major_ver}" != "" ]
    then
        if [ ${major_ver} -lt 4 ]
        then
            output_msg="Bash version 4 and above is required."
            return 1
        fi
    fi

    logging "Bash Version: ${BASH_VERSION}"
}

kube_curr_context=""

function precheck_kubectl()
{
    current_context=$( ${KUBECTL} config current-context 2>/dev/null )
    rc=$?
    if [ "${rc}" != "0" ]
    then
        output_msg="'${KUBECTL}' is not installed or configured properly."
        return 1
    elif [ "${current_context}" != "" ]
    then
        kube_curr_context=${current_context}
        if [ "${vars[kube_context]}" != "" -a "${vars[kube_context]}" != "${kube_curr_context}" ]
        then
            if ! ${KUBECTL} config use-context ${vars[kube_context]} 2>&1 | write_logs >>${vars[log_path]}
            then
                output_msg="Failed to set ${KUBECTL} context ${vars[kube_context]}."
                return 1
            fi
            kube_curr_context=${vars[kube_context]}
        fi
    fi
    cluster_name=$( ${KUBECTL} cluster-info | grep "Kubernetes" |awk -F':' '{print $2}' |tr -d '/:' 2>/dev/null )
    if [ "${cluster_name}" != "" ]
    then
        k8s_cluster=${cluster_name}
    fi

    logging "${STDOUT}" "Kubernetes cluster: ${vars[target_cluster]}(${k8s_cluster})"
    echo
    logging "Kubernetes context: ${kube_curr_context}, cluster: ${k8s_cluster}"
}

API_ERROR_KEY="message"

function precheck_federatorai_version()
{
    if [ "${vars[use_federatorai]}" = "no" ]
    then
        return 0
    fi

    retcode=2

    url="${HTTPS}://${vars[f8ai_host]}/apis/v1/version"

    INPUT=$( ${CURL[@]} GET "${url}" -H "${HEADER1}" -H "${HEADER2}" 2>/dev/null )
    INPUT_LENGTH="${#INPUT}"
    while IFS='=' read -d $'\n' -r k v
    do
        case "${k}" in
            ${API_ERROR_KEY})
                logging "${ERR}" "Federator.ai Version API: ${v}"
                output_msg="Federator.ai Version: ${v}"
                retcode=1
                break ;;
            version)
                F8AI_VERSION=${v} ;;
            build)
                F8AI_BUILD=$(expr ${v//[!0-9]/} + 0)
                retcode=0 ;;
        esac
    done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )

    if [ "${retcode}" = "0" ]
    then
        logging "${INFO}" "Federator.ai Version: ${F8AI_VERSION} Build: ${F8AI_BUILD}"
    elif [ "${retcode}" = "2" ]
    then
        output_msg="Failed to connect to ${HTTPS}://${vars[f8ai_host]}"
        echo
        ${CURL[@]} GET "${HTTPS}://${vars[f8ai_host]}/apis/v1/version" -H "${HEADER1}" -H "${HEADER2}"
        echo
    fi

    return 0
}

function precheck_federatorai()
{
    if [ "${vars[use_federatorai]}" = "no" ]
    then
        return 0
    fi

    retcode=2
    first_node="NOT_FOUND"
    output_msg="Target cluster: ${vars[target_cluster]} is not configured in Federator.ai"

    url="${HTTPS}://${vars[f8ai_host]}/apis/v1/resources/clusters/${vars[target_cluster]}/nodes"

    INPUT=$( ${CURL[@]} GET "${url}" -H "${HEADER1}" -H "${HEADER2}" 2>/dev/null )
    if [ "${INPUT}" = '{"data":[]}' ]
    then
        retcode=1
    else
        INPUT_LENGTH="${#INPUT}"
        while IFS='=' read -d $'\n' -r k v
        do
            case "${k}" in
                ${API_ERROR_KEY})
                    logging "${ERR}" "Federator.ai Resource API: ${v}"
                    output_msg="Target cluster: ${vars[target_cluster]}: ${v}"
                    retcode=1
                    break ;;
                data\.0\.name)
                    first_node=${v} ;;
                data\.0\.clusterName)
                    if [ "${v}" = "${vars[target_cluster]}" ]
                    then
                        retcode=0
                    fi ;;
            esac
        done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )

        if [ "${retcode}" = "0" ]
        then
            found=$( ${KUBECTL} get nodes | grep "${first_node}" 2>/dev/null )
            if [ "${found}" = "" ]
            then
                logging "${STDOUT}" "${WARN}" "Cluster '${vars[target_cluster]}' and '${k8s_cluster}' do not appear to be the same cluster!"
                echo
            fi
        elif [ "${retcode}" = "2" ]
        then
            output_msg="Failed to connect to ${HTTPS}://${vars[f8ai_host]}"
            echo
            ${CURL[@]} GET "${HTTPS}://${vars[f8ai_host]}/apis/v1/resources/clusters" -H "${HEADER1}" -H "${HEADER2}"
            echo
        fi
    fi

    return ${retcode}
}

function mem_sum()
{
    raw_line=$1
    local total_mem=0
    if [ "${raw_line}" != "" ]
    then
        value_line=$( echo ${raw_line} |numfmt --delimiter=, --field=- --from=auto --invalid=ignore )
        IFS=',' read -a container_mems <<< "${value_line}"
        for mb in ${container_mems[@]}
        do
            re='^[0-9]+$'
            if [[ ${mb} =~ ${re} ]]
            then
                total_mem=$((${total_mem} + ${mb}))
            fi
        done
    fi
    echo ${total_mem}
}

function cpu_sum()
{
    raw_line=$1
    local total_mcores=0
    if [ "${raw_line}" != "" ]
    then
        IFS=',' read -a container_mcores <<< "${raw_line}"
        for mc in ${container_mcores[@]}
        do
            u=1000
            if [ "${mc: -1}" = "m" ]
            then
                mc=${mc:0:-1}
                u=1
            fi
            re='^[0-9]+$'
            if [[ ${mc} =~ ${re} ]]
            then
                total_mcores=$(((${mc} * ${u}) + ${total_mcores}))
            fi
        done
    fi
    echo ${total_mcores}
}

function stats_of_array()
{
    arr=("$@")
    cnt=${#arr[@]}
    max=0
    min=0
    avg=0
    sum=0
    [[ ${cnt} -gt 0 ]] && min=${arr[0]}
    for num in ${arr[@]}
    do
        if ((num > max))
        then
            max=${num}
        fi
        if ((num < min))
        then
            min=${num}
        fi
        sum=$((${sum} + ${num}))
    done
    [[ ${cnt} -gt 0 ]] && avg=$((${sum} / ${cnt}))

    echo "${max},${min},${avg}"
}

function exist_in_array()
{
    item=$1
    shift
    arr=("$@")

    for ent in ${arr[@]}
    do
        if [ "${ent}" = "${item}" ]
        then
            return 0
        fi
    done
    return 1
}

###############################################################################
# bash-json-parser
# https://github.com/fkalis/bash-json-parser
###############################################################################
function output_entry() {
    echo "$1=$2"
}

function parse_array() {
    local current_path="${1:+$1.}$2"
    local current_scope="root"
    local current_index=0

    while [ "$chars_read" -lt "$INPUT_LENGTH" ]; do
        [ "$preserve_current_char" == "0" ] && chars_read=$((chars_read+1)) && read -r -s -n 1 c
        preserve_current_char=0
        c=${c:-' '}

        case "$current_scope" in
            "root") # Waiting for new object or value
                case "$c" in
                    '{')
                        parse_object "$current_path" "$current_index"
                        current_scope="entry_separator"
                        ;;
                    ']')
                        return
                        ;;
                    [\"tfTF\-0-9])
                        preserve_current_char=1 # Let the parse value function decide what kind of value this is
                        parse_value "$current_path" "$current_index"
                        preserve_current_char=1 # Parse value has terminated with a separator or an array end, but we can handle this only in the next while iteration
                        current_scope="entry_separator"
                        ;;

                esac
                ;;
            "entry_separator")
                [ "$c" == "," ] && current_index=$((current_index+1)) && current_scope="root"
                [ "$c" == "]" ] && return
                ;;
        esac
    done
}

function parse_value() {
    local current_path="${1:+$1.}$2"
    local current_scope="root"

    while [ "$chars_read" -lt "$INPUT_LENGTH" ]; do
        [ "$preserve_current_char" == "0" ] && chars_read=$((chars_read+1)) && read -r -s -n 1 c
        preserve_current_char=0
        c=${c:-' '}

        case "$current_scope" in
            "root") # Waiting for new string, number or boolean
                case "$c" in
                    '"') # String begin
                        current_scope="string"
                        current_varvalue=""
                        ;;
                    [\-0-9]) # Number begin
                        current_scope="number"
                        current_varvalue="$c"
                        ;;
                    [tfTF]) # True or false begin
                        current_scope="boolean"
                        current_varvalue="$c"
                        ;;
                    "[") # Array begin
                        parse_array "" "$current_path"
                        return
                        ;;
                    "{") # Object begin
                        parse_object "" "$current_path"
                        return
                esac
                ;;
            "string") # Waiting for string end
                case "$c" in
                    '"') # String end if not in escape mode, normal character otherwise
                        [ "$current_escaping" == "0" ] && output_entry "$current_path" "$current_varvalue" && return
                        [ "$current_escaping" == "1" ] && current_varvalue="$current_varvalue$c" && current_escaping=0
                        ;;
                    '\') # Escape character, entering or leaving escape mode
                        [ "$current_escaping" == "1" ] && current_varvalue="$current_varvalue$c"
                        current_escaping=$((1-current_escaping))
                        ;;
                    *) # Any other string character
                        current_escaping=0
                        current_varvalue="$current_varvalue$c"
                        ;;
                esac
                ;;
            "number") # Waiting for number end
                case "$c" in
                    [,\]}]) # Separator or array end or object end
                        output_entry "$current_path" "$current_varvalue"
                        preserve_current_char=1 # The caller needs to handle this char
                        return
                        ;;
                    [\-0-9.]) # Number can only contain digits, dots and a sign
                        current_varvalue="$current_varvalue$c"
                        ;;
                    # Ignore everything else
                esac
                ;;
            "boolean") # Waiting for boolean to end
                case "$c" in
                    [,\]}]) # Separator or array end or object end
                        output_entry "$current_path" "$current_varvalue"
                        preserve_current_char=1 # The caller needs to handle this char
                        return
                        ;;
                    [a-zA-Z]) # No need to do some strict checking, we do not want to validate the incoming json data
                        current_varvalue="$current_varvalue$c"
                        ;;
                    # Ignore everything else
                esac
                ;;
        esac
    done
}

function parse_object() {
    local current_path="${1:+$1.}$2"
    local current_scope="root"

    while [ "$chars_read" -lt "$INPUT_LENGTH" ]; do
        [ "$preserve_current_char" == "0" ] && chars_read=$((chars_read+1)) && read -r -s -n 1 c
        preserve_current_char=0
        c=${c:-' '}

        case "$current_scope" in
            "root") # Waiting for new field or object end
                [ "$c" == "}" ]  && return
                [ "$c" == "\"" ] && current_scope="varname" && current_varname="" && current_escaping=0
                ;;
            "varname") # Reading the field name
                case "$c" in
                    '"') # String end if not in escape mode, normal character otherwise
                        [ "$current_escaping" == "0" ] && current_scope="key_value_separator"
                        [ "$current_escaping" == "1" ] && current_varname="$current_varname$c" && current_escaping=0
                        ;;
                    '\') # Escape character, entering or leaving escape mode
                        current_escaping=$((1-current_escaping))
                        current_varname="$current_varname$c"
                        ;;
                    *) # Any other string character
                        current_escaping=0
                        current_varname="$current_varname$c"
                        ;;
                esac
                ;;
            "key_value_separator") # Waiting for the key value separator (:)
                [ "$c" == ":" ] && parse_value "$current_path" "$current_varname" && current_scope="field_separator"
                ;;
            "field_separator") # Waiting for the field separator (,)
                [ "$c" == ',' ] && current_scope="root"
                [ "$c" == '}' ] && return
                ;;
        esac
    done
}

function parse() {
    chars_read=0
    preserve_current_char=0

    while [ "$chars_read" -lt "$INPUT_LENGTH" ]; do
        read -r -s -n 1 c
        c=${c:-' '}
        chars_read=$((chars_read+1))

        # A valid JSON string consists of exactly one object
        [ "$c" == "{" ] && parse_object "" "" && return
        # ... or one array
        [ "$c" == "[" ] && parse_array "" "" && return

    done
}
###############################################################################
###############################################################################

HEADER1="accept: application/json"
HEADER2="authorization: Basic $(echo -n "${vars[f8ai_user]}:${vars[f8ai_pswd]}" |base64)"
HEADER3="Content-Type: application/json"
RECOMM_CPUREQ_KEY="plannings.0.plannings.0.requestPlannings.CPU_MILLICORES_USAGE.0.numValue"
RECOMM_MEMREQ_KEY="plannings.0.plannings.0.requestPlannings.MEMORY_BYTES_USAGE.0.numValue"
RECOMM_CPULIM_KEY="plannings.0.plannings.0.limitPlannings.CPU_MILLICORES_USAGE.0.numValue"
RECOMM_MEMLIM_KEY="plannings.0.plannings.0.limitPlannings.MEMORY_BYTES_USAGE.0.numValue"
RECOMM_CPUMAX_KEY="plannings.0.plannings.0.maxReplicaPlannings.CPU_MILLICORES_USAGE.0.numValue"
RECOMM_MEMMAX_KEY="plannings.0.plannings.0.maxReplicaPlannings.MEMORY_BYTES_USAGE.0.numValue"

function controller_planning()
{
    c_name=$1
    kind=$2
    namespace=$3
    replicas=$4
    granularity=$5
    start_time=$(date "+%s")
    end_time=$((${start_time} + ${granularity}))
    retcode=0
    recomm_cpulim=0
    recomm_memlim=0
    recomm_cpumax=0
    recomm_memmax=0

    if [ "${vars[use_federatorai]}" = "yes" ]
    then
        url="${HTTPS}://${vars[f8ai_host]}/apis/v1/plannings/clusters/${vars[target_cluster]}/namespaces/${namespace}/${kind}s/${c_name}?granularity=${granularity}&type=planning&limit=1&order=asc&startTime=${start_time}&endTime=${end_time}"

        INPUT=$( ${CURL[@]} GET "${url}" -H "${HEADER1}" -H "${HEADER2}" 2>/dev/null )
        INPUT_LENGTH="${#INPUT}"
        while IFS='=' read -d $'\n' -r k v
        do
            case "${k}" in
                ${API_ERROR_KEY})
                    logging "${ERR}" "Federator.ai Planning API: ${v}"
                    retcode=1
                    break ;;
                ${RECOMM_CPUREQ_KEY})
                    recomm_cpureq=$((${v} / ${replicas})) ;;
                ${RECOMM_MEMREQ_KEY})
                    recomm_memreq=$((${v} / ${replicas})) ;;
                ${RECOMM_CPULIM_KEY})
                    recomm_cpulim=$((${v} / ${replicas})) ;;
                ${RECOMM_MEMLIM_KEY})
                    recomm_memlim=$((${v} / ${replicas})) ;;
                ${RECOMM_CPUMAX_KEY})
                    recomm_cpumax=${v} ;;
                ${RECOMM_MEMMAX_KEY})
                    recomm_memmax=${v} ;;
            esac
        done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )
    fi

    if [ ${recomm_cpumax} -eq 0 -o ${recomm_memmax} -eq 0 ]
    then
        if [ ${recomm_cpulim} -eq 0 -o ${recomm_memlim} -eq 0 ]
        then
            if [ ${F8AI_BUILD} -gt 2280 ]   # v5.1.5
            then
                logging "${WARN}" "Unable to get replica recommendations for ${kind}/${c_name}"
            fi
        fi
    else
        recomm_cpulim=${recomm_cpumax}
        recomm_memlim=${recomm_memmax}
    fi
    [[ recomm_cpureq -gt recomm_cpulim ]] && recomm_cpureq=${recomm_cpulim}
    [[ recomm_memreq -gt recomm_memlim ]] && recomm_memreq=${recomm_memlim}

    echo -n "${recomm_cpureq:=0},${recomm_memreq:=0},${recomm_cpulim:=0},${recomm_memlim:=0}"
    return ${retcode}
}

OBS_TIM_KEY='data.raw_data.cpu.*.time'
OBS_CPU_KEY='data.raw_data.cpu.*.numValue'
OBS_MEM_KEY='data.raw_data.memory.*.numValue'
MAX_TIM_KEY='data.max_replica_data.cpu.*.time'
MAX_CPU_KEY='data.max_replica_data.cpu.*.numValue'
MAX_MEM_KEY='data.max_replica_data.memory.*.numValue'

function controller_observation()
{
    c_name=$1
    kind=$2
    namespace=$3
    replicas=$4
    past_days=${vars[past_period]}
    granularity=${vars[f8ai_granularity]}
    local retcode=0

    if [ ${vars[past_period]} -gt 0 ]
    then
        past_days=${vars[past_period]}
    elif [ ${vars[f8ai_granularity]} -eq 86400 ]
    then
        past_days=$(( ($(date +%s) - $(date -d "-3 months" +%s) + 3) / 86400 ))  # past 3 months
    elif [ ${vars[f8ai_granularity]} -eq 21600 ]
    then
        past_days=28  # past 4 weeks
    else
        granularity=3600
        past_days=7  # past 7 days
    fi

    end_time=${NOW}
    start_time=$((${end_time} - (${past_days} * 86400)))
    limit=$((${past_days} * (86400 / ${granularity})))

    obs_cpus=()
    obs_mems=()
    max_cpus=()
    max_mems=()
    raw_earliest=${NOW}
    max_earliest=${NOW}

    if [ "${vars[use_federatorai]}" = "yes" ]
    then
        url="${HTTPS}://${vars[f8ai_host]}/apis/v1/observations/clusters/${vars[target_cluster]}/namespaces/${namespace}/${kind}s/${c_name}?&startTime=${start_time}&endTime=${end_time}&granularity=${granularity}&limit=${limit}"

        INPUT=$( ${CURL[@]} GET "${url}" -H "${HEADER1}" -H "${HEADER2}" 2>/dev/null )
        INPUT_LENGTH="${#INPUT}"
        while IFS='=' read -d $'\n' -r k v
        do
            case "${k}" in
                ${API_ERROR_KEY})
                    logging "${ERR}" "Federator.ai Observation API: ${v}"
                    retcode=1
                    break ;;
                ${OBS_TIM_KEY})
                    [[ v -lt raw_earliest ]] && raw_earliest=${v} ;;
                ${OBS_CPU_KEY})
                    obs_cpus=( ${obs_cpus[@]} ${v} ) ;;
                ${OBS_MEM_KEY})
                    obs_mems=( ${obs_mems[@]} ${v} ) ;;
                ${MAX_TIM_KEY})
                    [[ v -lt max_earliest ]] && max_earliest=${v} ;;
                ${MAX_CPU_KEY})
                    max_cpus=( ${max_cpus[@]} ${v} ) ;;
                ${MAX_MEM_KEY})
                    max_mems=( ${max_mems[@]} ${v} ) ;;
            esac
        done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )

        IFS=, read -a cpu_stats <<< $(stats_of_array ${obs_cpus[@]})
        IFS=, read -a mem_stats <<< $(stats_of_array ${obs_mems[@]})
        IFS=, read -a cpu_maxs <<< $(stats_of_array ${max_cpus[@]})
        IFS=, read -a mem_maxs <<< $(stats_of_array ${max_mems[@]})
    fi

    if [ ${F8AI_BUILD} -gt 2280 -a "${cpu_maxs[0]}" != "0" ]
    then
        for i in 0 1 2
        do
            cpu_stats[${i}]=$(( ${cpu_maxs[${i}]} * ${replicas} ))
            mem_stats[${i}]=$(( ${mem_maxs[${i}]} * ${replicas} ))
            raw_earliest=${max_earliest}
        done
    fi

    past_days=$(( (${NOW} - ${raw_earliest} + ${granularity}) / 86400 ))

    logging "${INFO}" "Deployment ${c_name} stats: granularity=${granularity} days=${past_days} max=${cpu_stats[0]},${mem_stats[0]} min=${cpu_stats[1]},${mem_stats[1]} avg=${cpu_stats[2]},${mem_stats[2]}"

    echo -n "${cpu_stats[0]:=0},${mem_stats[0]:=0},${past_days:=0},${cpu_stats[1]:=0},${mem_stats[1]:=0},${cpu_stats[2]:=0},${mem_stats[2]:=0}"
    return ${retcode}
}

function controller_reqlim()
{
    c_name=$1
    c_ns=$2
    c_labels=$3

    kubectl_cmd=( ${KUBECTL} get pod -n ${c_ns} -l ${c_labels} -o custom-columns="${POD_CUSTOM_COLUMNS}" )

    while IFS= read -r one_line
    do
        IFS=' ' read -a line <<< "${one_line}"
        # Skip lines starting with sharp
        # or lines containing only space or empty lines
        [[ "${line[0]}" =~ ^([[:space:]]*|[[:space:]]*#.*)$ ]] && continue
        [[ "${line[0]}" = "Name" ]] && continue
        # convert units
        line[${PCC_IDX[F_CREQ]}]=$( cpu_sum ${line[${PCC_IDX[F_CREQ]}]} )
        line[${PCC_IDX[F_MREQ]}]=$( mem_sum ${line[${PCC_IDX[F_MREQ]}]} )
        line[${PCC_IDX[F_CLIM]}]=$( cpu_sum ${line[${PCC_IDX[F_CLIM]}]} )
        line[${PCC_IDX[F_MLIM]}]=$( mem_sum ${line[${PCC_IDX[F_MLIM]}]} )
        logging "Deployment ${c_name}/${line[${PCC_IDX[F_NAME]}]}: ${line[${PCC_IDX[F_CREQ]}]},${line[${PCC_IDX[F_MREQ]}]},${line[${PCC_IDX[F_CLIM]}]},${line[${PCC_IDX[F_MLIM]}]}"
        break
    done < <(${kubectl_cmd[@]} 2>/dev/null)

    echo "${line[${PCC_IDX[F_CREQ]}]},${line[${PCC_IDX[F_MREQ]}]},${line[${PCC_IDX[F_CLIM]}]},${line[${PCC_IDX[F_MLIM]}]}"
}

F8AI_CPU_USAGE_KEY[observations]="data.raw_data.cpu.0.numValue"
F8AI_MEM_USAGE_KEY[observations]="data.raw_data.memory.0.numValue"
F8AI_CPU_USAGE_KEY[predictions]="data.predictedRawData.cpu.0.numValue"
F8AI_MEM_USAGE_KEY[predictions]="data.predictedRawData.memory.0.numValue"

function f8ai_comp_usage()
{
    api=$1
    n_name=$2
    cpu_usage=$3
    mem_usage=$4
    cpu_v=0
    mem_v=0

    end_time=$(date "+%s")
    start_time=$((${end_time} - 3600))

    url="${HTTPS}://${vars[f8ai_host]}/apis/v1/${api}/clusters/${vars[target_cluster]}/nodes/${n_name}?granularity=3600&order=asc&startTime=${start_time}&endTime=${end_time}"

    INPUT=$( ${CURL[@]} GET "${url}" -H "${HEADER1}" -H "${HEADER2}" 2>/dev/null )
    INPUT_LENGTH="${#INPUT}"
    while IFS='=' read -d $'\n' -r k v
    do
        case "${k}" in
            ${API_ERROR_KEY})
                logging "${ERR}" "Federator.ai ${api} API: ${v}"
                retcode=1
                break ;;
            ${F8AI_CPU_USAGE_KEY[${api}]})
                cpu_v=${v} ;;
            ${F8AI_MEM_USAGE_KEY[${api}]})
                mem_v=${v} ;;
        esac
    done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )

    eval ${cpu_usage}=${cpu_v}
    eval ${mem_usage}=${mem_v}
}

function node_comp_usage()
{
    n_name=$1
    end_time=$(date "+%s")
    start_time=$((${end_time} - 3600))
    retcode=0

    obs_cpu=0
    obs_mem=0

    if [ "${vars[use_federatorai]}" = "yes" ]
    then
        # Observation API
        f8ai_comp_usage "observations" ${n_name} obs_cpu obs_mem
        logging "${n_name}: Observation: ${obs_cpu} ${obs_mem}"

        if [ "${obs_cpu}" = "0" -a "${obs_mem}" = "0" ]
        then
            # if no result, use prediction API
            f8ai_comp_usage "predictions" ${n_name} obs_cpu obs_mem
            logging "${n_name}: Predictions: ${obs_cpu} ${obs_mem}"
        fi
    fi
    if [ "${obs_cpu}" = "0" -a "${obs_mem}" = "0" ]
    then
        kubectl_top=( ${KUBECTL} top node ${n_name} --no-headers )
        if IFS=' ' read -r n cv cp mv mp < <(${kubectl_top[@]} 2>/dev/null)
        then
            obs_cpu=$( cpu_sum ${cv} )
            obs_mem=$( mem_sum ${mv} )
            logging "${n_name}: kubectl top: ${obs_cpu} ${obs_mem}"
        fi
    fi

    echo -n "${obs_cpu},${obs_mem}"
    return ${retcode}
}

declare -a SUPPORTED_LABELS=( \
    eks.amazonaws.com/nodegroup \
    alpha.eksctl.io/nodegroup-name \
    node-pool-name \
    kops.k8s.io/instancegroup \
    cloud.google.com/gke-nodepool \
    Agentpool )

declare -a CUSTOM_AFFINITY_LABELS=( \
    role )

declare -a MATCHED_LABELS

function nodepool_name()
{
    local key=$1
    local value=$2
    local na="<none>"
    if [ "${key}" != "" -a "${key}" != "<none>" ]
    then
        for label in ${MATCHED_LABELS[@]} ${SUPPORTED_LABELS[@]} ${CUSTOM_AFFINITY_LABELS[@]}
        do
            if [ "${key}" = "${label}" ]
            then
                break
            fi
        done
        if [ "${value}" != "" ]
        then
            na=${value}
        fi
    fi
    echo -n "${na}"
}

function nodepool_label()
{
    local labels="$@"
    labels=${labels#map[}
    labels=${labels%]}
    local np_name="<none>"
    if [ "${labels}" != "" ]
    then
        IFS= read -a label_array <<< "${labels}"
        for l in ${label_array[@]}
        do
            IFS=':' read -r k v <<< "${l}"
            if exist_in_array "${k}" ${MATCHED_LABELS[@]}
            then
                np_name=${v}
            fi
            if [ "${np_name}" != "<none>" ]
            then
                logging "Matching node label: ${k} in ( ${MATCHED_LABELS[@]} )"
                echo -n "${np_name}"
                return
            fi
        done

        for l in ${label_array[@]}
        do
            IFS=':' read -r k v <<< "${l}"
            if exist_in_array "${k}" ${SUPPORTED_LABELS[@]} ${CUSTOM_AFFINITY_LABELS[@]}
            then
                np_name=${v}
            fi
            if [ "${np_name}" != "<none>" ]
            then
                break
            fi
        done
    fi
    echo -n "${np_name}"
}

function create_deployment_csv()
{
    echo
    logging "${STDOUT}" "Start collecting Controller resource data."

    csv_filename="${vars[csv_dir]}/${DEPLOY_CSV}"
    rm -rf ${csv_filename} >/dev/null 2>&1

    echo "${VER},${NOW},${vars[target_cluster]},${vars[f8ai_granularity]}" >> ${csv_filename}

    for ctlr in ${CONTROLLERS[@]}
    do
        kubectl_get=( ${KUBECTL} get ${ctlr} -A -o custom-columns="${CTLR_CUSTOM_COLUMNS}" )

        while IFS= read -r one_line
        do
            tmpl_labels_str=""

            if [ ${#one_line} -gt 0 ]
            then
                # template.labels
                one_line=$( trim_trailing_spaces "${one_line}" )
                tmpl_labels_map=${one_line##*  }
                tmpl_labels_len=${#tmpl_labels_map}
                tmpl_labels_str=$( map_to_string "${tmpl_labels_map}" )
                one_line=${one_line:0:-$tmpl_labels_len}
                one_line=$( trim_trailing_spaces "${one_line}" )
            else
                continue
            fi

            IFS=' ' read -a line <<< "${one_line}"
            # Skip lines starting with sharp
            # or lines containing only space or empty lines
            [[ "${line[0]}" =~ ^([[:space:]]*|[[:space:]]*#.*)$ ]] && continue
            [[ "${line[0]}" = "Name" ]] && continue

            pod_reqlim_str=$( controller_reqlim ${ctlr} ${line[${CCC_IDX[F_NS]}]} "${tmpl_labels_str}" )
            IFS=',' read -a reqlim <<< "${pod_reqlim_str}"

            [[ reqlim[0] -eq 0 ]] && reqlim[0]=$( cpu_sum ${line[${CCC_IDX[F_CPUREQ]}]} )
            [[ reqlim[1] -eq 0 ]] && reqlim[1]=$( mem_sum ${line[${CCC_IDX[F_MEMREQ]}]} )
            [[ reqlim[2] -eq 0 ]] && reqlim[2]=$( cpu_sum ${line[${CCC_IDX[F_CPULIM]}]} )
            [[ reqlim[3] -eq 0 ]] && reqlim[3]=$( mem_sum ${line[${CCC_IDX[F_MEMLIM]}]} )

            ctlr_reqlims="${reqlim[0]},${reqlim[1]},${reqlim[2]},${reqlim[3]}"

            ctlr_recomms=$( controller_planning ${line[${CCC_IDX[F_NAME]}]} ${ctlr} ${line[${CCC_IDX[F_NS]}]} ${line[${CCC_IDX[F_REPLICAS]}]} ${vars[f8ai_granularity]} )
            if [ "${ctlr_recomms}" = "0,0,0,0" ]
            then
                ctlr_recomms=${ctlr_reqlims}
            fi

            ctlr_stats=$( controller_observation ${line[${CCC_IDX[F_NAME]}]} ${ctlr} ${line[${CCC_IDX[F_NS]}]} ${line[${CCC_IDX[F_REPLICAS]}]} )

            node_affinity=$( nodepool_name "${line[${CCC_IDX[F_NAKEY]}]}" "${line[${CCC_IDX[F_NAVALUE]}]}" )

            # Keep node affinity key in MATCHED_LABELS array which will be used for matching node labels
            if [ "${node_affinity}" != "" -a "${node_affinity}" != "<none>" ]
            then
                if ! exist_in_array "${line[${CCC_IDX[F_NAKEY]}]}" ${MATCHED_LABELS[@]}
                then
                    MATCHED_LABELS=( ${MATCHED_LABELS[@]} "${line[${CCC_IDX[F_NAKEY]}]}" )
                    logging "Node group affinity keys: ( ${MATCHED_LABELS[@]} )"
                fi
            fi

            echo "${line[${CCC_IDX[F_NAME]}]},${ctlr},${line[${CCC_IDX[F_NS]}]},${node_affinity},${line[${CCC_IDX[F_REPLICAS]}]},${ctlr_reqlims},${ctlr_recomms},${ctlr_stats}" >> ${csv_filename}
            #echo "${line[@]}"
            echo -n "."
        done < <(${kubectl_get[@]} 2>/dev/null)
    done
    echo
}

function get_metrics_config() {
    logging "Fetching metric config id."

    url="${HTTPS}://${vars[f8ai_host]}/series_postgres/getMetricsConfig"
    metricRes=$( ${CURL[@]} POST "${url}" \
    -H "$HEADER3" \
    --data '{
        "queries": [
            {
                "key": "getBuiltinMetricConfigs",
                "method": "get_builtin_metric_configs",
                "isPostgres": true
            }
        ]
    }')

    INPUT=$metricRes
    INPUT_LENGTH="${#INPUT}"
    while IFS='=' read -d $'\n' -r k v
    do
        case "${k}" in
            results.0.values.builtin_metric_configs_operation_type.node_fs_bytes_usage_pct_operationType_1.builtin_metric_config_id)
                nodeDiskCapID=${v}
                logging "nodeDiskCapID = ${v}" ;;
            results.0.values.builtin_metric_configs_operation_type.node_disk_io_util_operationType_1.builtin_metric_config_id)
                nodeDiskIOID=${v}
                logging "nodeDiskIOID = ${v}" ;;
            results.0.values.builtin_metric_configs_operation_type.node_network_transmit_bytes_operationType_1.builtin_metric_config_id)
                nodeTXID=${v}
                logging "nodeTXID = ${v}" ;;
            results.0.values.builtin_metric_configs_operation_type.node_network_receive_bytes_operationType_1.builtin_metric_config_id)
                nodeRXID=${v}
                logging "nodeRXID = ${v}" ;;
        esac
    done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )

    logging "Fetching metric config id is completed."
}

function get_response_by_id() {
    # $1 means metric config id.
    url="${HTTPS}://${vars[f8ai_host]}/series_datahub/getSeries"
    results=$( ${CURL[@]} POST "${url}" \
    -H "$HEADER3" \
    --data '{
        "queries": [
            {
                "key": "readNodeMetrics",
                "datahub_method": "readNodeMetrics",
                "request_body": {
                    "read_metrics": [
                        {
                            "granularity": "60",
                            "purpose": "0",
                            "metric_config_id":'\"${1}\"',
                            "query_condition": {
                                "time_range": {
                                    "start_time": {
                                        "seconds": '\"${FIFTEEN_MINS_AGO}\"'
                                    },
                                    "end_time": {
                                        "seconds": '\"${NOW}\"'
                                    }
                                },
                                "where_condition": [
                                    {
                                        "keys": [
                                            "cluster_name"
                                        ],
                                        "values": [
                                            '\"${vars[target_cluster]}\"'
                                        ],
                                        "operators": [
                                            "="
                                        ]
                                    }
                                ],
                                "groups": [
                                    "node_name"
                                ]
                            }
                        }
                    ]
                }
            }
        ]
    }')
    echo $results
}

declare -A node_disk_cap
declare -A node_disk_io
declare -A node_net_tx
declare -A node_net_rx

function all_checks() {
    logging "Fetching metric util."
    ids=($nodeDiskCapID $nodeDiskIOID $nodeTXID $nodeRXID)
    counter=0
    #ids=($nodeRXID)
    for id in "${ids[@]}"
    do
        ((counter++))
        result=$(get_response_by_id $id)

        declare -A node_values
        declare -A node_counts

        INPUT=$result
        INPUT_LENGTH="${#INPUT}"
        while IFS='=' read -d $'\n' -r k v
        do
            case "${k}" in
                results.0.series.*.tags.node_name)
                    n_name=${v}
                    node_values[${n_name}]=0
                    node_counts[${n_name}]=0
                    #echo "node name = ${v}"
                    ;;
                results.0.series.*.data.*.value)
                    node_values[${n_name}]=$(echo "${node_values[${n_name}]} + ${v}" | bc)
                    node_counts[${n_name}]=$((${node_counts[${n_name}]} + 1))
                    #echo "values = ${v}"
                    ;;
            esac
        done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )

        for n in "${!node_values[@]}"
        do
            node_values[${n}]=$(echo "scale=4; ${node_values[${n}]} / ${node_counts[${n}]}" | bc)
            case "${id}" in
                ${nodeDiskCapID})
                    node_disk_cap[${n}]=${node_values[${n}]} ;;
                ${nodeDiskIOID})
                    node_disk_io[${n}]=${node_values[${n}]} ;;
                ${nodeTXID})
                    node_net_tx[${n}]=${node_values[${n}]} ;;
                ${nodeRXID})
                    node_net_rx[${n}]=${node_values[${n}]} ;;
            esac
        done

        unset node_values
        unset node_counts
    done

    for n in "${!node_values[@]}"
    do
        logging "Disk/Network: ${n}: ${node_disk_cap[${n}]}, ${node_disk_io[${n}]}, ${node_net_rx[${n}]}, ${node_net_tx[${n}]}"
    done

    logging "Fetching metric util is completed."
}

function take_a_while()
{
    begin_time=$1
    end_time=$(date "+%s")
    elapsed=$((${end_time} - ${begin_time}))
    if [ ${elapsed} -gt 30 ]
    then
        echo "(It may take a few minutes to complete...)"
    fi
}

function create_node_csv()
{
    echo
    logging "${STDOUT}" "Start collecting Node resource data."

    csv_filename="${vars[csv_dir]}/${NODE_CSV}"
    rm -rf ${csv_filename} >/dev/null 2>&1

    if [ "${vars[use_federatorai]}" = "yes" ]
    then
        bt=$(date "+%s")
        echo -n "."
        get_metrics_config
        # take_a_while ${bt}
        echo -n "."
        all_checks
    fi

    kubectl_get=( ${KUBECTL} get nodes -o custom-columns="${NODE_CUSTOM_COLUMNS}" )

    while IFS= read -r one_line
    do
        IFS=' ' read -a line <<< "${one_line}"
        # Skip lines starting with sharp
        # or lines containing only space or empty lines
        [[ "${line[0]}" =~ ^([[:space:]]*|[[:space:]]*#.*)$ ]] && continue
        [[ "${line[0]}" = "Name" ]] && continue
        # convert units
        node_name=${line[${NCC_IDX[F_NAME]}]}
        line[${NCC_IDX[F_CPU]}]=$( cpu_sum ${line[${NCC_IDX[F_CPU]}]} )
        line[${NCC_IDX[F_MEM]}]=$( mem_sum ${line[${NCC_IDX[F_MEM]}]} )
        node_capacity="${line[${NCC_IDX[F_CPU]}]},${line[${NCC_IDX[F_MEM]}]}"

        node_label=$( nodepool_label "${line[@]:${NCC_IDX[F_LABEL]}}" )
        node_usage=$( node_comp_usage "${node_name}" )

        node_disk_capacity=${node_disk_cap[${node_name}]}
        node_disk_io_util=${node_disk_io[${node_name}]}
        node_network_rx=${node_net_rx[${node_name}]}
        node_network_tx=${node_net_tx[${node_name}]}

        echo "${node_name},${node_label},${node_capacity},${node_usage},\
${node_disk_capacity:-0},${node_disk_io_util:-0},${node_network_rx:-0},${node_network_tx:-0}" >> ${csv_filename}
        #echo "${line[@]}"
        echo -n "."
    done < <(${kubectl_get[@]} 2>/dev/null)
    echo
}

function banner()
{
    banner_string="Federator.ai Kubernetes Node/Controller Resource Collector v${VER}"
    echo ${banner_string}
    echo
}

function show_usage()
{
    cat << __EOF__

${PROG} [options]

Mandatory options:
  -h, --host=''           Federator.ai API host(ip:port) (DEFAULT: '127.0.0.1:31012')
  -u, --username=''       Federator.ai API user name (DEFAULT: 'admin')
  -p, --password=''       Federator.ai API password (or read from 'F8AI_API_PASSWORD')
  -c, --cluster=''        Target Kubernetes cluster name
Optional options:
  -x, --context=''        Kubeconfig context name (DEFAULT: '')
  -g, --granularity=''    Resource recommendation granularity (DEFAULT: '21600')
  -d, --directory=''      Local path where .csv files will be saved (DEFAULT: '.')
  -r, --resource='both'   Generate Node('node') and/or Controller('controller') .csv (DEFAULT: 'both')
  -l, --logfile=''        Full path of the log file (DEFAULT: './k8s-resource-collect.log')
  -a, --federatorai='yes' Whether to use Federator.ai recommendations (DEFAULT: 'yes')
  -t, --pastperiod=''     Past period in days for getting the maximum usage (DEFAULT: '28')

Examples:
  ${PROG} --host=127.0.0.1:31012 --username=admin --password=xxxx --cluster=h3-61

__EOF__
    exit 1
}

# arguments
function parse_options()
{
    optspec="x:h:u:p:c:g:d:r:l:a:t:-:"
    while getopts "$optspec" o; do
        case "${o}" in
            -)
                if [ "${OPTARG}" = "${OPTARG%%=*}" ]
                then
                    OPT_ARG=${OPTARG}
                    OPT_VAL=${!OPTIND}
                    OPTIND=$(( $OPTIND + 1 ))
                else
                    OPT_ARG=${OPTARG%%=*}
                    OPT_VAL=${OPTARG##*=}
                fi

                case "${OPT_ARG}" in
                    context)
                        vars[kube_context]="${OPT_VAL}" ;;
                    host)
                        vars[f8ai_host]="${OPT_VAL}" ;;
                    username)
                        vars[f8ai_user]="${OPT_VAL}" ;;
                    password)
                        vars[f8ai_pswd]="${OPT_VAL}" ;;
                    cluster)
                        vars[target_cluster]="${OPT_VAL}" ;;
                    granularity)
                        vars[f8ai_granularity]="${OPT_VAL}" ;;
                    directory)
                        vars[csv_dir]="${OPT_VAL}" ;;
                    resource)
                        vars[resource_type]="${OPT_VAL}" ;;
                    logfile)
                        vars[log_path]="${OPT_VAL}" ;;
                    federatorai)
                        vars[use_federatorai]="${OPT_VAL}" ;;
                    pastperiod)
                        vars[past_period]="${OPT_VAL}" ;;
                    *)
                        if [ "$OPTERR" = 1 ] && [ "${optspec:0:1}" != ":" ]; then
                            echo "ERROR: Invalid argument '--${OPT_ARG}'."
                        fi
                        show_usage
                        exit 1 ;;
                esac ;;
            x)
                vars[kube_context]="${OPTARG}" ;;
            h)
                vars[f8ai_host]="${OPTARG}" ;;
            u)
                vars[f8ai_user]="${OPTARG}" ;;
            p)
                vars[f8ai_pswd]="${OPTARG}" ;;
            c)
                vars[target_cluster]="${OPTARG}" ;;
            g)
                vars[f8ai_granularity]="${OPTARG}" ;;
            d)
                vars[csv_dir]="${OPTARG}" ;;
            r)
                vars[resource_type]="${OPTARG}" ;;
            l)
                vars[log_path]="${OPTARG}" ;;
            a)
                vars[use_federatorai]="${OPTARG}" ;;
            t)
                vars[past_period]="${OPTARG}" ;;
            *)
                echo "ERROR: Invalid argument '-${o}'."
                show_usage
                exit 1 ;;
        esac
    done
}

##
# main
##
PROG=${0##*/}
banner

if [ "${1:0:1}" != "-" ]
then
    show_usage
    exit 1
fi

# parse options
parse_options "$@"

# validate options
if [[ ! -z "${F8AI_API_PASSWORD}" ]]
then
    vars[f8ai_pswd]=${F8AI_API_PASSWORD}
fi
if [ "${vars[use_federatorai]}" != "yes" -a "${vars[use_federatorai]}" != "no" ]
then
    vars[use_federatorai]="yes"
fi
if [ "${vars[use_federatorai]}" = "yes" ]
then
    if [ "${vars[f8ai_host]}" = "" -o "${vars[f8ai_pswd]}" = "" -o "${vars[target_cluster]}" = "" ]
    then
        echo "ERROR: Federator.ai host or password or target cluster is empty."
        show_usage
        exit 1
    fi
fi
fhost=${vars[f8ai_host]}
if [ "${fhost}" != "${fhost#https://}" ]
then
    HTTPS="https"
    vars[f8ai_host]=${fhost#https://}
elif [ "${fhost}" != "${fhost#http://}" ]
then
    HTTPS="http"
    vars[f8ai_host]=${fhost#http://}
fi

HEADER2="authorization: Basic $(echo -n "${vars[f8ai_user]}:${vars[f8ai_pswd]}" |base64)"

logging "Federator.ai Kubernetes Node/Controller Resource Collector v${VER}"
logging "Arguments: $@"
for i in "${!vars[@]}"
do
    if [ "${i}" != "f8ai_pswd" ]
    then
        logging "vars[${i}]=${vars[${i}]}"
    fi
done

# pre-checks
if ! precheck_bash_version || ! precheck_kubectl || ! precheck_federatorai_version || ! precheck_federatorai
then
    logging "${STDOUT}" "${ERR}" ${output_msg}
    exit 1
fi

# generate controller csv
if [ "${vars[resource_type]}" = "both" -o "${vars[resource_type]}" = "controller" ]
then
    echo "(It may take a few minutes to complete...)"
    if ! create_deployment_csv
    then
        logging "${STDOUT}" "${ERR}" "${output_msg}"
        exit 1
    else
        logging "${STDOUT}" "${INFO}" "Successfully created Controller .csv: '${vars[csv_dir]}/${DEPLOY_CSV}'."
    fi
fi
# generate node csv
if [ "${vars[resource_type]}" = "both" -o "${vars[resource_type]}" = "node" ]
then
    if ! create_node_csv
    then
        logging "${STDOUT}" "${ERR}" "${output_msg}"
        exit 1
    else
        logging "${STDOUT}" "${INFO}" "Successfully created Node .csv: '${vars[csv_dir]}/${NODE_CSV}'."
    fi
fi
