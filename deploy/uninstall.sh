#!/usr/bin/env bash
#
# Need use bash to run this script
if [ "${BASH_VERSION}" = '' ]; then
    /bin/echo -e "\n[Error] Please use bash to run this script.\n"
    exit 1
fi

show_usage()
{
    cat << __EOF__

    Usage:
        a. Online (Interactive mode)
           bash $0
        b. Offline mode
           bash $0 --offline-mode

__EOF__
    exit 1
}

remove_containersai_crds()
{
    containersai_crd_list=`kubectl get crd -o name | grep containers.ai 2>/dev/null`
    for crd in `echo $containersai_crd_list`
    do
        echo -e "$(tput setaf 2)\nDeleting $crd ...$(tput sgr 0)"
        kubectl delete $crd
        if [ "$?" != "0" ]; then
            echo -e "$(tput setaf 1)Error in removing crd $crd$(tput sgr 0)"
            #exit 2
        fi
    done
}

remove_all_alamedaservice()
{
    kubectl get alamedaservice --all-namespaces 2>/dev/null|grep -v NAMESPACE|while read ns servicename extra
    do
        echo -e "$(tput setaf 2)\nDeleting $servicename in $ns namespace...$(tput sgr 0)"
        #kubectl delete alamedaservice $servicename -n $ns
        kubectl delete clusterrole alameda-gc
        if [ "$?" != "0" ]; then
            echo -e "$(tput setaf 1)Error in removing $servicename in $ns namespace$(tput sgr 0)"
            #exit 2
        fi
    done

    # wait for pods to be deleted
    sleep 10
}

parse_version(){
    echo "$@" | awk -F. '{ printf("%d%03d%03d%03d\n", $1,$2,$3,$4); }'
}

download_operator_yaml_if_needed()
{
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
    done

    # for namespace
    if [ "$machine_type" = "Linux" ]; then
        sed -i "s/name: federatorai/name: ${installed_namespace}/g" 00*.yaml
        sed -i "s|\bnamespace:.*|namespace: ${installed_namespace}|g" *.yaml
    else
        # Mac
        sed -i "" "s/name: federatorai/name: ${installed_namespace}/g" 00*.yaml
        sed -i "" "s| namespace:.*| namespace: ${installed_namespace}|g" *.yaml
    fi
}

remove_operator_ns_yaml()
{
    check_passed="y"
    all_res="$(kubectl -n ${installed_namespace} get all 2>/dev/null)"
    if [ "$all_res" != "" ]; then
        check_passed="n"
    fi

    if [ "$check_passed" = "y" ]; then
        pvc="$(kubectl -n ${installed_namespace} get pvc 2>/dev/null)"
        if [ "$pvc" != "" ]; then
            check_passed="n"
        fi
    fi

    if [ "$check_passed" = "y" ]; then
        for serviceaccount in `kubectl -n ${installed_namespace} get serviceaccount -o name`
        do
            if [ "$serviceaccount" != "serviceaccount/default" ] && [ "$serviceaccount" != "serviceaccount/builder" ] && [ "$serviceaccount" != "serviceaccount/deployer" ]; then
                check_passed="n"
                break
            fi
        done
    fi

    if [ "$check_passed" = "y" ]; then
        for configmap in `kubectl -n ${installed_namespace} get configmap -o name`
        do
            if [ "$configmap" != "configmap/kube-root-ca.crt" ] && [ "$configmap" != "configmap/openshift-service-ca.crt" ]; then
                check_passed="n"
                break
            fi
        done
    fi

    if [ "$check_passed" = "y" ]; then
        all_secret=$(kubectl -n $installed_namespace get secret -o name)
        for secret in `echo "$all_secret"`
        do
            secret_type="$(kubectl -n $installed_namespace get $secret -o jsonpath='{.type}')"
            if ! [[ $secret_type =~ ^kubernetes.io/.*$ ]]; then
                check_passed="n"
                break
            fi
        done
    fi
    if [ "$check_passed" = "y" ]; then
        # No resource left in namespace which is not belongs to Federator.ai
        kubectl delete -f $namespace_yaml
    else
        echo -e "$(tput setaf 3)\nNamespace $installed_namespace is not deleted since some resources existed.$(tput sgr 0)"
    fi
}

remove_operator_yaml()
{
    for yaml_fn in `ls [0-9]*yaml | sort -n -r`
    do
        # Move deleting 00-namespace.yaml to the last
        if [[ $yaml_fn =~ ^00-.*$ ]]; then
            namespace_yaml="$yaml_fn"
            continue
        fi
        echo -e "$(tput setaf 2)\nDeleting $yaml_fn ...$(tput sgr 0)"
        if [[ $yaml_fn =~ ^04-.*$ ]]; then
            kubectl delete -f ${yaml_fn} --ignore-not-found=true
        else
            kubectl delete -f ${yaml_fn}
        fi
        if [ "$?" != "0" ]; then
            echo -e "$(tput setaf 1)Error in removing $yaml_fn$(tput sgr 0)"
        fi
    done
}

wait_until_cr_removed()
{
    period="$1"
    interval="$2"

    cluster_resource_list=("clusterrole" "clusterrolebinding")
    for cluster_resource in "${cluster_resource_list[@]}"
    do
        check_passed="n"
        for ((i=0; i<$period; i+=$interval))
        do
            all_cluster_res=$(kubectl get $cluster_resource | grep "^${installed_namespace}-"|awk '{print $1}')
            if [ "$all_cluster_res" != "" ]; then
                echo -e "\nWaiting for $cluster_resource to be removed..."
                do_wait_cluster="y"
                sleep "$interval"
            else
                check_passed="y"
                break
            fi
        done
        if [ "$check_passed" = "n" ]; then
            echo -e "\n$(tput setaf 1)Warning!! Waited for $period seconds, but $cluster_resource still exist.$(tput sgr 0)"
            return 0
        fi
    done
    if [ "$do_wait_cluster" = "y" ]; then
        echo "Done"
    fi
}

wait_until_resource_removed()
{
    period="$1"
    interval="$2"

    resource_list=("configmap" "serviceaccount" "service" "deployment" "statefulset" "rolebinding" "role" "persistentvolumeclaim")
    for resource in "${resource_list[@]}"
    do
        all_res=$(kubectl -n $installed_namespace get $resource -o name)
        for res in `echo "$all_res"`
        do
            check_passed="n"
            for ((i=0; i<$period; i+=$interval))
            do
                owner_kind=$(kubectl -n $installed_namespace get $res -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null)
                if [ "$owner_kind" = "AlamedaService" ]; then
                    echo -e "\nWaiting for $res to be removed..."
                    do_wait_resource="y"
                    sleep "$interval"
                else
                    check_passed="y"
                    break
                fi
            done
            if [ "$check_passed" = "n" ]; then
                echo -e "\n$(tput setaf 1)Warning!! Waited for $period seconds, but $res still exist.$(tput sgr 0)"
                # Continue to delete crd
                return 0
            fi
        done
    done
    if [ "$do_wait_resource" = "y" ]; then
        echo "Done"
    fi
}

which curl > /dev/null 2>&1
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)Abort, \"curl\" command is needed for this tool.$(tput sgr 0)"
    exit 3
fi

operator_folder="operator"

while getopts "h-:" o; do
    case "${o}" in
        -)
            case "${OPTARG}" in
                offline-mode)
                    offline_mode="y"
                    ;;
                help)
                    show_usage
                    ;;
                *)
                    echo -e "\n$(tput setaf 1)Error! Unknown option --${OPTARG}$(tput sgr 0)"
                    exit
                    ;;
            esac;;
        h)
            show_usage
            ;;
        *)
            echo -e "\n$(tput setaf 1)Error! wrong paramter.$(tput sgr 0)"
            exit 5
            ;;
    esac
done

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

installed_namespace="`kubectl get pods --all-namespaces |egrep "alameda-datahub-|federatorai-operator-"|awk '{print $1}'|head -1`"
if [ "$installed_namespace" = "" ]; then
    echo -e "\nInstalled_namespace is empty. Federator.ai build doesn't exist in system."
    exit
fi

all_fed_pv="$(kubectl get pv --output jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.claimRef.name}{"\t"}{.spec.claimRef.namespace}{"\n"}'|grep "$installed_namespace")"
if [ "$all_fed_pv" != "" ]; then
    default="y"
    read -r -p "$(tput setaf 2)Do you want to preserve your Federator.ai persistent volumes? [default: $default]: $(tput sgr 0)" do_preserve </dev/tty
    do_preserve=${do_preserve:-$default}
    do_preserve=$(echo "$do_preserve" | tr '[:upper:]' '[:lower:]')

    if [ "$do_preserve" = "y" ]; then
        policy="Retain"
    elif [ "$do_preserve" = "n" ]; then
        policy="Delete"
    else
        echo -e "$(tput setaf 1)Abort, wrong answer.$(tput sgr 0)"
        exit 3
    fi

    while read pv_name pvc_name _junk; do
        pvc_kind=$(kubectl -n $installed_namespace get pvc $pvc_name --output jsonpath='{.metadata.ownerReferences[0].kind}')
        if [ "$pvc_kind" = "AlamedaService" ]; then
            echo "Patching pv ${pv_name} policy to '$policy'..."
            kubectl patch pv $pv_name -p "{\"spec\":{\"persistentVolumeReclaimPolicy\":\"$policy\"}}"
            if [ "$?" != "0" ]; then
                echo -e "$(tput setaf 1)Error in patching pv ${pv_name}$(tput sgr 0)"
                exit 3
            fi
            echo "Done."
        fi
    done <<< "$(echo "$all_fed_pv")"
fi

echo -e "$(tput setaf 3)\n----------------------------------------"
echo -e "Starting to remove the Federator.ai product"
echo -e "----------------------------------------\n$(tput sgr 0)"

realpath() {
    [[ $1 = /* ]] && echo "$1" || echo "$PWD/${1#./}"
}

if [ "$offline_mode" = "y" ]; then
    # Check if script ran under offline package folder
    if [ ! -f "../$operator_folder/00-namespace.yaml" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to locate offline operator yaml files$(tput sgr 0)"
        echo "Please make sure you extract the offline install package and execute uninstall.sh under scripts folder.$(tput sgr 0)"
        exit 3
    fi

    remove_all_alamedaservice

    cd ../$operator_folder
    if [ "$machine_type" = "Linux" ]; then
        sed -i "s/name: federatorai/name: ${installed_namespace}/g" 00*.yaml
        sed -i "s|\bnamespace:.*|namespace: ${installed_namespace}|g" *.yaml
    else
        # Mac
        sed -i "" "s/name: federatorai/name: ${installed_namespace}/g" 00*.yaml
        sed -i "" "s| namespace:.*| namespace: ${installed_namespace}|g" *.yaml
    fi

    for yaml_file in `ls ../$operator_folder/[0-9]*yaml|sort -n -r`
    do
        echo -e "$(tput setaf 2)\nDeleting $yaml_file ...$(tput sgr 0)"
        # Move deleting 00-namespace.yaml to the last
        if [[ $yaml_fn =~ 00-.*$ ]]; then
            namespace_yaml="$yaml_fn"
            continue
        fi
        if [[ $yaml_file =~ 04-.*$ ]]; then
            kubectl delete -f ${yaml_file} --ignore-not-found=true
        else
            kubectl delete -f ${yaml_file}
        fi
        if [ "$?" != "0" ]; then
            echo -e "$(tput setaf 1)Error in removing $yaml_file$(tput sgr 0)"
        fi
    done
    cd - > /dev/null
else
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
            read -r -p "$(tput setaf 2)Please enter the path of Federator.ai uninstallation directory [default: $default]: $(tput sgr 0) " save_path </dev/tty
            save_path=${save_path:-$default}
            save_path=$(echo "$save_path" | tr '[:upper:]' '[:lower:]')
            save_path="$save_path/federatorai"
        fi
    else
        save_path="$FEDERATORAI_FILE_PATH"
    fi

    file_folder="$save_path/uninstallation"
    if [ -d "$file_folder" ]; then
        rm -rf $file_folder
    fi
    mkdir -p $file_folder
    if [ ! -d "$file_folder" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to create folder to save Federator.ai uninstallation files.$(tput sgr 0)"
        exit 3
    fi
    current_location=`pwd`
    cd $file_folder

    while [[ "$info_correct" != "y" ]] && [[ "$info_correct" != "Y" ]]
    do
        # init variables
        tag_number=""

        read -r -p "$(tput setaf 2)Please enter your Federator.ai Operator tag:$(tput sgr 0) " tag_number </dev/tty

        echo -e "\n----------------------------------------"
        echo "Your tag number = $tag_number"
        echo "----------------------------------------"

        default="y"
        read -r -p "$(tput setaf 2)Is the above information correct? [default: y]: $(tput sgr 0)" info_correct </dev/tty
        info_correct=${info_correct:-$default}
    done

    download_operator_yaml_if_needed
    remove_all_alamedaservice
    remove_operator_yaml
fi

wait_until_resource_removed 900 60
remove_containersai_crds
wait_until_cr_removed 900 30

remove_operator_ns_yaml
cd - > /dev/null
