#!/usr/bin/env bash

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
    sed -i "s/name:.*/name: ${installed_namespace}/g" 00*.yaml
    sed -i "s|\bnamespace:.*|namespace: ${installed_namespace}|g" *.yaml

}

remove_operator_yaml()
{
    for yaml_fn in `ls [0-9]*yaml | sort -n -r`
    do
        echo -e "$(tput setaf 2)\nDeleting $yaml_fn ...$(tput sgr 0)"
        kubectl delete -f ${yaml_fn}
        if [ "$?" != "0" ]; then
            echo -e "$(tput setaf 1)Error in removing $yaml_fn$(tput sgr 0)"
            #exit 2
        fi
    done
}

wait_until_namespace_removed()
{
  period="$1"
  interval="$2"

  for ((i=0; i<$period; i+=$interval)); do

    # check if namespace still exist
    kubectl get ns "$installed_namespace" 2>/dev/null |grep -q "$installed_namespace"
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 6)Namespace $installed_namespace is removed successfully.$(tput sgr 0)"
        return 0
    else
        echo "Waiting for the namespace to be removed..."
    fi

    sleep "$interval"
  done

  echo -e "\n$(tput setaf 1)Warning!! Waited for $period seconds, but namespace $installed_namespace still exist.$(tput sgr 0)"
  #exit 4
}

which curl > /dev/null 2>&1
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)Abort, \"curl\" command is needed for this tool.$(tput sgr 0)"
    exit
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

installed_namespace="`kubectl get pods --all-namespaces |egrep "alameda-datahub-|federatorai-operator-"|awk '{print $1}'|head -1`"
if [ "$installed_namespace" = "" ]; then
    echo -e "\nInstalled_namespace is empty. Federator.ai build doesn't exist in system."
    exit
fi

all_fed_pv="$(kubectl get pv --output jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.claimRef.namespace}{"\n"}'|grep "$installed_namespace")"
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

    while read pv_name _junk; do
        echo "Patching pv ${pv_name} ..."
        kubectl patch pv ${pv_name} -p "{\"spec\":{\"persistentVolumeReclaimPolicy\":\"$policy\"}}"
        if [ "$?" != "0" ]; then
            echo -e "$(tput setaf 1)Error in patching pv ${pv_name}$(tput sgr 0)"
            exit 3
        fi
        echo "Done."
    done <<< "$(echo "$all_fed_pv")"
fi

echo -e "$(tput setaf 3)\n----------------------------------------"
echo -e "Starting to remove the Federator.ai product"
echo -e "----------------------------------------\n$(tput sgr 0)"

if [ "$offline_mode" = "y" ]; then
    # Check if script ran under offline package folder
    if [ ! -f "../$operator_folder/00-namespace.yaml" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to locate offline operator yaml files$(tput sgr 0)"
        echo "Please make sure you extract the offline install package and execute uninstall.sh under scripts folder.$(tput sgr 0)"
        exit 3
    fi

    remove_all_alamedaservice

    cd ../$operator_folder
    sed -i "s/name: federatorai/name: ${installed_namespace}/g" 00*.yaml
    sed -i "s|\bnamespace:.*|namespace: ${installed_namespace}|g" *.yaml

    for yaml_file in `ls ../$operator_folder/[0-9]*yaml|sort -n -r`
    do
        echo -e "$(tput setaf 2)\nDeleting $yaml_file ...$(tput sgr 0)"
        kubectl delete -f $yaml_file
        if [ "$?" != "0" ]; then
            echo -e "$(tput setaf 1)Error in removing $yaml_file$(tput sgr 0)"
        fi
    done
    cd - > /dev/null
else
    script_located_path=$(dirname $(readlink -f "$0"))
    if [ "$FEDERATORAI_FILE_PATH" = "" ]; then
        if [[ $script_located_path =~ .*/federatorai/repo/.* ]]; then
            save_path="$(dirname "$(dirname "$(dirname "$(realpath $script_located_path)")")")"
        else
            # Ask for input
            default="/opt"
            read -r -p "$(tput setaf 2)Please input Federator.ai uninstallation files save path [default: $default]: $(tput sgr 0) " save_path </dev/tty
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

        read -r -p "$(tput setaf 2)Please input your Federator.ai Operator tag:$(tput sgr 0) " tag_number </dev/tty

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
    cd - > /dev/null
fi

wait_until_namespace_removed 900 60
remove_containersai_crds
