#!/usr/bin/env bash

#=========================== target config info start =========================
target_config_info='{
  "rest_api_url": "https://172.31.2.41:31011",
  "login_account": "",
  "login_password": "",
  "resource_type": "controller", # controller or namespace
  "iac_command": "script", # script or terraform
  "kubeconfig_path": "", # optional # kubeconfig file path
  "planning_target":
    {
      "cluster_name": "hungo-17-135",
      "namespace": "cassandra",
      "time_interval": "daily", # daily, weekly, or monthly
      "resource_name": "cassandra",
      "kind": "StatefulSet", # StatefulSet, Deployment, DeploymentConfig
      "min_cpu": "100", # optional # mCore
      "max_cpu": "5000", # optional # mCore
      "cpu_headroom": "100", # optional # Absolute value (mCore) e.g. 1000 or Percentage e.g. 20% 
      "min_memory": "10000000", # optional # byte
      "max_memory": "18049217913", # optional # byte
      "memory_headroom": "27%" # optional # Absolute value (byte) e.g. 209715200 or Percentage e.g. 20%
      "trigger_condition": "20" optional # Trigger condition (percentage) e.g. 20 means 20%
    }
}'
#=========================== target config info end ===========================

if [ "$BASH_VERSION" = "" ]; then
    err_code="6"
    /bin/echo -e "{\n  \"reason\": \"Please use bash to run the script.\",\n  \"error_code\": $err_code\n}"
    exit $err_code
fi
set -o pipefail

awk_egrep () {
  local pattern_string=$1

  gawk '{
    while ($0) {
      start=match($0, pattern);
      token=substr($0, start, RLENGTH);
      print token;
      $0=substr($0, start+RLENGTH);
    }
  }' pattern="$pattern_string"
}

tokenize_json () {
  input="$1"
  local GREP
  local ESCAPE
  local CHAR

  if echo "test string" | egrep -ao --color=never "test" >/dev/null 2>&1
  then
    GREP='egrep -ao --color=never'
  else
    GREP='egrep -ao'
  fi

  if echo "test string" | egrep -o "test" >/dev/null 2>&1
  then
    ESCAPE='(\\[^u[:cntrl:]]|\\u[0-9a-fA-F]{4})'
    CHAR='[^[:cntrl:]"\\]'
  else
    GREP=awk_egrep
    ESCAPE='(\\\\[^u[:cntrl:]]|\\u[0-9a-fA-F]{4})'
    CHAR='[^[:cntrl:]"\\\\]'
  fi

  local STRING="\"$CHAR*($ESCAPE$CHAR*)*\""
  local NUMBER='-?(0|[1-9][0-9]*)([.][0-9]*)?([eE][+-]?[0-9]*)?'
  local KEYWORD='null|false|true'
  local SPACE='[[:space:]]+'

  # Force zsh to expand $A into multiple words
  local is_wordsplit_disabled=$(unsetopt 2>/dev/null | grep -c '^shwordsplit$')
  if [ $is_wordsplit_disabled != 0 ]; then setopt shwordsplit; fi
  echo "$input"|$GREP "$STRING|$NUMBER|$KEYWORD|$SPACE|." | egrep -v "^$SPACE$"
  if [ $is_wordsplit_disabled != 0 ]; then unsetopt shwordsplit; fi
}

parse_json_array () {
  local index=0
  local ary=''
  read -r token
  case "$token" in
    ']') ;;
    *)
      while :
      do
        parse_json_value "$1" "$index"
        index=$((index+1))
        ary="$ary""$value"
        read -r token
        case "$token" in
          ']') break ;;
          ',') ary="$ary," ;;
          *) exit 71;;
        esac
        read -r token
      done
      ;;
  esac
  [ "$BRIEF" -eq 0 ] && value=$(printf '[%s]' "$ary") || value=
  :
}

parse_json_object () {
  local key
  local obj=''
  read -r token
  case "$token" in
    '}') ;;
    *)
      while :
      do
        case "$token" in
          '"'*'"') key=$token ;;
          *) exit 70;;
        esac
        read -r token
        case "$token" in
          ':') ;;
          *) exit 73;;
        esac
        read -r token
        parse_json_value "$1" "$key"
        obj="$obj$key:$value"
        read -r token
        case "$token" in
          '}') break ;;
          ',') obj="$obj," ;;
          *) exit 74;;
        esac
        read -r token
      done
    ;;
  esac
  [ "$BRIEF" -eq 0 ] && value=$(printf '{%s}' "$obj") || value=
  :
}

parse_json_value () {
  local jpath="${1:+$1,}$2" isleaf=0 isempty=0 print=0
  case "$token" in
    '{') parse_json_object "$jpath" ;;
    '[') parse_json_array  "$jpath" ;;
    # At this point, the only valid single-character tokens are digits.
    ''|[!0-9]) exit 75;;
    *) value=$token
       # if asked, replace solidus ("\/") in json strings with normalized value: "/"
       [ "$NORMALIZE_SOLIDUS" -eq 1 ] && value=$(echo "$value" | sed 's#\\/#/#g')
       isleaf=1
       [ "$value" = '""' ] && isempty=1
       ;;
  esac
  [ "$value" = '' ] && return
  [ "$NO_HEAD" -eq 1 ] && [ -z "$jpath" ] && return

  [ "$LEAFONLY" -eq 0 ] && [ "$PRUNE" -eq 0 ] && print=1
  [ "$LEAFONLY" -eq 1 ] && [ "$isleaf" -eq 1 ] && [ $PRUNE -eq 0 ] && print=1
  [ "$LEAFONLY" -eq 0 ] && [ "$PRUNE" -eq 1 ] && [ "$isempty" -eq 0 ] && print=1
  [ "$LEAFONLY" -eq 1 ] && [ "$isleaf" -eq 1 ] && \
    [ $PRUNE -eq 1 ] && [ $isempty -eq 0 ] && print=1
  [ "$print" -eq 1 ] && printf "[%s]\t%s\n" "$jpath" "$value"
  :
}

parse_json_begin () {
  read -r token
  parse_json_value
  read -r token
  case "$token" in
    '') ;;
    *)  exit 72;;
  esac
}

check_target_config()
{
    if [ -z "$target_config_info" ]; then
        err_code="2"
        show_error "target_config_info variable is not defined." $err_code
        exit $err_code
    else
        echo "-------------- config info ----------------" >> $debug_log
        # Hide password
        echo "$target_config_info" |sed 's/"login_password.*/"login_password": *****/g' >> $debug_log
        echo "-----------------------------------------------------" >> $debug_log
    fi
}

show_usage()
{
    cat << __EOF__

    Usage:
        Requirement:
            Modify "target_config_info" variable at the beginning of this script to specify target's info
        Run the script:
            bash $(basename $BASH_SOURCE)
        Standalone options:
            --test-connection-only
            --dry-run-only
            --verbose
            --log-name [<path>/]<log filename> [e.g., --log-name mycluster.log]
            --terraform-path <path> [e.g., --terraform-path /var/test/output]
__EOF__
}

show_info()
{
    if [ "$verbose_mode" = "y" ]; then
        tee -a $debug_log 1>&2 << __EOF__
$*
__EOF__
    else
        echo "$*" >> $debug_log
    fi
    return 0
}

show_error()
{
    echo -e "{\n  \"reason\": \"$1\",\n  \"error_code\": $2,\n  \"log_file\": \"$debug_log\"\n}" | tee -a $debug_log
}

show_detail_to_stderr()
{
    echo "$*" >> $debug_log
    if [ "$detail_to_stderr" = "y" ]; then
        echo "$*" 1>&2
    fi
}

check_user_token()
{
    if [ "$access_token" = "null" ] || [ "$access_token" = "" ]; then
        err_code="2"
        show_error "Failed to get login token from REST API." $err_code 
        show_detail_to_stderr "Please check login account and login password."
        exit $err_code
    fi
}

parse_value_from_target_var()
{
    target_string="$1"
    if [ -z "$target_string" ]; then
        err_code="2"
        show_error "parse_value_from_target_var() target_string parameter can't be empty." $err_code
        exit $err_code
    fi
    echo "$target_config_info"|tr -d '\n'|grep -o "\"$target_string\":[^\"]*\"[^\"]*\""|sed -E 's/".*".*"(.*)"/\1/'
}

check_rest_api_url()
{
    show_info "Getting REST API URL..."
    api_url=$(parse_value_from_target_var "rest_api_url")

    if [ "$api_url" = "" ]; then
        err_code="2"
        show_error "Failed to get REST API URL from target_config_info." $err_code
        exit $err_code
    fi
    show_info "REST API URL = $api_url"
    show_info "Done."
}

rest_api_login()
{
    show_info "Logging into REST API..."
    if [ "$FEDERATORAI_ACCESS_TOKEN" = "" ]; then
        login_account=$(parse_value_from_target_var "login_account")
        if [ "$login_account" = "" ]; then
            err_code="2"
            show_error "Failed to get login account from target_config_info." $err_code
            exit $err_code
        fi
        login_password=$(parse_value_from_target_var "login_password")
        if [ "$login_password" = "" ]; then
            err_code="2"
            show_error "Failed to get login password from target_config_info." $err_code
            exit $err_code
        fi
        auth_string="${login_account}:${login_password}"
        auth_cipher=$(echo -n "$auth_string"|base64)
        if [ "$auth_cipher" = "" ]; then
            err_code="2"
            show_error "Failed to encode login string using base64 command." $err_code
            exit $err_code
        fi
        rest_output=$(curl -sS -k -X POST "$api_url/apis/v1/users/login" -H "accept: application/json" -H "authorization: Basic ${auth_cipher}")
        if [ "$?" != "0" ]; then
            err_code="3"
            show_error "Failed to connect to REST API service ($api_url/apis/v1/users/login)" $err_code
            show_detail_to_stderr "Please check REST API IP/login account/login password"
            exit $err_code
        fi
        access_token="$(echo $rest_output|tr -d '\n'|grep -o "\"accessToken\":[^\"]*\"[^\"]*\""|sed -E 's/".*".*"(.*)"/\1/')"
    else
        access_token="$FEDERATORAI_ACCESS_TOKEN"
        # Examine http response code
        token_test_http_response="$(curl -o /dev/null -sS -k -X GET "$api_url/apis/v1/resources/clusters" -w "%{http_code}" -H "accept: application/json" -H "Authorization: Bearer $access_token")"
        if [ "$token_test_http_response" != "200" ]; then
            err_code="3"
            show_error "The access_token can't access the REST API service." $err_code
            exit $err_code
        fi
    fi

    check_user_token

    show_info "Done."
}

rest_api_check_cluster_name()
{
    show_info "Getting the cluster name of the planning target ..."
    cluster_name=$(parse_value_from_target_var "cluster_name")
    if [ "$cluster_name" = "" ]; then
        err_code="2"
        show_error "Failed to get cluster name of the planning target from target_config_info." $err_code
        exit $err_code
    fi

    exec_cmd="curl -sS -k -X GET \"$api_url/apis/v1/resources/clusters\" -H \"accept: application/json\" -H \"Authorization: Bearer $access_token\""
    rest_output=$(eval $exec_cmd)
    if [ "$?" != "0" ]; then
        err_code="3"
        show_error "Failed to get clusters info using REST API (Command: $exec_cmd)" $err_code
        exit $err_code
    fi
    echo "$rest_output" |grep -q "\"name\":\"$cluster_name\""
    if [ "$?" != "0" ]; then
        err_code="3"
        show_error "The cluster name ($cluster_name) is not found in REST API return." $err_code
        show_detail_to_stderr "REST API output: $rest_output"
        exit $err_code
    fi

    show_info "cluster_name = $cluster_name"
    show_info "Done."
}

get_info_from_config()
{
    show_info "Getting the $resource_type info of the planning target..."

    resource_name=$(parse_value_from_target_var "resource_name")
    if [ "$resource_name" = "" ]; then
        err_code="2"
        show_error "Failed to get resource name of the planning target from target_config_info." $err_code
        exit $err_code
    fi

    if [ "$resource_type" = "controller" ]; then
        owner_reference_kind=$(parse_value_from_target_var "kind")
        if [ "$owner_reference_kind" = "" ]; then
            err_code="2"
            show_error "Failed to get controller kind of the planning target from target_config_info." $err_code
            exit $err_code
        fi

        owner_reference_kind="$(echo "$owner_reference_kind" | tr '[:upper:]' '[:lower:]')"
        if [ "$owner_reference_kind" = "statefulset" ] && [ "$owner_reference_kind" = "deployment" ] && [ "$owner_reference_kind" = "deploymentconfig" ]; then
            err_code="2"
            show_error "Only support controller type equals Statefulset/Deployment/DeploymentConfig." $err_code
            exit $err_code
        fi

        target_namespace=$(parse_value_from_target_var "namespace")
        if [ "$target_namespace" = "" ]; then
            err_code="2"
            show_error "Failed to get namespace of the planning target from target_config_info." $err_code
            exit $err_code
        fi
    else
        # resource_type = namespace
        # target_namespace is resource_name
        target_namespace=$resource_name
    fi

    iac_command=$(parse_value_from_target_var "iac_command")
    iac_command="$(echo "$iac_command" | tr '[:upper:]' '[:lower:]')"
    if [ "$iac_command" = "" ]; then
        err_code="2"
        show_error "Failed to get iac_command from target_config_info." $err_code
        exit $err_code
    elif [ "$iac_command" != "script" ] && [ "$iac_command" != "terraform" ]; then
        err_code="2"
        show_error "Only support iac_command equals 'script' or 'terraform'." $err_code
        exit $err_code
    fi

    readable_granularity=$(parse_value_from_target_var "time_interval")
    readable_granularity="$(echo "$readable_granularity" | tr '[:upper:]' '[:lower:]')"
    if [ "$readable_granularity" = "" ]; then
        err_code="2"
        show_error "Failed to get time interval of the planning target from target_config_info." $err_code
        exit $err_code
    fi

    min_cpu=$(parse_value_from_target_var "min_cpu")
    max_cpu=$(parse_value_from_target_var "max_cpu")
    cpu_headroom=$(parse_value_from_target_var "cpu_headroom")
    min_memory=$(parse_value_from_target_var "min_memory")
    max_memory=$(parse_value_from_target_var "max_memory")
    memory_headroom=$(parse_value_from_target_var "memory_headroom")
    trigger_condition=$(parse_value_from_target_var "trigger_condition")
    limits_only=$(parse_value_from_target_var "limits_only")
    requests_only=$(parse_value_from_target_var "requests_only")

    if [[ ! $min_cpu =~ ^[0-9]+$ ]]; then min_cpu=""; fi
    if [[ ! $max_cpu =~ ^[0-9]+$ ]]; then max_cpu=""; fi
    if [[ $cpu_headroom =~ ^[0-9]+[%]$ ]]; then
        # Percentage mode
        cpu_headroom_mode="%"
        # Remove last character as value
        if [ "$machine_type" = "Linux" ]; then
            cpu_headroom=`echo ${cpu_headroom::-1}`
        else
            # Mac
            cpu_headroom=`echo "${cpu_headroom%?}"`
        fi
    elif [[ $cpu_headroom =~ ^[0-9]+$ ]]; then
        # Absolute value (mCore) mode
        cpu_headroom_mode="m"
    else
        # No valid value or mode, set inactive value and mode
        cpu_headroom="0"
        cpu_headroom_mode="m"
    fi
    if [[ ! $min_memory =~ ^[0-9]+$ ]]; then min_memory=""; fi
    if [[ ! $max_memory =~ ^[0-9]+$ ]]; then max_memory=""; fi
    if [[ $memory_headroom =~ ^[0-9]+[%]$ ]]; then
        # Percentage mode
        memory_headroom_mode="%"
        # Remove last character as value
        if [ "$machine_type" = "Linux" ]; then
            memory_headroom=`echo ${memory_headroom::-1}`
        else
            # Mac
            memory_headroom=`echo "${memory_headroom%?}"`
        fi
    elif [[ $memory_headroom =~ ^[0-9]+$ ]]; then
        # Absolute value (byte) mode
        memory_headroom_mode="b"
    else
        # No valid value, set inactive value and mode
        memory_headroom="0"
        memory_headroom_mode="b"
    fi
    if [[ ! $trigger_condition =~ ^[0-9]+$ ]]; then trigger_condition=""; fi
    [ "$trigger_condition" = "0" ] && trigger_condition=""

    if [ "$limits_only" != 'y' ] && [ "$limits_only" != 'n' ]; then
        limits_only="n"
    fi
    if [ "$requests_only" != 'y' ] && [ "$requests_only" != 'n' ]; then
        requests_only="n"
    fi

    if [ "$readable_granularity" = "daily" ]; then
        granularity="3600"
    elif [ "$readable_granularity" = "weekly" ]; then
        granularity="21600"
    elif [ "$readable_granularity" = "monthly" ]; then
        granularity="86400"
    else
        err_code="2"
        show_error "Only support planning time interval equals daily/weekly/monthly." $err_code
        exit $err_code
    fi

    show_info "Cluster name = $cluster_name"
    show_info "Resource type = $resource_type"
    show_info "Resource name = $resource_name"
    if [ "$resource_type" = "controller" ]; then
        show_info "Kind = $owner_reference_kind"
        show_info "Namespace = $target_namespace"
    fi
    show_info "Time interval = $readable_granularity"
    show_info "min_cpu = $min_cpu"
    show_info "max_cpu = $max_cpu"
    show_info "cpu_headroom = $cpu_headroom"
    show_info "cpu_headroom_mode = $cpu_headroom_mode"
    show_info "min_memory = $min_memory"
    show_info "max_memory = $max_memory"
    show_info "memory_headroom = $memory_headroom"
    show_info "memory_headroom_mode = $memory_headroom_mode"
    show_info "Done."
}


get_valued_from_parsed_json(){
    all_data="$1"
    target_string="$2"
    echo "$all_data"|grep "$target_string"|awk '{print $2}'|sed 's/"//g'
}

parse_value_from_planning_for_multiple_conatiners(){
    for container_name in "${container_name_keys[@]}"
    do
        data=$(tokenize_json "$planning_all"| parse_json_begin)
        err_code="$?"
        if [ "$err_code" != "0" ]; then
            show_error "Failed to parse json output (multiple conatiners)." $err_code
            exit $err_code
        fi
        limit_con_cpu=$(get_valued_from_parsed_json "$data" "\[\"plannings\",0,\"plannings\",0,\"containerPlannings\",\"$container_name\",\"limitPlannings\",\"CPU_MILLICORES_USAGE\",0,\"numValue\"\]")
        limit_con_memory=$(get_valued_from_parsed_json "$data" "\[\"plannings\",0,\"plannings\",0,\"containerPlannings\",\"$container_name\",\"limitPlannings\",\"MEMORY_BYTES_USAGE\",0,\"numValue\"\]")
        request_con_cpu=$(get_valued_from_parsed_json "$data" "\[\"plannings\",0,\"plannings\",0,\"containerPlannings\",\"$container_name\",\"requestPlannings\",\"CPU_MILLICORES_USAGE\",0,\"numValue\"\]")
        request_con_memory=$(get_valued_from_parsed_json "$data" "\[\"plannings\",0,\"plannings\",0,\"containerPlannings\",\"$container_name\",\"requestPlannings\",\"MEMORY_BYTES_USAGE\",0,\"numValue\"\]")

        if [ "$limit_con_cpu" = "" ]; then
            err_code="3"
            show_error "Failed to parse limit cpu planning value of container ($container_name)." $err_code
            exit $err_code
        fi
        if [ "$limit_con_memory" = "" ]; then
            err_code="3"
            show_error "Failed to parse limit memory planning value of container ($container_name)." $err_code
            exit $err_code
        fi
        if [ "$request_con_cpu" = "" ]; then
            err_code="3"
            show_error "Failed to parse request cpu planning value of container ($container_name)." $err_code
            exit $err_code
        fi
        if [ "$request_con_memory" = "" ]; then
            err_code="3"
            show_error "Failed to parse request memory planning value of container ($container_name)." $err_code
            exit $err_code
        fi
        limit_con_cpu=$(( ($limit_con_cpu + $replica_number - 1)/$replica_number ))
        limit_con_memory=$(( ($limit_con_memory + $replica_number - 1)/$replica_number ))
        request_con_cpu=$(( ($request_con_cpu + $replica_number - 1)/$replica_number ))
        request_con_memory=$(( ($request_con_memory + $replica_number - 1)/$replica_number ))

        container_planning_array+=( "$container_name.limitPlannings.CPU_MILLICORES_USAGE:$limit_con_cpu" )
        container_planning_array+=( "$container_name.limitPlannings.MEMORY_BYTES_USAGE:$limit_con_memory" )
        container_planning_array+=( "$container_name.requestPlannings.CPU_MILLICORES_USAGE:$request_con_cpu" )
        container_planning_array+=( "$container_name.requestPlannings.MEMORY_BYTES_USAGE:$request_con_memory" )
        show_info "-------------- Planning for container ($container_name) --------------"
        show_info "resources.limits.cpu = $limit_con_cpu(m)"
        show_info "resources.limits.momory = $limit_con_memory(byte)"
        show_info "resources.requests.cpu = $request_con_cpu(m)"
        show_info "resources.requests.memory = $request_con_memory(byte)"
        show_info "-----------------------------------------------------"
    done
}

parse_value_from_planning()
{
    target_field="$1"
    target_resource="$2"
    if [ -z "$target_field" ]; then
        err_code="3"
        show_error "parse_value_from_planning() target_field parameter can't be empty." $err_code
        exit $err_code
    elif [ -z "$target_resource" ]; then
        err_code="3"
        show_error "parse_value_from_planning() target_resource parameter can't be empty." $err_code
        exit $err_code
    fi

    if [ "$target_field" != "limitPlannings" ] && [ "$target_field" != "requestPlannings" ]; then
        err_code="3"
        show_error "parse_value_from_planning() target_field can only be either 'limitPlannings' and 'requestPlannings'." $err_code
        exit $err_code
    fi

    if [ "$target_resource" != "CPU_MILLICORES_USAGE" ] && [ "$target_resource" != "MEMORY_BYTES_USAGE" ]; then
        err_code="3"
        show_error "parse_value_from_planning() target_field can only be either 'CPU_MILLICORES_USAGE' and 'MEMORY_BYTES_USAGE'." $err_code
        exit $err_code
    fi

    if [ "$resource_type" = "controller" ]; then
        data=$(tokenize_json "$planning_all"| parse_json_begin)
        err_code="$?"
        if [ "$err_code" != "0" ]; then
            show_error "Failed to parse json output (single conatiner)." $err_code
            exit $err_code
        fi
        echo $(get_valued_from_parsed_json "$data" "\[\"plannings\",0,\"plannings\",0,\"$target_field\",\"$target_resource\",0,\"numValue\"\]")
    else
        echo "$planning_all"|grep -o "\"$target_field\":[^{]*{[^}]*}[^}]*}"|grep -o "\"$target_resource\":[^\[]*\[[^]]*"|grep -o '"numValue":[^"]*"[^"]*"'|cut -d '"' -f4
    fi
}

get_container_number_and_name_list(){
    if [ "$DEMO_MODE" != "y" ]; then
        query_type="${owner_reference_kind}s"
        container_str=$($kube_cmd -n $target_namespace get $query_type ${resource_name} -o jsonpath='{.spec.template.spec.containers[*].name}')
        if [ "$container_str" = "" ]; then
            err_code="3"
            show_error "Failed to get container list (ns $target_namespace, $query_type, name ${resource_name})" $err_code
            exit $err_code
        fi
        container_array=(`echo "$container_str"`)
        container_number=${#container_array[@]}
    fi
}

get_planning_from_api()
{
    show_info "Getting planning values for the $resource_type through REST API..."
    show_info "Cluster name = $cluster_name"
    if [ "$resource_type" = "controller" ]; then
        show_info "Kind = $owner_reference_kind"
        show_info "Namespace = $target_namespace"
    else
        # namespace
        show_info "Namespace = $target_namespace"
    fi
    show_info "Resource name = $resource_name"
    show_info "Time interval = $readable_granularity"

    # Use 0 as 'now'
    interval_start_time="0"
    interval_end_time=$(($interval_start_time + $granularity - 1))

    show_info "Query interval (start) = 0"
    show_info "Query interval (end) = $interval_end_time"

    # Use planning here
    type="planning"
    if [ "$resource_type" = "controller" ]; then
        query_type="${owner_reference_kind}s"
        exec_cmd="curl -sS -k -X GET \"$api_url/apis/v1/plannings/clusters/$cluster_name/namespaces/$target_namespace/$query_type/${resource_name}?granularity=$granularity&type=$type&limit=1&order=asc&startTime=$interval_start_time&endTime=$interval_end_time\" -H \"accept: application/json\" -H \"Authorization: Bearer $access_token\""
    else
        # resource_type = namespace
        # Check if namespace is in monitoring state first
        exec_cmd="curl -sS -k -X GET \"$api_url/apis/v1/resources/clusters/$cluster_name/namespaces?names=$target_namespace\" -H \"accept: application/json\" -H \"Authorization: Bearer $access_token\""
        rest_output=$(eval $exec_cmd)
        if [ "$?" != "0" ]; then
            err_code="3"
            show_error "Failed to get namespace $target_namespace resource info using REST API (Command: $exec_cmd)" $err_code
            exit $err_code
        fi
        namespace_state="$(echo $rest_output|tr -d '\n'|grep -o "\"name\":.*\"${target_namespace}.*"|grep -o "\"state\":.*\".*\""|cut -d '"' -f4)"
        if [ "$namespace_state" != "monitoring" ]; then
            err_code="1"
            show_error "Namespace $target_namespace is not in 'monitoring' state." $err_code
            show_detail_to_stderr "REST API output: $rest_output"
            exit $err_code
        fi
        exec_cmd="curl -sS -k -X GET \"$api_url/apis/v1/plannings/clusters/$cluster_name/namespaces/$target_namespace?granularity=$granularity&type=$type&limit=1&order=asc&startTime=$interval_start_time&endTime=$interval_end_time\" -H \"accept: application/json\" -H \"Authorization: Bearer $access_token\""
    fi

    for repeat in `seq 1 10`
    do
        rest_output=$(eval $exec_cmd)
        if [ "$?" != "0" ]; then
            err_code="3"
            show_error "Failed to get planning value of $resource_type using REST API (Command: $exec_cmd)" $err_code
            exit $err_code
        fi
        planning_all="$rest_output"
        # check if return is '"plannings":[]}'
        planning_count=${#planning_all}
        if [ "$planning_all" = "" ] || [ "$planning_count" -le "15" ]; then
            err_code="1"
            show_error "Planning value ($readable_granularity) is empty." $err_code
            show_detail_to_stderr "REST API output: ${rest_output}"
            exit $err_code
        fi

        if [ "$resource_type" = "controller" ]; then
            data=$(tokenize_json "$planning_all"| parse_json_begin)
            err_code="$?"
            if [ "$err_code" != "0" ]; then
                show_error "Failed to parse json output (API result)." $err_code
                exit $err_code
            fi
            records=$(echo "$data" |grep "\[\"plannings\",0,\"plannings\",0,\"containerPlannings\"")
            container_records_num="$(echo "$records" | cut -d ',' -f6|sort|uniq|wc -l|xargs)"

            if [ "$DEMO_MODE" != "y" ]; then
                if [ "0$container_records_num" -ne "0$container_number" ]; then
                    err_code="3"
                    show_error "Container number doesn't match (system:planning=$container_number:$container_records_num)" $err_code
                    exit $err_code
                fi
            fi

            container_name_keys=($(echo "$records" | cut -d ',' -f6|sort|uniq|sed 's/"//g'))
            if [ "$DEMO_MODE" != "y" ]; then
                # verify all container name (system) do have key in planning
                need_repeat=""
                for name in "${container_array[@]}"
                do
                    matched="n"
                    for id in "${container_name_keys[@]}"
                    do
                        if [ "$id" = "$name" ]; then
                            matched="y"
                            break
                        fi
                    done
                    if [ "$matched" != "y" ]; then
                        need_repeat="y"
                        break
                    fi
                done

                if [ "$need_repeat" = "y" ]; then
                    if [ "$repeat" = "10" ]; then
                        err_code="3"
                        show_error "Can't locate container name ($name) as key inside Federator.ai planning output after repeat $repeat times." $err_code
                        exit $err_code
                    fi
                    sleep 1
                    continue
                else
                    break
                fi
            else
                # Demo
                break
            fi
        fi
    done

    limits_pod_cpu=$(parse_value_from_planning "limitPlannings" "CPU_MILLICORES_USAGE")
    requests_pod_cpu=$(parse_value_from_planning "requestPlannings" "CPU_MILLICORES_USAGE")
    limits_pod_memory=$(parse_value_from_planning "limitPlannings" "MEMORY_BYTES_USAGE")
    requests_pod_memory=$(parse_value_from_planning "requestPlannings" "MEMORY_BYTES_USAGE")

    if [ "$resource_type" = "controller" ]; then
        if [ "$DEMO_MODE" != "y" ]; then
            replica_number="$($kube_cmd get $owner_reference_kind $resource_name -n $target_namespace -o json|tr -d '\n'|grep -o "\"spec\":.*"|grep -o "\"replicas\":[^,]*[0-9]*"|head -1|cut -d ':' -f2|xargs)"

            if [ "$replica_number" = "" ]; then
                err_code="4"
                show_error "Failed to get replica number from controller ($resource_name) in ns $target_namespace" $err_code
                exit $err_code
            fi

            case $replica_number in
                ''|*[!0-9]*) err_code="4" && show_error "Replica number needs to be an integer." $err_code && exit $err_code ;;
                *) ;;
            esac

            show_info "Controller replica number = $replica_number"
            if [ "$replica_number" = "0" ]; then
                err_code="4"
                show_error "Replica number is zero." $err_code
                exit $err_code
            fi
        else
            replica_number="1"
        fi

        # Round up the result (planning / replica)
        limits_pod_cpu=$(( ($limits_pod_cpu + $replica_number - 1)/$replica_number ))
        requests_pod_cpu=$(( ($requests_pod_cpu + $replica_number - 1)/$replica_number ))
        limits_pod_memory=$(( ($limits_pod_memory + $replica_number - 1)/$replica_number ))
        requests_pod_memory=$(( ($requests_pod_memory + $replica_number - 1)/$replica_number ))
    fi

    if [ "$resource_type" = "controller" ] && [ "0$container_records_num" -ge "2" ]; then
        parse_value_from_planning_for_multiple_conatiners
    fi

    show_info "-------------- Planning for $resource_type --------------"
    show_info "resources.limits.cpu = $limits_pod_cpu(m)"
    show_info "resources.limits.momory = $limits_pod_memory(byte)"
    show_info "resources.requests.cpu = $requests_pod_cpu(m)"
    show_info "resources.requests.memory = $requests_pod_memory(byte)"
    show_info "-----------------------------------------------------"

    if [ "$limits_pod_cpu" = "" ] || [ "$requests_pod_cpu" = "" ] || [ "$limits_pod_memory" = "" ] || [ "$requests_pod_memory" = "" ]; then
        err_code="3"
        if [ "$resource_type" = "controller" ]; then
            show_error "Failed to get controller ($resource_name) planning. Missing value." $err_code
        else
            # namespace
            show_error "Failed to get namespace ($target_namespace) planning. Missing value." $err_code
        fi
        exit $err_code
    fi

    show_info "Done."
}

apply_min_max_margin()
{
    planning_name="$1"
    mode_name="$2"
    headroom_name="$3"
    min_name="$4"
    max_name="$5"
    original_value="${!planning_name}"

    if [ "${!mode_name}" = "%" ]; then
        # Percentage mode
        export $planning_name=$(( (${!planning_name}*(100+${!headroom_name})+99)/100 ))
    else
        # Absolute value mode
        export $planning_name=$(( ${!planning_name} + ${!headroom_name} ))
    fi
    if [ "${!min_name}" != "" ] && [ "${!min_name}" -gt "${!planning_name}" ]; then
        # Assign minimum value
        export $planning_name="${!min_name}"
    fi
    if [ "${!max_name}" != "" ] && [ "${!planning_name}" -gt "${!max_name}" ]; then
        # Assign maximum value
        export $planning_name="${!max_name}"
    fi

    show_info "-------------- Calculate min/max/headroom/default -------------"
    show_info "${mode_name} = ${!mode_name}"
    show_info "${headroom_name} = ${!headroom_name}"
    show_info "${min_name} = ${!min_name}"
    show_info "${max_name} = ${!max_name}"
    show_info "${planning_name} (before)= ${original_value}"
    show_info "${planning_name} (after)= ${!planning_name}"
    show_info "---------------------------------------------------------------"

}

check_default_value_satisfied()
{
    void_mode="x"
    void_value="0"
    show_info "Verifying default value satisfied..."
    apply_min_max_margin "requests_pod_cpu" "void_mode" "void_value" "default_min_cpu" "void"
    apply_min_max_margin "requests_pod_memory" "void_mode" "void_value" "default_min_memory" "void"
    apply_min_max_margin "limits_pod_cpu" "void_mode" "void_value" "default_min_cpu" "void"
    apply_min_max_margin "limits_pod_memory" "void_mode" "void_value" "default_min_memory" "void"
    show_info "Done"
}

compare_trigger_condition_with_difference()
{
    before=$1
    after=$2
    trigger_result=""
    result=$(awk -v t1="${!before}" -v t2="${!after}" 'BEGIN{printf "%.0f", (t2-t1)/t1 * 100}')
    show_info "Comparing current value ($before=${!before}) and planning value ($after=${!after})..."
    if [ "$result" -gt "0" ]; then
        # planning > current, ignore checking
        trigger_result="y"
        show_info "planning value is bigger than current value, ignore trigger condition check."
        return
    fi
    # Get absolute value
    result=$(echo ${result#-})
    show_info "comp_result=${result}%, trigger_condition=${trigger_condition}%"
    if [ "$trigger_condition" -le "$result" ]; then
        trigger_result="y"
        show_info "$(echo "$before"|awk -F'_' '{print $1"_"$2}') meet the trigger condition."
    else
        trigger_result="n"
        show_info "$(echo "$before"|awk -F'_' '{print $1"_"$2}') will be skipped."
    fi
}

check_trigger_condition_on_all_metrics()
{
    show_info "Verifying trigger condition..."
    if [ "$trigger_condition" != "" ]; then
        if [ "$limit_cpu_before" != "N/A" ]; then
            compare_trigger_condition_with_difference "limit_cpu_before_converted" "limits_pod_cpu"
            do_limit_cpu="$trigger_result"
        else
            do_limit_cpu="y"
        fi
        if [ "$limit_memory_before" != "N/A" ]; then
            compare_trigger_condition_with_difference "limit_memory_before_converted" "limits_pod_memory"
            do_limit_memory="$trigger_result"
        else
            do_limit_memory="y"
        fi
        if [ "$request_cpu_before" != "N/A" ]; then
            compare_trigger_condition_with_difference "request_cpu_before_converted" "requests_pod_cpu"
            do_request_cpu="$trigger_result"
        else
            do_request_cpu="y"
        fi
        if [ "$request_memory_before" != "N/A" ]; then
            compare_trigger_condition_with_difference "request_memory_before_converted" "requests_pod_memory"
            do_request_memory="$trigger_result"
        else
            do_request_memory="y"
        fi
    else
        show_info "'trigger_condition' is disabled."
        do_limit_cpu="y"
        do_limit_memory="y"
        do_request_cpu="y"
        do_request_memory="y"
    fi

    # New rule, if one of action is 'y', let every action become 'y'
    # Still reserve limits_only and requests_only
    if [ "$do_limit_cpu" = "y" ] || [ "$do_limit_memory" = "y" ] || [ "$do_request_cpu" = "y" ] || [ "$do_request_memory" = "y" ]; then
        show_info "One of do action is 'y', set all do actions to 'y'. Still reserve limits_only or requests_only settings."
        do_limit_cpu="y"
        do_limit_memory="y"
        do_request_cpu="y"
        do_request_memory="y"
    fi
    if [ "$limits_only" = "y" ]; then
        show_info "'Limits only' is enabled."
        do_request_cpu="n"
        do_request_memory="n"
    fi

    if [ "$requests_only" = "y" ]; then
        show_info "'Requests only' is enabled."
        do_limit_cpu="n"
        do_limit_memory="n"
    fi
    show_info "----- Final results -----"
    show_info "do_limit_cpu     : $do_limit_cpu"
    show_info "do_limit_memory  : $do_limit_memory"
    show_info "do_request_cpu   : $do_request_cpu"
    show_info "do_request_memory: $do_request_memory"
    show_info "-------------------------"
    show_info "Done."
}

get_value_from_planning_array(){
    container_name="$1"
    type="$2"
    metric="$3"

    ret=""
    for record in "${container_planning_array[@]}"
    do
        record_key="${record%%:*}"
        record_value=${record#*:}
        if [ "$record_key" = "$container_name.$type.$metric" ]; then
            # Found record
            ret=$record_value
            break
        fi
    done
    echo $ret
}

get_value_from_resource_array(){
    #container_resource_array+=( "$container_name.before.limits.cpu.original:$limit_cpu" )
    container_name="$1"
    time="$2"
    type="$3"
    metric="$4"
    modified="$5"

    ret=""
    for record in "${container_resource_array[@]}"
    do
        record_key="${record%%:*}"
        record_value=${record#*:}
        if [ "$record_key" = "$container_name.$time.$type.$metric.$modified" ]; then
            # Found record
            ret=$record_value
            break
        fi
    done
    echo $ret
}

do_filter_min_max_headroom(){
    apply_min_max_margin "limits_pod_cpu" "cpu_headroom_mode" "cpu_headroom" "min_cpu" "max_cpu"
    apply_min_max_margin "limits_pod_memory" "memory_headroom_mode" "memory_headroom" "min_memory" "max_memory"
    apply_min_max_margin "requests_pod_cpu" "cpu_headroom_mode" "cpu_headroom" "min_cpu" "max_cpu"
    apply_min_max_margin "requests_pod_memory" "memory_headroom_mode" "memory_headroom" "min_memory" "max_memory"
}

generate_controller_set_cmd(){
    set_cmd=""
    if [ "$do_limit_cpu" = "y" ]; then
        if [ "$do_limit_memory" = "y" ]; then
            set_cmd="--limits cpu=${limits_pod_cpu}m,memory=${limits_pod_memory}"
        else
            set_cmd="--limits cpu=${limits_pod_cpu}m"
        fi
    else
        # do_limit_cpu = n
        if [ "$do_limit_memory" = "y" ]; then
            set_cmd="--limits memory=${limits_pod_memory}"
        fi
    fi
    if [ "$do_request_cpu" = "y" ]; then
        if [ "$do_request_memory" = "y" ]; then
            set_cmd="$set_cmd --requests cpu=${requests_pod_cpu}m,memory=${requests_pod_memory}"
        else
            set_cmd="$set_cmd --requests cpu=${requests_pod_cpu}m"
        fi
    else
        # do_request_cpu = n
        if [ "$do_request_memory" = "y" ]; then
            set_cmd="$set_cmd --requests memory=${requests_pod_memory}"
        fi
    fi

    # For get_controller_resources_from_kubecmd 'after' mode
    if [ "$machine_type" = "Linux" ]; then
        [ "$do_limit_cpu" = "n" ] && limits_pod_cpu="${limit_cpu_before::-1}"
        [ "$do_request_cpu" = "n" ] && requests_pod_cpu="${request_cpu_before::-1}"
    else
        # Mac
        [ "$do_limit_cpu" = "n" ] && limits_pod_cpu="${limit_cpu_before%?}"
        [ "$do_request_cpu" = "n" ] && requests_pod_cpu="${request_cpu_before%?}"
    fi
    [ "$do_limit_memory" = "n" ] && limits_pod_memory=$limit_memory_before
    [ "$do_request_memory" = "n" ] && requests_pod_memory=$request_memory_before

    container_resource_array+=( "$container_name.after.limits.cpu.original:$limits_pod_cpu" )
    container_resource_array+=( "$container_name.after.limits.memory.original:$limits_pod_memory" )
    container_resource_array+=( "$container_name.after.requests.cpu.original:$requests_pod_cpu" )
    container_resource_array+=( "$container_name.after.requests.memory.original:$requests_pod_memory" )

    if [ "$set_cmd" = "" ]; then
        exec_cmd="N/A, execution skipped due to trigger condition is not met."
        execution_skipped="y"
    else
        execution_skipped="n"
        if [ "0$container_records_num" -ge "2" ]; then
            exec_cmd="$kube_cmd -n $target_namespace set resources $owner_reference_kind $resource_name -c=$container_name $set_cmd"
        else
            exec_cmd="$kube_cmd -n $target_namespace set resources $owner_reference_kind $resource_name $set_cmd"
        fi
    fi
    container_resource_array+=( "$container_name.after.issue.execute.cmd:$exec_cmd" )
}

execute_command(){
    # Optional parameter
    local con_name=$1

    show_info "Issuing cmd:"
    show_info "$exec_cmd"

    if [ "$execution_skipped" = "y" ]; then
        execution_time="N/A, execution skipped due to trigger condition is not met."
        if [ "$con_name" != "" ]; then
            container_resource_array+=( "$con_name.after.issue.execute.time:$execution_time" )
        fi
    else
        if [ "$mode" = "dry_run" ]; then
            execution_time="N/A, execution skipped due to --dry-run-only is specified."
            show_info "Dry run is enabled, skip execution."
            show_info "Done. Dry run is done."
            if [ "$con_name" != "" ]; then
                container_resource_array+=( "$con_name.after.issue.execute.time:$execution_time" )
            fi
            return
        fi

        execution_time="$(date -u)"
        if [ "$con_name" != "" ]; then
            container_resource_array+=( "$con_name.after.issue.execute.time:$execution_time" )
        fi
        if [ "$resource_type" = "namespace" ]; then
            # Clean other quotas
            all_quotas=$($kube_cmd -n $target_namespace get quota -o name|cut -d '/' -f2)
            for quota in $(echo "$all_quotas")
            do
                $kube_cmd -n $target_namespace patch quota $quota --type json --patch "[ { \"op\" : \"remove\" , \"path\" : \"/spec/hard/limits.cpu\"}]" >/dev/null 2>&1
                $kube_cmd -n $target_namespace patch quota $quota --type json --patch "[ { \"op\" : \"remove\" , \"path\" : \"/spec/hard/limits.memory\"}]" >/dev/null 2>&1
                $kube_cmd -n $target_namespace patch quota $quota --type json --patch "[ { \"op\" : \"remove\" , \"path\" : \"/spec/hard/requests.cpu\"}]" >/dev/null 2>&1
                $kube_cmd -n $target_namespace patch quota $quota --type json --patch "[ { \"op\" : \"remove\" , \"path\" : \"/spec/hard/requests.memory\"}]" >/dev/null 2>&1
            done
            # Delete previous federator.ai quota
            $kube_cmd -n $target_namespace delete quota $quota_name > /dev/null 2>&1
        fi

        eval $exec_cmd 3>&1 1>&2 2>&3 1>>$debug_log | tee -a $debug_log
        if [ "${PIPESTATUS[0]}" != "0" ]; then
            err_code="5"
            if [ "$resource_type" = "controller" ]; then
                show_error "Failed to update resources for $owner_reference_kind $resource_name" $err_code
            else
                show_error "Failed to update quota for namespace $target_namespace" $err_code
            fi
            exit $err_code
        fi
    fi
}

update_target_resources()
{
    mode=$1
    if [ "$mode" = "" ]; then
        err_code="3"
        show_error "update_target_resources() mode parameter can't be empty." $err_code
        exit $err_code
    fi

    show_info "Updateing $resource_type resources..."

    if [ "$resource_type" = "controller" ] && [ "0$container_records_num" -ge "2" ]; then

        for container_name in "${container_name_keys[@]}"
        do
            show_info "Calculating min/max/headroom for container ($container_name)..."
            limits_pod_cpu=$(get_value_from_planning_array $container_name limitPlannings CPU_MILLICORES_USAGE)
            limits_pod_memory=$(get_value_from_planning_array $container_name limitPlannings MEMORY_BYTES_USAGE)
            requests_pod_cpu=$(get_value_from_planning_array $container_name requestPlannings CPU_MILLICORES_USAGE)
            requests_pod_memory=$(get_value_from_planning_array $container_name requestPlannings MEMORY_BYTES_USAGE)
            if [ "$limits_pod_cpu" = "" ] || [ "$requests_pod_cpu" = "" ] || [ "$limits_pod_memory" = "" ] || [ "$requests_pod_memory" = "" ]; then
                err_code="3"
                show_error "Missing planning values." $err_code
                exit $err_code
            fi

            do_filter_min_max_headroom
            show_info "Done"

            # Make sure default cpu & memory value above existing one
            check_default_value_satisfied

            # Make sure trigger condition is met
            limit_cpu_before_converted=$(get_value_from_resource_array $container_name before limits cpu converted)
            limit_memory_before_converted=$(get_value_from_resource_array $container_name before limits memory converted)
            request_cpu_before_converted=$(get_value_from_resource_array $container_name before requests cpu converted)
            request_memory_before_converted=$(get_value_from_resource_array $container_name before requests memory converted)
            limit_cpu_before=$(get_value_from_resource_array $container_name before limits cpu original)
            limit_memory_before=$(get_value_from_resource_array $container_name before limits memory original)
            request_cpu_before=$(get_value_from_resource_array $container_name before requests cpu original)
            request_memory_before=$(get_value_from_resource_array $container_name before requests memory original)

            # Make sure trigger condition is met
            check_trigger_condition_on_all_metrics

            if [ "$iac_command" = "script" ]; then
                generate_controller_set_cmd
                execute_command $container_name
            else
                # terraform
                err_code="3"
                show_error "terraform with multiple container is not yet supported." $err_code
                exit $err_code
            fi

        done
    else
        if [ "$limits_pod_cpu" = "" ] || [ "$requests_pod_cpu" = "" ] || [ "$limits_pod_memory" = "" ] || [ "$requests_pod_memory" = "" ]; then
            err_code="3"
            show_error "Missing planning values." $err_code
            exit $err_code
        fi
        show_info "Calculating min/max/headroom ..."
        do_filter_min_max_headroom
        show_info "Done"

        # Make sure default cpu & memory value above existing one
        check_default_value_satisfied

        # Make sure trigger condition is met
        check_trigger_condition_on_all_metrics

        if [ "$iac_command" = "script" ]; then
            if [ "$resource_type" = "controller" ]; then
                generate_controller_set_cmd
            else
                # namespace quota
                execution_skipped="y"
                if [ "$do_limit_cpu" = "n" ]; then
                    limits_pod_cpu="${limit_cpu_before::-1}"
                else
                    execution_skipped="n"
                fi
                if [ "$do_limit_memory" = "n" ]; then
                    limits_pod_memory=$limit_memory_before
                else
                    execution_skipped="n"
                fi
                if [ "$do_request_cpu" = "n" ]; then
                    requests_pod_cpu="${request_cpu_before::-1}"
                else
                    execution_skipped="n"
                fi
                if [ "$do_request_memory" = "n" ]; then
                    requests_pod_memory=$request_memory_before
                else
                    execution_skipped="n"
                fi

                if [ "$execution_skipped" = "y" ]; then
                    exec_cmd="N/A, execution skipped due to trigger condition is not met."
                else
                    exec_cmd="$kube_cmd -n $target_namespace create quota $quota_name --hard=limits.cpu=${limits_pod_cpu}m,limits.memory=${limits_pod_memory},requests.cpu=${requests_pod_cpu}m,requests.memory=${requests_pod_memory}"
                fi
            fi

            execute_command
        else
            # iac_command = terraform
            # dry_run = normal

            variable_tf_name="${terraform_path}/federatorai_variables.tf"
            auto_tfvars_name="${terraform_path}/federatorai_recommendations.auto.tfvars"
            auto_tfvars_previous_name="${terraform_path}/federatorai_recommendations.auto.tfvars.previous"

            create_auto_tfvars
            create_variable_tf

            # Print final json output
            if [ "$resource_type" = "controller" ]; then
                echo -e "{\n  \"info\": {\n     \"cluster_name\": \"$cluster_name\",\n     \"resource_type\": \"$resource_type\",\n     \"namespace\": \"$target_namespace\",\n     \"resource_name\": \"$resource_name\",\n     \"kind\": \"$owner_reference_kind\",\n     \"time_interval\": \"$readable_granularity\",\n     \"execute_cmd\": \"N/A\",\n     \"execution_time\": \"N/A\"\n  },\n  \"log_file\": \"$debug_log\",\n  \"before_execution\":  {\n     \"limits\": {\n       \"cpu\": \"$limit_cpu_before\",\n       \"memory\": \"$limit_memory_before\"\n     },\n     \"requests\": {\n       \"cpu\": \"$request_cpu_before\",\n       \"memory\": \"$request_memory_before\"\n     }\n  },\n  \"recommended_values\": {\n     \"tf_file\": \"$variable_tf_name\",\n     \"tfvars_file\": \"$auto_tfvars_name\",\n     \"limits\": {\n       \"cpu\": \"${limits_pod_cpu}m\",\n       \"memory\": \"$limits_pod_memory\"\n     },\n     \"requests\": {\n       \"cpu\": \"${requests_pod_cpu}m\",\n       \"memory\": \"$requests_pod_memory\"\n     }\n  }\n}"  | tee -a $debug_log
            else
                #resource_type = namespace
                echo -e "{\n  \"info\": {\n     \"cluster_name\": \"$cluster_name\",\n     \"resource_type\": \"$resource_type\",\n     \"resource_name\": \"$target_namespace\",\n     \"time_interval\": \"$readable_granularity\",\n     \"execute_cmd\": \"N/A\",\n     \"execution_time\": \"N/A\"\n  },\n  \"log_file\": \"$debug_log\",\n  \"before_execution\":  {\n     \"limits\": {\n       \"cpu\": \"$limit_cpu_before\",\n       \"memory\": \"$limit_memory_before\"\n     },\n     \"requests\": {\n       \"cpu\": \"$request_cpu_before\",\n       \"memory\": \"$request_memory_before\"\n     }\n  },\n  \"recommended_values\": {\n     \"tf_file\": \"$variable_tf_name\",\n     \"tfvars_file\": \"$auto_tfvars_name\",\n     \"limits\": {\n       \"cpu\": \"${limits_pod_cpu}m\",\n       \"memory\": \"$limits_pod_memory\"\n     },\n     \"requests\": {\n       \"cpu\": \"${requests_pod_cpu}m\",\n       \"memory\": \"$requests_pod_memory\"\n     }\n  }\n}"  | tee -a $debug_log
            fi
        fi
    fi 

    show_info "Done"
}

create_variable_tf()
{
    if [ ! -f "$variable_tf_name" ]; then
        echo "variable \"federatorai_recommendations\" {" >> $variable_tf_name
        echo "    description = \"Recommendations given by Federator.ai\"" >> $variable_tf_name
        echo "    type        = map(map(map(string)))" >> $variable_tf_name
        echo "}" >> $variable_tf_name
    fi
    module_name="${resource_id}_${cluster_name}"
    cat $variable_tf_name |grep -q "module \"$module_name\" {"
    if [ "$?" != "0" ]; then
        echo "" >> $variable_tf_name
        echo "module \"$module_name\" {" >> $variable_tf_name
        echo "    source  = \"prophetstor-ai/resource-provision/federatorai\"" >> $variable_tf_name
        echo "    version = \"5.0.0\"" >> $variable_tf_name
        echo "    federatorai_resource_id = \"${resource_id}\"" >> $variable_tf_name
        echo "    federatorai_cluster_name = \"${cluster_name}\"" >> $variable_tf_name
        echo "    federatorai_recommendations = var.federatorai_recommendations" >> $variable_tf_name
        echo "}" >> $variable_tf_name
    fi

    show_info "tf file ($variable_tf_name) is generated."
}

create_auto_tfvars()
{
    if [ -f "$auto_tfvars_name" ]; then
        mv $auto_tfvars_name $auto_tfvars_previous_name
    fi

    if [ "$resource_type" = "controller" ]; then
        resource_id="federatorai_${owner_reference_kind}_${resource_name}_${target_namespace}"
    else
        resource_id="federatorai_namespace_${resource_name}"
    fi

    declare -A cluster_resource_map

    # Merge previous into map first
    if [ -f "$auto_tfvars_previous_name" ]; then
        rec_num="0"
        merge_tfvars "" < $auto_tfvars_previous_name
        rm -f $auto_tfvars_previous_name > /dev/null 2>&1
    fi

    # Add Current entry
    current_time="$(date)"
    current_rec="#UpdateTime=\"$current_time\",recommended_cpu_request=\"${requests_pod_cpu}m\",recommended_memory_request=\"$requests_pod_memory\",recommended_cpu_limit=\"${limits_pod_cpu}m\",recommended_memory_limit=\"$limits_pod_memory\""
    cluster_resource_map["federatorai_recommendations,$cluster_name,$resource_id"]="$current_rec"

    # Do export
    export_final_tfvars

    show_info "tfvars file ($auto_tfvars_name) is generated."
}

export_final_tfvars()
{
    > $auto_tfvars_name

    cluster_list=$(echo "${!cluster_resource_map[@]}"|tr ' ' '\n'|awk -F',' '{print $2}'|sort|uniq)

    # Generate final tfvars
    echo "federatorai_recommendations = {" >> $auto_tfvars_name
    for cluster in $(echo $cluster_list)
    do
        echo "    $cluster = {" >> $auto_tfvars_name
        for key in "${!cluster_resource_map[@]}"
        do
            target_cluster=$(echo "$key"|cut -d',' -f2)
            if [ "$target_cluster" = "$cluster" ]; then
                resource=$(echo "$key"|cut -d',' -f3)
                echo "        $resource = {" >> $auto_tfvars_name
                rec_string=${cluster_resource_map[$key]}
                update_time=$(echo $rec_string|grep -o "#UpdateTime=[^\"]*\"[^\"]*\"")
                reccpureq=$(echo $rec_string|grep -o "recommended_cpu_request=[^\"]*\"[^\"]*\"")
                recmemreq=$(echo $rec_string|grep -o "recommended_memory_request=[^\"]*\"[^\"]*\"")
                reccpulim=$(echo $rec_string|grep -o "recommended_cpu_limit=[^\"]*\"[^\"]*\"")
                recmemlim=$(echo $rec_string|grep -o "recommended_memory_limit=[^\"]*\"[^\"]*\"")
                echo "            $update_time" >> $auto_tfvars_name
                echo "            $reccpureq" >> $auto_tfvars_name
                echo "            $recmemreq" >> $auto_tfvars_name
                echo "            $reccpulim" >> $auto_tfvars_name
                echo "            $recmemlim" >> $auto_tfvars_name
                echo "        }" >> $auto_tfvars_name
            fi
        done
        echo "    }" >> $auto_tfvars_name
    done
    echo "}" >> $auto_tfvars_name
}

merge_tfvars()
{
    local KEYS
    local K
    local V

    while true
    do
        read LINE
        if [ "${LINE}" = "" ]
        then
            return
        fi

        if [[ "$LINE" =~ "#UpdateTime" ]]; then
            K=`echo ${LINE} | awk -F'=' '{print $1}'`
            V=`echo ${LINE} | awk -F'=' '{print $2}'`
        else
            K=`echo ${LINE} | awk -F'=' '{print $1}' | tr -d '[:space:]'`
            V=`echo ${LINE} | awk -F'=' '{print $2}' | tr -d '[:space:]'`
        fi

        if [ "${K}" = "}" ]
        then
            return
        else
            if [ "$1" = "" ]
            then
                KEYS="${K}"
            else
                KEYS="$1,${K}"
            fi

            if [ "${V}" = "{" ]
            then
                merge_tfvars ${KEYS}
            else
                rec_key=$(echo ${KEYS##*,})
                final_rec_value_string="${final_rec_value_string}${final_rec_value_string:+,}$rec_key=$V"
                rec_num=$(($rec_num + 1))
                if [ "$rec_num" = "5" ]; then
                    final_key=$(echo $KEYS|rev|cut -d',' -f2-|rev)
                    cluster_resource_map[${final_key}]="$final_rec_value_string"
                    rec_num="0"
                    final_rec_value_string=""
                fi
            fi
        fi
    done
}

convert_cpu_unit_to_bytes()
{
    unit="$1"
    result=$(echo "$unit"|awk '
    /^[0-9.]+$/ {
      print $0 * 1000
      exit
    }
    /^[0-9.]+m$/ {
      match($0, /^[0-9.]+/)
      mynumber = substr($0,RSTART,RLENGTH)
      print mynumber
      exit
    }
    // {
      print -1
    }
    ')
    echo $result
}

convert_memory_unit_to_bytes()
{
    unit="$1"
    result=$(echo "$unit"|awk '
    /^[0-9.]+e$/ {
      print -1
      exit
    }
    /^[0-9]+$/ {
      print $0
      exit
    }
    /^[0-9.]+[EPTGMkKi]+$/ {
      match($0, /^[0-9.]+/)
      myunit = substr($0,RLENGTH+1,length($0))
      mynumber = substr($0,RSTART,RLENGTH)
      #print mynumber,myunit
      if (myunit == "E")
        print mynumber * 1000 * 1000 * 1000 * 1000 * 1000 * 1000
      else if (myunit == "P")
        print mynumber * 1000 * 1000 * 1000 * 1000 * 1000
      else if (myunit == "T")
        print mynumber * 1000 * 1000 * 1000 * 1000
      else if (myunit == "G")
        print mynumber * 1000 * 1000 * 1000
      else if (myunit == "M")
        print mynumber * 1000 * 1000
      else if (myunit == "k")
        print mynumber * 1000
      else if (myunit == "Ei"||myunit == "EiB")
        print mynumber * 1024 * 1024 * 1024 * 1024 * 1024 * 1024
      else if (myunit == "Pi"||myunit == "PiB")
        print mynumber * 1024 * 1024 * 1024 * 1024 * 1024
      else if (myunit == "Ti"||myunit == "TiB")
        print mynumber * 1024 * 1024 * 1024 * 1024
      else if (myunit == "Gi"||myunit == "GiB")
        print mynumber * 1024 * 1024 * 1024
      else if (myunit == "Mi"||myunit == "MiB")
        print mynumber * 1024 * 1024
      else if (myunit == "Ki"||myunit == "KiB")
        print mynumber * 1024
      else
        print -1
      exit
    }
    /^[0-9.]+[eE][0-9]+$/ {
      IGNORECASE = 1;
      match($0, /^[0-9.]+/)
      myexponumber = substr($0,RLENGTH+2,length($0))
      mynumber = substr($0,RSTART,RLENGTH)
      print mynumber * 10 ^ myexponumber
      exit
    }
    /^[0-9.]+[m]+$/ {
      match($0, /^[0-9.]+/)
      myunit = substr($0,RLENGTH+1,length($0))
      mynumber = substr($0,RSTART,RLENGTH)
      printf "%.3f",mynumber /1000
      exit
    }
    // {
      print -1
    }
    ')
    echo $result
}

parse_value_from_resource()
{
    target_field="$1"
    target_resource="$2"
    if [ -z "$target_field" ]; then
        err_code="3"
        show_error "parse_value_from_resource() target_field parameter can't be empty." $err_code
        exit $err_code
    elif [ -z "$target_resource" ]; then
        err_code="3"
        show_error "parse_value_from_resource() target_resource parameter can't be empty." $err_code
        exit $err_code
    fi

    if [ "$target_field" != "limits" ] && [ "$target_field" != "requests" ]; then
        err_code="3"
        show_error "parse_value_from_resource() target_field can only be either 'limits' and 'requests'." $err_code
        exit $err_code
    fi

    if [ "$target_resource" != "cpu" ] && [ "$target_resource" != "memory" ]; then
        err_code="3"
        show_error "parse_value_from_resource() target_field can only be either 'cpu' and 'memory'." $err_code
        exit $err_code
    fi

    echo "$resources"|grep -o "\"$target_field\":[^{]*{[^}]*}"|grep -o "\"$target_resource\":[^\"]*\"[^\"]*\""|cut -d '"' -f4|head -1
}

parse_value_from_quota()
{
    target_field="$1"
    target_resource="$2"
    if [ -z "$target_field" ]; then
        err_code="3"
        show_error "parse_value_from_quota() target_field parameter can't be empty." $err_code
        exit $err_code
    elif [ -z "$target_resource" ]; then
        err_code="3"
        show_error "parse_value_from_quota() target_resource parameter can't be empty." $err_code
        exit $err_code
    fi

    if [ "$target_field" != "limits" ] && [ "$target_field" != "requests" ]; then
        err_code="3"
        show_error "parse_value_from_quota() target_field can only be either 'limits' and 'requests'." $err_code
        exit $err_code
    fi

    if [ "$target_resource" != "cpu" ] && [ "$target_resource" != "memory" ]; then
        err_code="3"
        show_error "parse_value_from_quota() target_field can only be either 'cpu' and 'memory'." $err_code
        exit $err_code
    fi

    echo "$quotas"|grep -o "\"$target_field.$target_resource\":[^\"]*\"[^\"]*\""|cut -d '"' -f4
}

get_namespace_quota_from_kubecmd()
{
    mode=$1
    if [ "$mode" = "" ]; then
        err_code="4"
        show_error "get_namespace_quota_from_kubecmd() mode parameter can't be empty." $err_code
        exit $err_code
    fi

    quota_name="${target_namespace}.federator.ai"

    show_info "Getting current namespace quota..."
    show_info "Namespace = $target_namespace"
    show_info "Quota name = $quota_name"

    if [ "$DEMO_MODE" != "y" ]; then
        quotas=$($kube_cmd get quota $quota_name -n $target_namespace -o json 2>/dev/null|tr -d '\n'|grep -o "\"spec\":.*"|grep -o "\"hard\":[^}]*}"|head -1)
        limit_cpu=$(parse_value_from_quota "limits" "cpu")
        limit_memory=$(parse_value_from_quota "limits" "memory")
        request_cpu=$(parse_value_from_quota "requests" "cpu")
        request_memory=$(parse_value_from_quota "requests" "memory")
    else
        limit_cpu=""
        limit_memory=""
        request_cpu=""
        request_memory=""
    fi

    if [ "$mode" = "before" ]; then
        if [ "$limit_cpu" = "" ]; then
            limit_cpu_before="N/A"
        else
            limit_cpu_before=$limit_cpu
        fi
        if [ "$limit_memory" = "" ]; then
            limit_memory_before="N/A"
        else
            limit_memory_before=$limit_memory
        fi
        if [ "$request_cpu" = "" ]; then
            request_cpu_before="N/A"
        else
            request_cpu_before=$request_cpu
        fi
        if [ "$request_memory" = "" ]; then
            request_memory_before="N/A"
        else
            request_memory_before=$request_memory
        fi
        show_info "--------- Namespace Quota: Before execution ---------"
        show_info "limits:"
        show_info "  cpu: $limit_cpu_before"
        show_info "  memory: $limit_memory_before"
        show_info "Requests:"
        show_info "  cpu: $request_cpu_before"
        show_info "  memory: $request_memory_before"
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
            if [ "$limit_cpu" = "" ]; then
                limit_cpu_after="N/A"
            else
                limit_cpu_after=$limit_cpu
            fi
            if [ "$limit_memory" = "" ]; then
                limit_memory_after="N/A"
            else
                limit_memory_after=$limit_memory
            fi
            if [ "$request_cpu" = "" ]; then
                request_cpu_after="N/A"
            else
                request_cpu_after=$request_cpu
            fi
            if [ "$request_memory" = "" ]; then
                request_memory_after="N/A"
            else
                request_memory_after=$request_memory
            fi
            show_info "--------- Namespace Quota: After execution ----------"
        fi
        show_info "limits:"
        show_info "  cpu: $limit_cpu_before -> $limit_cpu_after"
        show_info "  memory: $limit_memory_before -> $limit_memory_after"
        show_info "Requests:"
        show_info "  cpu: $request_cpu_before -> $request_cpu_after"
        show_info "  memory: $request_memory_before -> $request_memory_after"
        show_info "-----------------------------------------------------"
        echo -e "{\n  \"info\": {\n     \"cluster_name\": \"$cluster_name\",\n     \"resource_type\": \"$resource_type\",\n     \"resource_name\": \"$target_namespace\",\n     \"time_interval\": \"$readable_granularity\",\n     \"execute_cmd\": \"$exec_cmd\",\n     \"execution_time\": \"$execution_time\"\n  },\n  \"log_file\": \"$debug_log\",\n  \"before_execution\":  {\n     \"limits\": {\n       \"cpu\": \"$limit_cpu_before\",\n       \"memory\": \"$limit_memory_before\"\n     },\n     \"requests\": {\n       \"cpu\": \"$request_cpu_before\",\n       \"memory\": \"$request_memory_before\"\n     }\n  },\n  \"after_execution\": {\n     \"limits\": {\n       \"cpu\": \"$limit_cpu_after\",\n       \"memory\": \"$limit_memory_after\"\n     },\n     \"requests\": {\n       \"cpu\": \"$request_cpu_after\",\n       \"memory\": \"$request_memory_after\"\n     }\n  }\n}"  | tee -a $debug_log
    fi
    show_info "Done."
}

get_controller_resources_from_kubecmd()
{
    mode=$1
    if [ "$mode" = "" ]; then
        err_code="4"
        show_error "get_controller_resources_from_kubecmd() mode parameter can't be empty." $err_code
        exit $err_code
    fi

    get_container_number_and_name_list

    if [ "$DEMO_MODE" = "y" ]; then
        container_number=$container_records_num
        container_array=("${container_name_keys[@]}")
    fi

    if [ "0$container_number" -ge "2" ]; then
        show_info "Getting current controller resources (per container)..."
        show_info "Namespace = $target_namespace"
        show_info "Resource name = $resource_name"
        show_info "Kind = $owner_reference_kind"
        if [ "$DEMO_MODE" != "y" ]; then
            controller_resources="$($kube_cmd get $owner_reference_kind $resource_name -n $target_namespace -o json)"
            data=$(tokenize_json "$controller_resources"| parse_json_begin)
            err_code="$?"
            if [ "$err_code" != "0" ]; then
                show_error "Failed to parse json output (controller_resources)." $err_code
                exit $err_code
            fi
        fi

        for container_name in "${container_array[@]}"
        do
            for index in `seq 0 $(( container_number - 1 ))`
            do
                name=$(get_valued_from_parsed_json "$data" "\[\"spec\",\"template\",\"spec\",\"containers\",$index,\"name\"")
                if  [ "$name" = "$container_name" ]; then
                    limit_cpu=$(get_valued_from_parsed_json "$data" "\[\"spec\",\"template\",\"spec\",\"containers\",$index,\"resources\",\"limits\",\"cpu\"\]")
                    limit_memory=$(get_valued_from_parsed_json "$data" "\[\"spec\",\"template\",\"spec\",\"containers\",$index,\"resources\",\"limits\",\"memory\"\]")
                    request_cpu=$(get_valued_from_parsed_json "$data" "\[\"spec\",\"template\",\"spec\",\"containers\",$index,\"resources\",\"requests\",\"cpu\"\]")
                    request_memory=$(get_valued_from_parsed_json "$data" "\[\"spec\",\"template\",\"spec\",\"containers\",$index,\"resources\",\"requests\",\"memory\"\]")
                fi
            done

            if [ "$limit_cpu" = "" ]; then
                limit_cpu="N/A"
            else
                limit_cpu_converted=$(convert_cpu_unit_to_bytes "$limit_cpu")
            fi
            if [ "$limit_memory" = "" ]; then
                limit_memory="N/A"
            else
                limit_memory_converted=$(convert_memory_unit_to_bytes "$limit_memory")
            fi
            if [ "$request_cpu" = "" ]; then
                request_cpu="N/A"
            else
                request_cpu_converted=$(convert_cpu_unit_to_bytes "$request_cpu")
            fi
            if [ "$request_memory" = "" ]; then
                request_memory="N/A"
            else
                request_memory_converted=$(convert_memory_unit_to_bytes "$request_memory")
            fi
            show_info "container ($container_name) resources"
            show_info "limits:"
            show_info "  cpu: $limit_cpu"
            show_info "  memory: $limit_memory"
            show_info "Requests:"
            show_info "  cpu: $request_cpu"
            show_info "  memory: $request_memory"
            show_info "-----------------------------------------------------"

            if [ "$mode" = "before" ]; then
                container_resource_array+=( "$container_name.before.limits.cpu.original:$limit_cpu" )
                container_resource_array+=( "$container_name.before.limits.memory.original:$limit_memory" )
                container_resource_array+=( "$container_name.before.requests.cpu.original:$request_cpu" )
                container_resource_array+=( "$container_name.before.requests.memory.original:$request_memory" )
                container_resource_array+=( "$container_name.before.limits.cpu.converted:$limit_cpu_converted" )
                container_resource_array+=( "$container_name.before.limits.memory.converted:$limit_memory_converted" )
                container_resource_array+=( "$container_name.before.requests.cpu.converted:$request_cpu_converted" )
                container_resource_array+=( "$container_name.before.requests.memory.converted:$request_memory_converted" )
            else
                # mode = "after"
                if [ "$do_dry_run" = "y" ]; then
                    show_info "--------------------- Dry run -----------------------"
                    # dry run - set resource values from planning results to display
                    limits_pod_cpu=$(get_value_from_resource_array $container_name after limits cpu original)
                    limits_pod_memory=$(get_value_from_resource_array $container_name after limits memory original)
                    requests_pod_cpu=$(get_value_from_resource_array $container_name after requests cpu original)
                    requests_pod_memory=$(get_value_from_resource_array $container_name after requests memory original)
                    limit_cpu_after="${limits_pod_cpu}m"
                    limit_memory_after="$limits_pod_memory"
                    request_cpu_after="${requests_pod_cpu}m"
                    request_memory_after="$requests_pod_memory"
                else
                    # patch is done
                    show_info "------------------ After execution ------------------"
                    limit_cpu_after=$limit_cpu
                    limit_memory_after=$limit_memory
                    request_cpu_after=$request_cpu
                    request_memory_after=$request_memory
                fi
                limit_cpu_before=$(get_value_from_resource_array $container_name before limits cpu original)
                limit_memory_before=$(get_value_from_resource_array $container_name before limits memory original)
                request_cpu_before=$(get_value_from_resource_array $container_name before requests cpu original)
                request_memory_before=$(get_value_from_resource_array $container_name before requests memory original)
                show_info "container ($container_name)"
                show_info "limits:"
                show_info "  cpu: $limit_cpu_before -> $limit_cpu_after"
                show_info "  memory: $limit_memory_before -> $limit_memory_after"
                show_info "Requests:"
                show_info "  cpu: $request_cpu_before -> $request_cpu_after"
                show_info "  memory: $request_memory_before -> $request_memory_after"
                show_info "-----------------------------------------------------"
                if [ "$do_dry_run" = "y" ]; then
                    # For dry run mode, print every json result
                    exec_cmd=$(get_value_from_resource_array $container_name after issue execute cmd)
                    execution_time=$(get_value_from_resource_array $container_name after issue execute time)
                    echo -e "{\n  \"info\": {\n     \"cluster_name\": \"$cluster_name\",\n     \"resource_type\": \"$resource_type\",\n     \"namespace\": \"$target_namespace\",\n     \"resource_name\": \"$resource_name\",\n     \"kind\": \"$owner_reference_kind\",\n     \"time_interval\": \"$readable_granularity\",\n     \"execute_cmd\": \"$exec_cmd\",\n     \"execution_time\": \"$execution_time\"\n  },\n  \"log_file\": \"$debug_log\",\n  \"before_execution\":  {\n     \"limits\": {\n       \"cpu\": \"$limit_cpu_before\",\n       \"memory\": \"$limit_memory_before\"\n     },\n     \"requests\": {\n       \"cpu\": \"$request_cpu_before\",\n       \"memory\": \"$request_memory_before\"\n     }\n  },\n  \"after_execution\": {\n     \"limits\": {\n       \"cpu\": \"$limit_cpu_after\",\n       \"memory\": \"$limit_memory_after\"\n     },\n     \"requests\": {\n       \"cpu\": \"$request_cpu_after\",\n       \"memory\": \"$request_memory_after\"\n     }\n  }\n}"  | tee -a $debug_log
                fi
            fi
        done
        if [ "$mode" = "after" ] && [ "$do_dry_run" != "y" ]; then
            # Only display last container execution result for now
            echo -e "{\n  \"info\": {\n     \"cluster_name\": \"$cluster_name\",\n     \"resource_type\": \"$resource_type\",\n     \"namespace\": \"$target_namespace\",\n     \"resource_name\": \"$resource_name\",\n     \"kind\": \"$owner_reference_kind\",\n     \"time_interval\": \"$readable_granularity\",\n     \"execute_cmd\": \"$exec_cmd\",\n     \"execution_time\": \"$execution_time\"\n  },\n  \"log_file\": \"$debug_log\",\n  \"before_execution\":  {\n     \"limits\": {\n       \"cpu\": \"$limit_cpu_before\",\n       \"memory\": \"$limit_memory_before\"\n     },\n     \"requests\": {\n       \"cpu\": \"$request_cpu_before\",\n       \"memory\": \"$request_memory_before\"\n     }\n  },\n  \"after_execution\": {\n     \"limits\": {\n       \"cpu\": \"$limit_cpu_after\",\n       \"memory\": \"$limit_memory_after\"\n     },\n     \"requests\": {\n       \"cpu\": \"$request_cpu_after\",\n       \"memory\": \"$request_memory_after\"\n     }\n  }\n}"  | tee -a $debug_log
        fi
    else
        # only one container
        show_info "Getting current controller resources..."
        show_info "Namespace = $target_namespace"
        show_info "Resource name = $resource_name"
        show_info "Kind = $owner_reference_kind"

        if [ "$DEMO_MODE" != "y" ]; then
            resources=$($kube_cmd get $owner_reference_kind $resource_name -n $target_namespace -o json |tr -d '\n'|grep -o "\"spec\":.*"|grep -o "\"template\":.*"|grep -o "\"spec\":.*"|grep -o "\"containers\":.*"|grep -o "\"resources\":.*")
        fi
        if [ "$mode" = "before" ]; then
            show_info "----------------- Before execution ------------------"
            limit_cpu_before=$(parse_value_from_resource "limits" "cpu")
            if [ "$limit_cpu_before" = "" ]; then
                limit_cpu_before="N/A"
            else
                limit_cpu_before_converted=$(convert_cpu_unit_to_bytes "$limit_cpu_before")
            fi
            limit_memory_before=$(parse_value_from_resource "limits" "memory")
            if [ "$limit_memory_before" = "" ]; then
                limit_memory_before="N/A"
            else
                limit_memory_before_converted=$(convert_memory_unit_to_bytes "$limit_memory_before")
            fi
            request_cpu_before=$(parse_value_from_resource "requests" "cpu")
            if [ "$request_cpu_before" = "" ]; then
                request_cpu_before="N/A"
            else
                request_cpu_before_converted=$(convert_cpu_unit_to_bytes "$request_cpu_before")
            fi
            request_memory_before=$(parse_value_from_resource "requests" "memory")
            if [ "$request_memory_before" = "" ]; then
                request_memory_before="N/A"
            else
                request_memory_before_converted=$(convert_memory_unit_to_bytes "$request_memory_before")
            fi
            show_info "limits:"
            show_info "  cpu: $limit_cpu_before"
            show_info "  memory: $limit_memory_before"
            show_info "Requests:"
            show_info "  cpu: $request_cpu_before"
            show_info "  memory: $request_memory_before"
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
                limit_cpu_after=$(parse_value_from_resource "limits" "cpu")
                [ "$limit_cpu_after" = "" ] && limit_cpu_after="N/A"
                limit_memory_after=$(parse_value_from_resource "limits" "memory")
                [ "$limit_memory_after" = "" ] && limit_memory_after="N/A"
                request_cpu_after=$(parse_value_from_resource "requests" "cpu")
                [ "$request_cpu_after" = "" ] && request_cpu_after="N/A"
                request_memory_after=$(parse_value_from_resource "requests" "memory")
                [ "$request_memory_after" = "" ] && request_memory_after="N/A"
            fi

            show_info "limits:"
            show_info "  cpu: $limit_cpu_before -> $limit_cpu_after"
            show_info "  memory: $limit_memory_before -> $limit_memory_after"
            show_info "Requests:"
            show_info "  cpu: $request_cpu_before -> $request_cpu_after"
            show_info "  memory: $request_memory_before -> $request_memory_after"
            show_info "-----------------------------------------------------"

            echo -e "{\n  \"info\": {\n     \"cluster_name\": \"$cluster_name\",\n     \"resource_type\": \"$resource_type\",\n     \"namespace\": \"$target_namespace\",\n     \"resource_name\": \"$resource_name\",\n     \"kind\": \"$owner_reference_kind\",\n     \"time_interval\": \"$readable_granularity\",\n     \"execute_cmd\": \"$exec_cmd\",\n     \"execution_time\": \"$execution_time\"\n  },\n  \"log_file\": \"$debug_log\",\n  \"before_execution\":  {\n     \"limits\": {\n       \"cpu\": \"$limit_cpu_before\",\n       \"memory\": \"$limit_memory_before\"\n     },\n     \"requests\": {\n       \"cpu\": \"$request_cpu_before\",\n       \"memory\": \"$request_memory_before\"\n     }\n  },\n  \"after_execution\": {\n     \"limits\": {\n       \"cpu\": \"$limit_cpu_after\",\n       \"memory\": \"$limit_memory_after\"\n     },\n     \"requests\": {\n       \"cpu\": \"$request_cpu_after\",\n       \"memory\": \"$request_memory_after\"\n     }\n  }\n}"  | tee -a $debug_log
        fi
    fi

    show_info "Done."
}

connection_test()
{
    check_rest_api_url
    rest_api_login
}

# json parser parameter
NO_HEAD=0
NORMALIZE_SOLIDUS=0
BRIEF=1
LEAFONLY=1
PRUNE=1

while getopts "h-:" o; do
    case "${o}" in
        -)
            case "${OPTARG}" in
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
                        err_code="6"
                        show_error "Missing --${OPTARG} value" $err_code
                        exit $err_code
                    fi
                    ;;
                terraform-path)
                    terraform_path="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$terraform_path" = "" ]; then
                        err_code="6"
                        show_error "Missing --${OPTARG} value" $err_code
                        exit $err_code
                    fi
                    ;;
                detail-to-stderr)
                    detail_to_stderr="y"
                    ;;
                help)
                    show_usage
                    exit 0
                    ;;
                *)
                    err_code="6"
                    show_error "Unknown option --${OPTARG}" $err_code
                    exit $err_code
                    ;;
            esac;;
        h)
            show_usage
            exit 0
            ;;
        *)
            err_code="6"
            show_error "Wrong parameter." $err_code
            exit $err_code
            ;;
    esac
done

if [ "$DEMO_MODE" = "y" ] && [ "$do_dry_run" != "y" ]; then
    err_code="6"
    show_error "DEMO_MODE env enabled. It can only run with dry run mode" $err_code
    exit $err_code
fi

unameOut="$(uname -s)"
case "${unameOut}" in
    Linux*)
        machine_type=Linux;;
    Darwin*)
        machine_type=Mac;;
    *)
        err_code="6"
        show_error "Unsupported machine type (${unameOut})." $err_code
        exit $err_code
        ;;
esac

if [ "$FEDERATORAI_FILE_PATH" = "" ]; then
    save_path="/opt/federatorai"
else
    save_path="$FEDERATORAI_FILE_PATH"
fi

file_folder="$save_path/auto-provisioning"
realpath() {
    [[ $1 = /* ]] && echo "$1" || echo "$PWD/${1#./}"
}

if [ "$log_name" = "" ]; then
    log_name="output.log"
    debug_log="${file_folder}/${log_name}"
else
    if [[ "$log_name" = /* ]]; then
        # Absolute path
        file_folder="$(dirname "$log_name")"
        debug_log="$log_name"
    else
        # Relative path
        if [ "$machine_type" = "Linux" ]; then
            file_folder="${file_folder}/$(dirname "$log_name")"
            debug_log="${file_folder}/$(basename "$log_name")"
        else
            parent_folder=$(dirname $log_name)
            file_folder="$file_folder/$parent_folder"
            debug_log="${file_folder}/$(basename "$log_name")"
        fi
    fi
fi

mkdir -p $file_folder
if [ ! -d "$file_folder" ]; then
    err_code="6"
    show_error "Failed to create folder ($file_folder) to save Federator.ai planning-util files. Consider exporting the env variable \$FEDERATORAI_FILE_PATH to specify the folder path."
    exit $err_code
fi

if [ "$machine_type" = "Linux" ]; then
    script_located_path=$(dirname $(readlink -f "$0"))
else
    # Mac
    script_located_path=$(dirname $(realpath "$0"))
fi

if [ "$terraform_path" = "" ]; then
    terraform_path="$script_located_path"
fi
mkdir -p $terraform_path
if [ ! -d "$terraform_path" ]; then
    err_code="6"
    show_error "Failed to create terraform folder ($terraform_path) to save Federator.ai planning-util files." $err_code
    exit $err_code
fi

current_location=`pwd`
# mCore
default_min_cpu="50"
# Byte
default_min_memory="10485760"
echo "================================== New Round ======================================" >> $debug_log
echo "Receiving command: '$0 $@'" >> $debug_log
echo "Receiving time: `date -u`" >> $debug_log

# Check target_config_info variable
check_target_config

# Get resource type
resource_type=$(parse_value_from_target_var "resource_type")
resource_type="$(echo "$resource_type" | tr '[:upper:]' '[:lower:]')"

# Parse config info
get_info_from_config

# Get kubeconfig path
kubeconfig_path=$(parse_value_from_target_var "kubeconfig_path")

if [ "$DEMO_MODE" != "y" ]; then
    if [ "$resource_type" = "controller" ] && [ "$owner_reference_kind" = "deploymentconfig" ]; then
        if [ "$kubeconfig_path" = "" ]; then
            kube_cmd="oc"
            verify_cmd="kubectl"
        else
            kube_cmd="oc --kubeconfig $kubeconfig_path"
            verify_cmd="kubectl --kubeconfig $kubeconfig_path"
        fi
        cmd_type="oc"
    else
        if [ "$kubeconfig_path" = "" ]; then
            kube_cmd="kubectl"
        else
            kube_cmd="kubectl --kubeconfig $kubeconfig_path"
        fi
        cmd_type="kubectl"
    fi

    type $cmd_type > /dev/null 2>&1
    if [ "$?" != "0" ];then
        err_code="6"
        show_error "$cmd_type command is needed for this tool." $err_code
        exit $err_code
    fi

    if [ "$cmd_type" = "oc" ]; then
        # kubectl must exist too
        type kubectl > /dev/null 2>&1
        if [ "$?" != "0" ];then
            err_code="6"
            show_error "kubectl command is needed for this tool." $err_code
            exit $err_code
        fi
        # Still use kubectl version to verify server connection
        $verify_cmd version|grep -q "^Server"
    else
        $kube_cmd version|grep -q "^Server"
    fi

    if [ "$?" != "0" ];then
        err_code="6"
        show_error "Failed to get Kubernetes server info through $cmd_type cmd. Please login first or check your kubeconfig_path config value." $err_code
        exit $err_code
    fi
else
    # Demo mode
    kube_cmd="kubectl"
fi

type curl > /dev/null 2>&1
if [ "$?" != "0" ];then
    err_code="6"
    show_error "curl command is needed for this tool." $err_code
    exit $err_code
fi

type awk > /dev/null 2>&1
if [ "$?" != "0" ];then
    err_code="6"
    show_error "awk command is needed for this tool." $err_code
    exit $err_code
fi

type base64 > /dev/null 2>&1
if [ "$?" != "0" ];then
    err_code="6"
    show_error "base64 command is needed for this tool." $err_code
    exit $err_code
fi

connection_test
if [ "$do_test_connection" = "y" ]; then
    echo -e "{\n  \"connection_test\": \"passed\",\n  \"log_file\": \"$debug_log\"\n}" | tee -a $debug_log
    exit 0
fi

rest_api_check_cluster_name

container_resource_array=()
container_planning_array=()

if [ "$resource_type" = "controller" ];then
    if [ "$DEMO_MODE" != "y" ]; then
        get_controller_resources_from_kubecmd "before"
        get_planning_from_api
    else
        get_planning_from_api
        get_controller_resources_from_kubecmd "before"
    fi
elif [ "$resource_type" = "namespace" ]; then
    get_namespace_quota_from_kubecmd "before"
    get_planning_from_api
else
    err_code="3"
    show_error "Only support resource_type equals 'controller' or 'namespace'." $err_code
    exit $err_code
fi

if [ "$do_dry_run" = "y" ]; then
    update_target_resources "dry_run"
else
    update_target_resources "normal"
fi

if [ "$iac_command" = "script" ]; then
    if [ "$resource_type" = "controller" ];then
        get_controller_resources_from_kubecmd "after"
    else
        # resource_type = namespace
        get_namespace_quota_from_kubecmd "after"
    fi
fi