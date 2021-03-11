#!/usr/bin/env bash

#################################################################################################################
#
#   This script is created for installing Federator.ai Operator
#
#   1. Interactive Mode
#      Usage: ./install.sh
#
#   2. Silent Mode - Persistent storage
#      Usage: ./install.sh -t v4.2.260 -n federatorai -e y \
#                   -s persistent -l 11 -d 12 -c managed-nfs-storage
#
#   3. Silent Mode - Ephemeral storage
#      Usage: ./install.sh -t v4.2.260 -n federatorai -e y \
#                   -s ephemeral
#
#   -t followed by tag_number
#   -n followed by install_namespace
#   -s followed by storage_type
#   -l followed by log_size
#   -d followed by aiengine_size
#   -i followed by influxdb_size
#   -c followed by storage_class
#   -x followed by expose_service (y or n)
#
#   4. AWS support
#      Usage: ./install.sh --image-path 88888976.dkr.ecr.us-east-1.amazonaws.com/888888-37c8-4328-91b2-62c1acd2a04b/cg-1231030144/federatorai-operator:4.2-latest
#                   --cluster awsmp-new --region us-west-2
#
#   --image-path <space> AWS ECR url
#   --cluster <space> AWS EKS cluster name
#   --region <space> AWS region
#################################################################################################################

is_pod_ready()
{
  [[ "$(kubectl get po "$1" -n "$2" -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}')" == 'True' ]]
}

pods_ready()
{
  [[ "$#" == 0 ]] && return 0

  namespace="$1"

  kubectl get pod -n $namespace \
    -o=jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\t"}{.status.phase}{"\t"}{.status.reason}{"\n"}{end}' \
      | while read name status phase reason _junk; do
          if [ "$status" != "True" ]; then
            msg="Waiting for pod $name in namespace $namespace to be ready."
            [ "$phase" != "" ] && msg="$msg phase: [$phase]"
            [ "$reason" != "" ] && msg="$msg reason: [$reason]"
            echo "$msg"
            return 1
          fi
        done || return 1

  return 0
}

leave_prog()
{
    echo -e "\n$(tput setaf 5)Downloaded YAML files are located under $file_folder $(tput sgr 0)"
    cd $current_location > /dev/null
}

webhook_exist_checker()
{
    kubectl get alamedanotificationchannels -o 'jsonpath={.items[*].metadata.annotations.notifying\.containers\.ai\/test-channel}' 2>/dev/null | grep -q 'done'
    if [ "$?" = "0" ];then
        webhook_exist="y"
    fi
}

webhook_reminder()
{
    if [ "$openshift_minor_version" != "" ]; then
        echo -e "\n========================================"
        echo -e "$(tput setaf 9)Note!$(tput setaf 10) The following $(tput setaf 9)two admission plugins $(tput setaf 10)need to be enabled on $(tput setaf 9)each master node $(tput setaf 10)to make Federator.ai work properly."
        echo -e "$(tput setaf 6)1. ValidatingAdmissionWebhook 2. MutatingAdmissionWebhook$(tput sgr 0)"
        echo -e "Steps: (On every master nodes)"
        echo -e "A. Edit /etc/origin/master/master-config.yaml"
        echo -e "B. Insert following content after admissionConfig:pluginConfig:"
        echo -e "$(tput setaf 3)    ValidatingAdmissionWebhook:"
        echo -e "      configuration:"
        echo -e "        kind: DefaultAdmissionConfig"
        echo -e "        apiVersion: v1"
        echo -e "        disable: false"
        echo -e "    MutatingAdmissionWebhook:"
        echo -e "      configuration:"
        echo -e "        kind: DefaultAdmissionConfig"
        echo -e "        apiVersion: v1"
        echo -e "        disable: false"
        echo -e "$(tput sgr 0)C. Save the file."
        echo -e "D. Execute below commands to restart OpenShift API and controller:"
        echo -e "$(tput setaf 6)1. master-restart api 2. master-restart controllers$(tput sgr 0)"
    fi
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

    oc get clusterversion 2>/dev/null|grep -vq "VERSION"
    if [ "$?" = "0" ];then
        # OpenShift 4.x
        openshift_minor_version="12"
        return 0
    fi

    oc_token="$(oc whoami token 2>/dev/null)"
    oc_route="$(oc get route console -n openshift-console -o=jsonpath='{.status.ingress[0].host}' 2>/dev/null)"
    if [ "$oc_token" != "" ] && [ "$oc_route" != "" ]; then
        curl -s -k -H "Authorization: Basic ${oc_token}" https://${oc_route}:8443/version/openshift |grep -q '"minor":'
        if [ "$?" = "0" ]; then
            # OpenShift 3.11
            openshift_minor_version="11"
            return 0
        fi
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

check_if_pod_match_expected_version()
{
    pod_name="$1"
    period="$2"
    interval="$3"
    namespace="$4"

    for ((i=0; i<$period; i+=$interval)); do
        current_tag="$(kubectl get pod -n $namespace -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[*].image | grep "$pod_name" | head -1 |awk -F'/' '{print $NF}'|cut -d ':' -f2)"
        if [ "$current_tag" = "$tag_number" ]; then
            echo -e "\n$pod_name pod is present.\n"
            return 0
        fi
        echo "Waiting for $pod_name($tag_number) pod to appear ..."
        sleep "$interval"
    done
    echo -e "\n$(tput setaf 1)Warning!! Waited for $period seconds, but $pod_name pod doesn't show up. Please check $namespace namespace$(tput sgr 0)"
    leave_prog
    exit 7
}

wait_until_single_pod_become_ready()
{
    pod_name="$1"
    period="$2"
    interval="$3"
    namespace="$4"

    for ((i=0; i<$period; i+=$interval)); do
        while read _name _status _phase _version _reason _junk; do
            if [ "$_status" != "True" ]; then
                msg="Waiting for pod $_name in namespace $namespace to be ready ..."
                [ "$_phase" != "" ] && msg="$msg phase: [$_phase]"
                [ "$_reason" != "" ] && msg="$msg reason: [$_reason]"
                echo "$msg"
            else
                echo -e "\n$pod_name pod is ready."
                return 0
            fi
        done <<< "$(kubectl get pod -n $namespace \
        -o=jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\t"}{.status.phase}{"\t"}{.spec.containers[*].image}{"\t"}{.status.reason}{"\n"}{end}' \
        | grep "$pod_name" |grep "$tag_number")"

        sleep "$interval"
    done
    echo -e "\n$(tput setaf 1)Warning!! Waited for $period seconds, but $pod_name pod still isn't ready. Please check $namespace namespace$(tput sgr 0)"
    leave_prog
    exit 7
}

# prometheus_abnormal_handle()
# {
#     default="y"
#     echo ""
#     echo "$(tput setaf 127)We found that the Prometheus in system doesn't meet Federator.ai requirement.$(tput sgr 0)"
#     echo "$(tput setaf 127)Do you want to continue Federator.ai installation?$(tput sgr 0)"
#     echo "$(tput setaf 3) y) Only Datadog integration function works.$(tput sgr 0)"
#     echo "$(tput setaf 3) n) Abort installation.$(tput sgr 0)"
#     read -r -p "$(tput setaf 127)[default: y]: $(tput sgr 0)" continue_even_abnormal </dev/tty
#     continue_even_abnormal=${continue_even_abnormal:-$default}

#     if [ "$continue_even_abnormal" = "n" ]; then
#         echo -e "\n$(tput setaf 1)Uninstalling Federator.ai operator...$(tput sgr 0)"
#         for yaml_fn in `ls [0-9]*.yaml | sort -nr`; do
#             echo "Deleting ${yaml_fn}..."
#             kubectl delete -f ${yaml_fn}
#         done
#         leave_prog
#         exit 8
#     else
#         set_prometheus_rule_to="n"
#     fi
# }

# check_prometheus_metrics()
# {
#     echo "Checking Prometheus..."
#     current_operator_pod_name="`kubectl get pods -n $install_namespace |grep "federatorai-operator-"|awk '{print $1}'|head -1`"
#     kubectl exec $current_operator_pod_name -n $install_namespace -- /usr/bin/federatorai-operator prom_check > /dev/null 2>&1
#     return_state="$?"
#     echo "Return state = $return_state"
#     if [ "$return_state" = "0" ];then
#         # State = OK
#         set_prometheus_rule_to="y"
#     elif [ "$return_state" = "1" ];then
#         # State = Patchable
#         default="y"
#         read -r -p "$(tput setaf 127)Do you want to update the Prometheus rule to meet the Federator.ai requirement? [default: y]: $(tput sgr 0)" patch_answer </dev/tty
#         patch_answer=${patch_answer:-$default}
#         if [ "$patch_answer" = "n" ]; then
#             # Need to double confirm
#             prometheus_abnormal_handle
#         else
#             set_prometheus_rule_to="y"
#         fi
#     elif [ "$return_state" = "2" ];then
#         # State = Abnormal
#         prometheus_abnormal_handle
#     fi
# }

wait_until_pods_ready()
{
  period="$1"
  interval="$2"
  namespace="$3"
  target_pod_number="$4"

  wait_pod_creating=1
  for ((i=0; i<$period; i+=$interval)); do

    if [[ "$wait_pod_creating" = "1" ]]; then
        # check if pods created
        if [[ "`kubectl get po -n $namespace 2>/dev/null|wc -l`" -ge "$target_pod_number" ]]; then
            wait_pod_creating=0
            echo -e "\nChecking pods..."
        else
            echo "Waiting for pods in namespace $namespace to be created..."
        fi
    else
        # check if pods running
        if pods_ready $namespace; then
            echo -e "\nAll pods under namespace($namespace) are ready."
            return 0
        fi
        echo "Waiting for pods in namespace $namespace to be ready..."
    fi

    sleep "$interval"
    
  done

  echo -e "\n$(tput setaf 1)Warning!! Waited for $period seconds, but all pods are not ready yet. Please check $namespace namespace$(tput sgr 0)"
  leave_prog
  exit 4
}

wait_until_cr_ready()
{
  local period="$1"
  local interval="$2"
  local namespace="$3"

  for ((i=0; i<$period; i+=$interval)); do
    # check if cr created
    if [ "`kubectl get alamedaorganization default --no-headers -o custom-columns=Name:.metadata.name -n $namespace 2>/dev/null`" = "default" ]; then
        echo -e "\nThe default alamedaorganization under namespace $namespace is ready."
        return 0
    else
        echo "Waiting for default alamedaorganization in namespace $namespace to be created..."
    fi
    sleep "$interval"
  done
  echo -e "\n$(tput setaf 1)Warning!! Waited for $period seconds, but default alamedaorganization is not ready yet. Please check $namespace namespace$(tput sgr 0)"
  leave_prog
  exit 4
}

get_grafana_route()
{
    if [ "$openshift_minor_version" != "" ] ; then
        link=`oc get route -n $1 2>/dev/null|grep "federatorai-dashboard-frontend"|awk '{print $2}'`
        if [ "$link" != "" ] ; then
        echo -e "\n========================================"
        echo "You can now access GUI through $(tput setaf 6)https://${link} $(tput sgr 0)"
        echo "The default login credential is $(tput setaf 6)admin/admin$(tput sgr 0)"
        echo -e "\nAlso, you can start to apply alamedascaler CR for the target you would like to monitor."
        echo "$(tput setaf 6)Review the administration guide for further details.$(tput sgr 0)"
        echo "========================================"
        else
            echo "Warning! Failed to obtain grafana route address."
        fi
    else
        if [ "$expose_service" = "y" ]; then
            echo -e "\n========================================"
            echo "You can now access GUI through $(tput setaf 6)https://<YOUR IP>:$dashboard_frontend_node_port $(tput sgr 0)"
            echo "The default login credential is $(tput setaf 6)admin/admin$(tput sgr 0)"
            echo -e "\nAlso, you can start to apply alamedascaler CR for the target you would like to monitor."
            echo "$(tput setaf 6)Review the administration guide for further details.$(tput sgr 0)"
            echo "========================================"
        fi
    fi
}

get_restapi_route()
{
    if [ "$openshift_minor_version" != "" ] ; then
        link=`oc get route -n $1 2>/dev/null|grep "federatorai-rest" |awk '{print $2}'`
        if [ "$link" != "" ] ; then
        echo -e "\n========================================"
        echo "You can now access Federatorai REST API through $(tput setaf 6)https://${link} $(tput sgr 0)"
        echo "The default login credential is $(tput setaf 6)admin/admin$(tput sgr 0)"
        echo "The REST API online document can be found in $(tput setaf 6)https://${link}/apis/v1/swagger/index.html $(tput sgr 0)"
        echo "========================================"
        else
            echo "Warning! Failed to obtain Federatorai REST API route address."
        fi
    else
        if [ "$expose_service" = "y" ]; then
            echo -e "\n========================================"
            echo "You can now access Federatorai REST API through $(tput setaf 6)https://<YOUR IP>:$rest_api_node_port $(tput sgr 0)"
            echo "The default login credential is $(tput setaf 6)admin/admin$(tput sgr 0)"
            echo "The REST API online document can be found in $(tput setaf 6)https://<YOUR IP>:$rest_api_node_port/apis/v1/swagger/index.html $(tput sgr 0)"
            echo "========================================"
        fi
    fi
}

setup_data_adapter_secret()
{
    secret_name="federatorai-data-adapter-secret"
    secret_api_key="`kubectl get secret $secret_name -n $install_namespace -o jsonpath='{.data.datadog_api_key}'|base64 -d`"
    secret_app_key="`kubectl get secret $secret_name -n $install_namespace -o jsonpath='{.data.datadog_application_key}'|base64 -d`"

    modified="n"
    if [ "$secret_api_key" = "" ] || [ "$secret_app_key" = "" ] || [ "$secret_api_key" = "dummy" ] || [ "$secret_app_key" = "dummy" ]; then
        modified="y"
        while [ "$input_api_key" = "" ] || [ "$input_app_key" = "" ]
        do
            read -r -p "$(tput setaf 2)Please input Datadog API key: $(tput sgr 0)" input_api_key </dev/tty
            input_api_key=`echo -n "$input_api_key" | base64`
            read -r -p "$(tput setaf 2)Please input Datadog Application key: $(tput sgr 0)" input_app_key </dev/tty
            input_app_key=`echo -n "$input_app_key" | base64`
        done
    else
        while [ "$reconfigure_action" != "y" ] && [ "$reconfigure_action" != "n" ]
        do
            default="n"
            read -r -p "$(tput setaf 2)Do you want to reconfigure Datadog API & Application keys? [default: $default]: $(tput sgr 0)" reconfigure_action </dev/tty
            reconfigure_action=${reconfigure_action:-$default}
            reconfigure_action=$(echo "$reconfigure_action" | tr '[:upper:]' '[:lower:]')
        done
        if [ "$reconfigure_action" = "y" ]; then
            modified="y"
            while [ "$input_api_key" = "" ] || [ "$input_app_key" = "" ]
            do
                default="$secret_api_key"
                read -r -p "$(tput setaf 2)Please input Datadog API key [current: $default]: $(tput sgr 0)" input_api_key </dev/tty
                input_api_key=${input_api_key:-$default}
                input_api_key=`echo -n "$input_api_key" | base64`

                default="$secret_app_key"
                read -r -p "$(tput setaf 2)Please input Datadog Application key [current: $default]: $(tput sgr 0)" input_app_key </dev/tty
                input_app_key=${input_app_key:-$default}
                input_app_key=`echo -n "$input_app_key" | base64`
            done
        fi
    fi

    if [ "$modified" = "y" ]; then
        kubectl patch secret $secret_name -n $install_namespace --type merge --patch "{\"data\":{\"datadog_api_key\": \"$input_api_key\"}}"
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to update datadog API key in data adapter secret.$(tput sgr 0)"
            exit 1
        fi
        kubectl patch secret $secret_name -n $install_namespace --type merge --patch "{\"data\":{\"datadog_application_key\": \"$input_app_key\"}}"
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to update datadog Application key in data adapter secret.$(tput sgr 0)"
            exit 1
        fi
        restart_data_adapter_pod
    fi
}

restart_data_adapter_pod()
{
    adapter_pod_name=`kubectl get pods -n $install_namespace -o name |grep "federatorai-data-adapter-"|cut -d '/' -f2`
    if [ "$adapter_pod_name" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get Federator.ai data adapter pod name!$(tput sgr 0)"
        exit 2
    fi
    kubectl delete pod $adapter_pod_name -n $install_namespace
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to delete Federator.ai data adapter pod $adapter_pod_name$(tput sgr 0)"
        exit 8
    fi
    wait_until_pods_ready $max_wait_pods_ready_time 30 $install_namespace 5
}

check_previous_alamedascaler()
{
    while read version alamedascaler_name alamedascaler_ns
    do
        if [ "$version" = "" ] || [ "$alamedascaler_name" = "" ] || [ "$alamedascaler_ns" = "" ]; then
           continue
        fi

        if [ "$version" = "autoscaling.containers.ai/v1alpha1" ]; then
            echo -e "\n$(tput setaf 3)Warning!! Found alamedascaler with previous v1alpha1 version. Name: $alamedascaler_name Namespace: $alamedascaler_ns $(tput sgr 0)"
        fi
    done <<< "$(kubectl get alamedascaler --all-namespaces --output jsonpath='{range .items[*]}{"\n"}{.apiVersion}{"\t"}{.metadata.name}{"\t"}{.metadata.namespace}' 2>/dev/null)"
}

check_alamedaservice()
{
    local _images=""
    _images="`kubectl -n ${install_namespace} get alamedaservice -o yaml | grep ' image:' | tr -d '\"' | sed 's/image://g' | xargs`"
    if [ "${_images}" != "" ]; then
        /bin/echo -e "\n$(tput setaf 1)Warning!! The following container image is currently using inside alamedaservice.$(tput sgr 0)"
        for i in ${_images}; do
            /bin/echo -e "\t$(tput setaf 1)${i}$(tput sgr 0)"
        done
    fi
    return 0
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
    dd_cluster_agent_deploy_name="$(kubectl get deploy -n $dd_namespace|grep -v NAME|awk '{print $1}'|grep "cluster-agent$")"
    dd_cluster_name="$(kubectl get deploy $dd_cluster_agent_deploy_name -n $dd_namespace -o jsonpath='{range .spec.template.spec.containers[*]}{.env[?(@.name=="DD_CLUSTER_NAME")].value}' 2>/dev/null | awk '{print $1}')"
}

display_cluster_scaler_file_location()
{
    echo -e "You can find $alamedascaler_cluster_filename template file inside $file_folder"
}

# get_cluster_name()
# {
#     cluster_name=`kubectl get cm cluster-info -n default -o yaml 2>/dev/null|grep uid|awk '{print $2}'`
#     if [ "$cluster_name" = "" ];then
#         cluster_name=`kubectl get cm cluster-info -n kube-public -o yaml 2>/dev/null|grep uid|awk '{print $2}'`
#         if [ "$cluster_name" = "" ];then
#             cluster_name=`kubectl get cm cluster-info -n kube-service-catalog’ -o yaml 2>/dev/null|grep uid|awk '{print $2}'`
#         fi
#     fi
# }

setup_cluster_alamedascaler()
{
    alamedascaler_cluster_filename="alamedascaler_federatorai.yaml"

    cat > ${alamedascaler_cluster_filename} << __EOF__
apiVersion: autoscaling.containers.ai/v1alpha2
kind: AlamedaScaler
metadata:
  name: clusterscaler
  namespace: ${install_namespace}
spec:
  clusterName: NeedToBeReplacedByClusterName
__EOF__

    # Get Datadog agent info (User configuration)
    get_datadog_agent_info

    if [ "$dd_cluster_agent_deploy_name" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to auto-discover Datadog cluster agent deployment.$(tput sgr 0)"
        echo -e "\n$(tput setaf 1)Datadog cluster agent needs to be installed to make WPA/HPA work properly.$(tput sgr 0)"
        display_cluster_scaler_file_location
        return
    fi

    if [ "$dd_cluster_name" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to auto-discover DD_CLUSTER_NAME value in Datadog cluster agent env variable.$(tput sgr 0)"
        echo -e "\n$(tput setaf 1)Please help to set up cluster name accordingly.$(tput sgr 0)"
        display_cluster_scaler_file_location
        return
    else
        kubectl describe alamedascaler --all-namespaces 2>/dev/null |grep "Cluster Name"|grep -q "$dd_cluster_name"
        if [ "$?" = "0" ];then
            # Found at least one alamedascaler. No need to apply alamedascaler for cluster
            return
        fi
    fi

    while [ "$monitor_cluster" != "y" ] && [ "$monitor_cluster" != "n" ]
    do
        default="y"
        read -r -p "$(tput setaf 127)Do you want to monitor this cluster? [default: $default]: $(tput sgr 0)" monitor_cluster </dev/tty
        monitor_cluster=${monitor_cluster:-$default}
        monitor_cluster=$(echo "$monitor_cluster" | tr '[:upper:]' '[:lower:]')
    done

    if [ "$monitor_cluster" = "n" ]; then
        display_cluster_scaler_file_location
        return
    fi

    if [ "$dd_namespace" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Can't find the datadog agent installed namespace.$(tput sgr 0)"
        display_cluster_scaler_file_location
        return
    elif [ "$dd_api_key" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Can't find the datadog agent API key. Please correctly configure the datadog agent API key.$(tput sgr 0)"
        display_cluster_scaler_file_location
        return
    elif [ "$dd_app_key" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Can't find the datadog agent APP key. Please correctly configure the datadog agent APP key.$(tput sgr 0)"
        display_cluster_scaler_file_location
        return
    fi

    echo -e "$(tput setaf 3)Use \"$dd_cluster_name\" as the cluster name and DD_CLUSTER_NAME$(tput sgr 0)"
        sed -i "s|\bclusterName:.*|clusterName: ${dd_cluster_name}|g" $alamedascaler_cluster_filename

    echo "Applying file $alamedascaler_cluster_filename ..."
    kubectl apply -f $alamedascaler_cluster_filename
    if [ "$?" != "0" ];then
        echo -e "$(tput setaf 3)Warning!! Failed to apply $alamedascaler_cluster_filename $(tput sgr 0)"
    fi
    echo "Done"
    display_cluster_scaler_file_location
}

download_cr_files()
{
    cr_files=( "alamedadetection.yaml" "alamedanotificationchannel.yaml" "alamedanotificationtopic.yaml" )

    for file_name in "${cr_files[@]}"
    do
        if ! curl -sL --fail https://raw.githubusercontent.com/containers-ai/prophetstor/${tag_number}/deploy/example/${file_name} -O; then
            echo -e "\n$(tput setaf 1)Abort, download $file_name sample file failed!!!$(tput sgr 0)"
            exit 3
        fi
    done
}

download_alamedascaler_files()
{
    # Three kinds of alamedascaler
    # In offline mode, alamedascaler files will be downloaded by federatorai-launcher.sh
    alamedascaler_filename="alamedascaler.yaml"
    src_pool=( "kafka" "nginx" "redis" )

    for pool in "${src_pool[@]}"
    do
        if ! curl -sL --fail https://raw.githubusercontent.com/containers-ai/prophetstor/${tag_number}/deploy/example/${pool}/${alamedascaler_filename} -O; then
            echo -e "\n$(tput setaf 1)Abort, download $alamedascaler_filename sample file from $pool folder failed!!!$(tput sgr 0)"
            exit 3
        fi
        if [ "$pool" = "kafka" ]; then
            mv $alamedascaler_filename alamedascaler_kafka.yaml
        elif [ "$pool" = "nginx" ]; then
            mv $alamedascaler_filename alamedascaler_nginx.yaml
        else
            mv $alamedascaler_filename alamedascaler_generic.yaml
        fi
    done
}

backup_configuration()
{
    script_name="backup-restore.sh"
    backup_folder="/tmp/configuration_backup"
    default="y"
    read -r -p "$(tput setaf 2)Do you want to backup your configuration before upgrading Federator.ai? [default: $default]: $(tput sgr 0)" do_backup </dev/tty
    do_backup=${do_backup:-$default}
    do_backup=$(echo "$do_backup" | tr '[:upper:]' '[:lower:]')
    if [ "$do_backup" = "y" ]; then
        if [ ! -f "$script_located_path/$script_name" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to locate script $script_located_path/$script_name$(tput sgr 0)"
            default="n"
            read -r -p "$(tput setaf 2)Do you want to skip backup configuration process? [default: $default]: $(tput sgr 0)" skip_backup </dev/tty
            skip_backup=${skip_backup:-$default}
            skip_backup=$(echo "$skip_backup" | tr '[:upper:]' '[:lower:]')
            if [ "$skip_backup" = "y" ]; then
                return
            else
                # skip_backup = 'n'
                echo "Please make sure script $script_name and install.sh are in the same folder."
                echo -e "$(tput setaf 1)Abort installation.$(tput sgr 0)"
                exit 3
            fi
        fi

        default="$backup_folder"
        read -r -p "$(tput setaf 2)Please input path for storing backup configuration: [default: $default] $(tput sgr 0)" backup_path </dev/tty
        backup_path=${backup_path:-$default}
        backup_path=$(echo "$backup_path" | tr '[:upper:]' '[:lower:]')
        backup_folder=$backup_path
        mkdir -p $backup_folder
        echo "Backup configuration..."
        bash $script_located_path/$script_name -b -d $backup_path -t $tag_number
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to do configuration backup.$(tput sgr 0)"
            exit 8
        fi
        echo "Done."
    else
        # do_backup = 'n'
        return
    fi
}

# get_recommended_prometheus_url()
# {
#     if [[ "$openshift_minor_version" == "11" ]] || [[ "$openshift_minor_version" == "12" ]]; then
#         prometheus_port="9091"
#         prometheus_protocol="https"
#     else
#         # OpenShift 3.9 # K8S
#         prometheus_port="9090"
#         prometheus_protocol="http"
#     fi

#     found_none="n"
#     while read namespace name _junk
#     do
#         prometheus_namespace="$namespace"
#         prometheus_svc_name="$name"
#         found_none="y"
#     done<<<"$(kubectl get svc --all-namespaces --show-labels|grep -i prometheus|grep 9090|grep " None "|sort|head -1)"

#     if [ "$prometheus_svc_name" = "" ]; then
#         while read namespace name _junk
#         do
#             prometheus_namespace="$namespace"
#             prometheus_svc_name="$name"
#         done<<<"$(kubectl get svc --all-namespaces --show-labels|grep -i prometheus|grep $prometheus_port |sort|head -1)"
#     fi

#     key="`kubectl get svc $prometheus_svc_name -n $prometheus_namespace -o yaml|awk '/ selector:/{getline; print}'|cut -d ":" -f1|xargs`"
#     value="`kubectl get svc $prometheus_svc_name -n $prometheus_namespace -o yaml|awk '/ selector:/{getline; print}'|cut -d ":" -f2|xargs`"

#     if [ "${key}" != "" ] && [ "${value}" != "" ]; then
#         prometheus_pod_name="`kubectl get pods -l "${key}=${value}" -n $prometheus_namespace|grep -v NAME|awk '{print $1}'|grep ".*\-[0-9]$"|sort -n|head -1`"
#     fi

#     # Assign default value
#     if [ "$found_none" = "y" ] && [ "$prometheus_pod_name" != "" ]; then
#         prometheus_url="$prometheus_protocol://$prometheus_pod_name.$prometheus_svc_name.$prometheus_namespace:$prometheus_port"
#     else
#         prometheus_url="$prometheus_protocol://$prometheus_svc_name.$prometheus_namespace:$prometheus_port"
#     fi
# }

check_aws_version()
{
    awscli_required_version="1.16.283"
    awscli_required_version_major=`echo $awscli_required_version | cut -d'.' -f1`
    awscli_required_version_minor=`echo $awscli_required_version | cut -d'.' -f2`
    awscli_required_version_build=`echo $awscli_required_version | cut -d'.' -f3`

    # aws --version: aws-cli/2.0.0dev0
    awscli_version=`aws --version 2>&1 | cut -d' ' -f1 | cut -d'/' -f2`
    awscli_version_major=`echo $awscli_version | cut -d'.' -f1`
    awscli_version_minor=`echo $awscli_version | cut -d'.' -f2`
    awscli_version_build=`echo $awscli_version | cut -d'.' -f3`
    awscli_version_build=${awscli_version_build%%[^0-9]*}   # remove everything from the first non-digit

    if [ "$awscli_version_major" -gt "$awscli_required_version_major" ]; then
        return 0
    fi

    if [ "$awscli_version_major" = "$awscli_required_version_major" ] && \
        [ "$awscli_version_minor" -gt "$awscli_required_version_minor" ]; then
            return 0
    fi

    if [ "$awscli_version_major" = "$awscli_required_version_major" ] && \
        [ "$awscli_version_minor" = "$awscli_required_version_minor" ] && \
        [ "$awscli_version_build" -ge "$awscli_required_version_build" ]; then
            return 0
    fi

    echo -e "\n$(tput setaf 10)Error! AWS CLI version must be $awscli_required_version or greater.$(tput sgr 0)"
    exit 9
}

setup_aws_iam_role()
{
    REGION_NAME=$aws_region
    CLUSTER_NAME=$eks_cluster

    # Create an OIDC provider for the cluster
    ISSUER_URL=$(aws eks describe-cluster \
                    --name $CLUSTER_NAME \
                    --region $REGION_NAME \
                    --query cluster.identity.oidc.issuer \
                    --output text )
    ISSUER_URL_WITHOUT_PROTOCOL=$(echo $ISSUER_URL | sed 's/https:\/\///g' )
    ISSUER_HOSTPATH=$(echo $ISSUER_URL_WITHOUT_PROTOCOL | sed "s/\/id.*//" )
    # Grab all certificates associated with the issuer hostpath and save them to files. The root certificate is last
    rm -f *.crt || echo "No files that match *.crt exist"
    ROOT_CA_FILENAME=$(openssl s_client -showcerts -connect $ISSUER_HOSTPATH:443 < /dev/null 2>&1 \
                        | awk '/BEGIN/,/END/{ if(/BEGIN/){a++}; out="cert"a".crt"; print > out } END {print "cert"a".crt"}')
    ROOT_CA_FINGERPRINT=$(openssl x509 -fingerprint -noout -in $ROOT_CA_FILENAME \
                        | sed 's/://g' | sed 's/SHA1 Fingerprint=//')
    result=$(aws iam create-open-id-connect-provider \
                --url $ISSUER_URL \
                --thumbprint-list $ROOT_CA_FINGERPRINT \
                --client-id-list sts.amazonaws.com \
                --region $REGION_NAME 2>&1 | grep EntityAlreadyExists)
    if [ "$result" != "" ]; then
        echo "The provider for $ISSUER_URL already exists"
    fi

    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    PROVIDER_ARN="arn:aws:iam::$ACCOUNT_ID:oidc-provider/$ISSUER_URL_WITHOUT_PROTOCOL"
    ROLE_NAME="FederatorAI-$CLUSTER_NAME"
    POLICY_NAME="AWSMarketplaceMetering-$CLUSTER_NAME"
    POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"

    # Update trust relationships of pod execution roles so pods on our cluster can assume them
    cat > trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "$PROVIDER_ARN"
            },
            "Action": "sts:AssumeRoleWithWebIdentity"
        }
    ]
}
EOF

    result=$(aws iam create-role \
                --role-name $ROLE_NAME \
                --assume-role-policy-document file://trust-policy.json 2>&1 | grep EntityAlreadyExists)
    if [ "$result" != "" ]; then
        echo "The IAM role $ROLE_NAME already exists"
    fi

    # Attach policy to give required permission to call RegisterUsage API
cat > iam-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": [
                "aws-marketplace:RegisterUsage"
            ],
            "Effect": "Allow",
            "Resource": "*"
        }
    ]
}
EOF
    result=$(aws iam create-policy \
        --policy-name $POLICY_NAME \
        --policy-document file://iam-policy.json 2>&1 | grep EntityAlreadyExists)
    if [ "$result" != "" ]; then
        echo "The policy $POLICY_NAME already exists"
    fi

    aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn $POLICY_ARN
}

while getopts "t:n:e:p:s:l:d:c:x:o-:" o; do
    case "${o}" in
        -)
            case "${OPTARG}" in
                image-path)
                    ecr_url="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$ecr_url" = "" ]; then
                        echo "Error! Missing --${OPTARG} value"
                        exit
                    fi
                    ;;
                cluster)
                    eks_cluster="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$eks_cluster" = "" ]; then
                        echo "Error! Missing --${OPTARG} value"
                        exit
                    fi
                    ;;
                region)
                    aws_region="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$aws_region" = "" ]; then
                        echo "Error! Missing --${OPTARG} value"
                        exit
                    fi
                    ;;
                *)
                    echo "Unknown option --${OPTARG}"
                    exit
                    ;;
            esac;;
        o)
            offline_mode_enabled="y"
            ;;
        t)
            t_arg=${OPTARG}
            ;;
        n)
            n_arg=${OPTARG}
            ;;
        e)
            e_arg=${OPTARG}
            ;;
        # p)
        #     p_arg=${OPTARG}
        #     ;;
        s)
            s_arg=${OPTARG}
            ;;
        l)
            l_arg=${OPTARG}
            ;;
        i)
            i_arg=${OPTARG}
            ;;
        d)
            d_arg=${OPTARG}
            ;;
        c)
            c_arg=${OPTARG}
            ;;
        x)
            x_arg=${OPTARG}
            ;;
        *)
            echo "Warning! wrong parameter, ignore it."
            ;;
    esac
done

# ecr_url, eks_cluster, aws_region all are empty or all have values
if [ "$ecr_url" != "" ] && [ "$eks_cluster" != "" ] && [ "$aws_region" != "" ]; then
    aws_mode="y"
elif [ "$ecr_url" != "" ] || [ "$eks_cluster" != "" ] || [ "$aws_region" != "" ]; then
    if [ "$ecr_url" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Missing --image-path parameter in AWS mode.$(tput sgr 0)"
        exit
    elif [ "$eks_cluster" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Missing --cluster parameter in AWS mode.$(tput sgr 0)"
        exit
    elif [ "$aws_region" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Missing --region parameter in AWS mode.$(tput sgr 0)"
        exit
    fi
fi

[ "${t_arg}" = "" ] && silent_mode_disabled="y"
[ "${n_arg}" = "" ] && silent_mode_disabled="y"
#[ "${e_arg}" = "" ] && silent_mode_disabled="y"
#[ "${p_arg}" = "" ] && silent_mode_disabled="y"
[ "${s_arg}" = "" ] && silent_mode_disabled="y"
[ "${s_arg}" = "persistent" ] && [ "${l_arg}" = "" ] && silent_mode_disabled="y"
[ "${s_arg}" = "persistent" ] && [ "${d_arg}" = "" ] && silent_mode_disabled="y"
[ "${s_arg}" = "persistent" ] && [ "${c_arg}" = "" ] && silent_mode_disabled="y"
[ "${s_arg}" = "persistent" ] && [ "${i_arg}" = "" ] && silent_mode_disabled="y"

[ "${t_arg}" != "" ] && specified_tag_number="${t_arg}"
[ "${n_arg}" != "" ] && install_namespace="${n_arg}"
#[ "${e_arg}" != "" ] && enable_execution="${e_arg}"
#[ "${p_arg}" != "" ] && prometheus_address="${p_arg}"
[ "${s_arg}" != "" ] && storage_type="${s_arg}"
[ "${l_arg}" != "" ] && log_size="${l_arg}"
[ "${i_arg}" != "" ] && influxdb_size="${i_arg}"
[ "${d_arg}" != "" ] && aiengine_size="${d_arg}"
[ "${c_arg}" != "" ] && storage_class="${c_arg}"
[ "${x_arg}" != "" ] && expose_service="${x_arg}"
[ "$expose_service" = "" ] && expose_service="y" # Will expose service by default if not specified

if [ "$offline_mode_enabled" = "y" ] && [ "$RELATED_IMAGE_URL_PREFIX" = "" ]; then
    echo -e "\n$(tput setaf 1)Error! Need to specify export RELATED_IMAGE_URL_PREFIX for offline installation.$(tput sgr 0)"
    exit
fi

if [ "$ALAMEDASERVICE_FILE_PATH" != "" ]; then
    if [ ! -r "$ALAMEDASERVICE_FILE_PATH" ]; then
        echo -e "\n$(tput setaf 1)Error! alamedaservice file ($ALAMEDASERVICE_FILE_PATH) is not readable.$(tput sgr 0)"
        exit
    fi
    # read value for RELATED_IMAGE_URL_PREFIX
    RELATED_IMAGE_URL_PREFIX="`grep '^  imageLocation: ' ${ALAMEDASERVICE_FILE_PATH} | awk '{print $2}'`"
    [ "${RELATED_IMAGE_URL_PREFIX}" = "" ] && export ${RELATED_IMAGE_URL_PREFIX}
fi

kubectl version|grep -q "^Server"
if [ "$?" != "0" ];then
    echo -e "\nPlease login to Kubernetes first."
    exit
fi

echo "Checking environment version..."
check_version
echo "...Passed"

if [ "$aws_mode" = "y" ]; then
    echo -e "Checking AWS CLI version..."
    check_aws_version
    echo -e "...Passed\n"
fi

if [ "$offline_mode_enabled" != "y" ]; then
    which curl > /dev/null 2>&1
    if [ "$?" != "0" ];then
        echo -e "\n$(tput setaf 1)Abort, \"curl\" command is needed for this tool.$(tput sgr 0)"
        exit
    fi
fi

previous_alameda_namespace="`kubectl get pods --all-namespaces |grep "alameda-ai-"|awk '{print $1}'|head -1`"
previous_tag="`kubectl get pods -n $previous_alameda_namespace -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[*].image 2>/dev/null| grep datahub | head -1 |awk -F'/' '{print $NF}'| cut -d ':' -f2`"
previous_alamedaservice="`kubectl get alamedaservice -n $previous_alameda_namespace -o custom-columns=NAME:.metadata.name 2>/dev/null|grep -v NAME|head -1`"

# Read alamedaservice file option only work in fresh installation.
if [ "$previous_alameda_namespace" != "" ] && [ "$ALAMEDASERVICE_FILE_PATH" != "" ]; then
    echo -e "\n$(tput setaf 1)Error! Read alamedaservice file option doesn't work in upgrade mode.$(tput sgr 0)"
    exit
fi

# Read alamedaservice file option doesn't work with silent mode.
if [ "$silent_mode_disabled" != "y" ] && [ "$ALAMEDASERVICE_FILE_PATH" != "" ]; then
    echo -e "\n$(tput setaf 1)Error! Read alamedaservice file option doesn't work with silent mode.$(tput sgr 0)"
    exit
fi

# Read alamedaservice file option doesn't work with offline mode.
if [ "$offline_mode_enabled" = "y" ] && [ "$ALAMEDASERVICE_FILE_PATH" != "" ]; then
    echo -e "\n$(tput setaf 1)Error! Read alamedaservice file option doesn't work with offline mode.$(tput sgr 0)"
    exit
fi

if [ "$ALAMEDASERVICE_FILE_PATH" != "" ]; then
    while [ "$read_alamedaservice" != "y" ] && [ "$read_alamedaservice" != "n" ]
    do
        default="y"
        read -r -p "$(tput setaf 2)Do you want to install Federator.ai based on AlamedaService file ($ALAMEDASERVICE_FILE_PATH)? [default: $default]: $(tput sgr 0)" read_alamedaservice </dev/tty
        read_alamedaservice=${read_alamedaservice:-$default}
        read_alamedaservice=$(echo "$read_alamedaservice" | tr '[:upper:]' '[:lower:]')
    done
    if [ "$read_alamedaservice" != "y" ]; then
        echo -e "\n$(tput setaf 1)Installation aborted.$(tput sgr 0)"
        exit
    fi
fi

if [ "$previous_alameda_namespace" != "" ];then
    need_upgrade="y"
    ## find value of RELATED_IMAGE_URL_PREFIX for upgrading alamedaservice CR
    if [ "${RELATED_IMAGE_URL_PREFIX}" = "" ]; then
        previous_imageLocation="`kubectl get alamedaservice $previous_alamedaservice -n $previous_alameda_namespace -o 'jsonpath={.spec.imageLocation}'`"
        ## Compute previous value as RELATED_IMAGE_URL_PREFIX from federatorai-operator deployment
        if [ "$previous_imageLocation" = "" ]; then
            RELATED_IMAGE_URL_PREFIX="`kubectl get deployment federatorai-operator -n $previous_alameda_namespace -o yaml \
                                       | grep -A1 'name: .*RELATED_IMAGE_' | grep 'value: ' | grep '/alameda-ai:' \
                                       | sed -e 's|/alameda-ai:| |' | awk '{print $2}'`"
           ## Skip RELATED_IMAGE_URL_PREFIX if it is default value
           [ "${RELATED_IMAGE_URL_PREFIX}" = "quay.io/prophetstor" ] && RELATED_IMAGE_URL_PREFIX=""
        fi
    fi
fi

if [ "$ALAMEDASERVICE_FILE_PATH" = "" ]; then
    if [ "$silent_mode_disabled" = "y" ];then

        while [[ "$info_correct" != "y" ]] && [[ "$info_correct" != "Y" ]]
        do
            # init variables
            install_namespace=""
            # Check if tag number is specified
            if [ "$specified_tag_number" = "" ]; then
                tag_number=""
                read -r -p "$(tput setaf 2)Please input Federator.ai Operator tag:$(tput sgr 0) " tag_number </dev/tty
            else
                tag_number=$specified_tag_number
            fi

            if [ "$need_upgrade" = "y" ];then
                echo -e "\n$(tput setaf 11)Previous build with tag$(tput setaf 1) $previous_tag $(tput setaf 11)detected in namespace$(tput setaf 1) $previous_alameda_namespace$(tput sgr 0)"
                install_namespace="$previous_alameda_namespace"
            else
                default="federatorai"
                read -r -p "$(tput setaf 2)Enter the namespace you want to install Federator.ai [default: federatorai]: $(tput sgr 0)" install_namespace </dev/tty
                install_namespace=${install_namespace:-$default}
            fi

            echo -e "\n----------------------------------------"
            if [ "$need_upgrade" = "y" ];then
                echo "$(tput setaf 11)Upgrade:$(tput sgr 0)"
            fi
            echo "tag_number = $tag_number"
            echo "install_namespace = $install_namespace"
            echo "----------------------------------------"

            default="y"
            read -r -p "$(tput setaf 2)Is the above information correct? [default: y]: $(tput sgr 0)" info_correct </dev/tty
            info_correct=${info_correct:-$default}
        done
    else
        tag_number=$specified_tag_number
        echo -e "\n----------------------------------------"
        echo "tag_number=$specified_tag_number"
        echo "install_namespace=$install_namespace"
        #echo "enable_execution=$enable_execution"
        #echo "prometheus_address=$prometheus_address"
        echo "storage_type=$storage_type"
        echo "log_size=$log_size"
        echo "influxdb_size=$influxdb_size"
        echo "aiengine_size=$aiengine_size"
        echo "storage_class=$storage_class"
        if [ "$openshift_minor_version" = "" ]; then
            #k8s
            echo "expose_service=$expose_service"
        fi
        echo -e "----------------------------------------\n"
    fi
else
    install_namespace=`grep "^[[:space:]]*namespace:[[:space:]]" $ALAMEDASERVICE_FILE_PATH |awk -F ':' '{print $2}'|xargs`
    if [ "$install_namespace" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Can't parse the namespace info from alamedaservice file ($ALAMEDASERVICE_FILE_PATH).$(tput sgr 0)"
        exit
    fi
    tag_number=`grep "^[[:space:]]*version:[[:space:]]" $ALAMEDASERVICE_FILE_PATH|grep -v 'version: ""'|awk -F'[^ \t]' '{print length($1), $0}'|sort -k1 -n|head -1|awk '{print $3}'`
    if [ "$tag_number" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Can't parse the version info from alamedaservice file ($ALAMEDASERVICE_FILE_PATH).$(tput sgr 0)"
        exit
    fi
fi

file_folder="/tmp/install-op"
[ "$max_wait_pods_ready_time" = "" ] && max_wait_pods_ready_time=900  # maximum wait time for pods become ready

rm -rf $file_folder
mkdir -p $file_folder
current_location=`pwd`
script_located_path=$(dirname $(readlink -f "$0"))
cd $file_folder

if [ "$aws_mode" = "y" ]; then
    # Setup AWS IAM role for service account
    echo -e "\n$(tput setaf 2)Setting AWS IAM role for service account...$(tput sgr 0)"
    setup_aws_iam_role
    role_arn=$(aws iam get-role --role-name ${ROLE_NAME} --query Role.Arn --output text)
    echo "Done"
fi

if [ "$need_upgrade" = "y" ];then
    source_full_tag=$(echo "$previous_tag"|cut -d '-' -f1)
    if [ "$source_full_tag" = "dev" ]; then
        source_tag_first_digit=""
        source_tag_middle_digit=""
        source_tag_last_digit=""
    else
        source_tag_first_digit=${source_full_tag%%.*}
        source_tag_last_digit=${source_full_tag##*.}
        source_tag_middle_digit=${source_full_tag##$source_tag_first_digit.}
        source_tag_middle_digit=${source_tag_middle_digit%%.$source_tag_last_digit}
        source_tag_first_digit=$(echo $source_tag_first_digit|cut -d 'v' -f2)

    fi

    target_full_tag=$(echo "$tag_number"|cut -d '-' -f1)
    if [ "$target_full_tag" = "dev" ]; then
        target_tag_first_digit=""
        target_tag_middle_digit=""
        target_tag_last_digit=""
    else
        target_tag_first_digit=${target_full_tag%%.*}
        target_tag_last_digit=${target_full_tag##*.}
        target_tag_middle_digit=${target_full_tag##$target_tag_first_digit.}
        target_tag_middle_digit=${target_tag_middle_digit%%.$target_tag_last_digit}
        target_tag_first_digit=$(echo $target_tag_first_digit|cut -d 'v' -f2)
    fi

    # Only do backup when major or middle digit bigger than previous build
    if [ "0${target_tag_first_digit}" -gt "0${source_tag_first_digit}" ] || [ "0${target_tag_middle_digit}" -gt "0${source_tag_middle_digit}" ]; then
        backup_configuration
    fi
fi

if [ "$offline_mode_enabled" != "y" ]; then
    operator_files=`curl --silent https://api.github.com/repos/containers-ai/prophetstor/contents/deploy/upstream?ref=${tag_number} 2>&1|grep "\"name\":"|cut -d ':' -f2|cut -d '"' -f2`
    if [ "$operator_files" = "" ]; then
        echo -e "\n$(tput setaf 1)Abort, download operator file list failed!!!$(tput sgr 0)"
        echo "Please check tag name and network"
        exit 1
    fi

    for file in `echo $operator_files`
    do
        echo "Downloading file $file ..."
        if ! curl -sL --fail https://raw.githubusercontent.com/containers-ai/prophetstor/${tag_number}/deploy/upstream/${file} -O; then
            echo -e "\n$(tput setaf 1)Abort, download file failed!!!$(tput sgr 0)"
            echo "Please check tag name and network"
            exit 1
        fi
        echo "Done"
    done
else
    # Offline Mode
    # Copy Federator.ai operator 00-11 yamls
    echo "Copying Federator.ai operator yamls ..."
    if [[ "`ls ${script_located_path}/../operator/[0-9]*yaml 2>/dev/null|wc -l`" -lt "12" ]]; then
        echo -e "\n$(tput setaf 1)Error! Failed to locate all Federator.ai operator yaml files$(tput sgr 0)"
        echo "Please make sure you extract the offline install package and execute install.sh under scripts folder  "
        exit 1
    fi
    cp ${script_located_path}/../operator/[0-9]*yaml .
    echo "Done"
fi

# Modify federator.ai operator yaml(s)
# for tag
if [ "$aws_mode" = "y" ]; then
    sed -i "s|quay.io/prophetstor/federatorai-operator-ubi:latest|$ecr_url|g" 03*.yaml
    # Change command to /start.sh
    sed -i "/- federatorai-operator/ {n; :a; /- federatorai-operator/! {N; ba;}; s/- federatorai-operator/- \/start.sh/; :b; n; $! bb}" 03*.yaml
cat >> 01*.yaml << __EOF__
  annotations:
    eks.amazonaws.com/role-arn: ${role_arn}
__EOF__
else
    sed -i "s/:latest$/:${tag_number}/g" 03*.yaml
fi

# Specified alternative container image location
if [ "${RELATED_IMAGE_URL_PREFIX}" != "" ]; then
    sed -i -e "s%quay.io/prophetstor%${RELATED_IMAGE_URL_PREFIX}%g" 03*.yaml
fi

# No need for recent build
# if [ "$need_upgrade" = "y" ];then
#     # for upgrade - stop operator before applying new alamedaservice
#     sed -i "s/replicas: 1/replicas: 0/g" 03*.yaml
# fi

# for namespace
sed -i "s/name: federatorai/name: ${install_namespace}/g" 00*.yaml
sed -i "s|\bnamespace:.*|namespace: ${install_namespace}|g" *.yaml

if [ "${ENABLE_RESOURCE_REQUIREMENT}" = "y" ]; then
    sed -i -e "/image: /a\          resources:\n            limits:\n              cpu: 4000m\n              memory: 8000Mi\n            requests:\n              cpu: 100m\n              memory: 100Mi" `ls 03*.yaml`
fi

if [ "$need_upgrade" = "y" ];then
    # for upgrade - update owner of influxdb
    current_influxdb_owner="$(kubectl -n $install_namespace exec alameda-influxdb-0 -- id -u)"
    if [ "$current_influxdb_owner" = "0" ]; then
        # Currently, the owner is root
        echo -e "\n$(tput setaf 2)Updating InfluxDB owner...$(tput sgr 0)"
        kubectl -n $install_namespace exec alameda-influxdb-0 -- chown -R 1001:1001 /var/log/influxdb
        kubectl -n $install_namespace exec alameda-influxdb-0 -- chown -R 1001:1001 /var/lib/influxdb
        kubectl -n $install_namespace exec alameda-influxdb-0 -- chmod -R 777 /var/log/influxdb
        kubectl -n $install_namespace exec alameda-influxdb-0 -- chmod -R 777 /var/lib/influxdb
        echo "Done"
    fi
fi

echo -e "\n$(tput setaf 2)Applying Federator.ai operator yaml files...$(tput sgr 0)"

if [ "$need_upgrade" = "y" ];then
    # for upgrade - delete old federatorai-operator deployment before apply new yaml(s)

    while read deploy_name deploy_ns useless
    do
        if [ "$deploy_name" != "" ] && [ "$deploy_ns" != "" ]; then
            kubectl delete deployment $deploy_name -n $deploy_ns
            if [ "$?" != "0" ]; then
                echo -e "\n$(tput setaf 1)Error in deleting old Federator.ai operator deployment $deploy_name in ns $deploy_ns.$(tput sgr 0)"
                exit 8
            fi
        fi
    done <<< "$(kubectl get deployment --all-namespaces --output jsonpath='{range .items[*]}{"\n"}{.metadata.name}{"\t"}{.metadata.namespace}{"\t"}{range .spec.template.spec.containers[*]}{.image}{end}{end}' 2>/dev/null | grep '^federatorai-operator')"

fi

if [ "$need_upgrade" = "y" ];then
    for yaml_fn in `ls [0-9]*.yaml | sort -n`; do
        case "$yaml_fn" in
        *03-*)
          later_yaml="$yaml_fn"
          echo "Delay applying $yaml_fn"
          continue
          ;;
        esac
        echo "Applying ${yaml_fn}..."
        kubectl apply -f ${yaml_fn}
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error in applying yaml file ${yaml_fn}.$(tput sgr 0)"
            exit 8
        fi
    done
    echo "Applying ${later_yaml}..."
    kubectl apply -f ${later_yaml}
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error in applying yaml file ${later_yaml}.$(tput sgr 0)"
        exit 8
    fi
else
    for yaml_fn in `ls [0-9]*.yaml | sort -n`; do
        echo "Applying ${yaml_fn}..."
        kubectl apply -f ${yaml_fn}
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error in applying yaml file ${yaml_fn}.$(tput sgr 0)"
            exit 8
        fi
    done
fi

if [ "$need_upgrade" != "y" ];then
    wait_until_pods_ready $max_wait_pods_ready_time 30 $install_namespace 1
    echo -e "\n$(tput setaf 6)Install Federator.ai operator $tag_number successfully$(tput sgr 0)"
else
    # Upgrade
    check_if_pod_match_expected_version "federatorai-operator" $max_wait_pods_ready_time 30 $install_namespace
    wait_until_single_pod_become_ready "federatorai-operator" $max_wait_pods_ready_time 30 $install_namespace
fi

if [ "$ALAMEDASERVICE_FILE_PATH" = "" ]; then
    alamedaservice_example="alamedaservice_sample.yaml"
    if [ "$offline_mode_enabled" != "y" ]; then
        echo -e "\nDownloading Federator.ai CR sample files ..."
        if ! curl -sL --fail https://raw.githubusercontent.com/containers-ai/prophetstor/${tag_number}/deploy/example/${alamedaservice_example} -O; then
            echo -e "\n$(tput setaf 1)Abort, download alamedaservice sample file failed!!!$(tput sgr 0)"
            exit 2
        fi
        download_cr_files
        echo "Done"
        echo -e "\nDownloading Federator.ai alamedascaler sample files ..."
        download_alamedascaler_files
        echo "Done"
    else
        # Offline Mode
        # Copy CR yamls
        echo "Copying Federator.ai CR yamls ..."
        if [[ "`ls ${script_located_path}/../yamls/alameda*.yaml 2>/dev/null|wc -l`" -lt "4" ]]; then
            echo -e "\n$(tput setaf 1)Error! Failed to locate Federator.ai CR yaml files$(tput sgr 0)"
            echo "Please make sure you extract the offline install package and execute install.sh under scripts folder  "
            exit 1
        fi
        cp ${script_located_path}/../yamls/alameda*.yaml .
        echo "Done"
    fi

    # Specified alternative container image location
    if [ "${RELATED_IMAGE_URL_PREFIX}" != "" ]; then
        sed -i "s|imageLocation:.*|imageLocation: ${RELATED_IMAGE_URL_PREFIX}|g" ${alamedaservice_example}
    fi
    # Specified version tag
    sed -i "s/version: latest/version: ${tag_number}/g" ${alamedaservice_example}

    echo "========================================"

    if [ "$silent_mode_disabled" = "y" ] && [ "$need_upgrade" != "y" ];then

        # Check prometheus support in first non silent installation mode
        # check_prometheus_metrics

        while [[ "$information_correct" != "y" ]] && [[ "$information_correct" != "Y" ]]
        do
            # init variables
            #prometheus_address=""
            storage_type=""
            log_size=""
            aiengine_size=""
            influxdb_size=""
            storage_class=""
            expose_service=""

            # if [ "$set_prometheus_rule_to" = "y" ]; then
            #     get_recommended_prometheus_url
            #     default="$prometheus_url"
            #     echo "$(tput setaf 127)Enter the Prometheus service address"
            #     read -r -p "[default: ${default}]: $(tput sgr 0)" prometheus_address </dev/tty
            #     prometheus_address=${prometheus_address:-$default}
            # fi

            while [[ "$storage_type" != "ephemeral" ]] && [[ "$storage_type" != "persistent" ]]
            do
                default="persistent"
                echo "$(tput setaf 127)Which storage type you would like to use? ephemeral or persistent?"
                read -r -p "[default: $default]: $(tput sgr 0)" storage_type </dev/tty
                storage_type=${storage_type:-$default}
            done

            if [[ "$storage_type" == "persistent" ]]; then
                default="2"
                read -r -p "$(tput setaf 127)Specify log storage size [e.g., 2 for 2GB, default: 2]: $(tput sgr 0)" log_size </dev/tty
                log_size=${log_size:-$default}
                default="10"
                read -r -p "$(tput setaf 127)Specify AI engine storage size [e.g., 10 for 10GB, default: 10]: $(tput sgr 0)" aiengine_size </dev/tty
                aiengine_size=${aiengine_size:-$default}
                default="100"
                read -r -p "$(tput setaf 127)Specify InfluxDB storage size [e.g., 100 for 100GB, default: 100]: $(tput sgr 0)" influxdb_size </dev/tty
                influxdb_size=${influxdb_size:-$default}

                while [[ "$storage_class" == "" ]]
                do
                    read -r -p "$(tput setaf 127)Specify storage class name: $(tput sgr 0)" storage_class </dev/tty
                done
            fi

            if [ "$openshift_minor_version" = "" ]; then
                #k8s
                default="y"
                read -r -p "$(tput setaf 127)Do you want to expose dashboard and REST API services for external access? [default: y]:$(tput sgr 0)" expose_service </dev/tty
                expose_service=${expose_service:-$default}
            fi

            echo -e "\n----------------------------------------"
            echo "install_namespace = $install_namespace"

            # if [ "$set_prometheus_rule_to" = "y" ]; then
            #     echo "prometheus_address = $prometheus_address"
            # fi
            echo "storage_type = $storage_type"
            if [[ "$storage_type" == "persistent" ]]; then
                echo "log storage size = $log_size GB"
                echo "AI engine storage size = $aiengine_size GB"
                echo "InfluxDB storage size = $influxdb_size GB"
                echo "storage class name = $storage_class"
            fi
            if [ "$openshift_minor_version" = "" ]; then
                #k8s
                echo "expose service = $expose_service"
            fi
            echo "----------------------------------------"

            default="y"
            read -r -p "$(tput setaf 2)Is the above information correct [default: y]:$(tput sgr 0)" information_correct </dev/tty
            information_correct=${information_correct:-$default}
        done
    fi

    #grafana_node_port="31010"
    rest_api_node_port="31011"
    dashboard_frontend_node_port="31012"

    if [ "$need_upgrade" != "y" ]; then
        # First time installation case
        sed -i "s|\bnamespace:.*|namespace: ${install_namespace}|g" ${alamedaservice_example}

        # if [ "$set_prometheus_rule_to" = "y" ]; then
        #     sed -i "s|\bprometheusService:.*|prometheusService: ${prometheus_address}|g" ${alamedaservice_example}
        #     sed -i "s|\bautoPatchPrometheusRules:.*|autoPatchPrometheusRules: true|g" ${alamedaservice_example}
        # else
        #     sed -i "s|\bautoPatchPrometheusRules:.*|autoPatchPrometheusRules: false|g" ${alamedaservice_example}
        # fi

        if [[ "$storage_type" == "persistent" ]]; then
            sed -i '/- usage:/,+10d' ${alamedaservice_example}
            cat >> ${alamedaservice_example} << __EOF__
    - usage: log
      type: pvc
      size: ${log_size}Gi
      class: ${storage_class}
      accessModes:
        - ReadWriteOnce

__EOF__
            # FEDERATORAI_MAXIMUM_LOG_SIZE
            log_allowance=$((log_size*1024*1024*1024*90/100)) #byte
            cat >> ${alamedaservice_example} << __EOF__
  env:
  - name: FEDERATORAI_MAXIMUM_LOG_SIZE
    value: "${log_allowance}"

__EOF__
        fi

        # enableGPU: false
        cat >> ${alamedaservice_example} << __EOF__
  enableGPU: false
__EOF__

        if [ "$openshift_minor_version" = "" ]; then #k8s
            if [ "$expose_service" = "y" ] || [ "$expose_service" = "Y" ]; then
                cat >> ${alamedaservice_example} << __EOF__
  serviceExposures:
    - name: federatorai-dashboard-frontend
      nodePort:
        ports:
          - nodePort: ${dashboard_frontend_node_port}
            port: 9001
      type: NodePort
    - name: federatorai-rest
      nodePort:
        ports:
          - nodePort: ${rest_api_node_port}
            port: 5056
      type: NodePort
__EOF__
            fi
        fi

        # Enable resource requirement configuration
        if [ "${ENABLE_RESOURCE_REQUIREMENT}" = "y" ]; then
            cat >> ${alamedaservice_example} << __EOF__
  resources:
    limits:
      cpu: 4000m
      memory: 8000Mi
    requests:
      cpu: 100m
      memory: 100Mi
  alamedaDatahub:
    resources:
      requests:
        cpu: 100m
        memory: 500Mi
  alamedaNotifier:
    resources:
      requests:
        cpu: 50m
        memory: 100Mi
  alamedaOperator:
    resources:
      requests:
        cpu: 100m
        memory: 250Mi
  alamedaRabbitMQ:
    resources:
      requests:
        cpu: 100m
        memory: 250Mi
  federatoraiRest:
    resources:
      requests:
        cpu: 50m
        memory: 100Mi
__EOF__
        fi
        if [ "${ENABLE_RESOURCE_REQUIREMENT}" = "y" ] && [ "$storage_type" = "persistent" ]; then
            cat >> ${alamedaservice_example} << __EOF__
  alamedaAi:
    resources:
      limits:
        cpu: 8000m
        memory: 8000Mi
      requests:
        cpu: 2000m
        memory: 500Mi
    storages:
    - usage: data
      type: pvc
      size: ${aiengine_size}Gi
      class: ${storage_class}
      accessModes:
        - ReadWriteOnce
  alamedaInfluxdb:
    resources:
      requests:
        cpu: 500m
        memory: 500Mi
    storages:
    - usage: data
      type: pvc
      size: ${influxdb_size}Gi
      class: ${storage_class}
      accessModes:
        - ReadWriteOnce
  fedemeterInfluxdb:
    resources:
      requests:
        cpu: 500m
        memory: 500Mi
    storages:
    - usage: data
      type: pvc
      size: 10Gi
      class: ${storage_class}
      accessModes:
        - ReadWriteOnce
__EOF__
        elif [ "${ENABLE_RESOURCE_REQUIREMENT}" = "y" ] && [ "$storage_type" = "ephemeral" ]; then
            cat >> ${alamedaservice_example} << __EOF__
  alamedaAi:
    resources:
      limits:
        cpu: 8000m
        memory: 8000Mi
      requests:
        cpu: 2000m
        memory: 500Mi
  alamedaInfluxdb:
    resources:
      requests:
        cpu: 500m
        memory: 500Mi
  fedemeterInfluxdb:
    resources:
      requests:
        cpu: 500m
        memory: 500Mi
__EOF__
        elif [ "${ENABLE_RESOURCE_REQUIREMENT}" != "y" ] && [ "$storage_type" = "persistent" ]; then
            cat >> ${alamedaservice_example} << __EOF__
  alamedaAi:
    storages:
    - usage: data
      type: pvc
      size: ${aiengine_size}Gi
      class: ${storage_class}
      accessModes:
        - ReadWriteOnce
  alamedaInfluxdb:
    storages:
    - usage: data
      type: pvc
      size: ${influxdb_size}Gi
      class: ${storage_class}
      accessModes:
        - ReadWriteOnce
  fedemeterInfluxdb:
    storages:
    - usage: data
      type: pvc
      size: 10Gi
      class: ${storage_class}
      accessModes:
        - ReadWriteOnce
__EOF__
        fi

        kubectl apply -f $alamedaservice_example >/dev/null
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to update alamedaservice yaml (${file_folder}/${alamedaservice_example}).$(tput sgr 0)"
            exit 1
        fi
    else
        # Upgrade case
        _count=10
        _sleep=30
        while [ "$_count" -gt "0" ]
        do
            echo -e "Update alamedaservice..."
            if [ "0${target_tag_first_digit}" -gt "0${source_tag_first_digit}" ] || [ "0${target_tag_middle_digit}" -gt "0${source_tag_middle_digit}" ]; then
                # Upgrade from older version, patch version and enableExecution
                kubectl patch alamedaservice $previous_alamedaservice -n $install_namespace --type merge --patch "{\"spec\":{\"enableExecution\": true,\"version\": \"$tag_number\"}}"
            else
                # Patch version only
                kubectl patch alamedaservice $previous_alamedaservice -n $install_namespace --type merge --patch "{\"spec\":{\"version\": \"$tag_number\"}}"
            fi

            if [ "$?" = "0" ]; then
                # Double check version info in alamedaservice
                version_inside=$(kubectl get alamedaservice $previous_alamedaservice -n $install_namespace -o jsonpath='{.spec.version}')
                if [ "$version_inside" == "$tag_number" ]; then
                    echo -e "$(tput setaf 3)Done.$(tput sgr 0)"
                    patch_done="y"
                    break
                fi
            fi
            # Patch failure
            echo -e "$(tput setaf 3)Warning! Update alamedaservice failure. Sleep $_sleep seconds and retry...$(tput sgr 0)"
            _count=$(($_count-1))
            sleep $_sleep
        done

        if [ "$patch_done" != "y" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to update alamedaservice.(tput sgr 0)"
            exit 7
        fi

        # Add sysdig entry inside secret if needed
        sysdig_info=$(kubectl get secret federatorai-data-adapter-secret -n $install_namespace -o jsonpath='{.data.sysdig_api_token}')
        if [ "$sysdig_info" == "" ]; then
            sysdig_token=$(echo -n "dummy" | base64 )
            kubectl patch secret federatorai-data-adapter-secret -n $install_namespace --type merge --patch "{\"data\":{\"sysdig_api_token\": \"$sysdig_token\"}}"
            if [ "$?" != "0" ]; then
                echo -e "\n$(tput setaf 1)Error! Failed to update sysdig dummy token in data adapter secret.$(tput sgr 0)"
                exit 1
            fi
        fi

        # Specified alternative container imageLocation
        if [ "${RELATED_IMAGE_URL_PREFIX}" != "" ]; then
            kubectl patch alamedaservice $previous_alamedaservice -n $install_namespace --type merge --patch "{\"spec\":{\"imageLocation\": \"${RELATED_IMAGE_URL_PREFIX}\"}}"
        fi

        # Check if FEDERATORAI_MAXIMUM_LOG_SIZE needed to be added.
        current_max_log="$(kubectl -n $install_namespace get alamedaservice $previous_alamedaservice -o 'jsonpath={.spec.env[?(@.name=="FEDERATORAI_MAXIMUM_LOG_SIZE")]}')"
        if [ "$current_max_log" == "" ]; then
            # Check storage type
            type="$(kubectl -n $install_namespace get alamedaservice $previous_alamedaservice -o 'jsonpath={.spec.storages[?(@.usage=="log")].type}')"
            if [ "$type" == "pvc" ]; then
                # Get current pvc log size
                size="$(kubectl -n $install_namespace get alamedaservice $previous_alamedaservice -o 'jsonpath={.spec.storages[?(@.usage=="log")].size}'|sed 's/..$//')"
                if [ "$size" != "" ]; then
                    log_allowance=$((size*1024*1024*1024*90/100)) #byte
                else
                    log_allowance=$((10*1024*1024*1024*90/100)) #byte
                fi
            else
                # ephemeral
                log_allowance=$((10*1024*1024*1024*90/100)) #byte
            fi
            current_env_exist="$(kubectl -n $install_namespace get alamedaservice $previous_alamedaservice -o 'jsonpath={.spec.env}'|wc -c)"
            if [ "$current_env_exist" == 0 ]; then
                # env section empty
                kubectl patch alamedaservice $previous_alamedaservice -n $install_namespace --type merge --patch "{\"spec\":{\"env\":[{\"name\": \"FEDERATORAI_MAXIMUM_LOG_SIZE\",\"value\": \"$log_allowance\"}]}}"
            else
                # env section exist
                kubectl patch alamedaservice $previous_alamedaservice -n $install_namespace --type json --patch "[ { \"op\" : \"add\" , \"path\" : \"/spec/env/-\" , \"value\" : { \"name\" : \"FEDERATORAI_MAXIMUM_LOG_SIZE\", \"value\" : \"$log_allowance\" } } ]"
            fi
        fi
        # Restart operator after patching alamedaservice
        #kubectl scale deployment federatorai-operator -n $install_namespace --replicas=0
        #kubectl scale deployment federatorai-operator -n $install_namespace --replicas=1
    fi
else
    echo -e "\nDownloading Federator.ai CR sample files ..."
    download_cr_files
    echo "Done"
    echo -e "\nDownloading Federator.ai alamedascaler sample files ..."
    download_alamedascaler_files
    echo "Done"
    kubectl apply -f $ALAMEDASERVICE_FILE_PATH >/dev/null
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to update alamedaservice file ($ALAMEDASERVICE_FILE_PATH).$(tput sgr 0)"
        exit 1
    fi
fi

echo "Processing..."
check_if_pod_match_expected_version "datahub" $max_wait_pods_ready_time 60 $install_namespace
wait_until_pods_ready $max_wait_pods_ready_time 60 $install_namespace 5
wait_until_cr_ready $max_wait_pods_ready_time 60 $install_namespace

if [ "$need_upgrade" = "y" ];then
    # Drop fedemeter measurements during upgrade (4.2, 4.3, 4.3.1 upgrade to 4.4 or later)
    if [ "0${target_tag_first_digit}" -ge "4" ] && [ "0${target_tag_middle_digit}" -ge "4" ] && [ "0${source_tag_first_digit}" -eq "4" ] && [ "0${source_tag_middle_digit}" -lt "4" ]; then
        influxdb_name="alameda-influxdb-0"
        database_name="alameda_fedemeter"
        kubectl exec $influxdb_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database $database_name -execute "drop measurement calculation_price_instance;drop measurement calculation_price_storage;drop measurement recommendation_jeri;"
    fi
fi

webhook_exist_checker
if [ "$webhook_exist" != "y" ];then
    webhook_reminder
fi

###Configure data source from GUI
#setup_data_adapter_secret
get_grafana_route $install_namespace
get_restapi_route $install_namespace
echo -e "$(tput setaf 6)\nInstall Federator.ai $tag_number successfully$(tput sgr 0)"
check_previous_alamedascaler
###Configure data source from GUI
#setup_cluster_alamedascaler
check_alamedaservice
leave_prog
exit 0

