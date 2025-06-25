#!/usr/bin/env bash
# The script collects VM data and saves to .csv files for VM recommendation spreadsheet
# Versions:
#   1.0.1 - The first build.
#
VER=1.0.1

# defines
NOW=$(date +"%s")
CURL=( curl -sS -k -X )

VM_CLUSTER_CSV="f8ai-cluster-vms.csv"
DEF_LOG_FILE="/var/log/vm-setup-clusters.log"

# configurable variables
declare -A vars
vars[f8ai_host]="172.31.3.61:31012"
vars[f8ai_user]="admin"
vars[f8ai_pswd]=""
vars[access_key]=""
vars[secret_key]=""
vars[operation]=""
vars[dryrun]="no"
vars[csv_path]=""
vars[log_path]="${DEF_LOG_FILE}"

RANDOM=$(date "+%N")
SID=$((($RANDOM % 900 ) + 100))
SPF='['${SID}']'
output_msg="OK"
access_token=""

API_ERROR_KEY="message"
BEAPI_ERROR_KEY="data.message"

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

function precheck_federatorai()
{
    retcode=1
    first_node="NOT_FOUND"
    output_msg="Failed to log in Federator.ai"

    url="https://${vars[f8ai_host]}/apis/v1/users/login"

    INPUT=$( ${CURL[@]} POST "${url}" -H "${HEADER1}" -H "${HEADER2}" 2>/dev/null )
    INPUT_LENGTH="${#INPUT}"
    while IFS='=' read -d $'\n' -r k v
    do
        case "${k}" in
            ${API_ERROR_KEY})
                logging "${ERR}" "Federator.ai Login API: ${v}"
                retcode=1
                break ;;
            accessToken)
                access_token=${v}
                retcode=0 ;;
        esac
    done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )

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
    elapsed=$((${end_time} - ${begin_time}))
    if [ ${elapsed} -gt 30 ]
    then
        echo "(It may take a few minutes to complete...)"
    fi
}

function is_item_in_list()
{
    local -n item=$1
    local -n list=$2

    if [[ " ${list[*]} " =~ " ${item} " ]]
    then
        return 0
    else
        return 1
    fi
}

declare -A vm_to_cluster
declare -A asg_to_cluster

function vms_in_a_cluster()
{
    local cluster_list=()
    local cluster_name=""
    local retcode=0

    # configured clusters
    url="https://${vars[f8ai_host]}/apis/v1/resources/clusters"

    INPUT=$( ${CURL[@]} GET "${url}" -H "${HEADER1}" -H "${HEADER2}" 2>/dev/null )
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
            data\.*\.cluster_vendor)
                if [ "${v}" = "aws" -a "${cluster_name}" != "" ]
                then
                    cluster_list=( ${cluster_list[@]} ${cluster_name} )
                    cluster_name=""
                fi ;;
        esac
    done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )

    # VMs in configured clusters
    for cn in "${cluster_list[@]}"
    do
        local vn_list=""
        url="https://${vars[f8ai_host]}/apis/v1/resources/clusters/${cn}/nodes?type=vm"

        INPUT=$( ${CURL[@]} GET "${url}" -H "${HEADER1}" -H "${HEADER2}" 2>/dev/null )
        INPUT_LENGTH="${#INPUT}"
        while IFS='=' read -d $'\n' -r k v
        do
            case "${k}" in
                ${API_ERROR_KEY})
                    logging "${ERR}" "Federator.ai resources/clusters/nodes API: ${v}"
                    retcode=1
                    break ;;
                data\.*\.name)
                    vn_list="${vn_list} ${v}"
                    vm_to_cluster[${v}]=${cn} ;;
            esac
        done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )

        logging "Existing cluster ${cn}: ${vn_list}"
    done

    return ${retcode}
}

function asg_in_a_cluster()
{
    local asg_name=""
    local retcode=0

    # configured clusters
    url="https://${vars[f8ai_host]}/apis/v1/resources/aws/asg"

    INPUT=$( ${CURL[@]} GET "${url}" -H "${HEADER1}" -H "${HEADER2}" 2>/dev/null )
    INPUT_LENGTH="${#INPUT}"
    while IFS='=' read -d $'\n' -r k v
    do
        case "${k}" in
            ${API_ERROR_KEY})
                logging "${ERR}" "Federator.ai resources/aws/asg API: ${v}"
                retcode=1
                break ;;
            data\.*\.name)
                asg_name=${v} ;;
            data\.*\.cluster_name)
                if [ "${asg_name}" != "" -a "${v}" != "" ]
                then
                    logging "Existing ASG cluster ${v}: ${asg_name}"
                    asg_to_cluster[${asg_name}]=${v}
                    asg_name=""
                fi ;;
        esac
    done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )

    return ${retcode}
}

function is_individual_cluster_created()
{
    local cluster_name=$1

    for vn in "${!vm_to_cluster[@]}"
    do
        if [ "${cluster_name}" = "${vm_to_cluster[${vn}]}" ]
        then
            return 0
        fi
    done
    return 1
}

function is_asg_cluster_created()
{
    local cluster_name=$1

    for an in "${!asg_to_cluster[@]}"
    do
        if [ "${cluster_name}" = "${asg_to_cluster[${an}]}" ]
        then
            return 0
        fi
    done
    return 1
}

declare -a idv_vm_names
declare -a idv_vm_uids
declare -a idv_vm_displays
declare -a idv_vm_instances
declare -a idv_vm_regions
declare -a idv_vm_vendors
declare -a idv_vm_states

function aws_individual_vms()
{
    vm_cnt=0

    url="https://${vars[f8ai_host]}/apis/v1/resources/aws/vms?sub_type=individual"

    INPUT=$( ${CURL[@]} GET "${url}" -H "${HEADER1}" -H "${HEADER2}" 2>/dev/null )
    INPUT_LENGTH="${#INPUT}"
    while IFS='=' read -d $'\n' -r k v
    do
        case "${k}" in
            ${API_ERROR_KEY})
                logging "${ERR}" "Federator.ai resources/clusters API: ${v}"
                retcode=1
                break ;;
            data\.*\.name)
                idv_vm_names[${vm_cnt}]=${v} ;;
            data\.*\.uid)
                idv_vm_uids[${vm_cnt}]=${v} ;;
            data\.*\.io_instance_type)
                idv_vm_instances[${vm_cnt}]=${v} ;;
            data\.*\.vendor)
                idv_vm_vendors[${vm_cnt}]=${v} ;;
            data\.*\.io_region)
                idv_vm_regions[${vm_cnt}]=${v} ;;
            data\.*\.state)
                idv_vm_states[${vm_cnt}]=${v} ;;
            data\.*\.display_name)
                idv_vm_displays[${vm_cnt}]=${v}
                vm_cnt=$((${vm_cnt} + 1)) ;;
        esac
    done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )
}

declare -a asg_group_names
declare -a asg_vendors
declare -a asg_regions
declare -a asg_states

function aws_asg_groups()
{
    local asg_cnt=0
    local asg_group_name=""
    local asg_vendor=""
    local asg_region=""
    local asg_state=""

    url="https://${vars[f8ai_host]}/apis/v1/resources/aws/vms?sub_type=asg"

    INPUT=$( ${CURL[@]} GET "${url}" -H "${HEADER1}" -H "${HEADER2}" 2>/dev/null )
    INPUT_LENGTH="${#INPUT}"
    while IFS='=' read -d $'\n' -r k v
    do
        #echo "${k} = ${v}"
        case "${k}" in
            ${API_ERROR_KEY})
                logging "${ERR}" "Federator.ai aws/vms API: ${v}"
                retcode=1
                break ;;
            data\.*\.group_name)
                asg_group_name=${v} ;;
            data\.*\.vendor)
                asg_vendor=${v} ;;
            data\.*\.io_region)
                asg_region=${v} ;;
            data\.*\.state)
                asg_state=${v}
                if ! is_item_in_list asg_group_name asg_group_names
                then
                    asg_group_names[${asg_cnt}]=${asg_group_name}
                    asg_vendors[${asg_cnt}]=${asg_vendor}
                    asg_regions[${asg_cnt}]=${asg_region}
                    asg_states[${asg_cnt}]=${asg_state}
                    asg_cnt=$((${asg_cnt} + 1))
                fi
                asg_group_name=""
                asg_vendor=""
                asg_region=""
                asg_state="" ;;
        esac
    done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )
}

declare -a idv_cluster_list
declare -a idv_vm_clusters
declare -a asg_cluster_list
declare -a asg_clusters

function read_clusters_from_csv()
{
    if [ ! -e ${vars[csv_path]} ]
    then
        logging "${STDOUT}" "${ERR}" "CSV file ${vars[csv_path]} does not exist."
        return 1
    fi

    idv_cnt=0
    asg_cnt=0
    is_header=1
    while IFS=',' read -d $'\n' -r c_name c_type v_name v_uid v_display v_instance v_vendor v_region v_state
    do
        if [ "${is_header}" = "1" ]
        then
            if [ "${c_name}" != "Cluster" ]
            then
                logging "${STDOUT}" "${ERR}" "CSV file ${vars[csv_path]} does not have a valid header line."
                return 1
            fi
            is_header=0
            continue
        fi

        if [ "${c_type}" = "individual" ]
        then
            if ! is_item_in_list c_name idv_cluster_list
            then
                idv_cluster_list=( ${idv_cluster_list[@]} ${c_name} )
            fi
            idv_vm_clusters[${idv_cnt}]=${c_name}
            idv_vm_names[${idv_cnt}]=${v_name}
            idv_vm_uids[${idv_cnt}]=${v_uid}
            idv_vm_displays[${idv_cnt}]=${v_display}
            idv_vm_instances[${idv_cnt}]=${v_instance}
            idv_vm_vendors[${idv_cnt}]=${v_vendor}
            idv_vm_regions[${idv_cnt}]=${v_region}
            idv_vm_states[${idv_cnt}]=${v_state}
            idv_cnt=$((${idv_cnt} + 1))
            logging "Read individual VM: ${c_name} ${v_name} ${v_display} ${v_instance}"
        elif [ "${c_type}" = "asg" ]
        then
            if ! is_item_in_list c_name asg_cluster_list
            then
                asg_cluster_list=( ${asg_cluster_list[@]} ${c_name} )
            fi
            asg_clusters[${asg_cnt}]=${c_name}
            asg_group_names[${asg_cnt}]=${v_name}
            asg_vendors[${asg_cnt}]=${v_vendor}
            asg_regions[${asg_cnt}]=${v_region}
            asg_states[${asg_cnt}]=${v_state}
            asg_cnt=$((${asg_cnt} + 1))
            logging "Read ASG: ${c_name} ${v_name}"
        else
            logging "${STDOUT}" "${WARN}" "Unsupported VM cluster type: ${c_type}"
        fi
    done < "${vars[csv_path]}"
    return 0
}

function lookup_idv_cluster_region()
{
    local cluster_name=$1
    local region=$2
    local retcode=1
    local cnt=0
    while [ ${cnt} -lt ${#idv_vm_clusters[@]} ]
    do
        if [ "${idv_vm_clusters[${cnt}]}" = "${cluster_name}" ]
        then
            logging "Individual cluster ${cluster_name} region is ${idv_vm_regions[${cnt}]}"
            eval ${region}=${idv_vm_regions[${cnt}]}
            retcode=0
            break
        fi
        cnt=$((${cnt} + 1))
    done
    return ${retcode}
}

function lookup_asg_cluster_region_and_asg()
{
    local cluster_name=$1
    local region=$2
    local asg=$3
    local retcode=1
    local cnt=0
    while [ ${cnt} -lt ${#asg_clusters[@]} ]
    do
        if [ "${asg_clusters[${cnt}]}" = "${cluster_name}" ]
        then
            logging "ASG cluster ${cluster_name} region is ${asg_regions[${cnt}]}"
            eval ${region}=${asg_regions[${cnt}]}
            eval ${asg}=${asg_group_names[${cnt}]}
            retcode=0
            break
        fi
        cnt=$((${cnt} + 1))
    done
    return ${retcode}
}

function aws_test_connection()
{
    region=$1
    retcode=1
    url="https://${vars[f8ai_host]}/testconnection_aws"
    data=$( cat << __EOF__
    {
        "region": "${region}",
        "access_id": "${vars[access_key]}",
        "access_key": "${vars[secret_key]}"
    }
__EOF__
    )

    INPUT=$( ${CURL[@]} PUT "${url}" -H "${HEADER3}" --data-raw "${data}" 2>/dev/null )
    INPUT_LENGTH="${#INPUT}"
    while IFS='=' read -d $'\n' -r k v
    do
        #echo "${k} = ${v}"
        case "${k}" in
            ${BEAPI_ERROR_KEY})
                output_msg="${v}"
                logging "${ERR}" "Federator.ai test connection API: ${v}"
                retcode=1
                break ;;
            code)
                if [ "${v}" = "200" ]
                then
                    logging "Federator.ai test connection API: ${v}"
                    retcode=0
                    break
                fi ;;
        esac
    done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )
    return ${retcode}
}

function create_update_vm_cluster()
{
    local oper=$1
    local cluster_name=$2
    local cluster_region=$3
    
    if [ "${oper}" = "Create" ]
    then
        method="POST"
        historical_state="disabled"
        historical_endtime=0
        historical_starttime=0
    elif [ "${oper}" = "Update" ]
    then
        method="PUT"
        historical_state="collecting"
        historical_endtime=${NOW}
        historical_starttime=$((${historical_endtime} - 7776000)) # 90 days
    else
        return 1
    fi

    if [ "${vars[dryrun]}" = "yes" ]
    then
        echo "${oper} VM cluster: ${cluster_name} region: ${cluster_region}"
        return 0
    fi

    local retcode=1
    url="https://${vars[f8ai_host]}/rest_api"
    data=$( cat << __EOF__
    {
      "api_url": "/configs/organization/clusters",
      "method": "${method}",
      "body": {
        "clusters": [
          {
            "name": "${cluster_name}",
            "type": 2,
            "data_source": {
              "type": 5,
              "keys": [
                {
                  "key": "${vars[access_key]}",
                  "function": 1
                },
                {
                  "key": "${vars[secret_key]}",
                  "function": 4
                },
                {
                  "key": "${cluster_region}",
                  "function": 3
                }
              ]
            },
            "watched_namespace": {
              "names": [
                "openshift-*",
                "kube-public",
                "kube-service-catalog",
                "kube-system",
                "management-infra",
                "openshift",
                "kube-node-lease",
                "stackpoint-system",
                "marketplace"
              ],
              "operator": 2
            },
            "historical_data_collecting": {
              "state": "${historical_state}",
              "start_time": ${historical_starttime},
              "end_time": ${historical_endtime}
            },
            "features": [
              {
                "cost_analysis_feature": {
                  "feature_meta": {
                    "enabled": true,
                    "mode": 1,
                    "option_map": {
                      "pricebook/name": "default"
                    }
                  }
                }
              }
            ],
            "init_namespace_state": 2
          }
        ]
      },
      "token": "${access_token}"
    }
__EOF__
    )

    INPUT=$( ${CURL[@]} PUT "${url}" -H "${HEADER3}" --data-raw "${data}" 2>/dev/null )
    INPUT_LENGTH="${#INPUT}"
    while IFS='=' read -d $'\n' -r k v
    do
        #echo "${k} = ${v}"
        case "${k}" in
            ${BEAPI_ERROR_KEY})
                output_msg="${v}"
                logging "${ERR}" "Federator.ai create/update VM cluster API: ${v}"
                retcode=1
                break ;;
            code)
                if [ "${v}" = "200" ]
                then
                    logging "Federator.ai create/update VM cluster API: ${v}"
                    retcode=0
                    break
                fi ;;
        esac
    done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )
    return ${retcode}
}

function build_idv_vms_list()
{
    local cluster_name=$1
    local vms_array=$2
    local names_array=$3
    local vm_data=""
    local vm_names=""
    local vm_data_format="{ \"uid\": \"%s\", \"name\": \"%s\", \"evictable\": false }"

    local cnt=0
    while [ ${cnt} -lt ${#idv_vm_names[@]} ]
    do
        if [ "${idv_vm_clusters[${cnt}]}" = "${cluster_name}" ]
        then
            logging "Append VM ${idv_vm_names[${cnt}]} to cluster ${cluster_name} VM list"
            one_vm=$( printf "${vm_data_format}" "${idv_vm_uids[${cnt}]}" "${idv_vm_names[${cnt}]}" )
            vm_data="${vm_data}, ${one_vm}"
            vm_names="${vm_names}, ${idv_vm_names[${cnt}]}"
        fi
        cnt=$((${cnt} + 1))
    done

    if [ "${vm_data}" != "" ]
    then
        vm_data=${vm_data#, }
        vm_names=${vm_names#, }
        logging "Cluster ${cluster_name} VM list: ${vm_data}"
        eval ${vms_array}=\'${vm_data}\'
        eval ${names_array}=\"${vm_names}\"
        return 0
    fi
    return 1
}

function assign_vms_to_cluster()
{
    local cluster_name=$1
    local retcode=1

    if ! build_idv_vms_list ${cluster_name} vms_list vm_names_list
    then
        logging "Skip editing cluster ${cluster_name}: VM list is empty"
        return 1
    fi

    if [ "${vars[dryrun]}" = "yes" ]
    then
        echo "Assign VMs to individual cluster: ${cluster_name} VMs: ${vm_names_list}"
        return 0
    fi

    url="https://${vars[f8ai_host]}/rest_api"
    data=$( cat << __EOF__
    {
      "api_url": "/resources/allocatevms",
      "method": "PUT",

      "body": {
        "vendor": "aws",
        "clustername": "${cluster_name}",
        "vms": [
          ${vms_list}
        ]
      },
      "token": "${access_token}"
    }
__EOF__
    )

    INPUT=$( ${CURL[@]} POST "${url}" -H "${HEADER3}" --data-raw "${data}" 2>/dev/null )
    INPUT_LENGTH="${#INPUT}"
    while IFS='=' read -d $'\n' -r k v
    do
        #echo "${k} = ${v}"
        case "${k}" in
            ${BEAPI_ERROR_KEY})
                output_msg="${v}"
                logging "${ERR}" "Federator.ai allocate individual cluster API: ${v}"
                retcode=1
                break ;;
            code)
                if [ "${v}" = "200" ]
                then
                    logging "Federator.ai allocate individual cluster API: ${v}"
                    logging "${STDOUT}" "Successfully create and update individual cluster ${cluster_name} (${vm_names_list})"
                    retcode=0
                    break
                fi ;;
        esac
    done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )
    return ${retcode}
}

function assign_asg_to_cluster()
{
    local cluster_name=$1
    local cluster_asg_group=$2
    
    if [ "${vars[dryrun]}" = "yes" ]
    then
        echo "Assign ASG to individual cluster: ${cluster_name} ASG Group: ${cluster_asg_group}"
        return 0
    fi

    local retcode=1
    url="https://${vars[f8ai_host]}/rest_api"
    data=$( cat << __EOF__
    {
      "api_url": "/resources/aws/allocateasg",
      "method": "PUT",
      "body": {
        "clustername": "${cluster_name}",
        "asg": [
          {
            "name": "${cluster_asg_group}"
          }
        ]
      },
      "token": "${access_token}"
    }
__EOF__
    )

    INPUT=$( ${CURL[@]} POST "${url}" -H "${HEADER3}" --data-raw "${data}" 2>/dev/null )
    INPUT_LENGTH="${#INPUT}"
    while IFS='=' read -d $'\n' -r k v
    do
        #echo "${k} = ${v}"
        case "${k}" in
            ${BEAPI_ERROR_KEY})
                output_msg="${v}"
                logging "${ERR}" "Federator.ai allocate ASG cluster API: ${v}"
                retcode=1
                break ;;
            code)
                if [ "${v}" = "200" ]
                then
                    logging "Federator.ai allocate ASG cluster API: ${v}"
                    logging "${STDOUT}" "Successfully create and update ASG cluster ${cluster_name} (${cluster_asg_group})"
                    retcode=0
                    break
                fi ;;
        esac
    done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )
    return ${retcode}
}

function create_cluster_vm_csv()
{
    # write header to csv
    echo "Cluster,Type,Name,UID,Display Name,Instance Type,Vendor,Region,State" > ${vars[csv_path]}

    # generate individual VMs"
    if ! aws_individual_vms
    then
        logging "${STDOUT}" "${ERR}" "Failed to retrieve VM list for individual clusters."
        return 1
    else
        i=0
        while [ ${i} -lt ${#idv_vm_names[@]} ]
        do
            echo "${vm_to_cluster[${idv_vm_names[${i}]}]},individual,${idv_vm_names[${i}]},${idv_vm_uids[${i}]},${idv_vm_displays[${i}]},${idv_vm_instances[${i}]},${idv_vm_vendors[${i}]},${idv_vm_regions[${i}]},${idv_vm_states[${i}]}" >> ${vars[csv_path]}
            i=$((${i} + 1))
        done
    fi

    # generate ASGs"
    if ! aws_asg_groups
    then
        logging "${STDOUT}" "${ERR}" "Failed to retrieve ASG list for ASG clusters."
        return 1
    else
        i=0
        while [ ${i} -lt ${#asg_group_names[@]} ]
        do
            echo "${asg_to_cluster[${asg_group_names[${i}]}]},asg,${asg_group_names[${i}]},,,,${asg_vendors[${i}]},${asg_regions[${i}]},${asg_states[${i}]}" >> ${vars[csv_path]}
            i=$((${i} + 1))
        done
    fi

    logging "${STDOUT}" "${INFO}" "Successfully create VM/ASG CSV for VM clusters: '${vars[csv_path]}'."
    return 0
}

function create_vm_clusters()
{
    # create/update individual clusters
    for cn in "${idv_cluster_list[@]}"
    do
        # get region of the cluster
        if ! lookup_idv_cluster_region ${cn} cluster_region
        then
            logging "${STDOUT}" "${ERR}" "Failed to get region of individual cluster ${cn}"
            return 1
        fi

        # test connection
        if ! aws_test_connection ${cluster_region}
        then
            logging "${STDOUT}" "${ERR}" "Test connection is failed: ${output_msg}"
            return 1
        fi

        # add cluster if not exists
        if ! is_individual_cluster_created ${cn}
        then
            if ! create_update_vm_cluster "Create" ${cn} ${cluster_region}
            then
                logging "${STDOUT}" "${ERR}" "Failed to add new individual cluster ${cn}: ${output_msg}"
                return 1
            fi
        fi

        # assign VMs to the cluster
        if ! assign_vms_to_cluster ${cn}
        then
            logging "${STDOUT}" "${ERR}" "Failed to assign VMs to individual cluster ${cn}: ${output_msg}"
            return 1
        fi

        # enable collecting historical data (best effort)
        create_update_vm_cluster "Update" ${cn} ${cluster_region}
    done

    # create/update ASG clusters
    for cn in "${asg_cluster_list[@]}"
    do
        # get region of the cluster
        if ! lookup_asg_cluster_region_and_asg ${cn} cluster_region cluster_asg
        then
            logging "${STDOUT}" "${ERR}" "Failed to get region of ASG cluster ${cn}"
            return 1
        fi

        # test connection
        if ! aws_test_connection ${cluster_region}
        then
            logging "${STDOUT}" "${ERR}" "Test connection is failed: ${output_msg}"
            return 1
        fi

        # add cluster if not exists
        if ! is_asg_cluster_created ${cn}
        then
            if ! create_update_vm_cluster "Create" ${cn} ${cluster_region}
            then
                logging "${STDOUT}" "${ERR}" "Failed to add new ASG cluster ${cn}: ${output_msg}"
                return 1
            fi
        fi

        # assign VMs to the cluster
        if ! assign_asg_to_cluster ${cn} ${cluster_asg}
        then
            logging "${STDOUT}" "${ERR}" "Failed to assign ASG to cluster ${cn}: ${output_msg}"
            return 1
        fi

        # enable collecting historical data (best effort)
        create_update_vm_cluster "Update" ${cn} ${cluster_region}
    done
    return 0
}

function banner()
{
    banner_string="Federator.ai VM Clustersv ${VER}"
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
  -a, --accesskey=''      AWS CloudWatch access key (or read from 'AWS_ACCESS_KEY_ID')
  -s, --secretkey=''      AWS CloudWatch secret access key (or read from 'AWS_SECRET_ACCESS_KEY')
  -o, --operation=''      Operation 'collect'(save VMs to CSV) or 'create'(create clusters defined in CSV) 
  -r, --dryrun=''         Whether to create/update VM clusters (DEFAULT: 'no')
  -f, --csvpath=''        CSV file fulll path (DEFAULT: './${VM_CLUSTER_CSV}')
  -l, --logfile=''        Log file full path (DEFAULT: '${DEF_LOG_FILE}')

Examples: 
  # export F8AI_API_PASSWORD=*** ; export AWS_ACCESS_KEY_ID=*** ; export AWS_SECRET_ACCESS_KEY=***
  ${PROG} --host=127.0.0.1:31012 --operation collect --username=admin --csvpath=/tmp/f8ai-cluster-vms.csv
  ${PROG} --host=127.0.0.1:31012 --operation create --username=admin --csvpath=/tmp/f8ai-cluster-vms.csv --dryrun=yes

__EOF__
    exit 1
}

# arguments
function parse_options()
{
    optspec="h:u:p:a:s:o:r:f:l:-:"
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
                    accesskey)
                        vars[access_key]="${OPT_VAL}" ;;
                    secretkey)
                        vars[secret_key]="${OPT_VAL}" ;;
                    operation)
                        vars[operation]=$(lower_case "${OPT_VAL}") ;;
                    dryrun)
                        vars[dryrun]=$(lower_case "${OPT_VAL}") ;;
                    csvpath)
                        vars[csv_path]="${OPT_VAL}" ;;
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
            a)
                vars[access_key]="${OPTARG}" ;;
            s)
                vars[secret_key]="${OPTARG}" ;;
            o)
                vars[operation]=$(lower_case "${OPTARG}") ;;
            r)
                vars[dryrun]=$(lower_case "${OPTARG}") ;;
            f)
                vars[csv_path]="${OPTARG}" ;;
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

# trim "https://" from host
vars[f8ai_host]=${vars[f8ai_host]#https://}
vars[f8ai_host]=${vars[f8ai_host]#http://}

# validate options
if [[ ! -z "${F8AI_API_PASSWORD}" ]]
then
    vars[f8ai_pswd]=${F8AI_API_PASSWORD}
fi
if [[ ! -z "${AWS_ACCESS_KEY_ID}" ]]
then
    vars[access_key]=${AWS_ACCESS_KEY_ID}
fi
if [[ ! -z "${AWS_SECRET_ACCESS_KEY}" ]]
then
    vars[secret_key]=${AWS_SECRET_ACCESS_KEY}
fi

if [ "${vars[f8ai_host]}" = "" -o "${vars[f8ai_pswd]}" = "" ]
then
    echo "ERROR: Federator.ai host or password is empty."
    show_usage
    exit 1
fi
HEADER2="authorization: Basic $(echo -n "${vars[f8ai_user]}:${vars[f8ai_pswd]}" |base64)"

# operation 'collect' or 'create'
if [ "${vars[operation]}" = "collect" ]
then
    if [ "${vars[csv_path]}" = "" ]
    then
        vars[csv_path]="./${VM_CLUSTER_CSV}"
    fi
elif [ "${vars[operation]}" = "create" ]
then
    if [ "${vars[csv_path]}" = "" ]
    then
        echo "ERROR: CSV file ('-f') is required for operation 'create'."
        show_usage
        exit 1
    fi
    if [ "${vars[access_key]}" = "" -o "${vars[secret_key]}" = "" ]
    then
        echo "ERROR: Access Key and Secret Access Key are required for operator 'create'."
        show_usage
        exit 1
    fi
else
    echo "ERROR: Operation is 'collect' or 'create'."
    show_usage
    exit 1
fi

logging "Arguments: $@"
for i in "${!vars[@]}"
do
    if [ "${i}" != "f8ai_pswd" -a "${i}" != "access_key" -a "${i}" != "secret_key" ]
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

if [ "${vars[operation]}" = "collect" ] # 'collect' operation
then
    if [ -e ${vars[csv_path]} ]
    then
        logging "${STDOUT}" "${ERR}" "CSV file ${vars[csv_path]} already exists."
        exit 1
    fi

    # already assigned VMs/ASGs and clusters
    vms_in_a_cluster
    asg_in_a_cluster

    if ! create_cluster_vm_csv
    then
        exit 1
    fi
elif [ "${vars[operation]}" = "create" ] # 'create' operation
then
    if ! read_clusters_from_csv 
    then
        logging "${ERROR}" "Failed to read clusters/VMs configuration from CSV file '${vars[csv_path]}'."
        exit 1
    fi

    # already assigned VMs/ASGs and clusters
    vms_in_a_cluster
    asg_in_a_cluster

    if ! create_vm_clusters
    then
        exit 1
    fi
fi
