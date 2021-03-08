#!/usr/bin/env bash
set -o pipefail

show_usage()
{
    cat << __EOF__

    Usage:
        $(tput setaf 2)Requirement:$(tput sgr 0)
            --config-file <planning config filename> [e.g., $(tput setaf 6)--config-file planning.json$(tput sgr 0)]
        $(tput setaf 2)Standalone options:$(tput sgr 0)
            --test-connection-only
            --dry-run-only
            --verbose
            --log-name <log filename> [e.g., $(tput setaf 6)--log-name mycluster.log$(tput sgr 0)]
__EOF__
}

show_info()
{
    if [ "$verbose_mode" = "y" ]; then
        tee -a $debug_log  << __EOF__
$*
__EOF__
    else
        echo "$*" >> $debug_log
    fi
    return 0
}

log_prompt()
{
    echo -e "\n$(tput setaf 6)Please refer to the logfile $debug_log for details. $(tput sgr 0)"
}

check_user_token()
{
    if [ "$access_token" = "null" ] || [ "$access_token" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get login token from REST API.$(tput sgr 0)" | tee -a $debug_log
        echo "Please check login account and login password." | tee -a $debug_log
        log_prompt
        exit 8
    fi
}


check_rest_api_url()
{
    show_info "$(tput setaf 6)Getting REST API URL...$(tput sgr 0)" 
    api_url=$(jq -r '.rest_api_full_path' $config_file)
    if [ "$api_url" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get REST API URL.$(tput sgr 0)" | tee -a $debug_log
        log_prompt
        exit 8
    fi
    show_info "REST API URL = $api_url"
    show_info "Done."
}

rest_api_login()
{
    show_info "$(tput setaf 6)Logging into REST API...$(tput sgr 0)"
    login_account=$(jq -r '.login_account' $config_file)
    if [ "$login_account" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get login account.$(tput sgr 0)" | tee -a $debug_log
        log_prompt
        exit 8
    fi
    login_password=$(jq -r '.login_password' $config_file)
    if [ "$login_password" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get login password.$(tput sgr 0)" | tee -a $debug_log
        log_prompt
        exit 8
    fi
    auth_string="${login_account}:${login_password}"
    auth_cipher=$(echo -n "$auth_string"|base64)
    if [ "$auth_cipher" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to generate base64 output of login string.$(tput sgr 0)"  | tee -a $debug_log
        log_prompt
        exit 8
    fi
    rest_output=$(curl -sS -k -X POST "$api_url/apis/v1/users/login" -H "accept: application/json" -H "authorization: Basic ${auth_cipher}")
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to connect to REST API service ($api_url/apis/v1/users/login).$(tput sgr 0)" | tee -a $debug_log
        echo "Please check REST API IP" | tee -a $debug_log
        log_prompt
        exit 8
    fi
    access_token="$(echo $rest_output|jq '.accessToken'|tr -d "\"")"
    check_user_token

    show_info "Done."
}

rest_api_check_cluster_name()
{
    index=$1
    if [ "$index" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! rest_api_check_cluster_name() index parameter can't be empty.$(tput sgr 0)" | tee -a $debug_log
        log_prompt
        exit 3
    fi
    show_info "$(tput setaf 6)Getting the cluster name of the planning target ($index)...$(tput sgr 0)"
    cluster_name=$(jq -r '.planning_targets['$index'].cluster_name' $config_file)
    if [ "$cluster_name" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get cluster name of the planning target ($index).$(tput sgr 0)" | tee -a $debug_log
        log_prompt
        exit 8
    fi

    rest_cluster_output="$(curl -sS -k -X GET "$api_url/apis/v1/resources/clusters" -H "accept: application/json" -H "Authorization: Bearer $access_token" |jq '.data[].name'|tr -d "\"")"
    echo "$rest_cluster_output"|grep -q "$cluster_name"
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error! The cluster name is not found in REST API return.$(tput sgr 0)" | tee -a $debug_log
        log_prompt
        exit 8
    fi

    show_info "cluster_name = $cluster_name"
    show_info "Done."
}

get_controller_info_from_config()
{
    index=$1
    if [ "$index" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! get_controller_info_from_config() index parameter can't be empty.$(tput sgr 0)" | tee -a $debug_log
        log_prompt
        exit 3
    fi

    show_info "$(tput setaf 6)Getting the controller info of the planning target ($index)...$(tput sgr 0)"

    owner_reference_kind=$(jq -r '.planning_targets['$index'].controller_type' $config_file)
    if [ "$owner_reference_kind" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get controller kind of the planning target ($index).$(tput sgr 0)" | tee -a $debug_log
        log_prompt
        exit 8
    fi
    if [ "$owner_reference_kind" = "statefulset" ] && [ "$owner_reference_kind" = "deployment" ] && [ "$owner_reference_kind" = "deploymentconfig" ]; then
        echo -e "\n$(tput setaf 1)Error! Only support controller type equals statefulset/deployment/deploymentconfig.$(tput sgr 0)" | tee -a $debug_log
        log_prompt
        exit 8
    fi
    owner_reference_name=$(jq -r '.planning_targets['$index'].controller_name' $config_file)
    if [ "$owner_reference_name" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get controller name of the planning target ($index).$(tput sgr 0)" | tee -a $debug_log
        log_prompt
        exit 8
    fi
    target_namespace=$(jq -r '.planning_targets['$index'].namespace' $config_file)
    if [ "$target_namespace" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get namespace of the planning target ($index).$(tput sgr 0)" | tee -a $debug_log
        log_prompt
        exit 8
    fi

    readable_granularity=$(jq -r '.planning_targets['$index'].time_interval' $config_file)
    if [ "$readable_granularity" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get time interval of the planning target ($index).$(tput sgr 0)" | tee -a $debug_log
        log_prompt
        exit 8
    fi

    if [ "$readable_granularity" = "daily" ]; then
        granularity="3600"
    elif [ "$readable_granularity" = "weekly" ]; then
        granularity="21600"
    elif [ "$readable_granularity" = "monthly" ]; then
        granularity="86400"
    else
        echo -e "\n$(tput setaf 1)Error! Only support planning time interval equals daily/weekly/monthly.$(tput sgr 0)" | tee -a $debug_log
        log_prompt
        exit 8
    fi

    show_info "Cluster name = $cluster_name"
    show_info "Namespace = $target_namespace"
    show_info "Controller name = $owner_reference_name"
    show_info "Controller type = $owner_reference_kind"
    show_info "Time interval = $readable_granularity"
    show_info "Done."
}

get_controller_planning_from_api()
{
    show_info "$(tput setaf 6)Getting planning values for the controller through REST API...$(tput sgr 0)"
    show_info "Cluster name = $cluster_name"
    show_info "Namespace = $target_namespace"
    show_info "Controller name = $owner_reference_name"
    show_info "Controller type = $owner_reference_kind"
    show_info "Time interval = $readable_granularity"

    interval_start_time="$(date +%s)"
    interval_end_time=$(($interval_start_time + $granularity - 1))

    show_info "Query interval (start) = $interval_start_time"
    show_info "Query interval (end) = $interval_end_time"

    # Use planning here
    type="planning"
    query_type="${owner_reference_kind}s"
    rest_output="$(curl -sS -k -X GET "$api_url/apis/v1/plannings/clusters/$cluster_name/namespaces/$target_namespace/$query_type/${owner_reference_name}?granularity=$granularity&type=$type&limit=1&order=asc&startTime=$interval_start_time&endTime=$interval_end_time" -H "accept: application/json" -H "Authorization: Bearer $access_token")"
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get planning value using REST API (Command: curl -sS -k -X GET \"$api_url/apis/v1/plannings/clusters/$cluster_name/namespaces/$target_namespace/$query_type/${owner_reference_name}?granularity=$granularity&type=$type&limit=1&order=asc&startTime=$interval_start_time&endTime=$interval_end_time\" -H \"accept: application/json\" -H \"Authorization: Bearer $access_token\")$(tput sgr 0)" | tee -a $debug_log
        log_prompt
        exit 8
    fi
    planning_all="$(echo $rest_output|jq ".plannings[]")"
    if [ "$?" != "0" ] || [ "$planning_all" = "" ]; then
        echo -e "\n$(tput setaf 1)REST API output:$(tput sgr 0)" | tee -a $debug_log
        echo -e "${rest_output}" | tee -a $debug_log
        echo -e "\n$(tput setaf 1)Error! Planning value is empty.$(tput sgr 0)" | tee -a $debug_log
        log_prompt
        exit 8
    fi
    planning_values="$(echo $planning_all|jq ".plannings[0]|\"\(.limitPlannings.${query_cpu_string}[].numValue) \(.requestPlannings.${query_cpu_string}[].numValue) \(.limitPlannings.${query_memory_string}[].numValue) \(.requestPlannings.${query_memory_string}[].numValue)\""|tr -d "\"")"
    if [ "$?" != "0" ] || [ "$planning_values" = "" ]; then
        echo -e "\n$(tput setaf 1)Planning output:$(tput sgr 0)" | tee -a $debug_log
        echo -e "${planning_all}" | tee -a $debug_log
        echo -e "\n$(tput setaf 1)Error! Failed to get limit and request values of planning.$(tput sgr 0)" | tee -a $debug_log
        log_prompt
        exit 8
    fi
    replica_number="`kubectl get $owner_reference_kind $owner_reference_name -n $target_namespace -o json|jq '.spec.replicas'`"
    if [ "$replica_number" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get replica number from controller ($owner_reference_name) in ns $target_namespace$(tput sgr 0)" | tee -a $debug_log
        log_prompt
        exit 8
    fi
    show_info "Controller replica number = $replica_number"
    if [ "$replica_number" = "0" ]; then
        echo -e "\n$(tput setaf 1)Abort! Replica number is zero.$(tput sgr 0)" | tee -a $debug_log
        log_prompt
        exit 8
    fi

    limits_pod_cpu="`echo $planning_values |awk '{print $1}'`"
    requests_pod_cpu="`echo $planning_values |awk '{print $2}'`"
    limits_pod_memory="`echo $planning_values |awk '{print $3}'`"
    requests_pod_memory="`echo $planning_values |awk '{print $4}'`"

    # Round up the result (planning / replica)
    limits_pod_cpu=`echo "($limits_pod_cpu + $replica_number - 1)/$replica_number" | bc`
    requests_pod_cpu=`echo "($requests_pod_cpu + $replica_number - 1)/$replica_number" | bc`
    limits_pod_memory=`echo "($limits_pod_memory + $replica_number - 1)/$replica_number" | bc`
    requests_pod_memory=`echo "($requests_pod_memory + $replica_number - 1)/$replica_number" | bc`

    show_info "-------------- Planning for controller --------------"
    show_info "$(tput setaf 2)resources.limits.cpu $(tput sgr 0)= $(tput setaf 3)$limits_pod_cpu(m)$(tput sgr 0)"
    show_info "$(tput setaf 2)resources.limits.momory $(tput sgr 0)= $(tput setaf 3)$limits_pod_memory(byte)$(tput sgr 0)"
    show_info "$(tput setaf 2)resources.requests.cpu $(tput sgr 0)= $(tput setaf 3)$requests_pod_cpu(m)$(tput sgr 0)"
    show_info "$(tput setaf 2)resources.requests.memory $(tput sgr 0)= $(tput setaf 3)$requests_pod_memory(byte)$(tput sgr 0)"
    show_info "-----------------------------------------------------"

    if [ "$limits_pod_cpu" = "" ] || [ "$requests_pod_cpu" = "" ] || [ "$limits_pod_memory" = "" ] || [ "$requests_pod_memory" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get controller ($owner_reference_name) planning. Missing value.$(tput sgr 0)" | tee -a $debug_log
        log_prompt
        exit 8
    fi

    show_info "Done."
}

update_controller_resources()
{
    mode=$1
    if [ "$mode" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! update_controller_resources() mode parameter can't be empty.$(tput sgr 0)" | tee -a $debug_log
        log_prompt
        exit 3
    fi

    show_info "$(tput setaf 6)Updateing controller resources...$(tput sgr 0)"

    if [ "$limits_pod_cpu" = "" ] || [ "$requests_pod_cpu" = "" ] || [ "$limits_pod_memory" = "" ] || [ "$requests_pod_memory" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Missing planning values.$(tput sgr 0)" | tee -a $debug_log
        log_prompt
        exit 8
    fi

    # Update resources
    exec_cmd="kubectl -n $target_namespace set resources $owner_reference_kind $owner_reference_name --limits cpu=${limits_pod_cpu}m,memory=${limits_pod_memory} --requests cpu=${requests_pod_cpu}m,memory=${requests_pod_memory}"

    show_info "$(tput setaf 3)Issuing cmd:$(tput sgr 0)"
    show_info "$(tput setaf 2)$exec_cmd$(tput sgr 0)"
    if [ "$mode" = "dry_run" ]; then
        execution_time="N/A, skip due to dry run is enabled."
        show_info "$(tput setaf 3)Dry run is enabled, skip execution.$(tput sgr 0)"
        show_info "Done. Dry run is done."
        return
    fi

    execution_time="$(date -u)"
    eval $exec_cmd 2>&1|tee -a $debug_log
    if [ "$?" != "0" ]; then
        echo -e "\nFailed to update resources for $owner_reference_kind $owner_reference_name" | tee -a $debug_log
        log_prompt
        exit 8
    fi

    show_info "Done"
}

get_controller_resources_from_kubectl()
{
    mode=$1
    if [ "$mode" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! get_controller_resources_from_kubectl() mode parameter can't be empty.$(tput sgr 0)" | tee -a $debug_log
        log_prompt
        exit 3
    fi

    show_info "$(tput setaf 6)Getting current controller resources...$(tput sgr 0)"
    show_info "Namespace = $target_namespace"
    show_info "Controller name = $owner_reference_name"
    show_info "Controller type = $owner_reference_kind"
    
    resources=$(kubectl get $owner_reference_kind $owner_reference_name -n $target_namespace -o json |jq '.spec.template.spec.containers[].resources')
    if [ "$mode" = "before" ]; then
        show_info "----------------- Before execution ------------------"
        limit_cpu_before=$(echo $resources|jq '.limits.cpu'|sed 's/"//g')
        [ "$limit_cpu_before" = "" ] && limit_cpu_before="N/A"
        limit_memory_before=$(echo $resources|jq '.limits.memory'|sed 's/"//g')
        [ "$limit_memory_before" = "" ] && limit_memory_before="N/A"
        request_cpu_before=$(echo $resources|jq '.requests.cpu'|sed 's/"//g')
        [ "$request_cpu_before" = "" ] && request_cpu_before="N/A"
        request_memory_before=$(echo $resources|jq '.requests.memory'|sed 's/"//g')
        [ "$request_memory_before" = "" ] && request_memory_before="N/A"
        show_info "$(tput setaf 3)limits:"
        show_info "  cpu: $limit_cpu_before"
        show_info "  memory: $limit_memory_before"
        show_info "Requests:"
        show_info "  cpu: $request_cpu_before"
        show_info "  memory: $request_memory_before$(tput sgr 0)"
        show_info "-----------------------------------------------------"
    else
        # mode = "after"
        if [ "$do_dry_run" = "y" ]; then
            show_info "--------------------- Dry run -----------------------"
            # dry run - set resource values from planning results to display
            limit_cpu_after="${limits_pod_cpu}m"
            limit_memory_after="$limits_pod_memory"
            request_cpu_after="${requests_pod_cpu}m"
            request_memory_after="$requests_pod_memory"
        else
            # patch is done
            show_info "------------------ After execution ------------------"
            limit_cpu_after=$(echo $resources|jq '.limits.cpu'|sed 's/"//g')
            [ "$limit_cpu_after" = "" ] && limit_cpu_after="N/A"
            limit_memory_after=$(echo $resources|jq '.limits.memory'|sed 's/"//g')
            [ "$limit_memory_after" = "" ] && limit_memory_after="N/A"
            request_cpu_after=$(echo $resources|jq '.requests.cpu'|sed 's/"//g')
            [ "$request_cpu_after" = "" ] && request_cpu_after="N/A"
            request_memory_after=$(echo $resources|jq '.requests.memory'|sed 's/"//g')
            [ "$request_memory_after" = "" ] && request_memory_after="N/A"
        fi

        show_info "$(tput setaf 3)limits:"
        show_info "  cpu: $limit_cpu_before -> $limit_cpu_after"
        show_info "  memory: $limit_memory_before -> $limit_memory_after"
        show_info "Requests:"
        show_info "  cpu: $request_cpu_before -> $request_cpu_after"
        show_info "  memory: $request_memory_before -> $request_memory_after$(tput sgr 0)"
        show_info "-----------------------------------------------------"

        jq -n --arg namespace $target_namespace --arg time_interval $readable_granularity --arg controller_type $owner_reference_kind --arg controller_name $owner_reference_name --arg cluster_name $cluster_name --arg exec_cmd "$exec_cmd" --arg execution_time "$execution_time" --arg limit_cpu_before $limit_cpu_before --arg limit_cpu_after $limit_cpu_after --arg limit_memory_before $limit_memory_before --arg limit_memory_after $limit_memory_after --arg request_cpu_before $request_cpu_before --arg request_cpu_after $request_cpu_after --arg request_memory_before $request_memory_before --arg request_memory_after $request_memory_after '{"info":{"cluster_name":"\($cluster_name)","namespace":"\($namespace)","controller_name":"\($controller_name)","controller_type":"\($controller_type)","time_interval":"\($time_interval)","execute_cmd":"\($exec_cmd)","execution_time":"\($execution_time)"},"before_execution":{"limits": {"cpu":"\($limit_cpu_before)","memory":"\($limit_memory_before)"},"requests": {"cpu":"\($request_cpu_before)","memory":"\($request_memory_before)"}},"after_execution":{"limits": {"cpu":"\($limit_cpu_after)","memory":"\($limit_memory_after)"},"requests":{"cpu":"\($request_cpu_after)","memory":"\($request_memory_after)"}}}' | tee -a $debug_log
    fi
    
    show_info "Done."
}

connection_test()
{
    check_rest_api_url
    rest_api_login
}

while getopts "h-:" o; do
    case "${o}" in
        -)
            case "${OPTARG}" in
                config-file)
                    config_file_name="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$config_file_name" = "" ]; then
                        echo -e "\n$(tput setaf 1)Error! Missing --${OPTARG} value$(tput sgr 0)"
                        show_usage
                        exit 4
                    fi
                    ;;
                dry-run-only)
                    do_dry_run="y"
                    ;;
                test-connection-only)
                    do_test_connection="y"
                    ;;
                verbose)
                    verbose_mode="y"
                    ;;
                log-name)
                    log_name="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$log_name" = "" ]; then
                        echo -e "\n$(tput setaf 1)Error! Missing --${OPTARG} value$(tput sgr 0)"
                        show_usage
                        exit 4
                    fi
                    ;;
                help)
                    show_usage
                    exit 0
                    ;;
                *)
                    echo -e "\n$(tput setaf 1)Error! Unknown option --${OPTARG}$(tput sgr 0)"
                    show_usage
                    exit 4
                    ;;
            esac;;
        h)
            show_usage
            exit 0
            ;;
        *)
            echo -e "\n$(tput setaf 1)Error! wrong parameter.$(tput sgr 0)"
            show_usage
            exit 5
            ;;
    esac
done

file_folder="/tmp/auto-provisioning"
mkdir -p $file_folder
if [ "$log_name" = "" ]; then
    log_name="output.log"
fi
debug_log="${file_folder}/${log_name}"
current_location=`pwd`
echo ""
echo "Receiving command: '$0 $@'" >> $debug_log
echo "Receiving time: `date -u`" >> $debug_log

which kubectl > /dev/null 2>&1
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)Abort, \"kubectl\" command is needed for this tool.$(tput sgr 0)" | tee -a $debug_log
    log_prompt
    exit 3
fi

kubectl version|grep -q "^Server"
if [ "$?" != "0" ];then
    echo -e "\nPlease login to Kubernetes first." | tee -a $debug_log
    log_prompt
    exit 3
fi

which curl > /dev/null 2>&1
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)Abort, \"curl\" command is needed for this tool.$(tput sgr 0)" | tee -a $debug_log
    log_prompt
    exit 3
fi

which base64 > /dev/null 2>&1
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)Abort, \"base64\" command is needed for this tool.$(tput sgr 0)" | tee -a $debug_log
    log_prompt
    exit 3
fi

which jq > /dev/null 2>&1
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)Abort, \"jq\" command is needed for this tool.$(tput sgr 0)" | tee -a $debug_log
    echo "You may issue following commands to install jq." | tee -a $debug_log
    echo "1. wget https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64 -O jq" | tee -a $debug_log
    echo "2. chmod +x jq" | tee -a $debug_log
    echo "3. mv jq /usr/local/bin" | tee -a $debug_log
    echo "4. rerun the script" | tee -a $debug_log
    log_prompt
    exit 3
fi

# 4.4 or later
query_cpu_string="CPU_MILLICORES_USAGE"
query_memory_string="MEMORY_BYTES_USAGE"

script_located_path=$(dirname $(readlink -f "$0"))

# Check if config file exist.
config_file="$script_located_path/$config_file_name"
if [ ! -f ${config_file} ]; then
    echo -e "\n$(tput setaf 1)Error! ${config_file} doesn't exist.$(tput sgr 0)" | tee -a $debug_log
    log_prompt
    exit 3
else
    echo "-------------- Receiving config file ----------------" >> $debug_log
    # Hide password
    cat ${config_file} |sed 's/"login_password.*/"login_password": *****/g' >> $debug_log
    echo "-----------------------------------------------------" >> $debug_log
fi

# Check if config file is valid json file.
cat $config_file | jq empty
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)Error, ${config_file} is not a valid json file.$(tput sgr 0)" | tee -a $debug_log
    log_prompt
    exit 3
fi

connection_test

if [ "$do_test_connection" = "y" ]; then
    echo -e "\nDone. Connection test is passed." | tee -a $debug_log
    log_prompt
    exit 0
fi

planning_index=0
planning_target_count=$(jq -r '.planning_targets | length' $config_file)

if [ "$planning_target_count" = "0" ] || [ "$planning_target_count" = "" ]; then
    echo "planning_target_count = $planning_target_count" | tee -a $debug_log
    echo -e "\n$(tput setaf 1)Error, the planning targets in $config_file is empty.$(tput sgr 0)" | tee -a $debug_log
    log_prompt
    exit 3
fi

while [[ $planning_index -lt $planning_target_count ]]
do
    rest_api_check_cluster_name $planning_index
    get_controller_info_from_config $planning_index
    get_controller_resources_from_kubectl "before"
    get_controller_planning_from_api
    
    if [ "$do_dry_run" = "y" ]; then
        update_controller_resources "dry_run"
    else
        update_controller_resources "normal"
    fi
    get_controller_resources_from_kubectl "after"
    ((planning_index = planning_index + 1))
done

log_prompt

