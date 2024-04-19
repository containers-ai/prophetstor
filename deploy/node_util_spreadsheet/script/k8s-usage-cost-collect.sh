#!/bin/bash
# The script collects cluster nodes/applications usage and cost statistics and saves to .csv files for node usage spreadsheet
# Versions:
#   1.0.0 - The first build.
#
VER=1.0.0

# defines
JQ="${JQ:-jq}"
CURL=( curl -sS -L -k -X )

HTTPS="https"
NOW="${NOW:-$(date +"%s")}"
DAYS_PER_API="${DAYS_PER_API:-10}"    # Each RestAPI only retrieve this days
# Compute TZ offset seconds, e.g. +08:00 => '-8 * 3600' => '-28800'
o=$(date +%:z | cut -c1)
h=$(date +%:z | tr -d '+-' | awk -F: '{print $1}')
m=$(date +%:z | tr -d '+-' | awk -F: '{print $2}')
if [ "$(date +%:z | cut -c1)" = "-" ]; then
    COST_TZ_OFFSET_SECONDS="+ $(expr $h \* 3600 + $m \* 60)"
else
    COST_TZ_OFFSET_SECONDS="- $(expr $h \* 3600 + $m \* 60)"
fi

NODE_COUNT_CSV="node-count-raw.csv"
NODE_CPU_CSV="node-cpu-raw.csv"
NODE_MEM_CSV="node-mem-raw.csv"
NODE_COST_CSV="node-cost-raw.csv"
APP_CPU_CSV="app-cpu-raw.csv"
APP_MEM_CSV="app-mem-raw.csv"
APP_COST_CSV="app-cost-raw.csv"
CTRL_CPU_CSV="ctrl-cpu-raw.csv"
CTRL_MEM_CSV="ctrl-mem-raw.csv"
DEF_LOG_FILE="./k8s-usage-cost-collect.log"

F8AI_VERSION="5.1.5"
F8AI_BUILD="2297"

# configurable variables
declare -A vars
vars[f8ai_host]="172.31.3.61:31012"
vars[f8ai_user]="admin"
vars[f8ai_pswd]=""
vars[target_cluster]=""
vars[csv_dir]="."
vars[resource_type]="both"
vars[log_path]="${DEF_LOG_FILE}"
vars[past_period]="183"

# Generate session id
R=$(date "+%s")
RAND=$(expr ${R} + 0)
RANDOM=$((${RAND} % 10000))
SID=$((($RANDOM % 900 ) + 100))
SPF='['${SID}']'
output_msg="OK"

bmc_cost_allocation_node_3600=""
bmc_cost_allocation_application_3600=""

INFO=" INFO"
WARN=" WARN"
ERR="ERROR"
STAGE="STAGE"
STDOUT="STDOUT"

function logging()
{
    local stdout=""
    local level="${INFO}"
    if [ "$1" = "" ]; then
        return 0
    fi
    if [ "$1" = "${STDOUT}" ]; then
        stdout="$1"
        shift
    fi
    if [ "$1" = "${INFO}" -o "$1" = "${WARN}" -o "$1" = "${ERR}" -o "$1" = "${STAGE}" ]; then
        level="$1"
        shift
    fi
    msg="$@"
    if [ "${msg}" = "" ]; then
        return 0
    fi

    echo -e "${SPF} $(date '+%F %T') ${level}: ${msg}" >> ${vars[log_path]}

    if [ "${stdout}" = "${STDOUT}" ]; then
        if [ "${level}" = "${INFO}" ]; then
            echo -e "${msg}"
        else
            echo -e "${level}: ${msg}"
        fi
    fi
}

function write_logs()
{
    while read line; do
        echo "${SPF} ${line}"
    done
}

function precheck_bash_version()
{
    major_ver=${BASH_VERSION:0:1}
    if [ "${major_ver}" != "" ]; then
        if [ ${major_ver} -lt 4 ]; then
            output_msg="Bash version 4 and above is required."
            return 1
        fi
    fi

    logging "Bash Version: ${BASH_VERSION}"
}

function precheck_utils()
{
    # We need jq >= 1.6
    jq_version=$(jq --version | cut -c 4-)
    major=$(echo ${jq_version} | cut -d. -f 1)
    minor=$(echo ${jq_version} | cut -d. -f 2)
    pass=0
    [ "0${major}" -gt "1" ] && pass=1
    [ "0${major}" -eq "1" -a "0${minor}" -ge "6" ] && pass=1
    if [ "${pass}" != "1" ]; then
        output_msg="Required command 'jq >= 1.6' does not exist.\nYou can download jq from url https://jqlang.github.io/jq/download/"
        logging "${ERR}" "${output_msg}"
        return 1
    fi
    logging "Jq Version: ${jq_version}"

    utils=( numfmt bc base64 date grep awk tr )
    for util in "${utils[@]}"; do
        ${util} --help >/dev/null 2>&1
        ret=$?
        if [ ${ret} -ne 0 ]; then
            logging "${ERR}" "Required command '${util}' does not exist."
            output_msg="Required command '${util}' does not exist"
            return 1
        fi
    done
}

function precheck_federatorai_version()
{
    retcode=2
    url="${HTTPS}://${vars[f8ai_host]}/apis/v1/version"

    INPUT=$( "${CURL[@]}" GET "${url}" -H "${HEADER1}" -H "${HEADER2}" 2>/dev/null )
    if [ "$?" != "0" -o "$(echo ${INPUT} | ${JQ} '.message')" != "null" ]; then
        output_msg="Failed to connect to ${HTTPS}://${vars[f8ai_host]}"
        echo "${ERR}" "${output_msg}"
        logging "${ERR}" "${output_msg}"
        exit 1
    fi
    F8AI_VERSION=$(echo "${INPUT}" | jq .version)
    F8AI_BUILD=$(echo "${INPUT}" | jq .build)
    logging "${INFO}" "Federator.ai Version: ${F8AI_VERSION} Build: ${F8AI_BUILD}"

    return 0
}

function precheck_federatorai()
{
    retcode=2
    first_node="NOT_FOUND"
    output_msg="Target cluster: ${vars[target_cluster]} is not configured in Federator.ai"

    url="${HTTPS}://${vars[f8ai_host]}/apis/v1/resources/clusters/${vars[target_cluster]}/nodes"

    INPUT=$( "${CURL[@]}" GET "${url}" -H "${HEADER1}" -H "${HEADER2}" 2>/dev/null )
    if [ "$?" != "0" -o "$(echo ${INPUT} | ${JQ} '.message')" != "null" ]; then
        output_msg="Failed to connect to ${HTTPS}://${vars[f8ai_host]}"
        echo "${ERR}" "${output_msg}"
        logging "${ERR}" "${output_msg}"
        exit 1
    fi
    if [ "${INPUT}" = '{"data":[]}' ]; then
        output_msg="Target cluster: ${vars[target_cluster]} is not configured in Federator.ai"
        echo "${ERR}" "${output_msg}"
        logging "${ERR}" "${output_msg}"
        exit 1
    fi
    
    return 0
}

###############################################################################
###############################################################################

HEADER1="accept: application/json"
HEADER2="authorization: Basic $(echo -n "${vars[f8ai_user]}:${vars[f8ai_pswd]}" | base64)"
HEADER3="Content-Type: application/json"

function create_controller_csv()
{
    echo
    logging "${STDOUT}" "Start collecting Application and Controller data:"

    app_cpu_csv_filename="${vars[csv_dir]}/${APP_CPU_CSV}"
    app_mem_csv_filename="${vars[csv_dir]}/${APP_MEM_CSV}"
    app_cost_csv_filename="${vars[csv_dir]}/${APP_COST_CSV}"
    ctrl_cpu_csv_filename="${vars[csv_dir]}/${CTRL_CPU_CSV}"
    ctrl_mem_csv_filename="${vars[csv_dir]}/${CTRL_MEM_CSV}"
    rm -fv ${app_cpu_csv_filename} ${app_mem_csv_filename} ${app_cost_csv_filename} \
           ${ctrl_cpu_csv_filename} ${ctrl_mem_csv_filename}

    appctl_list=$(collect_app_and_controller_configs ${vars[target_cluster]})
    if [ "$?" != "0" -o "${appctl_list}" = "" ]; then
        echo "${ERR}" "Error in finding application/controller."
        logging "${ERR}" "Error in finding application/controller."
        exit 1
    fi

    echo
    cpu_list=""
    mem_list=""
    end_time=${NOW}

    # Compute start data, e.g. 2023-06-28
    start_time=$(expr ${NOW} / 86400 \* 86400 - ${vars[past_period]} \* 86400)
    date_str=$(date -d @${start_time} +%F)
    header="${date_str},${VER},${NOW},${vars[target_cluster]}"
    echo "${header}" > ${app_cpu_csv_filename}.tmp
    echo "${header}" > ${app_mem_csv_filename}.tmp
    echo "${header}" > ${app_cost_csv_filename}.tmp
    echo "${header}" > ${ctrl_cpu_csv_filename}.tmp
    echo "${header}" > ${ctrl_mem_csv_filename}.tmp

    # Prepare date string list ${date_list}
    # Format: <val_day1> <val_day2> ... <val_dayn>
    #  e.g. 2023-06-28 2023-06-29 ... 2023-12-28
    ts=${start_time}
    date_list=""
    while [ ${ts} -lt ${NOW} ]; do
        if [ "${date_list}" = "" ]; then date_list=$(date -d @${ts} +%F); else date_list="${date_list} $(date -d @${ts} +%F)"; fi
        ts=$(expr ${ts} + 86400)
    done

    # Preparing built-in metrics id variables
    get_metrics_config

    # Prepare ${app_cost_list} cost values list of all nodes
    # Format each line: <date> <node> <cost>
    #   e.g. 2023-06-28 c1-node-1 15.93132
    # Fetch maximum 10 days to avoid huge response
    # Cost is displayed with localtime, so we need to deal with offset
    cost_list=""
    start_time=$(expr ${NOW} / 86400 \* 86400 - ${vars[past_period]} \* 86400 ${COST_TZ_OFFSET_SECONDS})
    end_time=${NOW}
    while [ ${start_time} -lt ${NOW} ]; do
        end_time=$(expr ${start_time} + ${DAYS_PER_API} \* 86400 - 60)
        COST_INPUT=$(ui_rest_readCostApplication ${vars[target_cluster]} ${bmc_cost_allocation_application_3600} ${start_time} ${end_time})
        # Format each line: <localtime date> <node> <cost>
        # e.g. 2023-06-28 c1-node-1 15.93132
        cost_list=$(grep -v "^$" <<< "${cost_list}
$(echo ${COST_INPUT} | ${JQ} '.results[0].series[].data[] | (.time | .[:19] + "Z" | fromdateiso8601 | strflocaltime("%Y-%m-%d")) + " " + .application_name + " " + (.workload_cost | tostring)' | sort | tr -d '\"')")
        start_time=$(expr ${start_time} + ${DAYS_PER_API} \* 86400)
    done

    # Applications
    start_time=$(expr ${NOW} / 86400 \* 86400 - ${vars[past_period]} \* 86400)
    end_time=${NOW}
    for appname in $(echo "${appctl_list}" | awk '{print $1}' | sort | uniq); do
        # Applications
        api="observations"
        url="${HTTPS}://${vars[f8ai_host]}/apis/v1/${api}/clusters/${vars[target_cluster]}/applications/${appname}?limit=10000&order=asc&startTime=${start_time}&endTime=${end_time}&granularity=86400"
        APP_INPUT=$( "${CURL[@]}" GET "${url}" -H "${HEADER1}" -H "${HEADER2}" 2>/dev/null )
        if [ "$?" != "0" -o "$(echo ${APP_INPUT} | ${JQ} '.message')" != "null" ]; then
            echo "${ERR}" "Error in retrieving url: ${url}"
            logging "${ERR}" "Error in retrieving url: ${url}"
            exit 1
        fi
        # find cpu of each application
        cpu_list=$(echo ${APP_INPUT} | ${JQ} '.data.raw_data.cpu[] | (.time | todateiso8601 | .[:10]) + " " + (.numValue | tostring)' | tr -d '\"')
        cpu_line="${appname}"
        for date_str in ${date_list}; do
            cpu=$(grep "^${date_str} " <<< "${cpu_list}" | awk '{print $2}')
            cpu_line="${cpu_line},${cpu}"
        done
        echo -n "."
        echo "${cpu_line}" >> ${app_cpu_csv_filename}.tmp
        # find mem of each application
        mem_list=$(echo ${APP_INPUT} | ${JQ} '.data.raw_data.memory[] | (.time | todateiso8601 | .[:10]) + " " + (.numValue | tostring)' | tr -d '\"')
        mem_line="${appname}"
        for date_str in ${date_list}; do
            mem=$(grep "^${date_str} " <<< "${mem_list}" | awk '{print $2}')
            mem_line="${mem_line},${mem}"
        done
        echo -n "."
        echo "${mem_line}" >> ${app_mem_csv_filename}.tmp
        # find cost of each application
        cost_line="${appname}"
        for date_str in ${date_list}; do
            cost=$(grep "^${date_str} ${appname} " <<< "${cost_list}" | awk '{print $3}')
            cost_line="${cost_line},${cost}"
        done
        echo "${cost_line}" >> ${app_cost_csv_filename}.tmp
    done

    start_time=$(expr ${NOW} / 86400 \* 86400 - ${vars[past_period]} \* 86400)
    end_time=${NOW}
    while read appname ns controller kind; do
        # Controllers
        api="observations"
        url="${HTTPS}://${vars[f8ai_host]}/apis/v1/${api}/clusters/${vars[target_cluster]}/namespaces/${ns}/$(echo ${kind} | tr '[A-Z]' '[a-z]'a)s?names=${controller}&limit=10000&order=asc&startTime=${start_time}&endTime=${end_time}&granularity=86400"
        CTRL_INPUT=$( "${CURL[@]}" GET "${url}" -H "${HEADER1}" -H "${HEADER2}" 2>/dev/null )
        if [ "$?" != "0" -o "$(echo ${CTRL_INPUT} | ${JQ} '.message')" != "null" ]; then
            echo "${ERR}" "Error in retrieving url: ${url}"
            logging "${ERR}" "Error in retrieving url: ${url}"
            exit 1
        fi
        # find cpu of each controller
        cpu_list=$(echo ${CTRL_INPUT} | ${JQ} '.data[].raw_data.cpu[] | (.time | todateiso8601 | .[:10]) + " " + (.numValue | tostring)' | tr -d '\"')
        cpu_line="${kind}/${ns}/${controller}"
        for date_str in ${date_list}; do
            cpu=$(grep "^${date_str} " <<< "${cpu_list}" | awk '{print $2}')
            cpu_line="${cpu_line},${cpu}"
        done
        echo -n "."
        echo "${cpu_line}" >> ${ctrl_cpu_csv_filename}.tmp
        # find mem of each controller
        mem_list=$(echo ${CTRL_INPUT} | ${JQ} '.data[].raw_data.memory[] | (.time | todateiso8601 | .[:10]) + " " + (.numValue | tostring)' | tr -d '\"')
        mem_line="${kind}/${ns}/${controller}"
        for date_str in ${date_list}; do
            mem=$(grep "^${date_str} " <<< "${mem_list}" | awk '{print $2}')
            mem_line="${mem_line},${mem}"
        done
        echo -n "."
        echo "${mem_line}" >> ${ctrl_mem_csv_filename}.tmp
    done <<< "${appctl_list}"
    echo

    mv ${app_cpu_csv_filename}.tmp ${app_cpu_csv_filename}
    mv ${app_mem_csv_filename}.tmp ${app_mem_csv_filename}
    mv ${app_cost_csv_filename}.tmp ${app_cost_csv_filename}
    mv ${ctrl_cpu_csv_filename}.tmp ${ctrl_cpu_csv_filename}
    mv ${ctrl_mem_csv_filename}.tmp ${ctrl_mem_csv_filename}
    echo

    return 0
}

function get_metrics_config() {
    # Prometheus data source only
    logging "Fetching metric config id."

    url="${HTTPS}://${vars[f8ai_host]}/series_postgres/getMetricsConfig"
    INPUT=$( "${CURL[@]}" POST "${url}" \
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

    bmc_cost_allocation_node_3600=$(echo "${INPUT}" | ${JQ} ".results[0].values.builtin_metric_configs.cost_allocation_node_3600.builtin_metric_config_id" | tr -d '"')
    bmc_cost_allocation_application_3600=$(echo "${INPUT}" | ${JQ} ".results[0].values.builtin_metric_configs.cost_allocation_application_3600.builtin_metric_config_id" | tr -d '"')

    logging "Fetching metric config id is completed."

    return 0
}

function ui_rest_readCostNode() {
    cluster_name="$1"
    metric_config_id="$2"
    start_time="$3"
    end_time="$4"
    url="${HTTPS}://${vars[f8ai_host]}/series_datahub/getSeries"
    results=$( "${CURL[@]}" POST "${url}" \
    -H "$HEADER3" \
    --data '{
          "queries": [
            {
              "key": "readCostNode",
              "datahub_method": "readCostManagement",
              "request_body": {
                "read_metrics": [
                  {
                    "granularity": "3600",
                    "metric_config_id": '\"${metric_config_id}\"',
                    "query_condition": {
                      "time_range": {
                        "start_time": {
                          "seconds": '\"${start_time}000\"'
                        },
                        "end_time": {
                          "seconds": '\"${end_time}000\"'
                        }
                      },
                      "where_condition": [
                        {
                          "keys": [
                            "cluster_name"
                          ],
                          "values": [
                            '\"${cluster_name}\"'
                          ],
                          "operators": [
                            "="
                          ]
                        }
                      ],
                      "selects_clause": "sum(workload_cost) as workload_cost,count(workload_cost) as points",
                      "groups": [
                        "time(86400s, '$(echo "${COST_TZ_OFFSET_SECONDS}" | tr -d ' ')'s)",
                        "node_name"
                      ],
                      "fill": "none"
                    }
                  }
                ]
              },
              "pf_method": "getCostNodesAllocation"
            }
          ]
    }')
    echo $results
}

function ui_rest_readCostApplication() {
    cluster_name="$1"
    metric_config_id="$2"
    start_time="$3"
    end_time="$4"
    url="${HTTPS}://${vars[f8ai_host]}/series_datahub/getSeries"
    results=$( "${CURL[@]}" POST "${url}" \
    -H "$HEADER3" \
    --data '{
          "queries": [
            {
              "key": "readCostApplication",
              "datahub_method": "readCostManagement",
              "request_body": {
                "read_metrics": [
                  {
                    "granularity": "3600",
                    "metric_config_id": '\"${metric_config_id}\"',
                    "query_condition": {
                      "time_range": {
                        "start_time": {
                          "seconds": '\"${start_time}000\"'
                        },
                        "end_time": {
                          "seconds": '\"${end_time}000\"'
                        }
                      },
                      "where_condition": [
                        {
                          "keys": [
                            "cluster_name"
                          ],
                          "values": [
                            '\"${cluster_name}\"'
                          ],
                          "operators": [
                            "="
                          ]
                        }
                      ],
                      "selects_clause": "sum(workload_cost) as workload_cost,count(workload_cost) as points",
                      "groups": [
                        "time(86400s, '$(echo "${COST_TZ_OFFSET_SECONDS}" | tr -d ' ')'s)",
                        "application_name"
                      ],
                      "fill": "none"
                    }
                  }
                ]
              },
              "pf_method": "getCostApplicationsAllocation"
            }
          ]
    }')
    echo $results
}

function collect_app_and_controller_configs()
{
    local cluster_name="$1"
    local appctl_list=""

    api="configs"
    url="${HTTPS}://${vars[f8ai_host]}/apis/v1/${api}/scaler"
    SCALER_INPUT=$( "${CURL[@]}" GET "${url}" -H "${HEADER1}" -H "${HEADER2}" 2>/dev/null )
    if [ "$?" != "0" -o "$(echo ${SCALER_INPUT} | ${JQ} '.message')" != "null" ]; then
        echo "${ERR}" "Error in retrieving url: ${url}"
        logging "${ERR}" "Error in retrieving url: ${url}"
        exit 1
    fi
    apps=($(echo "${SCALER_INPUT}" | ${JQ} '.data[] | select (.target_cluster_name=="'${cluster_name}'") | .object_meta.name' | tr -d '"' | xargs))
    if [ "${#apps}" != "" ]; then
        for app_name in ${apps[@]}; do
            # Format each line: <app_name> <namespace> <controller_name> <kind>
            # e.g. app-tmp-1 myproject producer 1
            appctl_list=$(grep -v "^$" <<< "${appctl_list}
$(echo ${SCALER_INPUT} | ${JQ} '.data[] | select (.target_cluster_name=="'${cluster_name}'") | select(.object_meta.name=="'${app_name}'") | .controllers[].generic.target | "'${app_name}' " + .namespace + " " + .name + " " + (.controller_kind | tostring)' | sort | tr -d '\"')")
        done
    fi
    # Replase 1=>deployment, 2=>statefulset
    appctl_list=$(sed -e 's/ 1$/ DEPLOYMENT/g' -e 's/ 2$/ STATEFULSET/g' <<< "${appctl_list}")
    cat <<< "${appctl_list}"

    return 0
}

function create_node_csv()
{
    echo
    logging "${STDOUT}" "Start collecting Node resource data:"

    nodes_count_csv_filename="${vars[csv_dir]}/${NODE_COUNT_CSV}"
    nodes_cpu_csv_filename="${vars[csv_dir]}/${NODE_CPU_CSV}"
    nodes_mem_csv_filename="${vars[csv_dir]}/${NODE_MEM_CSV}"
    nodes_cost_csv_filename="${vars[csv_dir]}/${NODE_COST_CSV}"
    rm -fv ${nodes_count_csv_filename} ${nodes_cpu_csv_filename} ${nodes_mem_csv_filename} ${nodes_cost_csv_filename}

    # Preparing built-in metrics id variables
    get_metrics_config

    # Prepare ${cost_list} cost values list of all nodes
    # Format each line: <date> <node> <cost>
    #   e.g. 2023-06-28 c1-node-1 15.93132
    # Fetch maximum 10 days to avoid huge response
    # Cost is displayed with localtime, so we need to deal with offset
    cost_list=""
    start_time=$(expr ${NOW} / 86400 \* 86400 - ${vars[past_period]} \* 86400 ${COST_TZ_OFFSET_SECONDS})
    while [ ${start_time} -lt ${NOW} ]; do
        end_time=$(expr ${start_time} + ${DAYS_PER_API} \* 86400 - 60)
        COST_INPUT=$(ui_rest_readCostNode ${vars[target_cluster]} ${bmc_cost_allocation_node_3600} ${start_time} ${end_time})
        # Format each line: <date> <node> <cost>
        # e.g. 2023-06-28 c1-node-1 15.93132
        cost_list=$(grep -v "^$" <<< "${cost_list}
$(echo ${COST_INPUT} | ${JQ} '.results[0].series[].data[] | (.time | .[:19] + "Z" | fromdateiso8601 | strflocaltime("%Y-%m-%d")) + " " + .node_name + " " + (.workload_cost | tostring)' | sort | tr -d '\"')")
        start_time=$(expr ${start_time} + ${DAYS_PER_API} \* 86400)
    done

    # Prepare ${cpu_list} and ${mem_list} values list of all nodes
    # Format each line: <date> <node> <cpu>
    #   e.g. 2023-06-28 c1-node-1 15.93132
    # Format each line: <date> <node> <memory>
    #   e.g. 2023-06-28 c1-node-1 7845253120
    # Fetch maximum 10 days to avoid huge response
    start_time=$(expr ${NOW} / 86400 \* 86400 - ${vars[past_period]} \* 86400)
    cpu_list=""
    mem_list=""
    while [ ${start_time} -lt ${NOW} ]; do
        end_time=$(expr ${start_time} + ${DAYS_PER_API} \* 86400 - 60)
        api="observations"
        url="${HTTPS}://${vars[f8ai_host]}/apis/v1/${api}/clusters/${vars[target_cluster]}/nodes?limit=10000&granularity=86400&order=asc&startTime=${start_time}&endTime=${end_time}"
        NODE_INPUT=$( "${CURL[@]}" GET "${url}" -H "${HEADER1}" -H "${HEADER2}" 2>/dev/null )
        if [ "$?" != "0" -o "$(echo ${NODE_INPUT} | ${JQ} '.message')" != "null" ]; then
            echo "${ERR}" "Error in retrieving url: ${url}"
            logging "${ERR}" "Error in retrieving url: ${url}"
            exit 1
        fi
        # find cpu and mem of each nodes
        while read name; do
            cpu_list=$(grep -v "^$" <<< "${cpu_list}
$(echo ${NODE_INPUT} | ${JQ} '.data[] | select (.name=="'${name}'") | .raw_data.cpu[] | (.time | todateiso8601 | .[:10]) + " '${name}' " + (.numValue | tostring)' | tr -d '\"')")
            mem_list=$(grep -v "^$" <<< "${mem_list}
$(echo ${NODE_INPUT} | ${JQ} '.data[] | select (.name=="'${name}'") | .raw_data.memory[] | (.time | todateiso8601 | .[:10]) + " '${name}' " + (.numValue | tostring)' | tr -d '\"')")
        done <<< "$(echo ${NODE_INPUT} | ${JQ} '.data[].name' | tr -d '\"')"

        start_time=$(expr ${end_time} + 60)
        echo -n "."
    done

    # Compute start data, e.g. 2023-06-28
    start_time=$(expr ${NOW} / 86400 \* 86400 - ${vars[past_period]} \* 86400)
    date_str=$(date -d @${start_time} +%F)
    header="${date_str},${VER},${NOW},${vars[target_cluster]}"
    echo "${header}" > ${nodes_count_csv_filename}.tmp
    echo "${header}" > ${nodes_cpu_csv_filename}.tmp
    echo "${header}" > ${nodes_mem_csv_filename}.tmp
    echo "${header}" > ${nodes_cost_csv_filename}.tmp

    # Prepare date string list ${date_list}
    # Format: <val_day1> <val_day2> ... <val_dayn>
    #  e.g. 2023-06-28 2023-06-29 ... 2023-12-28
    ts=${start_time}
    date_list=""
    while [ ${ts} -lt ${NOW} ]; do
        if [ "${date_list}" = "" ]; then date_list=$(date -d @${ts} +%F); else date_list="${date_list} $(date -d @${ts} +%F)"; fi
        ts=$(expr ${ts} + 86400)
    done

    # Compute count_line from ${cpu_list}
    # Format: <val_day1>,<val_day2>,...,<val_dayn>
    for date_str in ${date_list}; do
        count=$(grep "^${date_str} " <<< "${cpu_list}" | wc -l)
        if [ "${count_line}" = "" ]; then count_line="${count}"; else count_line="${count_line},${count}"; fi
    done
    echo "${count_line}" >> ${nodes_count_csv_filename}.tmp

    # Compute cpu_line, mem_line and cost_line
    # Format: <node_name>,<val_day1>,<val_day2>,...,<val_dayn>
    node_list=$(awk '{print $2}' <<< "
${cpu_list}
${mem_list}
${cost_list}" | sort | uniq | xargs)
    for node in ${node_list}; do
        cpu_line="${node}"
        mem_line="${node}"
        cost_line="${node}"
        for date_str in ${date_list}; do
            cpu=$(grep "^${date_str} ${node} " <<< "${cpu_list}" | awk '{print $3}')
            mem=$(grep "^${date_str} ${node} " <<< "${mem_list}" | awk '{print $3}')
            cost=$(grep "^${date_str} ${node} " <<< "${cost_list}" | awk '{print $3}')
            cpu_line="${cpu_line},${cpu}"
            mem_line="${mem_line},${mem}"
            cost_line="${cost_line},${cost}"
            echo -n "."
        done
        echo "${cpu_line}" >> ${nodes_cpu_csv_filename}.tmp
        echo "${mem_line}" >> ${nodes_mem_csv_filename}.tmp
        echo "${cost_line}" >> ${nodes_cost_csv_filename}.tmp
    done
    echo

    mv ${nodes_count_csv_filename}.tmp ${nodes_count_csv_filename}
    mv ${nodes_cpu_csv_filename}.tmp ${nodes_cpu_csv_filename}
    mv ${nodes_mem_csv_filename}.tmp ${nodes_mem_csv_filename}
    mv ${nodes_cost_csv_filename}.tmp ${nodes_cost_csv_filename}

    echo

    return 0
}

function banner()
{
    banner_string="Federator.ai Kubernetes Node/Controller/Application Usage and Cost Statistics Collector v${VER}"
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
  -d, --directory=''      Local path where .csv files will be saved (DEFAULT: '.')
  -r, --resource='both'   Generate Node('node') and/or Controller('controller') .csv (DEFAULT: 'both')
  -l, --logfile=''        Full path of the log file (DEFAULT: './k8s-resource-collect.log')
  -t, --pastperiod=''     Past period in days for getting the usage (DEFAULT: '183')

Examples:
  ${PROG} --host=127.0.0.1:31012 --username=admin --password=xxxx --cluster=h3-61

__EOF__
    exit 1
}

# arguments
function parse_options()
{
    optspec="k:x:h:u:p:c:d:r:l:a:t:n:-:"
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
                    directory)
                        vars[csv_dir]="${OPT_VAL}" ;;
                    resource)
                        vars[resource_type]="${OPT_VAL}" ;;
                    logfile)
                        vars[log_path]="${OPT_VAL}" ;;
                    pastperiod)
                        vars[past_period]="${OPT_VAL}" ;;
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
            d)
                vars[csv_dir]="${OPTARG}" ;;
            r)
                vars[resource_type]="${OPTARG}" ;;
            l)
                vars[log_path]="${OPTARG}" ;;
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

if [ "${1:0:1}" != "-" ]; then
    show_usage
    exit 1
fi

# parse options
parse_options "$@"

# validate options
if [[ ! -z "${F8AI_API_PASSWORD}" ]]; then
    vars[f8ai_pswd]=${F8AI_API_PASSWORD}
fi
if [ "${vars[f8ai_host]}" = "" -o "${vars[f8ai_pswd]}" = "" -o "${vars[target_cluster]}" = "" ]; then
    echo "ERROR: Federator.ai host or password or target cluster is empty."
    show_usage
    exit 1
fi
fhost=${vars[f8ai_host]}
if [ "${fhost}" != "${fhost#https://}" ]; then
    HTTPS="https"
    vars[f8ai_host]=${fhost#https://}
elif [ "${fhost}" != "${fhost#http://}" ]; then
    HTTPS="http"
    vars[f8ai_host]=${fhost#http://}
fi

HEADER2="authorization: Basic $(echo -n "${vars[f8ai_user]}:${vars[f8ai_pswd]}" |base64)"

logging $(banner)
logging "$(echo \"Arguments: $*\" | sed -e 's/ --password=.* / --password=*** /g' -e 's/ -p .* / -p ***/g')"
for i in "${!vars[@]}"; do
    if [ "${i}" != "f8ai_pswd" ]; then
        logging "vars[${i}]=${vars[${i}]}"
    fi
done

# pre-checks
if ! precheck_bash_version || ! precheck_utils || ! precheck_federatorai_version || ! precheck_federatorai
then
    logging "${STDOUT}" "${ERR}" "${output_msg}"
    exit 1
fi

# generate controller csv
if [ "${vars[resource_type]}" = "both" -o "${vars[resource_type]}" = "controller" ]; then
    echo "(It may take a few minutes to complete...)"
    if ! create_controller_csv; then
        logging "${STDOUT}" "${ERR}" "${output_msg}"
        exit 1
    else
        logging "${STDOUT}" "${INFO}" "Successfully created Application and Controller .csv."
    fi
fi

# generate node csv
if [ "${vars[resource_type]}" = "both" -o "${vars[resource_type]}" = "node" ]; then
    if ! create_node_csv; then
        logging "${STDOUT}" "${ERR}" "${output_msg}"
        exit 1
    else
        logging "${STDOUT}" "${INFO}" "Successfully created Node resource .csv."
    fi
fi

exit 0
