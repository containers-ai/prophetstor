#!/usr/bin/env bash

show_usage()
{
    cat << __EOF__

    Usage:
        For K8S & VM:
            [-p] # Prepare environment
                Optional:
                    # Specify your local Kubernetes cluster name to install an NGINX for demo purpose.
                    [-a <cluster_name> -u <username>:<password>]
            [-c] # clean environment for preloader test
            [-e] # Enable preloader pod
            [-r] # Run preloader (normal mode: historical + current)
            [-o] # Run preloader (historical mode)
                 # K8S: historical + ab test
                 # VM: historical only
            [-f future data point (hour)] # Run preloader future mode
            [-d] # Disable & Remove preloader
            [-v] # Revert environment to normal mode
            [-h] # Display script usage
    Standalone options:
        For K8S:
            [-i] # Install Nginx on local Kubernetes cluster
                Requirement:
                    [-a <cluster_name> -u <username>:<password>]
                    Specify local Kubernetes cluster name and Federator.ai username/password
            [-k] # Remove Nginx
            [-b] # Retrigger ab test inside preloader pod
            [-g ab_traffic_ratio] # ab test traffic ratio (default:4000) [e.g., -g 4000]
            [-t replica number] # Nginx default replica number (default:5) [e.g., -t 5]
            [-s switch] # Specify enable execution value on Nginx (default: false) [e.g., -s true]

__EOF__
    exit 1
}

fedai_rest_get()
{
    local ret=1
    local resp=""
    local url="http://127.0.0.1:5055$1"

    # Retry 6 times
    for i in 1 2 3 4 5 6; do
        rest_pod_name=$(kubectl get pods -n ${install_namespace} -o name | grep 'pod/federatorai-rest-' | head -1)
        resp=$(kubectl -n ${install_namespace} exec -t ${rest_pod_name} -- \
            curl -s -k --max-time 120 --retry-max-time 5 --connect-timeout 30 \
              -u "${auth_username}:${auth_password}" \
              -H "Content-Type: application/json" \
              "${url}" 2>&1)
        ret=$?
        [ "${ret}" = "0" ] && echo "${resp}" && return 0
        sleep 30
    done
    return ${ret}
}

psql_query()
{
    local ret=1
    local result=""
    local sql_str="$1"

    # Retry 6 times
    for i in 1 2 3 4 5 6; do
        postgresql_pod_name="federatorai-postgresql-0"
        resp=$(kubectl -n ${install_namespace} exec -t ${postgresql_pod_name} -- \
            psql --dbname=federatorai --no-psqlrc --single-transaction --tuples-only --no-align --field-separator="|" \
              --command "${sql_str}" 2>&1)
        ret=$?
        [ "${ret}" = "0" ] && echo "${resp}" && return 0
        sleep 30
    done
    return ${ret}
}

pods_ready()
{
  [[ "$#" == 0 ]] && return 0

  namespace="$1"

  kubectl get pod -n $namespace \
    -o=jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' |egrep -v "\-build|\-deploy"\
      | while read name status _junk; do
          if [ "$status" != "True" ]; then
            echo "Waiting for pod $name in namespace $namespace to be ready..."
            return 1
          fi
        done || return 1

  return 0
}

leave_prog()
{
    scale_up_pods
    if [ ! -z "$(ls -A $file_folder)" ]; then      
        echo -e "\n$(tput setaf 6)Downloaded YAML files are located under $file_folder $(tput sgr 0)"
    fi
 
    cd $current_location > /dev/null
}

check_version()
{
    openshift_required_minor_version="9"
    k8s_required_version="11"

    oc version 2>/dev/null|grep "oc v"|grep -q " v[4-9]"
    if [ "$?" = "0" ];then
        # oc version is 4-9, passed
        openshift_minor_version="12"
        return 0
    fi

    # OpenShift Container Platform 4.x
    oc version 2>/dev/null|grep -q "Server Version: 4"
    if [ "$?" = "0" ];then
        # oc server version is 4, passed
        openshift_minor_version="12"
        return 0
    fi

    oc version 2>/dev/null|grep "oc v"|grep -q " v[0-2]"
    if [ "$?" = "0" ];then
        # oc version is 0-2, failed
        echo -e "\n$(tput setaf 10)Error! OpenShift version less than 3.$openshift_required_minor_version is not supported by Federator.ai$(tput sgr 0)"
        exit 5
    fi

    # oc major version = 3
    openshift_minor_version=`oc version 2>/dev/null|grep "oc v"|cut -d '.' -f2`
    # k8s version = 1.x
    k8s_version=`kubectl version 2>/dev/null|grep Server|grep -o "Minor:\"[0-9]*.\""|tr ':+"' " "|awk '{print $2}'`

    if [ "$openshift_minor_version" != "" ] && [ "$openshift_minor_version" -lt "$openshift_required_minor_version" ]; then
        echo -e "\n$(tput setaf 10)Error! OpenShift version less than 3.$openshift_required_minor_version is not supported by Federator.ai$(tput sgr 0)"
        exit 5
    elif [ "$openshift_minor_version" = "" ] && [ "$k8s_version" != "" ] && [ "$k8s_version" -lt "$k8s_required_version" ]; then
        echo -e "\n$(tput setaf 10)Error! Kubernetes version less than 1.$k8s_required_version is not supported by Federator.ai$(tput sgr 0)"
        exit 6
    elif [ "$openshift_minor_version" = "" ] && [ "$k8s_version" = "" ]; then
        echo -e "\n$(tput setaf 10)Error! Can't get Kubernetes or OpenShift version$(tput sgr 0)"
        exit 5
    fi
}

wait_until_pods_ready()
{
    local period="$1"
    local interval="$2"
    local namespace="$3"

    sleep "$interval"
    for ((i=0; i<${period}; i+=${interval})); do
        result=$(set +x; (kubectl -n ${namespace} get deployment; \
                  kubectl -n ${namespace} get statefulset; \
                  kubectl -n ${namespace} get daemonset) 2>&1 \
                  | egrep -v "^No resources found|^NAME | 0/0 | 1/1 | 2/2" | awk '{print $1}' | xargs)
        if [ "${result}" = "" ]; then
            echo -e "\nAll resources in ${namespace} are ready."
            return 0
        fi
        echo "Waiting for the following resources in namespace ${namespace} to be ready ..."
        echo -e "  ${result}\n"
        sleep "$interval"
    done

    echo -e "\n$(tput setaf 1)Warning!! Waited for ${period} seconds, but all pods are not ready yet. Please check ${namespace} namespace$(tput sgr 0)"
    leave_prog
    exit 4
}

wait_until_data_pump_finish()
{
  period="$1"
  interval="$2"
  type="$3"

  for ((i=0; i<$period; i+=$interval)); do
    if [ "$machine_type" = "Linux" ]; then
        duration_time=$(date -d @${i} +"%H:%M:%S" -u)
    else
        # Mac
        duration_time=$(date -u -r ${i} +%H:%M:%S)
    fi

    if [ "$type" = "future" ]; then
        echo "Waiting for data pump (future mode) to finish (Time Elapsed = $duration_time)..."
        kubectl logs -n $install_namespace $current_preloader_pod_name | grep -q "Completed to loader container future metrics data"
        if [ "$?" = "0" ]; then
            echo -e "\n$(tput setaf 6)The data pump (future mode) is finished.$(tput sgr 0)"
            return 0
        fi
    else #historical mode
        echo "Waiting for data pump to finish (Time Elapsed = $duration_time)..."
        if [[ "`kubectl logs -n $install_namespace $current_preloader_pod_name | egrep "Succeed to generate pods historical metrics|Succeed to generate nodes historical metrics" | wc -l|sed 's/[ \t]*//g'`" -gt "1" ]]; then
            echo -e "\n$(tput setaf 6)The data pump is finished.$(tput sgr 0)"
            starttime_utc="$(kubectl logs -n $install_namespace $current_preloader_pod_name|grep 'Start PreLoader agent'|awk '{print $1}')"
            endtime_utc="$(kubectl logs -n $install_namespace $current_preloader_pod_name|grep 'Succeed to'|tail -1|awk '{print $1}')"
            if [ "$starttime_utc" != "" ] && [ "$endtime_utc" != "" ]; then
                if [ "$machine_type" = "Linux" ]; then
                    startime_timestamp="$(date -d "$starttime_utc" +%s)"
                    endtime_timestamp="$(date -d "$endtime_utc" +%s)"
                else
                    # Mac
                    # Remove decimal point
                    starttime_utc="`echo $starttime_utc|cut -d '.' -f1`Z"
                    endtime_utc="`echo $endtime_utc|cut -d '.' -f1`Z"
                    startime_timestamp="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$starttime_utc" +"%s")"
                    endtime_timestamp="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$endtime_utc" +"%s")"
                fi
                if [ "$startime_timestamp" != "" ] && [ "$endtime_timestamp" != "" ]; then
                    duration_seconds="$(($endtime_timestamp-$startime_timestamp))"
                    if [ "$machine_type" = "Linux" ]; then
                        duration_time=$(date -d @${duration_seconds} +"%H:%M:%S" -u)
                    else
                        duration_time=$(date -u -r ${duration_seconds} +%H:%M:%S)
                    fi
                    echo "Pumping duration in seconds = $duration_seconds" |tee -a $debug_log
                    echo -e "Pumping duration(H:M:S) = $duration_time" |tee -a $debug_log
                fi
            fi
            return 0
        fi
    fi
    
    sleep "$interval"
  done

  echo -e "\n$(tput setaf 1)Warning!! Waited for $period seconds, but the data pump is still running.$(tput sgr 0)"
  leave_prog
  exit 4
}

get_current_preloader_name()
{
    current_preloader_pod_name=""
    current_preloader_pod_name="`kubectl get pods -n $install_namespace |grep "federatorai-agent-preloader-"|awk '{print $1}'|head -1`"
    echo "current_preloader_pod_name = $current_preloader_pod_name"
}

get_current_executor_name()
{
    current_executor_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-executor-"|awk '{print $1}'|head -1`"
    echo "current_executor_pod_name = $current_executor_pod_name"
}

display_resources_detail()
{
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    total_pods="$(kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 \
        -username admin -password adminpass -database alameda_cluster_status -format 'csv' -execute \
        'select "policy","name","namespace" from pod' 2>/dev/null|sed 1d)"
    total_pod_number="$(echo "$total_pods"|wc -l|sed 's/[ \t]*//g')"
    total_namespace_number="$(echo "$total_pods"|cut -d ',' -f 5|sort|uniq|wc -l|sed 's/[ \t]*//g')"
    total_node_number="$(kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 \
        -username admin -password adminpass -database alameda_cluster_status -format 'csv' -execute \
        'select * from node' 2>/dev/null|sed 1d|wc -l|sed 's/[ \t]*//g')"
    total_vm_number=$(kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 \
        -username admin -password adminpass -database alameda_cluster_status -format 'csv' -execute \
        "select * from node where type='vm'" 2>/dev/null|sed 1d|wc -l|sed 's/[ \t]*//g')
    echo -e "Number of target pod = $total_pod_number" |tee -a $debug_log
    echo -e "Number of target namespace = $total_namespace_number" |tee -a $debug_log
    echo -e "Number of target node = $total_node_number" |tee -a $debug_log
    echo -e "Number of target vm = $total_vm_number" |tee -a $debug_log
}

_do_cluster_status_verify()
{
    mode="$1"
    if [ "$mode" != "vm" ] && [ "$mode" != "k8s" ]; then
        echo -e "\n$(tput setaf 1)Error! _do_metrics_verify() mode paramter can only be either 'vm' or 'k8s'.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
    echo -e "\n$(tput setaf 6)Checking cluster status ($mode)...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    repeat_count="30"
    sleep_interval="20"
    pass="n"
    for i in $(seq 1 $repeat_count)
    do
        if [ "$mode" = "vm" ]; then
            # Found if any nodes exists inside the cluster
            resp=$(fedai_rest_get "/apis/v1/resources/clusters/${cluster_name}/nodes?type=vm")
            node_id_list=$(echo "${resp}" | jq -r '.data[].node_id')
            [ "${node_id_list}" != "" ] && result="ok"
        else
            # K8S - Do nothing for now
            # TODO: verify pods exists inside the cluster for this alamedascaler
            result="ok"
        fi

        if [ "$result" != "ok" ]; then
            echo "Not ready, keep retrying cluster status..."
            sleep $sleep_interval
        else
            pass="y"
            break
        fi
    done

    if [ "$pass" = "n" ]; then
        if [ "$mode" = "vm" ]; then
            # VM
            echo -e "\n$(tput setaf 1)Error! Failed to get any vm node record in alameda_cluster_status..node$(tput sgr 0)"
        else
            # K8S
            if [ "$demo_nginx_exist" = "true" ]; then
                echo -e "\n$(tput setaf 1)Error! Failed to find alamedascaler ($alamedascaler_name) status$(tput sgr 0)"
            else
                echo -e "\n$(tput setaf 1)Error! Failed to get any pod record$.(tput sgr 0)"
            fi
        fi
        leave_prog
        exit 8
    fi

    echo "Done."
}

wait_for_cluster_status_data_ready()
{
    start=`date +%s`

    if [ "$vm_enabled" = "true" ]; then
        _do_cluster_status_verify "vm"
    fi
    if [ "$k8s_enabled" = "true" ]; then
        _do_cluster_status_verify "k8s"
    fi

    end=`date +%s`
    duration=$((end-start))
    echo "Duration wait_for_cluster_status_data_ready = $duration" >> $debug_log
}

refine_preloader_variables_with_alamedaservice()
{
    ## Assign preloader environment variables
    local _env_list=""
    if [ "${PRELOADER_GRANULARITY}" != "" ]; then
        echo -e "\nSetting variable PRELOADER_GRANULARITY='${PRELOADER_GRANULARITY}'"
        _env_list="${_env_list}
    - name: PRELOADER_PRELOADER_GRANULARITY
      value: \"${PRELOADER_GRANULARITY}\"  # unit is sec, history preloaded data granularity
"
    fi
    if [ "${PRELOADER_PRELOAD_COUNT}" != "" ]; then
        echo -e "Setting variable PRELOADER_PRELOAD_COUNT='${PRELOADER_PRELOAD_COUNT}'"
        _env_list="${_env_list}
    - name: PRELOADER_PRELOADER_PRELOAD_COUNT
      value: \"${PRELOADER_PRELOAD_COUNT}\"
"
    fi
    if [ "${PRELOADER_PRELOAD_UNIT}" != "" ]; then
            if [ "${PRELOADER_PRELOAD_UNIT}" != "day" ]; then
                echo -e "\n$(tput setaf 1)Error! _do_metrics_verify() Only PRELOADER_PRELOAD_UNIT='day' is supported.$(tput sgr 0)"
                leave_prog
                exit 1
            fi
        echo -e "Setting variable PRELOADER_PRELOAD_UNIT='${PRELOADER_PRELOAD_UNIT}'"
        _env_list="${_env_list}
    - name: PRELOADER_PRELOADER_PRELOAD_UNIT
      value: \"${PRELOADER_PRELOAD_UNIT}\"    # "day"
"
    fi
    if [ "${_env_list}" != "" ]; then
        patch_data="
spec:
  federatoraiAgentPreloader:
    env:${_env_list}
"
        echo -e "\nPatching alamedaservice for enabling environment variables of preloader ..."
        kubectl patch alamedaservice ${alamedaservice_name} -n ${install_namespace} --type merge --patch "${patch_data}"
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed in patching AlamedaService.$(tput sgr 0)"
            exit 1
        fi
        # restart preloader pod
        get_current_preloader_name
        [ "${current_preloader_pod_name}" != "" ] && kubectl -n $install_namespace delete pod $current_preloader_pod_name --wait=true
    fi
}

run_ab_test()
{
    echo -e "\n$(tput setaf 6)Running ab test in preloader...$(tput sgr 0)"

    get_current_preloader_name
    if [ "$current_preloader_pod_name" = "" ]; then
        echo -e "\n$(tput setaf 1)ERROR! Can't find installed preloader pod.$(tput sgr 0)"
        leave_prog
        exit 8
    fi

    # Modify parameters
    nginx_ip="${nginx_name}.${nginx_ns}"
    if [ "$machine_type" = "Linux" ]; then
        sed -i "s/SVC_IP=.*/SVC_IP=${nginx_ip}/g" $preloader_folder/generate_loads.sh
        sed -i "s/SVC_PORT=.*/SVC_PORT=${nginx_port}/g" $preloader_folder/generate_loads.sh
        sed -i "s/traffic_ratio.*/traffic_ratio = ${traffic_ratio}/g" $preloader_folder/define.py
    else
        sed -i "" "s/SVC_IP=.*/SVC_IP=${nginx_ip}/g" $preloader_folder/generate_loads.sh
        sed -i "" "s/SVC_PORT=.*/SVC_PORT=${nginx_port}/g" $preloader_folder/generate_loads.sh
        sed -i "" "s/traffic_ratio.*/traffic_ratio = ${traffic_ratio}/g" $preloader_folder/define.py
    fi
    for ab_file in "${ab_files_list[@]}"
    do
        kubectl cp -n $install_namespace $preloader_folder/$ab_file ${current_preloader_pod_name}:/opt/alameda/federatorai-agent/
    done
    # New traffic folder
    kubectl -n $install_namespace exec $current_preloader_pod_name -- mkdir -p /opt/alameda/federatorai-agent/traffic
    # trigger ab test
    kubectl -n $install_namespace exec $current_preloader_pod_name -- bash -c "bash /opt/alameda/federatorai-agent/generate_loads.sh >run_output 2>run_output &"
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to trigger ab test inside preloader.$(tput sgr 0)"
    fi
    echo "Done."
}

run_preloader_command()
{
    running_mode="$1"
    if [ "$running_mode" = "historical_only" ]; then
        # Need to change data adapter to collect metrics
        patch_data_adapter_for_preloader "false"
    elif [ "$running_mode" = "normal" ]; then
        # collect meta data only
        patch_data_adapter_for_preloader "true"
    fi
    # Move scale_down inside run_preloader_command, just in case we need to patch data adapter (historical_only mode)
    scale_down_pods

    # check env is ready
    wait_for_cluster_status_data_ready

    start=`date +%s`
    echo -e "\n$(tput setaf 6)Running preloader in $running_mode mode...$(tput sgr 0)"
    display_resources_detail
    get_current_preloader_name
    if [ "$current_preloader_pod_name" = "" ]; then
        echo -e "\n$(tput setaf 1)ERROR! Can't find installed preloader pod.$(tput sgr 0)"
        leave_prog
        exit 8
    fi

    if [ "$running_mode" = "historical_only" ]; then
        kubectl exec -n $install_namespace $current_preloader_pod_name -- /opt/alameda/federatorai-agent/bin/transmitter loadhistoryonly --state=true
    fi

    if [ "$disable_all_node_metrics" = "y" ]; then
        echo -e "$(tput setaf 6)Disable load on empty node.$(tput sgr 0)"
        kubectl exec -n $install_namespace $current_preloader_pod_name -- /opt/alameda/federatorai-agent/bin/transmitter enable --state=true --DisableLoadAllNodeMetrics=true --random=true
    else
        kubectl exec -n $install_namespace $current_preloader_pod_name -- /opt/alameda/federatorai-agent/bin/transmitter enable
    fi

    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error in executing preloader enable command.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
    echo "Checking..."
    sleep 20
    kubectl logs -n $install_namespace $current_preloader_pod_name | grep -iq "Start PreLoader agent"
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Preloader pod is not running correctly. Please contact support staff$(tput sgr 0)"
        leave_prog
        exit 5
    fi

    if [ "$running_mode" = "historical_only" ] && [ "$k8s_enabled" = "true" ]; then
        if [ "$demo_nginx_exist" = "true" ]; then
            run_ab_test
        fi
    fi

    wait_until_data_pump_finish 21600 60 "historical"
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration run_preloader_command in $running_mode mode = $duration" >> $debug_log
}

run_futuremode_preloader()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Running future mode preloader...$(tput sgr 0)"
    get_current_preloader_name
    if [ "$current_preloader_pod_name" = "" ]; then
        echo -e "\n$(tput setaf 1)ERROR! Can't find installed preloader pod.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
    
    kubectl exec -n $install_namespace $current_preloader_pod_name -- /opt/alameda/federatorai-agent/bin/transmitter loadfuture --hours=$future_mode_length
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error in executing preloader loadfuture command.$(tput sgr 0)"
        leave_prog
        exit 8
    fi

    echo "Checking..."
    sleep 10
    wait_until_data_pump_finish 21600 60 "future"
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration run_futuremode_preloader = $duration" >> $debug_log
}

scale_down_pods()
{
    echo -e "\n$(tput setaf 6)Scaling down alameda-ai and alameda-ai-dispatcher ...$(tput sgr 0)"
    original_alameda_ai_replicas="`kubectl get deploy alameda-ai -n $install_namespace -o jsonpath='{.spec.replicas}'`"
    # Bring down federatorai-operator to prevent it start scale down pods automatically
    kubectl patch deployment federatorai-operator -n $install_namespace -p '{"spec":{"replicas": 0}}'
    kubectl patch deployment alameda-ai -n $install_namespace -p '{"spec":{"replicas": 0}}'
    kubectl patch deployment alameda-ai-dispatcher -n $install_namespace -p '{"spec":{"replicas": 0}}'
    kubectl patch deployment $restart_recommender_deploy -n $install_namespace -p '{"spec":{"replicas": 0}}'
    kubectl patch deployment federatorai-dashboard-backend -n $install_namespace -p '{"spec":{"replicas": 0}}'
    kubectl patch deployment federatorai-dashboard-frontend -n $install_namespace -p '{"spec":{"replicas": 0}}'
    echo "Done"
}

scale_up_pods()
{
    echo -e "\n$(tput setaf 6)Scaling up alameda-ai and alameda-ai-dispatcher ...$(tput sgr 0)"
    if [ "`kubectl get deploy alameda-ai -n $install_namespace -o jsonpath='{.spec.replicas}'`" -eq "0" ]; then
        if [ "$original_alameda_ai_replicas" != "" ]; then
            kubectl patch deployment alameda-ai -n $install_namespace -p "{\"spec\":{\"replicas\": $original_alameda_ai_replicas}}"
        else
            kubectl patch deployment alameda-ai -n $install_namespace -p '{"spec":{"replicas": 1}}'
        fi
        do_something="y"
    fi

    if [ "`kubectl get deploy alameda-ai-dispatcher -n $install_namespace -o jsonpath='{.spec.replicas}'`" -eq "0" ]; then
        kubectl patch deployment alameda-ai-dispatcher -n $install_namespace -p '{"spec":{"replicas": 1}}'
        do_something="y"
    fi

    if [ "`kubectl get deploy $restart_recommender_deploy -n $install_namespace -o jsonpath='{.spec.replicas}'`" -eq "0" ]; then
        kubectl patch deployment $restart_recommender_deploy -n $install_namespace -p '{"spec":{"replicas": 1}}'
        do_something="y"
    fi

    if [ "`kubectl get deploy federatorai-operator -n $install_namespace -o jsonpath='{.spec.replicas}'`" -eq "0" ]; then
        kubectl patch deployment federatorai-operator -n $install_namespace -p '{"spec":{"replicas": 1}}'
        do_something="y"
    fi

    if [ "`kubectl get deploy federatorai-dashboard-backend -n $install_namespace -o jsonpath='{.spec.replicas}'`" -eq "0" ]; then
        kubectl patch deployment federatorai-dashboard-backend -n $install_namespace -p '{"spec":{"replicas": 1}}'
        do_something="y"
    fi

    if [ "`kubectl get deploy federatorai-dashboard-frontend -n $install_namespace -o jsonpath='{.spec.replicas}'`" -eq "0" ]; then
        kubectl patch deployment federatorai-dashboard-frontend -n $install_namespace -p '{"spec":{"replicas": 1}}'
        do_something="y"
    fi

    if [ "$do_something" = "y" ]; then
        wait_until_pods_ready 600 30 $install_namespace
    fi
    echo "Done"
}

OBSOLETED_reschedule_dispatcher()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Rescheduling alameda-ai dispatcher...$(tput sgr 0)"
    current_dispatcher_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-ai-dispatcher-"|awk '{print $1}'|head -1`"
    if [ "$current_dispatcher_pod_name" = "" ]; then
        echo -e "\n$(tput setaf 1)ERROR! Can't find alameda-ai dispatcher pod.$(tput sgr 0)"
        leave_prog
        exit 8
    fi

    kubectl delete pod -n $install_namespace $current_dispatcher_pod_name
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error in deleting dispatcher pod.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
    echo ""
    wait_until_pods_ready 600 30 $install_namespace
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration reschedule_dispatcher = $duration" >> $debug_log

}

alamedaservice_set_component_env()
{
    local component="$1"
    local key="$2"
    local value="$3"    # delete env if value is empty

    # delete env if value is empty
    if [ "${value}" = "" ]; then
        patch_index=$(kubectl get alamedaservice ${alamedaservice_name} -n ${install_namespace} -o jsonpath="{.spec.${component}.env[*]}" | sed 's/ /\n/g' | sed 's/"//g' | grep "name:" | awk '{print NR-1 "," $0}' | grep "${key}" | cut -d ',' -f1)
        if [ "${patch_index}" != "" ]; then
            # Remove existing value
            kubectl patch alamedaservice ${alamedaservice_name} -n ${install_namespace} --type=json --patch "[{\"op\": \"remove\", \"path\": \"/spec/${component}/env/${patch_index}\"}]"
            if [ "$?" != "0" ]; then
                echo -e "\n$(tput setaf 1)Error in removing ${component} env ${key} (op replace).$(tput sgr 0)"
                leave_prog
                exit 8
            fi
        fi
        echo -e "\n$(tput setaf 6)Remove ${component} env ${key}.$(tput sgr 0)"
        return 0
    fi

    current_value=$(kubectl get alamedaservice ${alamedaservice_name} -n ${install_namespace} -o jsonpath="{.spec.${component}.env[?(@.name==\"${key}\")].value}")
    if [ "${current_value}" != "" ]; then
        # Modify only if values are differents
        if [ "${current_value}" != "${value}" ]; then
            # Get ${key} index in env array
            patch_index=$(kubectl get alamedaservice ${alamedaservice_name} -n ${install_namespace} -o jsonpath="{.spec.${component}.env[*]}" | sed 's/ /\n/g' |sed 's/"//g' | grep "name:" | awk '{print NR-1 "," $0}' | grep "${key}" | cut -d ',' -f1)
            if [ "${patch_index}" != "" ]; then
                # replace value at $patch_index
                kubectl patch alamedaservice ${alamedaservice_name} -n ${install_namespace} --type json --patch "[ { \"op\" : \"replace\" , \"path\" : \"/spec/${component}/env/${patch_index}\" , \"value\" : { \"name\" : \"${key}\", \"value\" : \"${value}\" } } ]"
                if [ "$?" != "0" ]; then
                    echo -e "\n$(tput setaf 1)Error in setting ${component} env ${key} (op replace).$(tput sgr 0)"
                    leave_prog
                    exit 8
                fi
            else
                echo -e "\n$(tput setaf 1)Error in setting ${component} env ${key} (Can't get ${key} index).$(tput sgr 0)"
                leave_prog
                exit 8
            fi
            echo -e "\n$(tput setaf 6)Modify ${component} env ${key}=${value}.$(tput sgr 0)"
        else
            echo -e "\n$(tput setaf 6)Use existing ${component} env ${key}=${value}.$(tput sgr 0)"
        fi
    else
        # ${key} not found
        # Check if env[] exist
        current_env_exist="$(kubectl -n ${install_namespace} get alamedaservice ${alamedaservice_name} -o "jsonpath={.spec.${component}.env}" | wc -c | sed 's/[ \t]*//g')"
        if [ "${current_env_exist}" == 0 ]; then
            # env section empty
            kubectl patch alamedaservice ${alamedaservice_name} -n ${install_namespace} --type merge --patch "{\"spec\":{\"${component}\":{\"env\":[{\"name\": \"${key}\",\"value\": \"${value}\"}]}}}"
            if [ "$?" != "0" ]; then
                echo -e "\n$(tput setaf 1)Error in setting agent env ${key} (merge patch).$(tput sgr 0)"
                leave_prog
                exit 8
            fi
        else
            # env section exist, add entry
            kubectl patch alamedaservice ${alamedaservice_name} -n ${install_namespace} --type json --patch "[ { \"op\" : \"add\" , \"path\" : \"/spec/${component}/env/-\" , \"value\" : { \"name\" : \"${key}\", \"value\" : \"${value}\" } } ]"
            if [ "$?" != "0" ]; then
                echo -e "\n$(tput setaf 1)Error in setting agent env ${key} (op add).$(tput sgr 0)"
                leave_prog
                exit 8
            fi
        fi
        echo -e "\n$(tput setaf 6)Set ${component} env ${key}=${value}.$(tput sgr 0)"
    fi
    return 0
}

patch_agent_for_preloader()
{
    local _mode="$1"
    local _period="*/10 * * * *"  # every 10 mins

    start=`date +%s`
    [ "${_mode}" = "true" ] && echo -e "\n$(tput setaf 6)Updating Agent to compute monthly/weekly cost recommendation every `echo ${_period} | sed -e 's/@every //g'` for preloader...$(tput sgr 0)"

    # Need federatorai-operator ready for webhook service to validate alamedaservice
    wait_until_pods_ready 600 30 $install_namespace

    flag_updated="n"
    for key in FEDERATORAI_AGENT_INPUT_JOBS_COST_ANALYSIS_NORMAL_DAILY_SCHEDULE_SPEC \
               FEDERATORAI_AGENT_INPUT_JOBS_COST_ANALYSIS_NORMAL_WEEKLY_SCHEDULE_SPEC \
               FEDERATORAI_AGENT_INPUT_JOBS_COST_ANALYSIS_NORMAL_MONTHLY_SCHEDULE_SPEC \
               FEDERATORAI_AGENT_INPUT_JOBS_COST_ANALYSIS_NORMAL_YEARLY_SCHEDULE_SPEC \
               FEDERATORAI_AGENT_INPUT_JOBS_COST_ANALYSIS_HIGH_RECOMMENDATION_SCHEDULE_SPEC; do
        if [ "${_mode}" = "true" ]; then
            alamedaservice_set_component_env federatoraiAgent ${key} "${_period}"
        else
            alamedaservice_set_component_env federatoraiAgent ${key} ""
        fi
    done
    wait_until_pods_ready 600 30 $install_namespace

    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration patch_agent_for_preloader = $duration" >> $debug_log
}

patch_ai_dispatcher_for_preloader()
{
    local _mode="$1"
    local _period="600"

    start=`date +%s`
    [ "${_mode}" = "true" ] && echo -e "\n$(tput setaf 6)Updating AI Dispatcher to compute daily/monthly/weekly prediction every ${_period}s for preloader...$(tput sgr 0)"

    # Need federatorai-operator ready for webhook service to validate alamedaservice
    wait_until_pods_ready 600 30 $install_namespace

    flag_updated="n"
    # To shorten CI running time, need to compute prediction in shorter time for different intervals
    for key in ALAMEDA_AI_DISPATCHER_JOB_INTERVAL_DAILY \
               ALAMEDA_AI_DISPATCHER_JOB_INTERVAL_WEEKLY \
               ALAMEDA_AI_DISPATCHER_JOB_INTERVAL_MONTHLY \
               ALAMEDA_AI_DISPATCHER_JOB_INTERVAL_YEARLY; do
        if [ "${_mode}" = "true" ]; then
            alamedaservice_set_component_env alameda-dispatcher ${key} "${_period}"
        else
            alamedaservice_set_component_env alameda-dispatcher ${key} ""
        fi
    done
    wait_until_pods_ready 600 30 $install_namespace

    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration patch_ai_dispatcher_for_preloader = $duration" >> $debug_log
}

patch_data_adapter_for_preloader()
{
    only_mode="$1"
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Updating data adapter (collect metadata only mode to $only_mode) for preloader...$(tput sgr 0)"

    # Need federatorai-operator ready for webhook service to validate alamedaservice
    wait_until_pods_ready 600 30 $install_namespace

    # To shorten CI running time, need to collect data in shorter time for different intervals
    if [ "${DO_CI}" = "1" ]; then
        alamedaservice_set_component_env federatoraiDataAdapter COLLECTION_INTERVAL_1H "10m"
        alamedaservice_set_component_env federatoraiDataAdapter COLLECTION_INTERVAL_6H "10m"
        alamedaservice_set_component_env federatoraiDataAdapter COLLECTION_INTERVAL_24H "10m"
    fi

    flag_updated="n"
    current_flag_value=$(kubectl get alamedaservice $alamedaservice_name -n $install_namespace -o 'jsonpath={.spec.federatoraiDataAdapter.env[?(@.name=="COLLECT_METADATA_ONLY")].value}')
    if [ "$current_flag_value" != "" ]; then
        if [ "$current_flag_value" != "$only_mode" ]; then
            # Get COLLECT_METADATA_ONLY index in env array
            patch_index=$(kubectl get alamedaservice $alamedaservice_name -n $install_namespace -o jsonpath='{.spec.federatoraiDataAdapter.env[*]}'|sed 's/ /\n/g'|sed 's/"//g'|grep "name:"|awk '{print NR-1 "," $0}'|grep "COLLECT_METADATA_ONLY"|cut -d ',' -f1)
            if [ "$patch_index" != "" ]; then
                # replace value at $patch_index
                kubectl patch alamedaservice $alamedaservice_name -n $install_namespace --type json --patch "[ { \"op\" : \"replace\" , \"path\" : \"/spec/federatoraiDataAdapter/env/${patch_index}\" , \"value\" : { \"name\" : \"COLLECT_METADATA_ONLY\", \"value\" : \"$only_mode\" } } ]"
                if [ "$?" != "0" ]; then
                    echo -e "\n$(tput setaf 1)Error in updating data adapter to collect_metadata_only = \"$only_mode\" mode (op replace).$(tput sgr 0)"
                    leave_prog
                    exit 8
                fi
                flag_updated="y"
            else
                echo -e "\n$(tput setaf 1)Error in updating data adapter to collect_metadata_only = \"$only_mode\" mode (Can't get COLLECT_METADATA_ONLY index).$(tput sgr 0)"
                leave_prog
                exit 8
            fi
        fi
    else
        # COLLECT_METADATA_ONLY not found
        # Check if env[] exist
        current_env_exist="$(kubectl -n $install_namespace get alamedaservice $alamedaservice_name -o 'jsonpath={.spec.federatoraiDataAdapter.env}'|wc -c|sed 's/[ \t]*//g')"
        if [ "$current_env_exist" == 0 ]; then
            # env section empty
            kubectl patch alamedaservice $alamedaservice_name -n $install_namespace --type merge --patch "{\"spec\":{\"federatoraiDataAdapter\":{\"env\":[{\"name\": \"COLLECT_METADATA_ONLY\",\"value\": \"$only_mode\"}]}}}"
            if [ "$?" != "0" ]; then
                echo -e "\n$(tput setaf 1)Error in updating data adapter to collect_metadata_only = \"$only_mode\" mode (merge patch).$(tput sgr 0)"
                leave_prog
                exit 8
            fi
            flag_updated="y"
        else
            # env section exist, add entry
            kubectl patch alamedaservice $alamedaservice_name -n $install_namespace --type json --patch "[ { \"op\" : \"add\" , \"path\" : \"/spec/federatoraiDataAdapter/env/-\" , \"value\" : { \"name\" : \"COLLECT_METADATA_ONLY\", \"value\" : \"$only_mode\" } } ]"
            if [ "$?" != "0" ]; then
                echo -e "\n$(tput setaf 1)Error in updating data adapter to collect_metadata_only = \"$only_mode\" mode (op add).$(tput sgr 0)"
                leave_prog
                exit 8
            fi
            flag_updated="y"
        fi
    fi

    if [ "$flag_updated" = "y" ]; then
        wait_until_pods_ready 600 30 $install_namespace
    fi

    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration patch_data_adapter_for_preloader = $duration" >> $debug_log
}

patch_datahub_for_preloader()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Updating datahub for preloader...$(tput sgr 0)"
    kubectl get alamedaservice $alamedaservice_name -n $install_namespace -o yaml|grep "\- name: ALAMEDA_DATAHUB_APIS_METRICS_SOURCE" -A1|grep -q influxdb
    if [ "$?" != "0" ]; then
        kubectl patch alamedaservice $alamedaservice_name -n $install_namespace --type merge --patch '{"spec":{"alamedaDatahub":{"env":[{"name": "ALAMEDA_DATAHUB_APIS_METRICS_SOURCE","value": "influxdb"}]}}}'
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error in updating datahub pod.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
        echo ""
        wait_until_pods_ready 600 30 $install_namespace
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration patch_datahub_for_preloader = $duration" >> $debug_log
}

patch_datahub_back_to_normal()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Rolling back datahub...$(tput sgr 0)"
    kubectl get alamedaservice $alamedaservice_name -n $install_namespace -o yaml|grep "\- name: ALAMEDA_DATAHUB_APIS_METRICS_SOURCE" -A1|grep -q prometheus
    if [ "$?" != "0" ]; then
        kubectl patch alamedaservice $alamedaservice_name -n $install_namespace --type merge --patch '{"spec":{"alamedaDatahub":{"env":[{"name": "ALAMEDA_DATAHUB_APIS_METRICS_SOURCE","value": "prometheus"}]}}}'
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error in rolling back datahub pod.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
        echo ""
        wait_until_pods_ready 600 30 $install_namespace
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration patch_datahub_back_to_normal = $duration" >> $debug_log
}

check_federatorai_cluster_type()
{
    vm_enabled="false"
    k8s_enabled="false"

    echo -e "\n$(tput setaf 6)Checking Federator.ai cluster type...$(tput sgr 0)"

    resp=$(fedai_rest_get /apis/v1/resources/clusters)
    # Retry until cluster become active, REST will response also the inactive-clusters
    for i in `seq 1 12`; do
        resp='{"data":[]}'
        [ "`echo \"${resp}\" | jq '.data'`" != "[]" ] && break
        sleep 10
        resp=$(fedai_rest_get /apis/v1/resources/clusters)
    done
    [ "`echo \"${resp}\" | jq '.data[].type' 2> /dev/null | grep 'k8s' 2> /dev/null`" != "" ] && k8s_enabled="true"
    [ "`echo \"${resp}\" | jq '.data[].type' 2> /dev/null | grep 'vm' 2> /dev/null`" != "" ] && vm_enabled="true"
    if [ "$vm_enabled" = "false" ] && [ "$k8s_enabled" = "false" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get cluster type.$(tput sgr 0)"
        exit 8
    fi
    echo "k8s_enabled = $k8s_enabled"
    echo "vm_enabled = $vm_enabled"
    echo "Done"
}

check_influxdb_retention()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Checking retention policy...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "show retention policies"|grep "autogen"|grep -q "3600h"
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error! retention policy of alameda_metric pod is not 3600h.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration check_influxdb_retention = $duration" >> $debug_log
}

patch_grafana_for_preloader()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Adding flag for grafana ...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "select * from grafana_config order by time desc limit 1" 2>/dev/null|grep -q true
    if [ "$?" != "0" ]; then
        kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -execute "show databases" |grep -q "alameda_metric"
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Can't find alameda_metric in influxdb.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
        kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "insert grafana_config preloader=true"
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Adding flag for grafana failed.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration patch_grafana_for_preloader = $duration" >> $debug_log
}

patch_grafana_back_to_normal()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Adding flag to roll back grafana ...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "select * from grafana_config order by time desc limit 1" 2>/dev/null|grep -q false
    if [ "$?" != "0" ]; then
        kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -execute "show databases" |grep -q "alameda_metric"
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Can't find alameda_metric in influxdb.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
        kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "insert grafana_config preloader=false"
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Adding flag to roll back grafana failed.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration patch_grafana_back_to_normal = $duration" >> $debug_log
}

_do_metrics_verify()
{
    mode="$1"
    if [ "$mode" != "vm" ] && [ "$mode" != "k8s" ]; then
        echo -e "\n$(tput setaf 1)Error! _do_metrics_verify() mode paramter can only be either 'vm' or 'k8s'.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
    echo -e "\n$(tput setaf 6)Verifying $mode metrics in influxdb ...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    verification_result="true"
    if [ "$mode" = "vm" ]; then
        # VM
        # metricsArray=("node_cpu" "node_memory")
        # metrics_required_number=`echo "${#metricsArray[@]}"`
        # metrics_list=$(kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "show measurements")
        # metrics_num_found="0"
        # for i in $(seq 0 $((metrics_required_number-1)))
        # do
        #     echo "$metrics_list"|grep -q "^${metricsArray[$i]}$"
        #     if [ "$?" = "0" ]; then
        #         metrics_num_found=$((metrics_num_found+1))
        #     fi
        # done
        echo -e "\n$(tput setaf 2)Note!! Temporarily skip vm metrics check.\n$(tput sgr 0)"
    else
        # K8S
        containerMeasurementsArray=("container_0" "container_1" "container_2")
        namespaceMeasurementsArray=("namespace_0" "namespace_1" "namespace_2")
        nodeMeasurementsArray=("node_0" "node_1" "node_2")
        if [ "${PRELOADER_PRELOAD_COUNT}" = "" ]; then
            verify_before_time_range="110d"    # default pump 120d, so we verify data before 110d
        else
            if [ "${PRELOADER_PRELOAD_COUNT}" -ge 11 ]; then
                verify_before_time_range="`expr ${PRELOADER_PRELOAD_COUNT} - 10`d"
            else
                verify_before_time_range="0d"
            fi
        fi

        total_num="0"
        all_id_list=""
        for measurement in "${containerMeasurementsArray[@]}"
        do
            unique_id_list=$(kubectl -n $install_namespace exec $influxdb_pod_name -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database metric_instance_workload_le3599 -execute "select * from $measurement where time < now() - ${verify_before_time_range} order by time asc limit 100"|tail -n+4|grep -o " builtin-[^ ]*"|sed 's/^ *//g'|sort|uniq)
            if [ "$unique_id_list" != "" ]; then
                unique_id_num=$(echo "$unique_id_list"|wc -l|sed 's/[ \t]*//g')
                total_num=$((total_num+unique_id_num))
                if [ "$all_id_list" = "" ]; then
                    all_id_list="$unique_id_list"
                else
                    all_id_list="$all_id_list"$'\n'"$unique_id_list"
                fi
            fi
        done
        if [ "$total_num" -lt "2" ]; then
            verification_result="false"
            echo -e "$(tput setaf 1)Error! Missing container built-in metric ID.$(tput sgr 0)"
            echo -e "Container ID exist in the system:\n$all_id_list"
        fi

        total_num="0"
        all_id_list=""
        for measurement in "${namespaceMeasurementsArray[@]}"
        do
            unique_id_list=$(kubectl -n $install_namespace exec $influxdb_pod_name -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database metric_instance_workload_le3599 -execute "select * from $measurement where time < now() - ${verify_before_time_range} order by time asc limit 100"|tail -n+4|grep -o " builtin-[^ ]*"|sed 's/^ *//g'|sort|uniq)
            if [ "$unique_id_list" != "" ]; then
                unique_id_num=$(echo "$unique_id_list"|wc -l|sed 's/[ \t]*//g')
                total_num=$((total_num+unique_id_num))
                if [ "$all_id_list" = "" ]; then
                    all_id_list="$unique_id_list"
                else
                    all_id_list="$all_id_list"$'\n'"$unique_id_list"
                fi
            fi
        done
        if [ "$total_num" -lt "2" ]; then
            verification_result="false"
            echo -e "$(tput setaf 1)Error! Missing namespace built-in metric ID.$(tput sgr 0)"
            echo -e "Namespace ID exist in the system:\n$all_id_list"
        fi

        total_num="0"
        all_id_list=""
        for measurement in "${nodeMeasurementsArray[@]}"
        do
            unique_id_list=$(kubectl -n $install_namespace exec $influxdb_pod_name -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database metric_instance_workload_le3599 -execute "select * from $measurement where time < now() - ${verify_before_time_range} order by time asc limit 100"|tail -n+4|grep -o " builtin-[^ ]*"|sed 's/^ *//g'|sort|uniq)
            if [ "$unique_id_list" != "" ]; then
                unique_id_num=$(echo "$unique_id_list"|wc -l|sed 's/[ \t]*//g')
                total_num=$((total_num+unique_id_num))
                if [ "$all_id_list" = "" ]; then
                    all_id_list="$unique_id_list"
                else
                    all_id_list="$all_id_list"$'\n'"$unique_id_list"
                fi
            fi
        done
        if [ "$total_num" -lt "2" ]; then
            verification_result="false"
            echo -e "$(tput setaf 1)Error! Missing node built-in metric ID.$(tput sgr 0)"
            echo -e "Node ID exist in the system:\n$all_id_list"
        fi
        if [ "$verification_result" != "true" ]; then
            leave_prog
            exit 8
        fi
    fi

    echo "Done"
}

verify_metrics_exist()
{
    start=`date +%s`

    if [ "$vm_enabled" = "true" ]; then
        _do_metrics_verify "vm"
    fi
    if [ "$k8s_enabled" = "true" ]; then
        _do_metrics_verify "k8s"
    fi

    end=`date +%s`
    duration=$((end-start))
    echo "Duration verify_metrics_exist = $duration" >> $debug_log
}

delete_nginx_example()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Deleting NGINX sample ...$(tput sgr 0)"
    dc_name="`kubectl get dc -n $nginx_ns 2>/dev/null|grep -v "NAME"|awk '{print $1}'`"
    if [ "$dc_name" != "" ]; then
        kubectl delete dc $dc_name -n $nginx_ns
    fi
    deploy_name="`kubectl get deploy -n $nginx_ns 2>/dev/null|grep -v "NAME"|awk '{print $1}'`"
    if [ "$deploy_name" != "" ]; then
        kubectl delete deploy $deploy_name -n $nginx_ns
    fi
    kubectl get ns $nginx_ns >/dev/null 2>&1
    if [ "$?" = "0" ]; then
        kubectl delete ns $nginx_ns
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration delete_nginx_example = $duration" >> $debug_log
}

new_nginx_example()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Creating a new NGINX sample pod ...$(tput sgr 0)"

    if [ "$demo_nginx_exist" = "true" ]; then
        echo "nginx-preloader-sample namespace and pod already exist."
    else
        if [ "$openshift_minor_version" != "" ]; then
            # OpenShift
            nginx_openshift_yaml="nginx_openshift.yaml"
            cat > ${nginx_openshift_yaml} << __EOF__
{
    "kind": "List",
    "apiVersion": "v1",
    "metadata": {},
    "items": [
        {
            "apiVersion": "apps.openshift.io/v1",
            "kind": "DeploymentConfig",
            "metadata": {
                "labels": {
                    "app": "${nginx_name}"
                },
                "name": "${nginx_name}"
            },
            "spec": {
                "replicas": ${replica_number},
                "selector": {
                    "app": "${nginx_name}",
                    "deploymentconfig": "${nginx_name}"
                },
                "strategy": {
                    "resources": {},
                    "rollingParams": {
                        "intervalSeconds": 1,
                        "maxSurge": "25%",
                        "maxUnavailable": "25%",
                        "timeoutSeconds": 600,
                        "updatePeriodSeconds": 1
                    },
                    "type": "Rolling"
                },
                "template": {
                    "metadata": {
                        "labels": {
                            "app": "${nginx_name}",
                            "deploymentconfig": "${nginx_name}"
                        }
                    },
                    "spec": {
                        "containers": [
                            {
                                "image": "twalter/openshift-nginx:stable-alpine",
                                "imagePullPolicy": "IfNotPresent",
                                "name": "${nginx_name}",
                                "ports": [
                                    {
                                        "containerPort": ${nginx_port},
                                        "protocol": "TCP"
                                    }
                                ],
                                "resources":
                                {
                                    "limits":
                                        {
                                        "cpu": "200m",
                                        "memory": "20Mi"
                                        },
                                    "requests":
                                        {
                                        "cpu": "100m",
                                        "memory": "10Mi"
                                        }
                                },
                                "terminationMessagePath": "/dev/termination-log"
                            }
                        ],
                        "dnsPolicy": "ClusterFirst",
                        "restartPolicy": "Always",
                        "securityContext": {},
                        "terminationGracePeriodSeconds": 30
                    }
                }
            }
        },
        {
            "apiVersion": "v1",
            "kind": "Service",
            "metadata": {
                "labels": {
                    "app": "${nginx_name}"
                },
                "name": "${nginx_name}"
            },
            "spec": {
                "ports": [
                    {
                        "name": "http",
                        "port": ${nginx_port},
                        "protocol": "TCP",
                        "targetPort": ${nginx_port}
                    }
                ],
                "selector": {
                    "app": "${nginx_name}",
                    "deploymentconfig": "${nginx_name}"
                }
            }
        },
        {
            "apiVersion": "route.openshift.io/v1",
            "kind": "Route",
            "metadata": {
                "labels": {
                    "app": "${nginx_name}"
                },
                "name": "${nginx_name}"
            },
            "spec": {
                "port": {
                    "targetPort": ${nginx_port}
                },
                "to": {
                    "kind": "Service",
                    "name": "${nginx_name}"
                },
                "weight": 100,
                "wildcardPolicy": "None"
            }
        }
    ]
}
__EOF__
            oc new-project $nginx_ns
            oc apply -f ${nginx_openshift_yaml}
            if [ "$?" != "0" ]; then
                echo -e "\n$(tput setaf 1)Error! create NGINX app failed.$(tput sgr 0)"
                leave_prog
                exit 8
            fi
            echo ""
            wait_until_pods_ready 600 30 $nginx_ns
            oc project $install_namespace
        else
            # K8S
            nginx_k8s_yaml="nginx_k8s.yaml"
            cat > ${nginx_k8s_yaml} << __EOF__
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${nginx_name}
  namespace: ${nginx_ns}
  labels:
     app: ${nginx_name}
spec:
  selector:
    matchLabels:
      app: ${nginx_name}
  replicas: ${replica_number}
  template:
    metadata:
      labels:
        app: ${nginx_name}
    spec:
      containers:
      - name: ${nginx_name}
        image: nginx:1.7.9
        resources:
            limits:
                cpu: "200m"
                memory: "20Mi"
            requests:
                cpu: "100m"
                memory: "10Mi"
        ports:
        - containerPort: ${nginx_port}
      serviceAccountName: ${nginx_name}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${nginx_name}
rules:
- apiGroups:
  - policy
  resources:
  - podsecuritypolicies
  verbs:
  - use
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${nginx_name}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${nginx_name}
subjects:
- kind: ServiceAccount
  name: ${nginx_name}
  namespace: ${nginx_ns}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${nginx_name}
  namespace: ${nginx_ns}
__EOF__
            kubectl create ns $nginx_ns
            kubectl apply -f $nginx_k8s_yaml
            if [ "$?" != "0" ]; then
                echo -e "\n$(tput setaf 1)Error! create NGINX app failed.$(tput sgr 0)"
                leave_prog
                exit 8
            fi
            echo ""
            wait_until_pods_ready 600 30 $nginx_ns
        fi
    fi
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration new_nginx_example = $duration" >> $debug_log
}

get_datadog_agent_info()
{
    while read a b c
    do
        dd_namespace=$a
        dd_key=$b
        dd_api_secret_name=$c
        if [ "$dd_namespace" != "" ] && [ "$dd_key" != "" ] && [ "$dd_api_secret_name" != "" ]; then
           break
        fi
    done<<<"$(kubectl get daemonset --all-namespaces -o jsonpath='{range .items[*]}{@.metadata.namespace}{"\t"}{range .spec.template.spec.containers[*]}{.env[?(@.name=="DD_API_KEY")].name}{"\t"}{.env[?(@.name=="DD_API_KEY")].valueFrom.secretKeyRef.name}{"\n"}{end}{"\t"}{end}' 2>/dev/null| grep "DD_API_KEY")"

    if [ "$dd_key" = "" ] || [ "$dd_namespace" = "" ] || [ "$dd_api_secret_name" = "" ]; then
        return
    fi
    dd_api_key="`kubectl get secret -n $dd_namespace $dd_api_secret_name -o jsonpath='{.data.api-key}'`"
    dd_app_key="`kubectl get secret -n $dd_namespace -o jsonpath='{range .items[*]}{.data.app-key}'`"
    dd_cluster_agent_deploy_name="$(kubectl get deploy -n $dd_namespace |grep -v NAME|awk '{print $1}'|grep "cluster-agent$")"
    dd_cluster_name="$(kubectl get deploy $dd_cluster_agent_deploy_name -n $dd_namespace -o jsonpath='{range .spec.template.spec.containers[*]}{.env[?(@.name=="DD_CLUSTER_NAME")].value}' 2>/dev/null | awk '{print $1}')"
}

get_cluster_name_from_alamedascaler()
{
    resp=$(fedai_rest_get /apis/v1/configs/scaler)
    # Retry until cluster become active, REST will response also the inactive-clusters
    for i in `seq 1 12`; do
        [ "`echo \"${resp}\" | jq '.data'`" != "[]" ] && break
        sleep 10
        resp=$(fedai_rest_get /apis/v1/configs/scaler)
    done
    cluster_name=$(echo "${resp}" | jq -r '.data[] | select(.object_meta.name=="'${alamedascaler_name}'") | .target_cluster_name')
    if [ "${cluster_name}" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get cluster name of alamedascaler ($alamedascaler_name).$(tput sgr 0)"
        exit 3
    fi
}

get_datasource_in_alamedaorganization()
{
    # Get cluster specific data source setting
    data_source_type=$(psql_query "select data_source from configuration.clusters where cluster_name='"${cluster_name}"'")
    if [ "$data_source_type" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to find data source of cluster ($cluster_name)$(tput sgr 0)"
        echo -e "$(tput setaf 1)Remember to configure cluster through GUI before running preloader script or check specified cluster name.$(tput sgr 0)"
        exit 3
    fi
}

# 4.4 will handle local cluster automatically
# add_dd_tags_to_executor_env()
# {
#     start=`date +%s`
#     echo -e "\n$(tput setaf 6)Adding dd tags to executor env...$(tput sgr 0)"
#     if [ "$cluster_name" = "" ]; then
#         echo -e "\n$(tput setaf 1)Error! Cluster name can't be empty. Use option '-a' to specify cluster name$(tput sgr 0)"
#         show_usage
#         exit 3
#     fi
#     kubectl patch alamedaservice $alamedaservice_name -n ${install_namespace} --type merge --patch "{\"spec\":{\"alamedaExecutor\":{\"env\":[{\"name\": \"ALAMEDA_EXECUTOR_CLUSTERNAME\",\"value\": \"$cluster_name\"}]}}}"
#     if [ "$?" != "0" ]; then
#         echo -e "\n$(tput setaf 1)Error! Failed to set ALAMEDA_EXECUTOR_CLUSTERNAME as alamedaExecutor env.$(tput sgr 0)"
#         leave_prog
#         exit 8
#     fi

#     echo "Done"
#     end=`date +%s`
#     duration=$((end-start))
#     echo "Duration add_dd_tags_to_executor_env = $duration" >> $debug_log
# }

check_cluster_name_not_empty()
{
    if [ "$cluster_name" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Cluster name can't be empty. Use option '-a' to specify cluster name$(tput sgr 0)"
        show_usage
        exit 3
    fi
}

check_needed_commands()
{
    type jq > /dev/null 2>&1
    if [ "$?" != "0" ];then
        echo -e "\n$(tput setaf 1)Error! Failed to locate jq command.$(tput sgr 0)"
        echo "Please intall jq command by following steps:"
        echo "a) curl -sLo jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64"
        echo "b) chmod +x jq"
        echo "c) mv jq /usr/bin"
        leave_prog
        exit 8
    fi
}

add_alamedascaler_for_nginx()
{
    check_needed_commands
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Adding/Updating NGINX alamedascaler ...$(tput sgr 0)"
    check_cluster_name_not_empty

    if [ "$openshift_minor_version" = "" ]; then
        # K8S - Deployment
        kind_type="1"
        kind_name="DEPLOYMENT"
    else
        # OpenShift - DeploymentConfig
        kind_type="3"
        kind_name="DEPLOYMENTCONFIG"
    fi

    case ${data_source_type} in
        "datadog") data_source_id=1;;
        "prometheus") data_source_id=2;;
        "sysdig") data_source_id=3;;
        "vmware") data_source_id=4;;
        "cloudwatch") data_source_id=5;;
        *)
            echo -e "\n$(tput setaf 1)Error! Invalid data source type '${data_source_type}'.$(tput sgr 0)"
            leave_prog
            exit 8
            ;;
    esac

    # Retrieve metrics
    rest_pod_name="`kubectl get pods -n ${install_namespace} | grep "federatorai-rest-" | awk '{print $1}' | head -1`"
    json_data="{\"cluster_name\": \"${cluster_name}\", \"data_source\": ${data_source_id}}"
    get_result=$(kubectl -n ${install_namespace} exec -t ${rest_pod_name} -- \
        curl -s -X POST -v -H "Content-Type: application/json" \
        -u "${auth_username}:${auth_password}" \
        -d "${json_data}" \
        http://127.0.0.1:5055/apis/v1/configs/allow_metrics)
    metrics_record=$(echo "${get_result}" | jq ".data[] | select (.representative.Name == \"cpu\")" 2> /dev/null)

    # Create new scaler
    json_data="{\"data\":[{\"object_meta\":{\"name\":\"${alamedascaler_name}\",\"namespace\":\"${install_namespace}\"\
    ,\"nodename\":\"\",\"clustername\":\"\",\"uid\":\"\",\"creationtimestamp\":0},\"target_cluster_name\":\"${cluster_name}\",\
    \"correlation_analysis\":1,\"controllers\":[{\"evictable\":{\"value\":${evictable_option}},\"enable_execution\":{\"value\":${enable_execution}},\
    \"scaling_type\":${autoscaling_method},\"application_type\":\"generic\",\"generic\":{\"target\":{\"namespace\":\"${nginx_ns}\",\
    \"name\":\"${nginx_name}\",\"controller_kind\":${kind_type}},\"hpa_parameters\":{\"min_replicas\":{\"value\":1},\
    \"max_replicas\":40}},\"metrics\":[${metrics_record}]}]}]}"

    if [ "$(find_current_scalers '1')" = "n" ]; then
        curl_method="POST"
    else
        # previous alamedascaler existed. Do update
        curl_method="PUT"
    fi

    create_response="$(kubectl -n ${install_namespace} exec -t ${rest_pod_name} -- \
    curl -s -X ${curl_method} -v -H "Content-Type: application/json" \
        -u "${auth_username}:${auth_password}" \
        -d "${json_data}" \
        http://127.0.0.1:5055/apis/v1/configs/scaler 2>&1)"
    if [ "`echo \"${create_response}\" | grep 'HTTP/1.1 200 '`" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Create/Update alamedascaler for NGINX app failed.$(tput sgr 0)"
        echo -e "The request response shows as following.\n${create_response}\n"
        leave_prog
        exit 8
    fi

    if [ "$(find_current_scalers '5')" = "n" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to find new created NGINX alamedascaler.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
    sleep 10


    # Change namespace to 'monitoring' instead of default 'collecting' state
    # rest api to update namespace state
    # method:  PUT
    # rest url: http://127.0.0.1:5055/apis/v1/configs/updatenamespacestate
    # request body: {"data": { "cluster_name": "my-k8s-1", "name": "kube-system", "state": "monitoring"}}
    json_data="{\"data\": { \"cluster_name\": \"${cluster_name}\", \"name\": \"${nginx_ns}\", \"state\": \"monitoring\"}}"
    # Retry maximum 20*15s=300s because data-adapter took time to add namespace into alameda_cluster_status.namespace measurement
    for i in `seq 1 20`; do
        rest_pod_name="`kubectl get pods -n ${install_namespace} | grep "federatorai-rest-" | awk '{print $1}' | head -1`"
        (kubectl -n ${install_namespace} exec -it ${rest_pod_name} -- \
            curl -s -v -X PUT -H "Content-Type: application/json" \
                -u "${auth_username}:${auth_password}" \
                -d "${json_data}" \
                http://127.0.0.1:5055/apis/v1/configs/updatenamespacestate \
                2>&1) > /tmp/.preloader-running.$$
        cat /tmp/.preloader-running.$$ >> $debug_log
        # Wait until exists in alameda_cluster_status.namespace
        grep "Namespace .*. in cluster .*. is not found" /tmp/.preloader-running.$$ > /dev/null
        if [ "$?" = "0" ]; then
            echo "Waiting for namespace ${nginx_ns} become ready in database"
            sleep 15
            continue
        fi
        #
        grep 'HTTP/1.1 200 OK' /tmp/.preloader-running.$$ > /dev/null
        if [ "$?" = "0" ]; then
            break
        fi
        cat /tmp/.preloader-running.$$
        echo "Error in setting 'monitoring' state." >> $debug_log
        echo "Error in setting 'monitoring' state."
        sleep 5
    done
    rm -f /tmp/.preloader-running.$$
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration add_alamedascaler_for_nginx = $duration" >> $debug_log
}

find_current_scalers()
{
    repeat="$1"
    rest_pod_name="`kubectl get pods -n ${install_namespace} | grep "federatorai-rest-" | awk '{print $1}' | head -1`"
    # test if scaler exist (10-12 seconds)
    for i in `seq 1 $repeat`
    do
        get_result=$(kubectl -n ${install_namespace} exec -it ${rest_pod_name} -- \
            curl -s -X GET -H "Content-Type: application/json" \
                -u "${auth_username}:${auth_password}" \
                http://127.0.0.1:5055/apis/v1/configs/scaler)

        record="$(echo "$get_result"|jq ".data[]|select (.target_cluster_name == \"${cluster_name}\") |select (.object_meta.name == \"${alamedascaler_name}\")|select (.controllers[].generic.target.namespace == \"${nginx_ns}\")" 2>/dev/null)"

        if [ "$record" = "" ]; then
            sleep 2
            continue
        else
            echo "y"
            return
        fi
    done
    echo "n"
    return
}

cleanup_influxdb_prediction_related_contents()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Cleaning old influxdb prediction/recommendation/planning records ...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    for database in alameda_prediction alameda_recommendation alameda_planning alameda_fedemeter
    do
        echo "database=$database"
        # prepare sql command
        m_list=""
        sql_cmd=""
        measurement_list="`kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database $database -execute "show measurements" 2>&1 |tail -n+4`"
        for measurement in `echo $measurement_list`
        do
            m_list="${m_list} ${measurement}"
            sql_cmd="${sql_cmd}drop measurement $measurement;"
        done
        if [ "${m_list}" != "" ]; then
            echo "cleaning up measurements: ${m_list}"
            kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database $database -execute "${sql_cmd}" | grep -v "^$"
        fi
    done
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration cleanup_influxdb_prediction_related_contents = $duration" >> $debug_log
}

cleanup_alamedaai_models()
{
    start=`date +%s`
    #/var/lib/alameda/alameda-ai/models/online/workload_prediction
    echo -e "\n$(tput setaf 6)Cleaning old alameda ai model ...$(tput sgr 0)"
    for ai_pod_name in `kubectl get pods -n $install_namespace -o jsonpath='{range .items[*]}{"\n"}{.metadata.name}'|grep alameda-ai-|grep -v dispatcher`
    do
        kubectl exec $ai_pod_name -n $install_namespace -- rm -rf /var/lib/alameda/alameda-ai/models/online/workload_prediction
    done
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration cleanup_alamedaai_models = $duration" >> $debug_log
}

cleanup_influxdb_preloader_related_contents()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Cleaning old influxdb preloader metrics records ...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    
    measurement_list="`kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "show measurements" 2>&1 |tail -n+4`"
    echo "database=alameda_metric"
    # prepare sql command
    m_list=""
    for measurement in `echo $measurement_list`
    do
        if [ "$measurement" = "grafana_config" ]; then
            continue
        fi
        m_list="${m_list} ${measurement}"
        sql_cmd="${sql_cmd}drop measurement $measurement;"
    done
    if [ "${m_list}" != "" ]; then
        echo "cleaning up measurements: ${m_list}"
        kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "${sql_cmd}" | grep -v "^$"
    fi

    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration cleanup_influxdb_preloader_related_contents = $duration" >> $debug_log
    cleanup_influxdb_3er_metrics
}

cleanup_influxdb_3er_metrics(){
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Cleaning old influxdb 3er preloader metrics records ...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"

    target_databases=( metric_instance_workload_le3599 metric_instance_workload_le21599 metric_instance_workload_le86399
    metric_instance_workload_ge86400 metric_instance_prediction_le3599 metric_instance_prediction_le21599
    metric_instance_prediction_le86399 metric_instance_prediction_ge86400 metric_instance_recommendation_le3599
    metric_instance_recommendation_le21599 metric_instance_recommendation_le86399 metric_instance_recommendation_ge86400
    metric_instance_planning_le3599 metric_instance_planning_le21599 metric_instance_planning_le86399
    metric_instance_planning_ge86400)
    for db in "${target_databases[@]}"
    do
        measurement_list="`kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database $db -execute "show measurements" 2>&1 |tail -n+4`"
        echo "database=$db"
        # prepare sql command
        m_list=""
        for measurement in `echo $measurement_list`
        do
            m_list="${m_list} ${measurement}"
            sql_cmd="${sql_cmd}drop measurement $measurement;"
        done
        if [ "${m_list}" != "" ]; then
            echo "cleaning up measurements: ${m_list}"
            kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database $db -execute "${sql_cmd}" | grep -v "^$"
        fi
    done

    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration cleanup_influxdb_3er_metrics = $duration" >> $debug_log
}

check_prediction_status()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Checking the prediction status of monitored objects ...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    measurements_list="`oc exec alameda-influxdb-54949c7c-jp4lk -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_cluster_status -execute "show measurements"|tail -n+4`"
    for measurement in `echo $measurements_list`
    do
        record_number="`oc exec $influxdb_pod_name -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_cluster_status -execute "select count(*) from $measurement"|tail -1|awk '{print $NF}'`"
        echo "$measurement = $xx"
        case $future_mode_length in
                ''|*[!0-9]*) echo -e "\n$(tput setaf 1)future mode length (hour) needs to be an integer.$(tput sgr 0)" && show_usage ;;
                *) ;;
        esac

        re='^[0-9]+$'
        if ! [[ $xx =~ $re ]] ; then
            echo "error: Not a number" >&2; exit 1
        else
            yy=$(($yy + $xx))
        fi
    done
    end=`date +%s`
    duration=$((end-start))
    echo "Duration check_prediction_status() = $duration" >> $debug_log
}

check_deployment_status()
{
    period="$1"
    interval="$2"
    deploy_name="$3"
    deploy_status_expected="$4"

    for ((i=0; i<$period; i+=$interval)); do
        kubectl -n $install_namespace get deploy $deploy_name >/dev/null 2>&1
        if [ "$?" = "0" ] && [ "$deploy_status_expected" = "on" ]; then
            echo -e "Deployment $deploy_name exists."
            return 0
        elif [ "$?" != "0" ] && [ "$deploy_status_expected" = "off" ]; then
            echo -e "Deployment $deploy_name is gone."
            return 0
        fi
        echo "Waiting for deployment $deploy_name become expected status ($deploy_status_expected)..."
        sleep "$interval"
    done
    echo -e "\n$(tput setaf 1)Error!! Waited for $period seconds, but deployment $deploy_name status is not ($deploy_status_expected).$(tput sgr 0)"
    leave_prog
    exit 7
}

# switch_alameda_executor_in_alamedaservice()
# {
#     start=`date +%s`
#     switch_option="$1"
#     get_current_executor_name
#     modified="n"
#     if [ "$current_executor_pod_name" = "" ] && [ "$switch_option" = "on" ]; then
#         # Turn on
#         echo -e "\n$(tput setaf 6)Enabling executor in alamedaservice...$(tput sgr 0)"
#         kubectl patch alamedaservice $alamedaservice_name -n $install_namespace --type merge --patch '{"spec":{"enableExecution": true}}'
#         if [ "$?" != "0" ]; then
#             echo -e "\n$(tput setaf 1)Error in enabling executor pod.$(tput sgr 0)"
#             leave_prog
#             exit 8
#         fi
#         modified="y"
#         check_deployment_status 180 10 "alameda-executor" "on"
#     elif [ "$current_executor_pod_name" != "" ] && [ "$switch_option" = "off" ]; then
#         # Turn off
#         echo -e "\n$(tput setaf 6)Disable executor in alamedaservice...$(tput sgr 0)"
#         kubectl patch alamedaservice $alamedaservice_name -n $install_namespace --type merge --patch '{"spec":{"enableExecution": false}}'
#         if [ "$?" != "0" ]; then
#             echo -e "\n$(tput setaf 1)Error in deleting preloader pod.$(tput sgr 0)"
#             leave_prog
#             exit 8
#         fi
#         modified="y"
#         check_deployment_status 180 10 "alameda-executor" "off"
#     fi

#     if [ "$modified" = "y" ]; then
#         echo ""
#         wait_until_pods_ready 600 30 $install_namespace
#     fi

#     get_current_executor_name
#     if [ "$current_executor_pod_name" = "" ] && [ "$switch_option" = "on" ]; then
#         echo -e "\n$(tput setaf 1)ERROR! Can't find executor pod.$(tput sgr 0)"
#         leave_prog
#         exit 8
#     elif [ "$current_executor_pod_name" != "" ] && [ "$switch_option" = "off" ]; then
#         echo -e "\n$(tput setaf 1)ERROR! Executor pod still exists as $current_executor_pod_name.$(tput sgr 0)"
#         leave_prog
#         exit 8
#     fi

#     echo "Done"
#     end=`date +%s`
#     duration=$((end-start))
#     echo "Duration switch_alameda_executor_in_alamedaservice = $duration" >> $debug_log
# }

enable_preloader_in_alamedaservice()
{
    start=`date +%s`

    # Refine variables before running preloader
    refine_preloader_variables_with_alamedaservice

    get_current_preloader_name
    if [ "$current_preloader_pod_name" != "" ]; then
        echo -e "\n$(tput setaf 6)Skip preloader installation due to preloader pod exists.$(tput sgr 0)"
        echo -e "Deleting preloader pod to renew the pod state..."
        # Delete previous agent.log to prevent pump status checking error.
        kubectl -n $install_namespace exec $current_preloader_pod_name -- rm -f /var/log/alameda/agent.log >/dev/null 2>&1
        kubectl delete pod -n $install_namespace $current_preloader_pod_name
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error in deleting preloader pod.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
    else
        echo -e "\n$(tput setaf 6)Enabling preloader in alamedaservice...$(tput sgr 0)"
        kubectl patch alamedaservice $alamedaservice_name -n $install_namespace --type merge --patch '{"spec":{"enablePreloader": true}}'
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error in updating alamedaservice $alamedaservice_name.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
    fi
    # Check if preloader is ready
    check_deployment_status 180 10 "federatorai-agent-preloader" "on"
    echo ""
    wait_until_pods_ready 600 30 $install_namespace
    get_current_preloader_name
    if [ "$current_preloader_pod_name" = "" ]; then
        echo -e "\n$(tput setaf 1)ERROR! Can't find installed preloader pod.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration enable_preloader_in_alamedaservice = $duration" >> $debug_log
}

add_svc_for_nginx()
{
    # K8S only
    if [ "$openshift_minor_version" = "" ]; then
        start=`date +%s`
        echo -e "\n$(tput setaf 6)Adding svc for NGINX ...$(tput sgr 0)"

        # Check if svc already exist
        kubectl get svc ${nginx_name} -n $nginx_ns &>/dev/null
        if [ "$?" = "0" ]; then
            echo "svc already exists in namespace $nginx_ns"
            echo "Done"
            return
        fi

        nginx_svc_yaml="nginx_svc.yaml"
        cat > ${nginx_svc_yaml} << __EOF__
apiVersion: v1
kind: Service
metadata:
  name: ${nginx_name}
  namespace: ${nginx_ns}
  labels:
    app: ${nginx_name}
spec:
  type: NodePort
  ports:
  - port: ${nginx_port}
    nodePort: 31020
    targetPort: ${nginx_port}
    protocol: TCP
    name: http
  selector:
    app: ${nginx_name}
__EOF__

        kubectl apply -f $nginx_svc_yaml
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Apply NGINX svc yaml failed.$(tput sgr 0)"
            leave_prog
            exit 8
        fi

        echo "Done"
        end=`date +%s`
        duration=$((end-start))
        echo "Duration add_svc_for_nginx = $duration" >> $debug_log
    fi
}

check_recommendation_pod_type()
{
    dispatcher_type_deploy_name="federatorai-recommender-dispatcher"
    non_dispatcher_type_deploy_name="alameda-recommender"
    kubectl -n $install_namespace get deploy $dispatcher_type_deploy_name >/dev/null 2>&1
    if [ "$?" = "0" ]; then
        # federatorai-recommender-worker and federatorai-recommender-dispatcher
        restart_recommender_deploy=$dispatcher_type_deploy_name
    else
        # alameda-recommender
        restart_recommender_deploy=$non_dispatcher_type_deploy_name
    fi
}

disable_preloader_in_alamedaservice()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Disabling preloader in alamedaservice...$(tput sgr 0)"
    get_current_preloader_name
    if [ "$current_preloader_pod_name" != "" ]; then
        kubectl patch alamedaservice $alamedaservice_name -n $install_namespace  --type merge --patch '{"spec":{"enablePreloader": false}}'
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error in updating alamedaservice $alamedaservice_name.$(tput sgr 0)"
            leave_prog
            exit 8
        fi

        # Check if preloader is removed and other pods are ready
        check_deployment_status 180 10 "federatorai-agent-preloader" "off"
        echo ""
        wait_until_pods_ready 600 30 $install_namespace
        get_current_preloader_name
        if [ "$current_preloader_pod_name" != "" ]; then
            echo -e "\n$(tput setaf 1)ERROR! Can't stop preloader pod.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration disable_preloader_in_alamedaservice = $duration" >> $debug_log
}

clean_environment_operations()
{
    get_current_preloader_name
    if [ "$current_preloader_pod_name" != "" ]; then
        echo -e "Deleting preloader pod to renew the pod state..."
        kubectl delete pod -n $install_namespace $current_preloader_pod_name
    fi
    cleanup_influxdb_preloader_related_contents
    cleanup_influxdb_prediction_related_contents
    cleanup_alamedaai_models
}

if [ "$#" -eq "0" ]; then
    show_usage
    exit
fi

while getopts "f:n:t:s:x:g:cjdehikprvoyba:u:" o; do
    case "${o}" in
        p)
            prepare_environment="y"
            ;;
        i)
            install_nginx="y"
            ;;
        k)
            remove_nginx="y"
            ;;
        j)
            # For data verifier
            disable_all_node_metrics="y"
            ;;
        c)
            clean_environment="y"
            ;;
        e)
            enable_preloader="y"
            ;;
        b)
            run_ab_from_preloader="y"
            ;;
        r)
            run_preloader_with_normal_mode="y"
            ;;
        o)
            run_preloader_with_historical_only="y"
            ;;
        f)
            future_mode_enabled="y"
            f_arg=${OPTARG}
            ;;
        t)
            replica_num_specified="y"
            t_arg=${OPTARG}
            ;;
        s)
            enable_execution_specified="y"
            s_arg=${OPTARG}
            ;;
        a)
            cluster_name_specified="y"
            cluster_name="${OPTARG}"
            ;;
        # x)
        #     autoscaling_specified="y"
        #     x_arg=${OPTARG}
        #     ;;
        g)
            traffic_ratio_specified="y"
            g_arg=${OPTARG}
            ;;
        n)
            nginx_name_specified="y"
            n_arg=${OPTARG}
            ;;
        d)
            disable_preloader="y"
            ;;
        v)
            revert_environment="y"
            ;;
        u)
            auth_user_pass_specified="y"
            u_arg="${OPTARG}"
            ;;
        h)
            show_usage
            exit
            ;;
        *)
            echo "Warning! wrong parameter, ignore it."
            ;;
    esac
done

# We need 'curl' command
if [ "`curl --version 2> /dev/null`" = "" ]; then
    echo -e "\nThe 'curl' command is missing. Please install 'curl' command."
    exit 1
fi

unameOut="$(uname -s)"
case "${unameOut}" in
    Linux*)
        machine_type=Linux;;
    Darwin*)
        machine_type=Mac;;
    *)
        echo -e "\n$(tput setaf 1)Error! Unsupported machine type (${unameOut}).$(tput sgr 0)"
        exit
        ;;
esac

kubectl version|grep -q "^Server"
if [ "$?" != "0" ];then
    echo -e "\nPlease login to Kubernetes first."
    exit 1
fi

install_namespace="`kubectl get pods --all-namespaces |grep "alameda-datahub-"|awk '{print $1}'|head -1`"
if [ "$install_namespace" = "" ];then
    echo -e "\n$(tput setaf 1)Error! Please Install Federatorai before running this script.$(tput sgr 0)"
    exit 3
fi

# argument '-a' must co-exists with '-u'
if [ "${cluster_name_specified}" = "y" -a "${auth_user_pass_specified}" != "y" ]; then
    echo -e "\n$(tput setaf 1)Error! Missing '-u' argument.$(tput sgr 0)"
    show_usage
    exit 3
fi

if [ "${auth_user_pass_specified}" = "y" ]; then
    auth_username="`echo \"${u_arg}\" | xargs | tr ':' ' ' | awk '{print $1}'`"
    len="`echo \"${auth_username}:\" | wc -m|sed 's/[ \t]*//g'`"
    auth_password="`echo \"${u_arg}\" | xargs | cut -c${len}-`"
fi

check_federatorai_cluster_type
if [ "$k8s_enabled" = "false" ]; then
    # No K8S, VM only
    not_support_action_list=( install_nginx remove_nginx run_ab_from_preloader replica_num_specified enable_execution_specified cluster_name_specified traffic_ratio_specified nginx_name_specified )
    for action in "${not_support_action_list[@]}"
    do
        if [ "`echo ${!action}`" = "y" ]; then
            echo -e "\n$(tput setaf 1)Error! Action \"$action\" is not supported when only VM cluster type exist.$(tput sgr 0)"
            show_usage
            exit 3
        fi
    done
fi

if [ "$k8s_enabled" = "true" ]; then
    #K8S
    if [ "$install_nginx" = "y" ] && [ "$cluster_name_specified" != "y" ]; then
        check_cluster_name_not_empty
    fi
fi

if [ "$cluster_name_specified" = "y" ]; then
    check_cluster_name_not_empty

    # check data source
    get_datasource_in_alamedaorganization
    if [ "$data_source_type" = "datadog" ]; then
        # No double check for prometheus or sysdig for now.
        # Do DD_CLUSTER_NAME check
        get_datadog_agent_info
        if [ "$dd_cluster_name" = "" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to auto-discover DD_CLUSTER_NAME value in Datadog cluster agent env variable.$(tput sgr 0)"
            echo -e "\n$(tput setaf 1)Please help to set up cluster name accordingly.$(tput sgr 0)"
            exit 7
        else
            if [ "$cluster_name" != "$dd_cluster_name" ]; then
                echo -e "\n$(tput setaf 1)Error! Cluster name ($cluster_name) specified through (-a) option doesn not match the DD_CLUSTER_NAME ($dd_cluster_name) value in Datadog cluster agent env variable.$(tput sgr 0)"
                exit 5
            fi
        fi
    fi

fi

if [ "$future_mode_enabled" = "y" ]; then
    future_mode_length=$f_arg
    case $future_mode_length in
        ''|*[!0-9]*) echo -e "\n$(tput setaf 1)future mode length (hour) needs to be an integer.$(tput sgr 0)" && show_usage ;;
        *) ;;
    esac
fi

if [ "$traffic_ratio_specified" = "y" ]; then
    traffic_ratio=$g_arg
    case $traffic_ratio in
        ''|*[!0-9]*) echo -e "\n$(tput setaf 1)ab test traffic ratio needs to be an integer.$(tput sgr 0)" && show_usage ;;
        *) ;;
    esac
else
    traffic_ratio="4000"
fi

if [ "$run_preloader_with_normal_mode" = "y" ] && [ "$run_preloader_with_historical_only" = "y" ]; then
    echo -e "\n$(tput setaf 1)Error! You can specify either the '-r' or the '-o' parameter, but not both.$(tput sgr 0)" && show_usage
    exit 3
fi

if [ "$run_preloader_with_normal_mode" = "y" ] && [ "$run_ab_from_preloader" = "y" ]; then
    echo -e "\n$(tput setaf 1)Error! You can specify either the '-r' or the '-b' parameter, but not both.$(tput sgr 0)" && show_usage
    exit 3
fi

if [ "$run_preloader_with_historical_only" = "y" ] && [ "$run_ab_from_preloader" = "y" ]; then
    echo -e "\n$(tput setaf 1)Error! You can specify either the '-o' or the '-b' parameter, but not both.$(tput sgr 0)" && show_usage
    exit 3
fi

if [ "$replica_num_specified" = "y" ]; then
    replica_number=$t_arg
    case $replica_number in
        ''|*[!0-9]*) echo -e "\n$(tput setaf 1)replica number needs to be an integer.$(tput sgr 0)" && show_usage ;;
        *) ;;
    esac
else
    # default replica
    replica_number="5"
fi

if [ "$nginx_name_specified" = "y" ]; then
    nginx_name=$n_arg
    if [ "$nginx_name" = "" ]; then
        echo -e "\n$(tput setaf 1)nginx name needs to be specified with n parameter.$(tput sgr 0)"
    fi
else
    # Set default nginx name
    nginx_name="nginx-prepared"
fi

echo "Checking environment version..."
check_version
echo "...Passed"

alamedaservice_name="`kubectl get alamedaservice -n $install_namespace -o jsonpath='{range .items[*]}{.metadata.name}'`"
if [ "$alamedaservice_name" = "" ]; then
    echo -e "\n$(tput setaf 1)Error! Failed to get alamedaservice name.$(tput sgr 0)"
    leave_prog
    exit 8
fi

check_recommendation_pod_type


nginx_ns="nginx-preloader-sample"
if [ "$openshift_minor_version" = "" ]; then
    # K8S
    nginx_port="80"
else
    # OpenShift
    nginx_port="8081"
fi
alamedascaler_name="nginx-alamedascaler"
if [ "$(kubectl get po -n $nginx_ns 2>/dev/null|grep -v "NAME"|grep "Running"|wc -l)" -gt "0" ]; then
    demo_nginx_exist="true"
fi

debug_log="debug.log"

realpath() {
    [[ $1 = /* ]] && echo "$1" || echo "$PWD/${1#./}"
}

if [ "$machine_type" = "Linux" ]; then
    script_located_path=$(dirname $(readlink -f "$0"))
else
    # Mac
    script_located_path=$(dirname $(realpath "$0"))
fi

if [ "$FEDERATORAI_FILE_PATH" = "" ]; then
    if [[ $script_located_path =~ .*/federatorai/repo/.* ]]; then
        save_path="$(dirname "$(dirname "$(dirname "$(realpath $script_located_path)")")")"
    else
        # Ask for input
        default="/opt"
        read -r -p "$(tput setaf 2)Please enter the path of Federator.ai preloader-util directory [default: $default]: $(tput sgr 0) " save_path </dev/tty
        save_path=${save_path:-$default}
        save_path=$(echo "$save_path" | tr '[:upper:]' '[:lower:]')
        save_path="$save_path/federatorai"
    fi
else
    save_path="$FEDERATORAI_FILE_PATH"
fi

file_folder="$save_path/preloader"
if [ -d "$file_folder" ]; then
    rm -rf $file_folder
fi
mkdir -p $file_folder
if [ ! -d "$file_folder" ]; then
    echo -e "\n$(tput setaf 1)Error! Failed to create folder to save Federator.ai preloader-util files.$(tput sgr 0)"
    exit 3
fi
current_location=`pwd`
if [ "$enable_execution_specified" = "y" ]; then
    enable_execution="$s_arg"
    if [ "$enable_execution" != "true" ] && [ "$enable_execution" != "false" ]; then
        echo -e "\n$(tput setaf 1) Error! [-s] Enable execution specified value can only be true or false.$(tput sgr 0)"
        exit 3
    fi

else
    enable_execution="true"
fi

if [ "$disable_all_node_metrics" = "y" ]; then
    # For data verifier
    # PredictOnly
    if [ "$enable_execution_specified" = "y" ] && [ "$enable_execution" = "true" ]; then
        echo -e "\n$(tput setaf 1) Error! [-j] can't run with [-s true].$(tput sgr 0)"
        exit 3
    fi
    autoscaling_method="1"
    evictable_option="false"
    enable_execution="false"
else
    # HPA
    autoscaling_method="2"
    evictable_option="true"
fi

if [ "$k8s_enabled" = "true" ]; then
    # K8S
    # copy preloader ab files if run historical only mode enabled
    preloader_folder="${script_located_path}/preloader_ab_runner"
    if [ "$run_preloader_with_historical_only" = "y" ] || [ "$run_ab_from_preloader" = "y" ]; then
        # Check folder exists
        [ ! -d "$preloader_folder" ] && echo -e "$(tput setaf 1)Error! Can't locate $preloader_folder folder.$(tput sgr 0)" && exit 3

        ab_files_list=("define.py" "generate_loads.sh" "generate_traffic1.py" "run_ab.py" "transaction.txt")
        for ab_file in "${ab_files_list[@]}"
        do
            # Check files exist
            [ ! -f "$preloader_folder/$ab_file" ] && echo -e "$(tput setaf 1)Error! Can't locate file ($preloader_folder/$ab_file).$(tput sgr 0)" && exit 3
        done

        cp -r $preloader_folder $file_folder
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Can't copy folder $preloader_folder to $file_folder"
            exit 3
        fi
    fi
fi

cd $file_folder
echo "Receiving command '$0 $@'" >> $debug_log

if [ "$prepare_environment" = "y" ]; then
    if [ "$k8s_enabled" = "true" ]; then
        if [ "$cluster_name" != "" ]; then
            # -a is used to specify cluster_name
            new_nginx_example
            add_svc_for_nginx
            add_alamedascaler_for_nginx
        fi
        #patch_datahub_for_preloader
        #patch_grafana_for_preloader
    fi
    patch_data_adapter_for_preloader "true"
    check_influxdb_retention
fi

if [ "$clean_environment" = "y" ]; then
    clean_environment_operations
fi

if [ "$enable_preloader" = "y" ]; then
    enable_preloader_in_alamedaservice
    patch_agent_for_preloader "true"
    patch_ai_dispatcher_for_preloader "true"
fi

if [ "$run_ab_from_preloader" = "y" ]; then
    if [ "$demo_nginx_exist" = "true" ]; then
        run_ab_test
    fi
fi

if [ "$run_preloader_with_normal_mode" = "y" ] || [ "$run_preloader_with_historical_only" = "y" ]; then
    # Move scale_down_pods into run_preloader_command method
    if [ "$run_preloader_with_normal_mode" = "y" ]; then
        if [ "$demo_nginx_exist" = "true" ] && [ "$k8s_enabled" = "true" ]; then
            add_alamedascaler_for_nginx
        fi
        run_preloader_command "normal"
    elif [ "$run_preloader_with_historical_only" = "y" ]; then
        if [ "$demo_nginx_exist" = "true" ] && [ "$k8s_enabled" = "true" ]; then
            get_cluster_name_from_alamedascaler
            get_datasource_in_alamedaorganization
            add_alamedascaler_for_nginx
        fi
        run_preloader_command "historical_only"
    fi
    verify_metrics_exist
    scale_up_pods
fi

if [ "$future_mode_enabled" = "y" ]; then
    run_futuremode_preloader
    verify_metrics_exist
fi

if [ "$disable_preloader" = "y" ]; then
    # scale up if any failure encounter previously or program abort
    scale_up_pods
    #switch_alameda_executor_in_alamedaservice "off"
    patch_agent_for_preloader "false"
    patch_ai_dispatcher_for_preloader "false"
    disable_preloader_in_alamedaservice
fi

if [ "$revert_environment" = "y" ]; then
    # scale up if any failure encounter previously or program abort
    scale_up_pods
    if [ "$k8s_enabled" = "true" ]; then
        # K8S
        delete_nginx_example
        #patch_datahub_back_to_normal
        #patch_grafana_back_to_normal
    fi
    patch_data_adapter_for_preloader "false"
    clean_environment_operations
fi

if [ "$install_nginx" = "y" ]; then
    new_nginx_example
    add_svc_for_nginx
    add_alamedascaler_for_nginx
fi

if [ "$remove_nginx" = "y" ]; then
    delete_nginx_example
fi

leave_prog
exit 0
