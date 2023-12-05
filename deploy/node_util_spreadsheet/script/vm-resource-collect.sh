#!/bin/bash
# The script collects VM data and saves to .csv files for VM recommendation spreadsheet
# Versions:
#   1.0.1 - The first build.
#   1.0.2 - Use user specified http or https protocol
#   1.0.3 - Support AWS/GCP/Azure VM clusters
#
VER=1.0.3

# defines
NOW=$(date +"%s")
CURL=( curl -sS -k -X )
HTTPS="https"

VM_IDV_CSV="vm-idv-raw.csv"
VM_ASG_CSV="vm-asg-raw.csv"
DEF_LOG_FILE="./vm-resource-collect.log"

SUBTYPE_IDV="individual"
SUBTYPE_ASG="asg"

# configurable variables
declare -A vars
vars[f8ai_host]=""
vars[f8ai_user]="admin"
vars[f8ai_pswd]=""
vars[f8ai_granularity]=21600
vars[target_cluster]=""
vars[csv_dir]="."
vars[log_path]="${DEF_LOG_FILE}"

R=$(date "+%s")
RAND=$(expr ${R} + 0)
RANDOM=$((RAND % 10000))
SID=$(((RANDOM % 900 ) + 100))
SPF='['${SID}']'
output_msg="OK"

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
    msg="$*"
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

API_ERROR_KEY="message"

function precheck_federatorai()
{
    retcode=2
    first_node="NOT_FOUND"
    output_msg="Failed to get Federator.ai information"

    url="${HTTPS}://${vars[f8ai_host]}/apis/v1/resources/clusters"

    INPUT=$( "${CURL[@]}" GET "${url}" -H "${HEADER1}" -H "${HEADER2}" 2>/dev/null )
    INPUT_LENGTH="${#INPUT}"
    while IFS='=' read -d $'\n' -r k v
    do
        case "${k}" in
            ${API_ERROR_KEY})
                logging "${ERR}" "Federator.ai Resource API: ${v}"
                retcode=1
                break ;;
            data.*.name)
                if [ "${vars[target_cluster]}" = "" -o "${v}" = "${vars[target_cluster]}" ]
                then
                    retcode=0
                    break
                fi ;;
        esac
    done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )

    if [ "${retcode}" = "2" ]
    then
        output_msg="Failed to connect to ${HTTPS}://${vars[f8ai_host]}"
        echo
        "${CURL[@]}" GET "${url}" -H "${HEADER1}" -H "${HEADER2}"
        echo
    fi
    return ${retcode}
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

function take_a_while()
{
    begin_time=$1
    end_time=$(date "+%s")
    elapsed=$((end_time - begin_time))
    if [ ${elapsed} -gt 30 ]
    then
        echo "(It may take a few minutes to complete...)"
    fi
}

function vm_clusters()
{
    cluster_list=$1
    c_list=()
    retcode=0
    cluster_name=""
    data_source=""
    status_active=""
    cluster_type=""

    url="${HTTPS}://${vars[f8ai_host]}/apis/v1/resources/clusters"

    INPUT=$( "${CURL[@]}" GET "${url}" -H "${HEADER1}" -H "${HEADER2}" 2>/dev/null )
    INPUT_LENGTH="${#INPUT}"
    while IFS='=' read -d $'\n' -r k v
    do
        case "${k}" in
            ${API_ERROR_KEY})
                logging "${ERR}" "Federator.ai resources/clusters API: ${v}"
                retcode=1
                break ;;
            data\.*\.name)
                cluster_name=${v} ;;
            data\.*\.data_source)
                data_source=${v} ;;
            data\.*\.active)
                status_active=${v} ;;
            data\.*\.type)
                cluster_type=${v} ;;
        esac

        if [ "${cluster_name}" != "" -a "${cluster_type}" = "vm" -a "${data_source}" != "vmware" -a "${status_active}" = "true" ]
        then
            if ! [[ " ${c_list[*]} " =~ " ${cluster_name} " ]]
            then
                c_list=( "${c_list[@]}" "${cluster_name}" )
            fi
        fi
        if [ "${cluster_name}" != "" -a "${cluster_type}" != "" -a "${data_source}" != "" -a "${status_active}" != "" ]
        then
            cluster_name=""
            data_source=""
            status_active=""
            cluster_type=""
        fi
    done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )

    eval ${cluster_list}=\( "${c_list[@]}" \)

    if [ ${retcode} -eq 0 ]
    then
        if [ ${#c_list[@]} -eq 0 ]
        then
            logging "${ERR}" "No AWS/GCP/Azure VM cluster is configured."
            retcode=1
        else
            logging "VM clusters: ${c_list[*]}"
        fi
    fi
    return ${retcode}
}

function cluster_vendor()
{
    cluster=$1
    c_vendor=$2
    vendor=""
    retcode=0

    url="${HTTPS}://${vars[f8ai_host]}/apis/v1/resources/clusters/${cluster}"

    INPUT=$( "${CURL[@]}" GET "${url}" -H "${HEADER1}" -H "${HEADER2}" 2>/dev/null )
    INPUT_LENGTH="${#INPUT}"
    while IFS='=' read -d $'\n' -r k v
    do
        case "${k}" in
            ${API_ERROR_KEY})
                logging "${ERR}" "Federator.ai clusters/${cluster} API: ${v}"
                retcode=1
                break ;;
            data\.cluster_vendor)
                vendor=${v}
                break ;;
        esac
    done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )

    if [ "${vendor}" = "" ]
    then
        logging "${ERR}" "Failed to get VM vendor for cluster ${cluster}."
        retcode=1
    else
        eval ${c_vendor}="${vendor}"
        logging "Cluster ${cluster} vendor: ${vendor}"
    fi
    return ${retcode}
}

function cluster_vms()
{
    cluster=$1
    vm_list=$2
    v_list=()
    retcode=0

    url="${HTTPS}://${vars[f8ai_host]}/apis/v1/resources/clusters/${cluster}/nodes?type=vm"

    INPUT=$( "${CURL[@]}" GET "${url}" -H "${HEADER1}" -H "${HEADER2}" 2>/dev/null )
    INPUT_LENGTH="${#INPUT}"
    while IFS='=' read -d $'\n' -r k v
    do
        case "${k}" in
            ${API_ERROR_KEY})
                logging "${ERR}" "Federator.ai clusters/${cluster}/nodes API: ${v}"
                retcode=1
                break ;;
            data\.*\.name)
                vm_name=${v}
                v_list=( "${v_list[@]}" "${vm_name}" ) ;;
        esac
    done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )

    eval ${vm_list}=\( "${v_list[@]}" \)

    if [ ${retcode} -eq 0 ]
    then
        if [ ${#v_list[@]} -eq 0 ]
        then
            logging "${ERR}" "No VM is in cluster ${cluster}."
            retcode=1
        else
            logging "Cluster ${cluster} VMs: ${v_list[*]}"
        fi
    fi
    return ${retcode}
}

function vm_info()
{
    vmname=$1
    vmvendor=$2
    vmregion=$3
    vmsubtype=$4
    vmdatastring=$5
    vmcpu=$6
    vmmem=$7

    retcode=0
    cpu_cores=""
    mem_bytes=""
    subtype=""
    instance_type=""
    region=""
    display_name=""

    [[ "${vmvendor}" = "vmware" ]] && vstring="" || vstring=${vmvendor}

    url="${HTTPS}://${vars[f8ai_host]}/apis/v1/resources/${vstring}/vms?names=${vmname}"

    INPUT=$( "${CURL[@]}" GET "${url}" -H "${HEADER1}" -H "${HEADER2}" 2>/dev/null )
    INPUT_LENGTH="${#INPUT}"
    while IFS='=' read -d $'\n' -r k v
    do
        case "${k}" in
            ${API_ERROR_KEY})
                logging "${ERR}" "Federator.ai resources/${vstring}/vm API (${vmname}): ${v}"
                retcode=1
                break ;;
            data\.*\.cpu_cores)
                cpu_cores=${v} ;;
            data\.*\.memory_bytes)
                mem_bytes=${v} ;;
            data\.*\.io_instance_type)
                instance_type=${v} ;;
            data\.*\.sub_type)
                subtype=${v} ;;
            data\.*\.io_region)
                region=${v} ;;
            data\.*\.display_name)
                display_name=${v} ;;
        esac
    done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )

    if [ "${cpu_cores}" = "" -o "${mem_bytes}" = "" ]
    then
        logging "${WARN}" "RESOURCE: Failed to get VM info for VM ${vmname}"
        return 1
    fi

    eval ${vmsubtype}=\'${subtype}\'
    eval ${vmdatastring}=\'${display_name},${instance_type},${vmregion},${cpu_cores},${mem_bytes}\'
    eval ${vmcpu}=${cpu_cores}
    eval ${vmmem}=${mem_bytes}
    if [ ${retcode} -eq 0 ]
    then
        logging "RESOURCE: ${subtype} VM ${vmname}: ${display_name},${instance_type},${vmregion},${cpu_cores},${mem_bytes}"
    fi
    return ${retcode}
}

function max_in_list()
{
    maxnum=$1
    shift
    num_list=("$@")
    maximum=0
    for n in "${num_list[@]}"
    do
        if [ ${n} -gt ${maximum} ]
        then
            maximum=${n}
        fi
    done
    eval ${maxnum}=${maximum}
}

function vm_predictions()
{
    vmcluster=$1
    vmname=$2
    predstring=$3

    retcode=0
    start_time=${NOW}
    granularity=${vars[f8ai_granularity]}
    pred_mcores=0
    pred_mbytes=0

    while true
    do
        pred_mcores_list=( 0 )
        pred_mbytes_list=( 0 )

        case "${granularity}" in
            604800)
                end_time=$(((${granularity} * 52) + ${start_time})) ;;
            86400)
                end_time=$(((${granularity} * 30) + ${start_time})) ;;
            21600)
                end_time=$(((${granularity} * 28) + ${start_time})) ;;
            3600)
                end_time=$(((${granularity} * 24) + ${start_time})) ;;
            *)
                logging "${ERR}" "Unknown prediction granularity: ${granularity}"
                retcode=1
                break ;;
        esac

        # cluster prediction if vmname == ""
        if [ "${vmname}" = "" ]
        then
            url="${HTTPS}://${vars[f8ai_host]}/apis/v1/predictions/clusters/${vmcluster}?order=desc&startTime=${start_time}&endTime=${end_time}&granularity=${granularity}"
        else
            url="${HTTPS}://${vars[f8ai_host]}/apis/v1/predictions/clusters/${vmcluster}/vms/${vmname}?order=desc&startTime=${start_time}&endTime=${end_time}&granularity=${granularity}"
        fi

        INPUT=$( "${CURL[@]}" GET "${url}" -H "${HEADER1}" -H "${HEADER2}" 2>/dev/null )
        INPUT_LENGTH="${#INPUT}"
        while IFS='=' read -d $'\n' -r k v
        do
            # echo "${k} - ${v}"
            case "${k}" in
                ${API_ERROR_KEY})
                    logging "${ERR}" "Federator.ai predictions [${granularity}] API (${vmcluster}/${vmname}): ${v}"
                    retcode=1
                    break ;;
                data.predictedRawData.cpu\.*\.numValue)
                    pred_mcores_list=( "${pred_mcores_list[@]}" "${v}" ) ;;
                data.predictedRawData.memory\.*\.numValue)
                    pred_mbytes_list=( "${pred_mbytes_list[@]}" "${v}" ) ;;
            esac
        done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )

        max_in_list pred_mcores "${pred_mcores_list[@]}"
        max_in_list pred_mbytes "${pred_mbytes_list[@]}"

        if [ ${granularity} -eq 3600 ]
        then
            break
        fi
        if [ ${pred_mcores} -ne 0 -a ${pred_mbytes} -ne 0 ]
        then
            break
        else
            granularity=3600
        fi
    done

    eval ${predstring}=\'${pred_mcores},${pred_mbytes}\'
    if [ ${retcode} -eq 0 ]
    then
        if [ "${vmname}" = "" ]
        then
            logging "PREDICTION: Cluster ${vmcluster}: ${pred_mcores},${pred_mbytes}"
        else
            logging "PREDICTION: VM ${vmcluster}/${vmname}: ${pred_mcores},${pred_mbytes}"
        fi
    fi
    return ${retcode}
}

function vm_recommendations()
{
    vmcluster=$1
    clusterregion=$2
    recommstring_list=$3
    recommcpu=$4
    recommmem=$5

    retcode=0
    granularity=${vars[f8ai_granularity]}
    start_time=${NOW}
    end_time=$((${start_time} + ${granularity}))

    declare -a recomm_list
    EMPTYVAL=99999
    local vm_name=""
    local vm_cpu=${EMPTYVAL}
    local vm_memory=${EMPTYVAL}
    local vm_instance_type=""
    local vm_master_num=${EMPTYVAL}
    local vm_worker_num=${EMPTYVAL}
    local vm_region=""
    local prev_vm=""
    local rcpu=0
    local rmem=0

    url="${HTTPS}://${vars[f8ai_host]}/apis/v1/costmanagement/clusters/${vmcluster}/recommendations/operations/scaling?granularity=${granularity}&start_time=${start_time}&end_time=${end_time}"
    body="{\"acceptance\":[{}]}"

    INPUT=$( "${CURL[@]}" POST "${url}" -H "${HEADER1}" -H "${HEADER2}" -d "${body}" 2>/dev/null )
    INPUT_LENGTH="${#INPUT}"
    while IFS='=' read -d $'\n' -r k v
    do
        # echo "${k} - ${v}"
        case "${k}" in
            ${API_ERROR_KEY})
                logging "${ERR}" "Federator.ai Cost Management Scaling API: ${v}"
                retcode=1
                break ;;
            0.recommendations.0.nodes\.*\.node_name)
                vm_name=${v}
                vm_cpu=${EMPTYVAL}
                vm_memory=${EMPTYVAL}
                vm_instance_type=""
                vm_master_num=${EMPTYVAL}
                vm_worker_num=${EMPTYVAL} ;;
            0.recommendations.0.nodes\.*\.cpu)
                vm_cpu=${v} ;;
            0.recommendations.0.nodes\.*\.memory)
                vm_memory=${v} ;;
            0.recommendations.0.nodes\.*\.instance_type)
                vm_instance_type=${v} ;;
            0.recommendations.0.nodes\.*\.master_num)
                vm_master_num=${v} ;;
            0.recommendations.0.nodes\.*\.worker_num)
                vm_worker_num=${v} ;;
            0.recommendations.0.region)
                vm_region=${v} ;;
        esac

        if [ "${vm_name}" != "" -a "${vm_cpu}" != "${EMPTYVAL}" -a "${vm_memory}" != "${EMPTYVAL}" -a \
             "${vm_instance_type}" != "" -a "${vm_master_num}" != "${EMPTYVAL}" -a "${vm_worker_num}" != "${EMPTYVAL}" ]
        then
            if [ "${vm_name}" != "${prev_vm}" ]
            then
                if [ ${vm_master_num} -ne 0 -a ${vm_worker_num} -ne 0 ]
                then
                    role="master/worker"
                elif [ ${vm_master_num} -ne 0 ]
                then
                    role="master"
                else
                    role="worker"
                fi
                recomm_list=( "${recomm_list[@]}" "${vm_name}:${role},${vm_instance_type},${vm_cpu},${vm_memory}" )
                prev_vm=${vm_name}
                rcpu=$((${rcpu} + ${vm_cpu}))
                rmem=$((${rmem} + ${vm_memory}))
            fi
        fi
    done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )

    eval ${clusterregion}=\'${vm_region}\'
    eval ${recommstring_list}=\( "${recomm_list[@]}" \)
    eval ${recommcpu}=${rcpu}
    eval ${recommmem}=${rmem}

    if [ ${retcode} -eq 0 ]
    then
        logging "RECOMM: Cluster ${vmcluster}: ${recomm_list[*]}"
    fi
    return ${retcode}
}

function create_vm_csv()
{
    logging "${STDOUT}" "Start collecting VM resource data."

    rm -rf ${vars[csv_dir]}/${VM_IDV_CSV} >/dev/null 2>&1
    rm -rf ${vars[csv_dir]}/${VM_ASG_CSV} >/dev/null 2>&1

    echo "${VER},${NOW},${vars[target_cluster]},${vars[f8ai_granularity]}" >> ${vars[csv_dir]}/${VM_IDV_CSV}
    echo "${VER},${NOW},${vars[target_cluster]},${vars[f8ai_granularity]}" >> ${vars[csv_dir]}/${VM_ASG_CSV}

    if [ "${vars[target_cluster]}" = "" ]
    then
        # get the list of VM clusters
        if ! vm_clusters cluster_list
        then
            return 1
        fi
    else
        cluster_list=( "${vars[target_cluster]}" )
    fi

    declare -A vm_dic
    declare -A vm_recomm_dic

    for cluster_name in "${cluster_list[@]}"
    do
        vm_dic=()
        vm_recomm_dic=()

        # get vendor ('vmware', 'aws', ...)
        if ! cluster_vendor "${cluster_name}" vm_vendor
        then
            continue
        fi

        # get the list of VMs in the cluster
        if ! cluster_vms "${cluster_name}" vm_list
        then
            continue
        fi

        recomm_cpu=0
        recomm_mem=0
        # get the list of VMs' recommendations in the cluster
        if ! vm_recommendations "${cluster_name}" cluster_region vm_recomm_list recomm_cpu recomm_mem
        then
            logging "${WARN}" "No recommendations!"
            # continue
        fi

        for vm_str in "${vm_recomm_list[@]}"
        do
            IFS=':' read -r -a strarr <<< "${vm_str}"
            vm_recomm_dic[${strarr[0]}]=${strarr[1]}
            if ! [[ " ${vm_list[*]} " =~ " ${strarr[0]} " ]]
            then
                vm_list=( "${vm_list[@]}" "${strarr[0]}" )
            fi
        done

        cluster_subtype=""
        cluster_cpu=0
        cluster_mem=0
        vm_subtype=""

        # get VMs' information in the cluster
        for vm_name in "${vm_list[@]}"
        do
            # get VM basic info
            if ! vm_info ${vm_name} "${vm_vendor}" "${cluster_region}" vm_subtype vm_data_string vm_cores vm_mem_bytes
            then
                vm_data_string="${vm_name},-,${cluster_region},,"
                vm_cores=0
                vm_mem_bytes=0
            fi
            cluster_cpu=$((${cluster_cpu} + ${vm_cores}))
            cluster_mem=$((${cluster_mem} + ${vm_mem_bytes}))

            if [ "${vm_recomm_dic[${vm_name}]}" = "" ]
            then
                vm_dic[${vm_name}]="${vm_data_string},-,-,,"
            else
                vm_dic[${vm_name}]="${vm_data_string},${vm_recomm_dic[${vm_name}]}"
            fi

            if [ "${cluster_subtype}" = "" ]
            then
                cluster_subtype=${vm_subtype}
            fi
        done

        csv_file=${vars[csv_dir]}/${VM_IDV_CSV}
        cluster_preds_retrieved="false"

        # get VMs' or cluster's predictions in the cluster
        for vm_name in "${vm_list[@]}"
        do
            # if "individual", get predictions/recommendations per VM
            if [ "${cluster_subtype}" = "${SUBTYPE_IDV}" ]
            then
                if ! vm_predictions ${cluster_name} ${vm_name} vm_pred_string
                then
                    vm_pred_string=","
                fi
                csv_file=${vars[csv_dir]}/${VM_IDV_CSV}
            # if "asg", get predictions/recommendations per cluster
            elif [ "${cluster_subtype}" = "${SUBTYPE_ASG}" ]
            then
                if [ "${cluster_preds_retrieved}" = "false" ]
                then
                    cluster_preds_retrieved="true"
                    if ! vm_predictions ${cluster_name} "" vm_pred_string
                    then
                        vm_pred_string=","
                    fi
                else
                    vm_pred_string=","
                fi
                csv_file=${vars[csv_dir]}/${VM_ASG_CSV}
            fi
            vm_dic[${vm_name}]="${vm_dic[${vm_name}]},${vm_pred_string}"
            logging "${cluster_name} [${vm_subtype}]: ${vm_name} --- ${vm_dic[${vm_name}]}" 

            # write results to CSV
            echo "${cluster_name},${vm_name},${vm_dic[${vm_name}]},${cluster_cpu},${cluster_mem},${recomm_cpu},${recomm_mem}" >> ${csv_file}
            echo -n "."
        done
    done
    echo
}

function banner()
{
    banner_string="Federator.ai VM Resource Collector v${VER}"
    echo ${banner_string}
    logging "${banner_string}"
    echo
}

function show_usage()
{
    cat << __EOF__

${PROG} [options]

Options:
  -h, --host=''           Federator.ai API host(ip:port) (DEFAULT: '127.0.0.1:31012')
  -u, --username=''       Federator.ai API user name (DEFAULT: 'admin')
  -p, --password=''       Federator.ai API password (or read from 'F8AI_API_PASSWORD')
  -c, --cluster=''        Target VM cluster name (all clusters if target VM cluster is not specified)
  -g, --granularity=''    Resource recommendation granularity (DEFAULT: '21600')
  -d, --directory=''      Local directory where .csv files will be saved (DEFAULT: '.')
  -l, --logfile=''        Log file full path (DEFAULT: '${DEF_LOG_FILE}')

Examples:
  ${PROG} --host=127.0.0.1:31012 --username=admin --granularity=21600 --directory=/tmp

__EOF__
    exit 1
}

# arguments
function parse_options()
{
    optspec="h:u:p:c:g:d:l:-:"
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
                    *)
                        if [ "$OPTERR" = 1 ] && [ "${optspec:0:1}" != ":" ]; then
                            echo "ERROR: Invalid argument '--${OPT_ARG}'."
                        fi
                        show_usage
                        exit 1 ;;
                esac ;;
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

# validate options
if [[ ! -z "${F8AI_API_PASSWORD}" ]]
then
    vars[f8ai_pswd]=${F8AI_API_PASSWORD}
fi
if [ "${vars[f8ai_host]}" = "" -o "${vars[f8ai_pswd]}" = "" ]
then
    echo "ERROR: Federator.ai host or password is empty."
    show_usage
    exit 1
fi
HEADER2="authorization: Basic $(echo -n "${vars[f8ai_user]}:${vars[f8ai_pswd]}" |base64)"

logging "Arguments: $*"
for i in "${!vars[@]}"
do
    if [ "${i}" != "f8ai_pswd" ]
    then
        logging "vars[${i}]=${vars[${i}]}"
    fi
done

# pre-checks
if ! precheck_bash_version || ! precheck_federatorai
then
    logging "${STDOUT}" "${ERR}" ${output_msg}
    exit 1
fi

# generate VM csv
if ! create_vm_csv
then
    logging "${STDOUT}" "${ERR}" "Failed to create VM .csv files."
    exit 1
else
    logging "${STDOUT}" "${INFO}" "Successfully created VM .csv: '${vars[csv_dir]}/${VM_IDV_CSV}', '${vars[csv_dir]}/${VM_ASG_CSV}'."
fi
