#!/bin/bash

CURL=( curl -sS -k -X )
F8AI_DOMAIN="172.31.2.63:31012"
METRIC_CONFIG_URL="https://${F8AI_DOMAIN}/series_postgres/getMetricsConfig"
SERIES_URL="https://${F8AI_DOMAIN}/series_datahub/getSeries"
HEADER="Content-Type: application/json"
INPUT_CSV_FILE="k8s-node-to-vm.csv"
OUTPUT_CSV_FILE="k8s-node-to-vm-mapping.csv"

node_mem_config_id=""
vm_mem_config_id=""
cluster_id=""
node_id=""

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

function getMetricsConfig() {
    echo "Fetching metric config id."

    metricRes=$( ${CURL[@]} POST "${METRIC_CONFIG_URL}" \
    -H "$HEADER" \
    --data '{
        "queries": [
            {
                "key": "getBuiltinMetricConfigs",
                "method": "get_builtin_metric_configs",
                "isPostgres": true
            }
        ]
    }')

    node_mem_config_id=$(echo $metricRes | grep -Eo '"node_memory_operationType_1":\{[^}]+\}' | sed -n 's/.*"builtin_metric_config_id":"\([^"]*\)".*/\1/p')
    vm_mem_config_id=$(echo $metricRes | grep -Eo '"node_memory_operationType_9":\{[^}]+\}' | sed -n 's/.*"builtin_metric_config_id":"\([^"]*\)".*/\1/p')

    echo "Node MEM ID is $node_mem_config_id"
    echo "VM MEM ID is $vm_mem_config_id"
    echo "Fetching metric config id is completed."
}

function getMetaByName() {
    results=$( ${CURL[@]} POST "${SERIES_URL}" \
    -H "$HEADER" \
    --data '{
        "queries":[
            {
                "key":"readNodes",
                "datahub_method":"readResourceMeta",
                "request_body":{
                    "query_condition":{
                        "selects": ["cluster_name", "node_name", "cluster_id", "node_id"],
                        "where_condition": [
                            {
                                "keys": ["cluster_name", "node_name"],
                                "values": ['\"${1}\"', '\"${2}\"'],
                                "operators": ["=", "="]
                            }
                        ]
                    }
                }
            }
        ]
    }')
    echo $results
}

function getClusterNodeIDs() {
    cluster_name=$1
    node_name=$2
    result=$(getMetaByName $cluster_name $node_name)

    INPUT=$result
    INPUT_LENGTH="${#INPUT}"

    while IFS='=' read -d $'\n' -r k v
    do
    case "${k}" in
        results.0.values.0.node_id)
            node_id=$v
            echo "node id = ${node_id}"
            ;;
        results.0.values.0.cluster_id)
            cluster_id=$v
            echo "cluster id = ${cluster_id}"
            ;;
    esac
    done < <( parse "" "" <<< "${INPUT}" 2>/dev/null )
}

function getMICID() {
    local cluster_id=$1
    local node_id=$2
    local display_name=$3
    local res=$(kubectl exec federatorai-postgresql-0 -n federatorai -- psql -U postgres -d federatorai -c "select metric_instance_config_id from public.node_metric_instance_configs where cluster_id='${cluster_id}' and node_id='${node_id}' and display_name='node_memory'" --csv)
    echo $(echo $res | grep node_inst | awk '{print $2}')
}

function writeCSV() {
    while IFS=',' read -r cluster_name node_name empty_col3 vm_cluster_name vm_name
    do
        record=""
        IFS=',' read -r vm_name _ <<< "$vm_name" # remove last comma symbol.

        ####### get k8s #######
        getClusterNodeIDs $cluster_name $node_name
        node_mic_id=$(getMICID $cluster_id $node_id)
        record="${cluster_name},${node_name},${node_mic_id},${node_mem_config_id}"
        ####### get k8s #######

        ####### get vm #######
        getClusterNodeIDs $vm_cluster_name $vm_name
        vm_mic_id=$(getMICID $cluster_id $node_id)
        record="${record},${vm_cluster_name},${vm_name},${vm_mic_id},${vm_mem_config_id}"
        ####### get vm #######

        echo "${record}" >> ${OUTPUT_CSV_FILE}
    done < "${INPUT_CSV_FILE}"
}

getMetricsConfig
writeCSV
