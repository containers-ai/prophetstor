#!/bin/bash
# The script collects current running instances and their region in cloud. The goal is to calculate instance-hours of each node group.
# Versions:
#   1.0.1 - The first build.
#   1.0.2 - Fix grabbing wrong node group labels
#   1.0.3 - Revised to be runable in a bash container
#
VER=1.0.3

# defines
kctl=( "${KUBECTL:-kubectl}" )
CURL=( curl -sS -k -X )

NODE_CUSTOM_COLUMNS="\
Name:.metadata.name,\
CPU:.status.allocatable.cpu,\
MEM:.status.allocatable.memory,\
Label:.metadata.labels"
declare -A NCCI=( [F_NAME]=0 [F_CPU]=1 [F_MEM]=2 [F_LABEL]=3 )

proto="https"
NOW=$(date +"%s")

OUTPUT_RETENTION=8
OUTPUT_PREFIX="instance-duration"
DEF_LOG_FILE="./instance-duration-collect.log"

F8AI_VERSION="5.1.4"
F8AI_BUILD=2262

# configurable variables
declare -A vars
vars[kubeconfig]=""
vars[kube_context]=""
vars[f8ai_host]=""
vars[f8ai_user]="admin"
vars[f8ai_pswd]=""
vars[f8ai_granularity]=3600
vars[target_cluster]=""
vars[csv_dir]="."
vars[log_path]="${DEF_LOG_FILE}"
vars[use_federatorai]="no"
vars[interval]=3600

RAND=$((NOW + 0))
RANDOM=$((RAND % 10000))
SID=$(((RANDOM % 900 ) + 100))
SPF='['${SID}']'
output_msg="OK"
k8s_cluster=""
serial=0
output_csv=""
timestamp=0

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
    if [ "$1" = "${INFO}" ] || [ "$1" = "${WARN}" ] || [ "$1" = "${ERR}" ] || [ "$1" = "${STAGE}" ]
    then
        level="$1"
        shift
    fi
    msg="$*"
    if [ "${msg}" = "" ]
    then
        return 0
    fi

    echo -e "${SPF} $(date '+%F %T') ${level}: ${msg}" >> "${vars[log_path]}"

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
    while read -r line
    do
        echo "${SPF} ${line}"
    done
}

function stderr_logs()
{
    while read -r line
    do
        logging "${ERR}" "${line}"
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
    echo "${str}"
}

function list_to_string()
{
    lst="$1"
    if [ "${lst:0:1}" = "[" ]
    then
        str=$( echo -n "${lst:1:-1}" |tr ' ' ',' )
    else
        str="${lst}"
    fi
    echo "${str}"
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
        if [ "${major_ver}" -lt 4 ]
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
    if [ "${vars[kubeconfig]}" != "" ]
    then
        if [ -e "${vars[kubeconfig]}" ]
        then
            kctl=("${kctl[@]}" "--kubeconfig=${vars[kubeconfig]}")
        else
            output_msg="Kubeconfig file '${vars[kubeconfig]}' does not exist."
            return 1
        fi
    fi
    kube_curr_context=$( "${kctl[@]}" config current-context 2>&1 )
    if [ "${vars[kube_context]}" != "" ]
    then
        kctl=("${kctl[@]}" "--context=${vars[kube_context]}")
        kube_curr_context=${vars[kube_context]}
    fi

    cluster_info_str=$( "${kctl[@]}" cluster-info 2>&1 )
    rc=$?
    if [ "${rc}" != "0" ]
    then
        output_msg="'${kctl[*]} cluster-info: ${cluster_info_str}'"
        return 1
    fi
    cluster_name=$( echo "${cluster_info_str}" | grep "Kubernetes" |awk -F':' '{print $2}' |tr -d '/:' 2> >( stderr_logs ) )
    if [ "${cluster_name}" != "" ]
    then
        k8s_cluster=${cluster_name}
    fi

    logging "${STDOUT}" "Kubernetes cluster: ${vars[target_cluster]}(${k8s_cluster})"
    echo
    logging "Kubernetes context: ${kube_curr_context}, cluster: ${k8s_cluster}"
}

function precheck_utils()
{
    export PATH=${PATH}:/usr/local/bin
    utils=( "${KUBECTL:-kubectl}" numfmt bc base64 date grep awk tr sed gzip )
    for util in "${utils[@]}"
    do
        ${util} --help >/dev/null 2>&1
        ret=$?
        if [ ${ret} -ne 0 ]
        then
            ${util} --help >/dev/null 2> >( stderr_logs )
            logging "${ERR}" "Required command '${util}' does not exist."
            output_msg="Required command '${util}' does not exist"
            return 1
        fi
    done
}

API_ERROR_KEY="message"

function precheck_federatorai_version()
{
    if [ "${vars[use_federatorai]}" = "no" ]
    then
        return 0
    fi

    retcode=2

    url="${proto}://${vars[f8ai_host]}/apis/v1/version"

    INPUT=$( "${CURL[@]}" GET "${url}" -H "${header1}" -H "${header2}" 2> >( stderr_logs ) )
    INPUT_LENGTH="${#INPUT}"
    while IFS='=' read -d $'\n' -r k v
    do
        case "${k}" in
            "${API_ERROR_KEY}")
                logging "${ERR}" "Federator.ai Version API: ${v}"
                output_msg="Federator.ai Version: ${v}"
                retcode=1
                break ;;
            version)
                F8AI_VERSION=${v} ;;
            build)
                F8AI_BUILD=$((${v//[!0-9]/} + 0))
                retcode=0 ;;
        esac
    done < <( parse "" "" <<< "${INPUT}" 2> >( stderr_logs ) )

    if [ "${retcode}" = "0" ]
    then
        logging "${INFO}" "Federator.ai Version: ${F8AI_VERSION} Build: ${F8AI_BUILD}"
    elif [ "${retcode}" = "2" ]
    then
        output_msg="Failed to connect to ${proto}://${vars[f8ai_host]}"
        echo
        "${CURL[@]}" GET "${proto}://${vars[f8ai_host]}/apis/v1/version" -H "${header1}" -H "${header2}"
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

    url="${proto}://${vars[f8ai_host]}/apis/v1/resources/clusters/${vars[target_cluster]}/nodes"

    INPUT=$( "${CURL[@]}" GET "${url}" -H "${header1}" -H "${header2}" 2> >( stderr_logs ) )
    if [ "${INPUT}" = '{"data":[]}' ]
    then
        retcode=1
    else
        INPUT_LENGTH="${#INPUT}"
        while IFS='=' read -d $'\n' -r k v
        do
            case "${k}" in
                "${API_ERROR_KEY}")
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
        done < <( parse "" "" <<< "${INPUT}" 2> >( stderr_logs ) )

        if [ "${retcode}" = "0" ]
        then
            found=$( "${kctl[@]}" get nodes | grep "${first_node}" 2> >( stderr_logs ) )
            if [ "${found}" = "" ]
            then
                logging "${STDOUT}" "${WARN}" "Cluster '${vars[target_cluster]}' and '${k8s_cluster}' do not appear to be the same cluster!"
                echo
            fi
        elif [ "${retcode}" = "2" ]
        then
            output_msg="Failed to connect to ${proto}://${vars[f8ai_host]}"
            echo
            "${CURL[@]}" GET "${proto}://${vars[f8ai_host]}/apis/v1/resources/clusters" -H "${header1}" -H "${header2}"
            echo
        fi
    fi

    return ${retcode}
}

function rotate_output_file()
{
    # output csv files
    output_gz_files=$( ls -1 "${vars[csv_dir]}"/${OUTPUT_PREFIX}-*.csv* 2> >( stderr_logs ) )
    for of in ${output_gz_files}
    do
        wk=$( echo "${of}" |awk -F'-' '{print $NF}' |awk -F'.' '{print $1}' )
        if [ "${wk}" -lt "$(( serial - OUTPUT_RETENTION ))" ]
        then
            rm -f "${of}" 2> >( stderr_logs )
        elif [ "${wk}" -ne "${serial}" ]
        then
            ext=$( echo "${of}" |awk -F'.' '{print $NF}' )
            if [ "${ext}" != "gz" ]
            then
                gzip "${of}" 2> >( stderr_logs )
            fi
        fi
    done
    # log file
    tail -5000 "${vars[log_path]}" > "${vars[log_path]}.tmp" 2> >( stderr_logs )
    rm -f "${vars[log_path]}" 2> >( stderr_logs )
    mv "${vars[log_path]}.tmp" "${vars[log_path]}" 2> >( stderr_logs )
}

function mem_sum()
{
    raw_line=$1
    local total_mem=0
    if [ "${raw_line}" != "" ]
    then
        value_line=$( echo "${raw_line}" |numfmt --delimiter=',' --field=- --from=auto --invalid=ignore )
        IFS=',' read -r -a container_mems <<< "${value_line}"
        for mb in "${container_mems[@]}"
        do
            [[ "${mb}" = "<none>" ]] && continue
            re='^[0-9]+$'
            if [[ ${mb} =~ ${re} ]]
            then
                total_mem=$((total_mem + mb))
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
        IFS=',' read -r -a container_mcores <<< "${raw_line}"
        for mc in "${container_mcores[@]}"
        do
            [[ "${mc}" = "<none>" ]] && continue
            u=1000
            if [ "${mc: -1}" = "m" ]
            then
                mc=${mc:0:-1}
                u=1
            fi
            re='^[0-9]+$'
            if [[ ${mc} =~ ${re} ]]
            then
                total_mcores=$(((mc * u) + total_mcores))
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
    for num in "${arr[@]}"
    do
        if ((num > max))
        then
            max=${num}
        fi
        if ((num < min))
        then
            min=${num}
        fi
        sum=$((sum + num))
    done
    [[ ${cnt} -gt 0 ]] && avg=$((sum / cnt))

    echo "${max},${min},${avg}"
}

function exist_in_array()
{
    item=$1
    shift
    arr=("$@")

    for ent in "${arr[@]}"
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

header1="accept: application/json"
header2="authorization: Basic $(echo -n "${vars[f8ai_user]}:${vars[f8ai_pswd]}" |base64)"

declare -a nodegroup_list

function collect_nodegroup_list()
{
    kubectl_cmd=( "${kctl[@]}" get nodes --show-labels )

    while IFS= read -r one_line
    do
        IFS=',' read -r -a line <<< "${one_line}"
        # Skip lines starting with sharp
        # or lines containing only space or empty lines
        [[ "${line[0]}" =~ ^([[:space:]]*|[[:space:]]*#.*)$ ]] && continue
        [[ "${line[0]}" = "LABELS" ]] && continue
        for label in "${line[@]}"
        do
            IFS='=' read -r k v <<< "${label}"
            if exist_in_array "${k}" "${SUPPORTED_LABELS[@]}" "${custom_affinity_labels[@]}"
            then
                if [[ " ${nodegroup_list[*]} " =~ " ${v} " ]]
                then
                    continue
                fi
                nodegroup_list=( "${nodegroup_list[@]}" "${v}" )
            fi
        done
    done < <("${kubectl_cmd[@]}" |awk '{print $6}' 2> >( stderr_logs ))
    logging "Node Group List: ( ${nodegroup_list[*]} )"
    return
}

declare -a SUPPORTED_LABELS=( \
    eks.amazonaws.com/nodegroup \
    alpha.eksctl.io/nodegroup-name \
    node-pool-name \
    kops.k8s.io/instancegroup \
    cloud.google.com/gke-nodepool \
    Agentpool )

declare -a custom_affinity_labels=( \
    role )

declare -a INSTANCE_TYPE_KEYS=( \
    beta.kubernetes.io/instance-type \
    node.kubernetes.io/instance-type )

declare -a REGION_KEYS=( \
    topology.kubernetes.io/region )

declare -a matched_labels

function node_labels()
{
    local labels="$*"
    labels=${labels#map[}
    labels=${labels%]}
    local np_name="<none>"
    local instance_type="<none>"
    local region="<none>"
    if [ "${labels}" != "" ]
    then
        IFS=' ' read -r -a label_array <<< "${labels}"
        for l in "${label_array[@]}"
        do
            IFS=':' read -r k v <<< "${l}"
            # node group
            if exist_in_array "${k}" "${matched_labels[@]}"
            then
                # overwrite np_name with matched label
                np_name=${v}
            fi
            if exist_in_array "${k}" "${SUPPORTED_LABELS[@]}"
            then
                if [ "${np_name}" = "<none>" ]
                then
                    np_name=${v}
                fi
            fi
            if exist_in_array "${k}" "${custom_affinity_labels[@]}"
            then
                np_name=${v}
            fi
            # instance type
            if exist_in_array "${k}" "${INSTANCE_TYPE_KEYS[@]}"
            then
                instance_type=${v}
            fi
            # region
            if exist_in_array "${k}" "${REGION_KEYS[@]}"
            then
                region=${v}
            fi
        done
    fi
    echo -n "${np_name},${instance_type},${region}"
}

declare -A f8ai_cpu_usage_key
declare -A f8ai_mem_usage_key
f8ai_cpu_usage_key[observations]="data.raw_data.cpu.0.numValue"
f8ai_mem_usage_key[observations]="data.raw_data.memory.0.numValue"
f8ai_cpu_usage_key[predictions]="data.predictedRawData.cpu.0.numValue"
f8ai_mem_usage_key[predictions]="data.predictedRawData.memory.0.numValue"

function f8ai_comp_usage()
{
    api=$1
    n_name=$2
    cpu_usage=$3
    mem_usage=$4
    cpu_v=0
    mem_v=0

    end_time=${NOW}
    start_time=$((NOW - 3600))

    url="${proto}://${vars[f8ai_host]}/apis/v1/${api}/clusters/${vars[target_cluster]}/nodes/${n_name}?granularity=${vars[f8ai_granularity]}&order=asc&startTime=${start_time}&endTime=${end_time}"

    INPUT=$( "${CURL[@]}" GET "${url}" -H "${header1}" -H "${header2}" 2> >( stderr_logs ) )
    INPUT_LENGTH="${#INPUT}"
    while IFS='=' read -d $'\n' -r k v
    do
        case "${k}" in
            "${API_ERROR_KEY}")
                logging "${ERR}" "Federator.ai ${api} API: ${v}"
                retcode=1
                break ;;
            "${f8ai_cpu_usage_key[${api}]}")
                cpu_v=${v} ;;
            "${f8ai_mem_usage_key[${api}]}")
                mem_v=${v} ;;
        esac
    done < <( parse "" "" <<< "${INPUT}" 2> >( stderr_logs ) )

    eval "${cpu_usage}"="${cpu_v}"
    eval "${mem_usage}"="${mem_v}"
}

function node_comp_usage()
{
    n_name=$1
    end_time=${NOW}
    start_time=$((NOW - 3600))
    retcode=0

    obs_cpu=0
    obs_mem=0

    if [ "${vars[use_federatorai]}" = "yes" ]
    then
        # Observation API
        f8ai_comp_usage "observations" "${n_name}" obs_cpu obs_mem
        logging "${n_name}: Observation: ${obs_cpu} ${obs_mem}"

        if [ "${obs_cpu}" = "0" ] && [ "${obs_mem}" = "0" ]
        then
            # if no result, use prediction API
            f8ai_comp_usage "predictions" "${n_name}" obs_cpu obs_mem
            logging "${n_name}: Predictions: ${obs_cpu} ${obs_mem}"
        fi
    fi
    if [ "${obs_cpu}" = "0" ] && [ "${obs_mem}" = "0" ]
    then
        kubectl_top=( "${kctl[@]}" top node "${n_name}" --no-headers )
        if IFS=' ' read -r n cv cp mv mp < <("${kubectl_top[@]}" 2>/dev/null)
        then
            obs_cpu=$( cpu_sum "${cv}" )
            obs_mem=$( mem_sum "${mv}" )
            logging "${n_name}: kubectl top: ${obs_cpu} ${obs_mem}"
        fi
    fi

    echo -n "${obs_cpu},${obs_mem}"
    return ${retcode}
}

function create_instance_csv()
{
    echo
    logging "${STDOUT}" "Start collecting Instance data:"

    kubectl_get=( "${kctl[@]}" get nodes -o custom-columns="${NODE_CUSTOM_COLUMNS}" )

    nodes=0
    while IFS= read -r one_line
    do
        IFS=' ' read -r -a line <<< "${one_line}"
        # Skip lines starting with sharp
        # or lines containing only space or empty lines
        [[ "${line[0]}" =~ ^([[:space:]]*|[[:space:]]*#.*)$ ]] && continue
        [[ "${line[0]}" = "Name" ]] && continue
        # convert units
        node_name=${line[${NCCI[F_NAME]}]}
        line[NCCI[F_CPU]]=$( cpu_sum "${line[NCCI[F_CPU]]}" )
        line[NCCI[F_MEM]]=$( mem_sum "${line[NCCI[F_MEM]]}" )
        node_capacity="${line[${NCCI[F_CPU]}]},${line[${NCCI[F_MEM]}]}"

        labels_str=$( node_labels "${line[@]:${NCCI[F_LABEL]}}" )
        IFS=',' read -r -a labels_arr <<< "${labels_str}"
        nodegroup_name=${labels_arr[0]}
        node_instance_type=${labels_arr[1]}
        node_region=${labels_arr[2]}
        node_usage=$( node_comp_usage "${node_name}" )

        echo "${timestamp},${vars[target_cluster]},${node_name},${nodegroup_name},${node_capacity},${node_usage},${node_instance_type},${node_region}" >> "${vars[csv_dir]}/${output_csv}"
        echo -n "."
        nodes=$((nodes + 1))
    done < <("${kubectl_get[@]}" 2> >( stderr_logs ))
    echo
    logging "${STDOUT}" "${nodes} instance(s) data have been collected."
}

function banner()
{
    banner_string="Federator.ai Kubernetes Instance Duration Collector v${VER}"
    echo "${banner_string}"
    echo
}

function show_usage()
{
    cat << __EOF__

${PROG} [options]

Mandatory options:
  -c, --cluster=''        Target Kubernetes cluster name
Optional options:
  -k, --kubeconfig=''     Kubeconfig file full path (DEFAULT: $KUBECONFIG)
  -x, --context=''        Kubeconfig context name (DEFAULT: '')
  -g, --granularity=''    Resource monitoring granularity (DEFAULT: '3600')
  -d, --directory=''      Local path where .csv files will be saved (DEFAULT: '.')
  -l, --logfile=''        Full path of the log file (DEFAULT: './instance-duration-collect.log')
  -h, --host=''           Federator.ai API host(ip:port) (DEFAULT: '127.0.0.1:31012')
  -u, --username=''       Federator.ai API user name (DEFAULT: 'admin')
  -p, --password=''       Federator.ai API password (or read from 'F8AI_API_PASSWORD')
  -i, --interval=''       Collect interval in seconds (DEFAULT: '3600')

Examples:
  ${PROG} --cluster=h3-61 --kubeconfig=/root/.kube/config-h3-61

__EOF__
}

# arguments
function parse_options()
{
    optspec="k:x:h:u:p:c:g:d:l:i:-:"
    while getopts "$optspec" o; do
        case "${o}" in
            -)
                if [ "${OPTARG}" = "${OPTARG%%=*}" ]
                then
                    OPT_ARG=${OPTARG}
                    OPT_VAL=${!OPTIND}
                    OPTIND=$(( OPTIND + 1 ))
                else
                    OPT_ARG=${OPTARG%%=*}
                    OPT_VAL=${OPTARG##*=}
                fi

                case "${OPT_ARG}" in
                    kubeconfig)
                        vars[kubeconfig]="${OPT_VAL}" ;;
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
                    logfile)
                        vars[log_path]="${OPT_VAL}" ;;
                    interval)
                        vars[interval]="${OPT_VAL}" ;;
                    *)
                        if [ "$OPTERR" = 1 ] && [ "${optspec:0:1}" != ":" ]; then
                            echo "ERROR: Invalid argument '--${OPT_ARG}'."
                        fi
                        show_usage
                        exit 1 ;;
                esac ;;
            k)
                vars[kubeconfig]="${OPTARG}" ;;
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
            l)
                vars[log_path]="${OPTARG}" ;;
            i)
                vars[interval]="${OPTARG}" ;;
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
if [[ -n "${F8AI_API_PASSWORD}" ]]
then
    vars[f8ai_pswd]=${F8AI_API_PASSWORD}
fi

if [ "${vars[target_cluster]}" = "" ]
then
    echo "ERROR: target cluster is empty."
    show_usage
    exit 1
fi

if [ "${vars[f8ai_host]}" != "" ]
then
    if [ "${vars[f8ai_pswd]}" = "" ] || [ "${vars[f8ai_user]}" = "" ]
    then
        echo "ERROR: Federator.ai username or password is empty."
        show_usage
        exit 1
    else
        vars[use_federatorai]="yes" 
    fi
fi

fhost=${vars[f8ai_host]}
if [ "${fhost}" != "${fhost#https://}" ]
then
    proto="https"
    vars[f8ai_host]=${fhost#https://}
elif [ "${fhost}" != "${fhost#http://}" ]
then
    proto="http"
    vars[f8ai_host]=${fhost#http://}
fi

logdir="${vars[log_path]%/*}"
if [ "${logdir}" != "" ] && [ "${logdir}" != "${vars[log_path]}" ] && [ ! -d "${logdir}" ]
then
    mkdir -p "${logdir}" 2> >( stderr_logs )
fi

if [ ! -d "${vars[csv_dir]}" ]
then
    mkdir -p "${vars[csv_dir]}" 2> >( stderr_logs )
fi

header2="authorization: Basic $(echo -n "${vars[f8ai_user]}:${vars[f8ai_pswd]}" |base64)"

logging "Federator.ai Kubernetes Instance Duration Collector v${VER}"
logging "Arguments: $*"
for i in "${!vars[@]}"
do
    if [ "${i}" != "f8ai_pswd" ]
    then
        logging "vars[${i}]=${vars[${i}]}"
    fi
done

# pre-checks
if ! precheck_bash_version || ! precheck_utils || ! precheck_kubectl || ! precheck_federatorai_version || ! precheck_federatorai
then
    logging "${STDOUT}" "${ERR}" "${output_msg}"
    exit 1
fi

retinv=$((vars[interval] * 168))
serial=$((NOW / retinv))
output_csv="${OUTPUT_PREFIX}-${vars[interval]}-${serial}.csv"
timestamp=$(((((vars[interval] / 6) + NOW) / vars[interval]) * vars[interval]))

# rotate log
rotate_output_file

# generate instance csv
if ! create_instance_csv
then
    logging "${STDOUT}" "${ERR}" "${output_msg}"
    exit 1
else
    logging "${STDOUT}" "${INFO}" "Successfully created Instance .csv: '${vars[csv_dir]}/${output_csv}'."
fi
