#!/usr/bin/env bash

show_usage()
{
    cat << __EOF__

    Usage:
        -b,    backup, cannot use with restore(-r) at the same time
        -r,    restore, cannot use with backup(-b) at the same time
        -d,    backup or restore folder [e.g., -d /opt/backup]

__EOF__
    exit 1
}

restore(){
    ask_confirmation_from_user
    check_and_uncompress_file
    stop_services
    restore_influxdb
    restore_postgresql
    start_services
    echo "Restoration job has completed successfully."
}

backup(){
    prepare_folder
    backup_influxdb
    backup_postgresql
    compress_files
    echo "backup file saved to folder $tgz_file"
}

ask_confirmation_from_user(){
    default="n"
    echo -e "$(tput setaf 2)Restoration will drop all the data inside current dbs.$(tput sgr 0)"
    read -r -p "$(tput setaf 2)Do you want to continue the restoration process? [default: $default]: $(tput sgr 0)" go_restore </dev/tty
    go_restore=${go_restore:-$default}
    go_restore=$(echo "$go_restore" | tr '[:upper:]' '[:lower:]')
    if [ "$go_restore" != "y" ]; then
        exit 2
    fi
}

stop_services(){
    # Stop operator first
    echo "Stopping Federator.ai services..."
    kubectl -n $fed_ns scale deploy federatorai-operator --replicas=0 >/dev/null 2>&1
    if [ "$?" != 0 ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to bring down Federator.ai operator service.$(tput sgr 0)"
        exit 3
    fi

    # Stop all deploys
    all_deploys="$(kubectl -n $fed_ns get deploy|grep -v ^NAME|awk '{print $1}'|xargs)"
    kubectl -n $fed_ns scale deploy $all_deploys --replicas=0 >/dev/null 2>&1
    if [ "$?" != 0 ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to bring down Federator.ai services for restoration.$(tput sgr 0)"
        exit 3
    fi
    sleep 20
    echo -e "Done.\n"
}

start_services()
{
    echo "Starting Federator.ai services..."
    # 1. rabbitmq
    kubectl -n $fed_ns scale deploy --replicas=1 alameda-rabbitmq >/dev/null 2>&1
    sleep 30
    # 2. datahub
    kubectl -n $fed_ns scale deploy --replicas=1 alameda-datahub >/dev/null 2>&1
    sleep 40
    # 3. Others
    all_deploys="$(kubectl -n $fed_ns get deploy|grep -v ^NAME|awk '{print $1}'|xargs)"
    kubectl -n $fed_ns scale deploy $all_deploys --replicas=1 >/dev/null 2>&1
    # Check status
    wait_until_pods_ready $max_wait_pods_ready_time 30 $fed_ns 6
    echo -e "Done.\n"
}

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
  exit 4
}

pods_ready()
{
  [[ "$#" == 0 ]] && return 0

  namespace="$1"
  kubectl get pod -n $namespace \
    '-o=go-template={{range .items}}{{.metadata.name}}{{"\t"}}{{range .status.conditions}}{{if eq .type "Ready"}}{{.status}}{{"\t"}}{{end}}{{end}}{{.status.phase}}{{"\t"}}{{if .status.reason}}{{.status.reason}}{{end}}{{"\n"}}{{end}}' \
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

restore_postgresql(){
    echo "Restoring PostgreSQL backup files..."
    kubectl -n $fed_ns exec $postgresql_name -- dropdb -U postgres federatorai
    if [ "$?" != 0 ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to drop federatorai db in PostgreSQL.$(tput sgr 0)"
        exit 3
    fi
    kubectl -n $fed_ns exec $postgresql_name -- createdb -U postgres federatorai
    if [ "$?" != 0 ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to recreate federatorai db in PostgreSQL.$(tput sgr 0)"
        exit 3
    fi
    kubectl -n $fed_ns exec $postgresql_name -- pg_restore -U postgres -d federatorai $postgresql_internal_folder/postgres.dump
    if [ "$?" != 0 ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to recreate federatorai db in PostgreSQL.$(tput sgr 0)"
        exit 3
    fi
    echo -e "Done.\n"
}

restore_influxdb(){

    # Find all backup dbs needed to be restored.
    echo "Restoring InfluxDB backup files..."
    db_name_all="$(kubectl -n $fed_ns exec $influxdb_name -- bash -c "find $influxdb_internal_folder/* -maxdepth 0 -type d"|awk -F/ '{print $NF}')"
    if [ "$db_name_all" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to locate restore folders inside pod.$(tput sgr 0)"
        exit 3
    fi
    # Drop databases
    for db_name in $(echo "$db_name_all")
    do
        kubectl -n $fed_ns exec $influxdb_name -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -execute "drop database $db_name" >/dev/null
        if [ "$?" != 0 ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to drop influxdb database ($db_name).$(tput sgr 0)"
            exit 3
        fi
    done

    # Restore databases
    for db_name in $(echo "$db_name_all")
    do
        kubectl -n $fed_ns exec $influxdb_name -- influxd restore -portable -db $db_name ${influxdb_internal_folder}/${db_name}
        if [ "$?" != 0 ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to restore influxdb database ($db_name).$(tput sgr 0)"
            exit 3
        fi
    done
    echo -e "Done.\n"
}

check_and_uncompress_file(){
    # Locate backup file
    matched_file="0"
    for file in $specific_dir/*.tgz
    do
        if [[ $file =~ federatorai-v5.0.0.*-backup-.* ]]; then
            backup_file="$file"
            # Remove ".tgz"
            backup_folder="${backup_file%????}"
            matched_file=$((matched_file+1))
        fi
    done
    if [ "$matched_file" -gt "1" ]; then
        echo -e "\n$(tput setaf 1)Error! Multiple backup file inside specific folder ($specific_dir).$(tput sgr 0)"
        exit 3
    elif [ "$matched_file" -eq "0" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to locate backup file inside specific folder ($specific_dir).$(tput sgr 0)"
        exit 3
    fi

    # Delete previous folder if exist
    if [ -d "$backup_folder" ]; then
        rm -rf $backup_folder
    fi
    # Untar file
    tar zxf $backup_file -C $specific_dir
    if [ "$?" != 0 ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to untar Federator.ai backup file ($backup_file).$(tput sgr 0)"
        exit 3
    fi

    # check two backup files inside
    if [ ! -f "$backup_folder/$influxdb_backup_name" ]; then
        echo -e "\n$(tput setaf 1)Error! No InfluxDB backup file ($influxdb_backup_name) found.$(tput sgr 0)"
        exit 3
    fi
    if [ ! -f "$backup_folder/$postgresql_backup_name" ]; then
        echo -e "\n$(tput setaf 1)Error! No PostgreSQL backup file ($postgresql_backup_name) found.$(tput sgr 0)"
        exit 3
    fi

    # Test to untar InfluxDB file
    tar xf $backup_folder/$influxdb_backup_name -C $backup_folder
    if [ "$?" != 0 ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to untar InfluxDB backup file ($backup_folder/$influxdb_backup_name).$(tput sgr 0)"
        exit 3
    fi
    # Delete test files
    if [ -d $backup_folder/var ]; then
        rm -rf $backup_folder/var
    fi

    # Test to untar PostgreSQL file
    tar xf $backup_folder/$postgresql_backup_name -C $backup_folder
    if [ "$?" != 0 ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to untar PostgreSQL backup file ($backup_folder/$postgresql_backup_name).$(tput sgr 0)"
        exit 3
    fi
    # Delete test files
    if [ -d $backup_folder/var ]; then
        rm -rf $backup_folder/var
    fi

    # Copy backup file into pod
    kubectl -n $fed_ns exec $influxdb_name -- rm -rf $influxdb_internal_folder
    kubectl -n $fed_ns exec $influxdb_name -- mkdir -p $influxdb_internal_folder
    kubectl -n $fed_ns cp $backup_folder/$influxdb_backup_name $influxdb_name:$influxdb_internal_folder
    if [ "$?" != 0 ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to copy InfluxDB backup file into InfluxDB pod.$(tput sgr 0)"
        exit 3
    fi

    # Copy backup file into pod
    kubectl -n $fed_ns exec $postgresql_name -- rm -rf $postgresql_internal_folder
    kubectl -n $fed_ns exec $postgresql_name -- mkdir -p $postgresql_internal_folder
    kubectl -n $fed_ns cp $backup_folder/$postgresql_backup_name $postgresql_name:$postgresql_internal_folder
    if [ "$?" != 0 ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to copy PostgreSQL backup file into PostgreSQL pod.$(tput sgr 0)"
        exit 3
    fi

    #Untar file inside pod
    kubectl -n $fed_ns exec $influxdb_name -- tar xf $influxdb_internal_folder/$influxdb_backup_name
    if [ "$?" != 0 ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to untar InfluxDB backup file inside pod.$(tput sgr 0)"
        exit 3
    fi
    #Untar file inside pod
    kubectl -n $fed_ns exec $postgresql_name -- tar xf $postgresql_internal_folder/$postgresql_backup_name
    if [ "$?" != 0 ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to untar PostgreSQL backup file inside pod.$(tput sgr 0)"
        exit 3
    fi
}

compress_files(){
    tgz_file="$specific_dir/${backup_name}.tgz"
    tar -C $specific_dir -zcf $tgz_file $backup_name
    if [ "$?" != 0 ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to create backup tgz file ($tgz_file).$(tput sgr 0)"
        exit 3
    fi

    # Remove useless folder
    if [ -d "$specific_dir/$backup_name" ]; then
        rm -rf $specific_dir/$backup_name
    fi
}

prepare_folder(){
    # Prepare external backup folder
    if [ ! -d "$specific_dir" ]; then
        mkdir -p $specific_dir
        if [ "$?" != 0 ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to create backup folder ($specific_dir).$(tput sgr 0)"
            exit 3
        fi
    fi
    backup_name="federatorai-${fed_tag}-backup-$(date +"%Y%m%d-%H%M%S")"
    backup_folder_path="$specific_dir/$backup_name"
    mkdir $backup_folder_path
}

backup_postgresql(){
    # Prepare internal backup folder
    kubectl -n $fed_ns exec $postgresql_name -- rm -rf $postgresql_internal_folder
    kubectl -n $fed_ns exec $postgresql_name -- mkdir -p $postgresql_internal_folder

    # Start to backup postgresql to binary file
    kubectl -n $fed_ns exec $postgresql_name -- bash -c "pg_dump -Fc -U postgres federatorai > ${postgresql_internal_folder}/postgres.dump"
    if [ "$?" != 0 ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to backup postgresql.$(tput sgr 0)"
        exit 3
    fi
    # (Double confirmation) Start to backup postgresql to text file
    # ignore result check
    kubectl -n $fed_ns exec $postgresql_name -- bash -c "pg_dump -U postgres federatorai > $postgresql_internal_folder/postgres.pgsql"
    
    # Retrieve backup files
    kubectl -n $fed_ns exec $postgresql_name -- tar cf - $postgresql_internal_folder > $backup_folder_path/$postgresql_backup_name 2>/dev/null
    if [ "$?" != 0 ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to copy backup file out of influxdb pod.$(tput sgr 0)"
        exit 3
    fi
}

backup_influxdb(){
    # Prepare internal backup folder
    kubectl -n $fed_ns exec $influxdb_name -- rm -rf $influxdb_internal_folder
    kubectl -n $fed_ns exec $influxdb_name -- mkdir -p $influxdb_internal_folder

    # Start to backup needed dbs
    for db_name in "${backup_dbs[@]}"
    do
        # Check if database has measurement(s)
        measurements=$(kubectl -n $fed_ns exec $influxdb_name -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database $db_name -execute "show measurements")
        if [ "$measurements" = "" ]; then
            # If database is empty, skill backup to prevent restore failure.
            continue
        fi
        kubectl -n $fed_ns exec $influxdb_name -- mkdir -p $influxdb_internal_folder/$db_name
        kubectl -n $fed_ns exec $influxdb_name -- influxd backup -portable -database $db_name $influxdb_internal_folder/$db_name >/dev/null
        if [ "$?" != 0 ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to backup influxdb database ($db_name).$(tput sgr 0)"
            exit 3
        fi
    done

    # Retrieve backup files
    kubectl -n $fed_ns exec $influxdb_name -- tar cf - $influxdb_internal_folder > $backup_folder_path/$influxdb_backup_name 2>/dev/null
    if [ "$?" != 0 ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to copy backup file out of influxdb pod.$(tput sgr 0)"
        exit 3
    fi
}

kubectl version|grep -q "^Server"
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)Error! Please login to Kubernetes first.$(tput sgr 0)"
    exit 3
fi

which tar 2>&1 >/dev/null
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)Error! Need tar command to use this tool.$(tput sgr 0)"
    exit 3
fi

which gzip 2>&1 >/dev/null
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)Error! Need gzip command to use this tool.$(tput sgr 0)"
    exit 3
fi

influxdb_name="alameda-influxdb-0"
postgresql_name="federatorai-postgresql-0"
influxdb_backup_name="influxdb.tar"
postgresql_backup_name="postgres.tar"
influxdb_internal_folder="/var/lib/influxdb/backup"
postgresql_internal_folder="/var/lib/postgresql/data/backup"
fed_ns="`kubectl get alamedaservice --all-namespaces 2>/dev/null|tail -1|awk '{print $1}'`"
fed_tag="`kubectl get alamedaservices -n $fed_ns -o custom-columns=VERSION:.spec.version 2>/dev/null|grep -v VERSION|head -1`"
backup_dbs=("alameda_cluster_status" "alameda_cluster_resource" "alameda_application" "alameda_config" "alameda_target" "alameda_profile" "alameda_automation" "alameda_user")
[ "$max_wait_pods_ready_time" = "" ] && max_wait_pods_ready_time=900

if [ "$fed_ns" = "" ]; then
    echo -e "\n$(tput setaf 1)Error! Failed to locate installed Federator.ai$(tput sgr 0)"
    exit 3
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

if [ "$machine_type" = "Linux" ]; then
    script_located_path=$(dirname $(readlink -f "$0"))
else
    # Mac
    script_located_path=$(dirname $(realpath "$0"))
fi

while getopts "brd:h" o; do
    case "${o}" in
        b)
            do_backup="y"
            ;;
        r)
            do_restore="y"
            ;;
        d)
            specific_dir=${OPTARG}
            ;;
        h)
            show_usage
            exit
            ;;
        *)
            echo "Error! wrong parameter."
            exit 3
            ;;
    esac
done

if [ "$do_backup" = "" ] && [ "$do_restore" = "" ]; then
    echo -e "\n$(tput setaf 1)Error! Please specify the job you want to run (backup/restore).$(tput sgr 0)"
    show_usage
    exit 1
fi

if [ "$do_backup" = "y" ] && [ "$do_restore" = "y" ]; then
    echo -e "\n$(tput setaf 1)Error! Backup and restore can't be run at the same time.$(tput sgr 0)"
    show_usage
    exit 1
fi

if [ "$specific_dir" = "" ]; then
    echo -e "\n$(tput setaf 1)Error! Please specify backup/restore folder.$(tput sgr 0)"
    show_usage
    exit 1
fi

if [ "$do_restore" = "y" ] && [ ! -d "$specific_dir" ]; then
    echo -e "\n$(tput setaf 1)Error! Restore folder doesn't exist.$(tput sgr 0)"
    exit 1
fi

if [ "$do_backup" = "y" ]; then
    backup
fi

if [ "$do_restore" = "y" ]; then
    restore
fi
