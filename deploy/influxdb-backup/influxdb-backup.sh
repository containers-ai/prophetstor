#!/bin/bash
# The script is used for backup and restore Federator.ai InfluxDB.
# Versions:
#   1.0.1 - The first build.
#   1.0.2 - Fix restore failed to read the backup file if not encrypted
#
VER=1.0.2

KUBECTL="kubectl"
INFLUXD_PROG="influxd"
INFLUXDB_POD="alameda-influxdb-0"
INFLUXDB_PATH="/var/lib/influxdb"
BACKUP_PATH="${INFLUXDB_PATH}/backup"
BACKUP_PREFIX="InfluxDB-backup"
BACKUP_INFO_FILE=".influxdb-backup.info"
FEDERATORAI_OPERATOR="federatorai-operator"
FEDERATORAI_VERSION_FILE="/opt/alameda/alameda-influxdb/etc/version.txt"

# Initialize variables with default values
declare -A vars
vars[operation]="backup"
vars[curr_context]=""
vars[context]=""
vars[dryrun]="no"
vars[namespace]=""
vars[encrypt]="yes"
vars[directory]="backup"
vars[cluster]="kubernetes"
vars[force]="no"
vars[cleanup]="yes"
vars[backup]=""
vars[password]=""
vars[always_up]="no"
vars[retries]=3
vars[logfile]="/var/log/influxdb-backup.log"

output_msg="OK"
start_timestamp=$( date -u "+%s" )
datetime_now=$( date -u "+%Y%m%d-%H%M%S-%Z" )
RANDOM=$( date "+%N" )
SID=$((($RANDOM % 900 ) + 100))
SPF='['${SID}']'

set -o pipefail

lower_case()
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

logging()
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

    echo -e "${SPF} $(date '+%F %T') ${level}: ${msg}" >> ${vars[logfile]}

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

write_logs()
{
    while read line
    do
        echo "${SPF} ${line}"
    done
}

precheck_architecture()
{
    machine_os=$( uname -mo )
    if [ "${machine_os}" != "x86_64 GNU/Linux" ]
    then
        output_msg="This script supports only Linux x86_64 architecture."
        return 1
    fi

    logging "Architecture: ${machine_os}"
}

precheck_kubectl()
{
    current_context=$( ${KUBECTL} config current-context 2>/dev/null )
    rc=$?
    if [ "${rc}" != "0" ]
    then
        output_msg="'${KUBECTL}' is not installed or configured properly."
        return 1
    elif [ "${current_context}" != "" ]
    then
        vars[curr_context]=${current_context}
        if [ "${vars[context]}" != "" -a "${vars[context]}" != "${vars[curr_context]}" ]
        then
            if ! ${KUBECTL} config use-context ${vars[context]} 2>&1 | write_logs >>${vars[logfile]}
            then
                output_msg="Failed to set ${KUBECTL} context ${vars[context]}."
                return 1
            fi
        fi
    fi
    cluster_name=$( ${KUBECTL} cluster-info | grep "Kubernetes" |awk -F':' '{print $2}' |tr -d '/:' 2>/dev/null )
    if [ "${cluster_name}" != "" ]
    then
        vars[cluster]=${cluster_name}
    fi

    logging "Kubernetes context: ${vars[curr_context]}, cluster: ${vars[cluster]}"
}

precheck_openssl()
{
    if ! which openssl > /dev/null 2>&1
    then
        vars[encrypt]="no"
        logging "${WARN}" "'Openssl' is not available. Encrypt/Decrypt backup is not supported."
    fi
}

precheck_federatorai()
{
    f8ai_ns=$( ${KUBECTL} get pod --all-namespaces |grep ${INFLUXDB_POD} |head -1 |awk '{print $1}' 2>/dev/null )
    rc=$?
    if [ "${rc}" != "0" ]
    then
        output_msg="Federator.ai InfluxDB is not running or '${KUBECTL}' is not configured correctly."
        return 1
    fi
    vars[namespace]=${f8ai_ns}

    logging "Federator.ai namespace: ${vars[namespace]}"
}

precheck_free_space()
{
    df_cmd="df ${INFLUXDB_PATH} | tail -1"
    du_cmd="du -s ${INFLUXDB_PATH}"

    read -d $'\n' -r dev blocks used avail rest < <(${KUBECTL} -n ${vars[namespace]} exec ${INFLUXDB_POD} -- bash -c "${df_cmd}" 2>/dev/null)
    read -d $'\n' -r size path < <(${KUBECTL} -n ${vars[namespace]} exec ${INFLUXDB_POD} -- bash -c "${du_cmd}" 2>/dev/null)

    if [ "${avail##*[0-9]*}" != "" -o "${size##*[0-9]*}" != "" ]
    then
        output_msg="Failed to get size of ${INFLUXDB_PATH}."
        return 1
    fi

    req_size=$((${size} / 4))
    if [ ${avail} -le ${req_size} ]
    then
        output_msg="Not enough free space in ${INFLUXDB_PATH}, at least ${req_size} KBytes are needed."
        return 1
    fi
}

declare -A cleanup_cmds
idx=0

cleanup_push()
{
    cmd=( "$@" )
    cleanup_cmds[${idx}]=${cmd[@]}
    idx=$((${idx} + 1))
}

do_cleanup()
{
    local rc=0
    if [ "${vars[cleanup]}" != "no" ]
    then
        i=$((${#cleanup_cmds[@]} - 1))
        while [ ${i} -ge 0 ]
        do
            logging "Clean Up: ${cleanup_cmds[${i}]}"
            if ! ${cleanup_cmds[${i}]} 2>&1 | write_logs >>${vars[logfile]}
            then
                rc=$?
            fi
            i=$((${i} - 1))
        done
    fi
    unset cleanup_cmds
    idx=0
    return ${rc}
}

proceed()
{
    local retcode=0
    local rc=$1
    shift
    cmd=( "$@" )
    retry=0

    if [ "${rc}" != "0" ]
    then
        logging "Skip command '${cmd[@]}'"
        output_msg=""
        return 0
    fi
    logging "Command: '${cmd[@]}'"
    # run command
    while [ ${retry} -lt ${vars[retries]} ]
    do
        if ! ${cmd[@]} 2>&1 | write_logs >>${vars[logfile]}
        then
            retcode=1
        else
            retcode=0
            break
        fi
        retry=$((${retry} + 1))
        sleep 3
        logging "Retry (${retry}/${vars[retries]})"
    done
    return ${retcode}
}

get_keyfile()
{
    local rc=0
    kf=$1

    if [ "${vars[password]}" = "" ]
    then
        if [[ -z "${INFLUX_BACKUP_PASSWORD}" ]]
        then
            backup_passwd=""
            while [ ${#backup_passwd} -lt 8 ]
            do
                read -s -p "Enter InfluxDB backup password (at least 8 characters): " backup_passwd
                echo
            done
            vars[password]="${backup_passwd}"
        else
            vars[password]="${INFLUX_BACKUP_PASSWORD}"
        fi
    fi

    if [ "${vars[password]}" = "" ]
    then
        output_msg="Failed to generate key file for encryption/decryption."
        keyfile=""
        rc=1
    else
        kfbase="$( echo ${vars[password]} | openssl base64 2>/dev/null )"
        keyfile="$( echo "kfi${vars[password]:1:4}le" | openssl base64 2>/dev/null )"
        keyfile="/tmp/${keyfile}"
        echo "${kfbase}" > ${keyfile}
    fi
    eval ${kf}=${keyfile}
    return ${rc}
}

get_meta_md5()
{
    local backup_name=$1
    meta_md5=$2

    mtmd5=$( md5sum ${vars[directory]}/${backup_name}/*.meta 2>/dev/null )
    local rc=$?
    if [ "${rc}" != "0" ]
    then
        output_msg="Failed to generate backup meta md5sum."
        return ${rc}
    fi
    eval ${meta_md5}="${mtmd5%% *}"
}

INFO_KEY_VERSION="Version"
INFO_KEY_FEDERATORAI="Federatorai"
INFO_KEY_CLUSTER="Cluster"
INFO_KEY_TIME="Time"
INFO_KEY_MD5="MD5"

generate_backup_info()
{
    local backup_name="${BACKUP_PREFIX}-${vars[cluster]}-${datetime_now}"
    local backup_info_path="${vars[directory]}/${backup_name}/${BACKUP_INFO_FILE}"

    f8ai_version_cmd=( ${kexec_cmd[@]} grep VERSION ${FEDERATORAI_VERSION_FILE} )
    cmd_out=$( ${f8ai_version_cmd[@]} 2>/dev/null )
    if [ "${cmd_out}" = "" ]
    then
        output_msg="Failed to get Federator.ai version."
        return 1
    fi
    f8ai_ver=${cmd_out##*=}

    get_meta_md5 ${backup_name} meta_md5
    local rc=$?
    if [ "${rc}" != "0" ]
    then
        return ${rc}
    fi

    echo "${INFO_KEY_VERSION}=${VER}" > ${backup_info_path}
    echo "${INFO_KEY_FEDERATORAI}=${f8ai_ver}" >> ${backup_info_path}
    echo "${INFO_KEY_CLUSTER}=${vars[cluster]}" >> ${backup_info_path}
    echo "${INFO_KEY_TIME}=${datetime_now}" >> ${backup_info_path}
    echo "${INFO_KEY_MD5}=${meta_md5}" >> ${backup_info_path}

    logging "Generate backup info: ${VER}/${f8ai_ver}/${vars[cluster]}/${datetime_now}/${meta_md5}"
}

verify_backup_info()
{
    local backup_name=$1
    local backup_info_path="${vars[directory]}/${backup_name}/${BACKUP_INFO_FILE}"
    if [ "${backup_name}" = "" -o ! -e ${backup_info_path} ]
    then
        output_msg="Backup info file '${backup_info_path}' does not exist."
        return 1
    fi

    declare -A info_prop
    while IFS='=' read -d $'\n' -r k v
    do
        # Skip lines starting with sharp
        # or lines containing only space or empty lines
        [[ "${k}" =~ ^([[:space:]]*|[[:space:]]*#.*)$ ]] && continue
        # Store key value into assoc array
        info_prop[${k}]="${v}"
    done < ${backup_info_path}

    get_meta_md5 ${backup_name} meta_md5
    local rc=$?
    if [ "${rc}" != "0" ]
    then
        return ${rc}
    fi

    if [ "${info_prop[${INFO_KEY_CLUSTER}]}" = "" -o "${info_prop[${INFO_KEY_TIME}]}" = "" -o "${info_prop[${INFO_KEY_MD5}]}" = "" ]
    then
        output_msg="Invalid backup info in '${backup_name}'."
        return 1
    fi

    if [ "${info_prop[${INFO_KEY_CLUSTER}]}" != "${vars[cluster]}" ]
    then
        output_msg="Attempt to restore '${backup_name}' of cluster '${info_prop[${INFO_KEY_CLUSTER}]}' to '${vars[cluster]}'."
        return 1
    elif [ "${info_prop[${INFO_KEY_MD5}]}" != "${meta_md5}" ]
    then
        output_msg="Backup '${backup_name}' meta md5 schecksum mismatches."
        return 1
    fi

    logging "Verify backup info: Succeeded"
}

encrypt_backup()
{
    local rc=0
    local backup_file="$1"

    if [ "${backup_file}" = "" ]
    then
        return 1
    fi

    if ! get_keyfile keyfile
    then
        return 1
    fi

    encrypt_cmd=( openssl enc -in ${vars[directory]}/${backup_file} -out ${vars[directory]}/${backup_file}.enc -e -aes-256-cbc -k ${keyfile} )
    if ! ${encrypt_cmd[@]} 2>&1 | write_logs >>${vars[logfile]}
    then
        output_msg="Failed to encrypt backup file '${backup_file}'."
        rc=1
    else
        rm -rf ${vars[directory]}/${backup_file} 2>&1 | write_logs >>${vars[logfile]}
        logging "Successfully encrypt backup: ${backup_file}"
    fi

    rm -rf ${keyfile} 2>&1 | write_logs >>${vars[logfile]}
    return ${rc}
}

decrypt_backup()
{
    local rc=0
    local backup_path_enc="$1"
    decrypted_backup_file=$2

    if [ "${backup_path_enc}" = "" ]
    then
        return 1
    fi

    # get backup file name (remove .enc subfix)
    IFS='.' read -r -a fn_array <<< "${backup_path_enc}"
    if [ ${#fn_array[@]} -ge 2 -a "${fn_array[-1]}" = "enc" ]
    then
        backup_file=${backup_path_enc%.*}
    else
        backup_file=${backup_path_enc}.backup
    fi
    backup_file=${backup_file##*/}

    # generate key file
    if ! get_keyfile keyfile
    then
        return 1
    fi
    cmd=( rm -rf "${keyfile}" )
    cleanup_push "${cmd[@]}"

    # decrypt backup
    cmd=( rm -rf "${vars[directory]}/${backup_file}" )
    cleanup_push "${cmd[@]}"

    decrypt_cmd=( openssl enc -in ${backup_path_enc} -out ${vars[directory]}/${backup_file} -d -aes-256-cbc -k ${keyfile} )
    if ! ${decrypt_cmd[@]} 2>&1 | write_logs >>${vars[logfile]}
    then
        output_msg="Failed to decrypt backup '${backup_path_enc}'."
        return 1
    fi
    eval ${decrypted_backup_file}=${backup_file}

    logging "Successfully decrypt backup: ${backup_path_enc}"
}

run_backup()
{
    local rc=0
    local backup_name="${BACKUP_PREFIX}-${vars[cluster]}-${datetime_now}"

    if [ -d "${vars[directory]}/${backup_name}" ]
    then
        output_msg="Backup has been triggered more than once."
        logging "${STDOUT}" "${ERR}" "${output_msg}"
        return 1
    fi

    # create backup directory
    cmd=( rm -rf "${vars[directory]}/${backup_name}" )
    cleanup_push "${cmd[@]}"

    logging "${STAGE}" "Create local backup directory"

    cmd=( mkdir -p "${vars[directory]}/${backup_name}" )
    if ! proceed ${rc} ${cmd[@]}
    then
        output_msg="Unable to create backup directory (${vars[directory]}/${backup_name})."
        logging "${STDOUT}" "${ERR}" "${output_msg}"
        return 1
    fi

    mkdir_cmd=( ${kexec_cmd[@]} mkdir -p "${BACKUP_PATH}" )
    backup_cmd=( ${kexec_cmd[@]} ${INFLUXD_PROG} backup -portable "${BACKUP_PATH}" )
    download_cmd=( ${kubectl_cmd[@]} cp ${INFLUXDB_POD}:${BACKUP_PATH}/ ${vars[directory]}/${backup_name}/ )
    tar_cmd=( tar cf ${vars[directory]}/${backup_name}.backup -C ${vars[directory]} ${backup_name} )

    if [ "${vars[dryrun]}" = "yes" ]
    then
        logging "DryRun: ${mkdir_cmd[@]}"
        logging "DryRun: ${backup_cmd[@]}"
        logging "DryRun: ${download_cmd[@]}"
        vars[backup]=${backup_name}.backup
        if [ "${vars[encrypt]}" = "yes" ]
        then
            vars[backup]=${backup_name}.backup.enc
            logging "DryRun: ${download_cmd[@]}"
        fi
    else
        cmd=( ${kexec_cmd[@]} rm -rf "${BACKUP_PATH}" )
        cleanup_push "${cmd[@]}"

        # create backup folder in InfluxdB pod
        logging "${STAGE}" "Create backup directory in InfluxDB container"
        if ! proceed ${rc} ${mkdir_cmd[@]}
        then
            output_msg="Failed to create '${BACKUP_PATH}' folder in '${INFLUXDB_POD}' pod."
            logging "${STDOUT}" "${ERR}" "${output_msg}"
            rc=1
        fi
        # start backup
        logging "${STAGE}" "Start backup in InfluxDB container"
        if ! proceed ${rc} ${backup_cmd[@]}
        then
            output_msg="Failed to create InfluxDB backup in '${INFLUXDB_POD}' pod."
            logging "${STDOUT}" "${ERR}" "${output_msg}"
            rc=1
        fi
        # download backup files
        logging "${STAGE}" "Download backup from InfluxDB container"
        if ! proceed ${rc} ${download_cmd[@]}
        then
            output_msg="Failed to download InfluxDB backup to '${vars[directory]}/${backup_name}' directory."
            logging "${STDOUT}" "${ERR}" "${output_msg}"
            rc=1
        fi
        # generate backup info
        logging "${STAGE}" "Generate backup info"
        if ! proceed ${rc} generate_backup_info
        then
            logging "${STDOUT}" "${ERR}" "${output_msg}"
            rc=1
        fi
        # pack backup files into a tar file
        logging "${STAGE}" "Pack backup files"
        if ! proceed ${rc} ${tar_cmd[@]}
        then
            output_msg="Failed to 'tar' backup files into one .backup file."
            logging "${STDOUT}" "${ERR}" "${output_msg}"
            rc=1
        fi
        vars[backup]=${backup_name}.backup
        # encrypt backup if enabled
        logging "${STAGE}" "Encrypt backup file: ${vars[encrypt]}"
        if [ "${vars[encrypt]}" = "yes" ]
        then
            if [ ${rc} -ne 0 ]
            then
                logging "Skip encrypt ${backup_name}.backup"
            else
                if ! encrypt_backup "${backup_name}.backup"
                then
                    logging "${STDOUT}" "${WARN}" "${output_msg}"
                else
                    vars[backup]=${backup_name}.backup.enc
                fi
            fi
        fi
    fi

    do_cleanup
    return ${rc}
}

scale_down()
{
    kind=$1
    dp=$2
    logging "Scale down replicas: ${dp}"
    scale_cmd=( ${kubectl_cmd[@]} scale --replicas=0 ${kind}/${dp} )
    if ! proceed 0 ${scale_cmd[@]}
    then
        output_msg="Failed to scale down '${dp}'."
        return 1
    fi
}

scale_up()
{
    kind=$1
    dp=$2
    logging "Scale up replicas: ${dp}"
    scale_cmd=( ${kubectl_cmd[@]} scale --replicas=1 ${kind}/${dp} )
    if ! proceed 0 ${scale_cmd[@]}
    then
        output_msg="Failed to scale up '${dp}'."
        return 1
    fi
}

declare -A f8ai_deploys

stop_federatorai()
{
    deploys_cmd=( ${kubectl_cmd[@]} get deploy --no-headers )

    while IFS=' ' read -d $'\n' -r k v x y z
    do
        # Skip lines starting with sharp
        # or lines containing only space or empty lines
        [[ "${k}" =~ ^([[:space:]]*|[[:space:]]*#.*)$ ]] && continue
        # Store key value into assoc array
        f8ai_deploys[${k}]="${v#*/}"
    done < <(${deploys_cmd[@]} 2>/dev/null)

    logging "Stop Federator.ai deployments: ${!f8ai_deploys[@]}"

    # first stop operator
    for dp in ${!f8ai_deploys[@]}
    do
        if [ "${dp}" = "${FEDERATORAI_OPERATOR}" -a "${f8ai_deploys[${dp}]}" = "1" ]
        then
            scale_down deploy ${FEDERATORAI_OPERATOR}
            # sleep a few seconds to enasure operator is scaled down
            sleep 3
        fi
    done

    # stop other deployments
    for dp in ${!f8ai_deploys[@]}
    do
        if [ "${dp}" != "${FEDERATORAI_OPERATOR}" -a "${f8ai_deploys[${dp}]}" = "1" ]
        then
            scale_down deploy ${dp}
        fi
    done
}

start_federatorai()
{
    logging "Start Federator.ai deployments: ${!f8ai_deploys[@]}"

    # first start other deployments
    for dp in ${!f8ai_deploys[@]}
    do
        if [ "${dp}" != "${FEDERATORAI_OPERATOR}" ]
        then
            if [ "${f8ai_deploys[${dp}]}" = "1" -o "${vars[always_up]}" = "yes" ]
            then
                scale_up deploy ${dp}
            fi
        fi
    done

    # first stop operator
    for dp in ${!f8ai_deploys[@]}
    do
        if [ "${dp}" = "${FEDERATORAI_OPERATOR}" ]
        then
            if [ "${f8ai_deploys[${dp}]}" = "1" -o "${vars[always_up]}" = "yes" ]
            then
                scale_up deploy ${FEDERATORAI_OPERATOR}
            fi
        fi
    done
}

restart_influxdb()
{
    influlx_sts=${INFLUXDB_POD%-*}
    scale_op=( scale_down scale_up )
    sts_status=( 0 1 )

    for i in 0 1
    do
        proceed 0 ${scale_op[${i}]} sts ${influlx_sts}

        ready=0
        st=$( date -u "+%s" )
        while true
        do
            get_sts_cmd=( ${kubectl_cmd[@]} get sts ${influlx_sts} --no-headers )
            while IFS=' ' read -d $'\n' -r k v x y z
            do
                ready="${v%/*}"
            done < <(${get_sts_cmd[@]} 2>/dev/null)
            if [ "${ready}" = "${sts_status[${i}]}" ]
            then
                break
            fi
            et=$( date -u "+%s" )
            rt=$((${et} - ${st}))
            if [ ${rt} -gt 300 ]
            then
                break
            fi
            logging "Waiting for ${INFLUXDB_POD} to ${scale_op[${i}]}. (${rt} seconds)"
            sleep 10
        done
    done
}

drop_databases()
{
    local backup_name=$1
    local backup_path="${vars[directory]}/${backup_name}"

    kubeexec_cmd=( ${kexec_cmd[@]} bash -c )
    influx_cmd='influx -ssl -unsafeSsl -username=${INFLUXDB_ADMIN_USER} -password=${INFLUXDB_ADMIN_PASSWORD} -format=csv -execute '

    local retry=0
    local drop_failed=0
    while [ ${retry} -lt ${vars[retries]} ]
    do
        drop_failed=0
        # get a list of databases
        declare -a databases
        show_db_cmd=${influx_cmd}'"show databases"'
        while IFS=',' read -d $'\n' -r k v
        do
            # Skip lines starting with sharp
            # or lines containing only space or empty lines
            [[ "${k}" =~ ^([[:space:]]*|[[:space:]]*#.*)$ ]] && continue
            # Store key value into assoc array
            # remove 'space','double-quote','comma' from ${v}
            if [ "${k}" = "databases" ]
            then
                databases+=(${v})
            fi
        done < <(${kubeexec_cmd[@]} "${show_db_cmd}" 2>/dev/null)

        logging "Drop InfluxDB databases: ${databases[@]}"

        # drop databases
        for db in ${databases[@]}
        do
            drop_db_cmd=${influx_cmd}'"drop database '${db}'"'
            if ! ${kubeexec_cmd[@]} "${drop_db_cmd}" 2>&1 | write_logs >>${vars[logfile]}
            then
                output_msg="Drop database ${db} encountered errors."
                drop_failed=1
            fi
        done
        if [ ${drop_failed} -eq 0 ]
        then
            break
        fi
        retry=$((${retry} + 1))
    done
    return ${drop_failed}
}

influxdb_restore()
{
    local rc=0
    local backup_name="$1"

    if ! drop_databases ${backup_name}
    then
        return 1
    fi

    logging "Restore InfluxDB databases"
    restore_cmd=( ${kexec_cmd[@]} ${INFLUXD_PROG} restore -portable ${BACKUP_PATH}/${backup_name} )
    if ! ${restore_cmd[@]} 2>&1 | write_logs >>${vars[logfile]}
    then
        output_msg="Failed to restore backup '${backup_name}'."
        return 1
    else
        logging "Restore InfluxDB databases completed"
    fi
    restart_influxdb
}

run_restore()
{
    local backup_fullpath=$1
    local extract_only=$2
    local rc=0

    if [ ! -e ${backup_fullpath} ]
    then
        output_msg="Backup file '${backup_fullpath}' is not found."
        logging "${STDOUT}" "${ERR}" "${output_msg}"
        return 1
    fi

    if [ ! -d ${vars[directory]} ]
    then
        if ! proceed ${rc} mkdir -p ${vars[directory]}
        then
            output_msg="Failed to create backup directory '${vars[directory]}'."
            logging "${STDOUT}" "${ERR}" "${output_msg}"
            return 1
        fi
        cmd=( rm -rf "${vars[directory]}" )
        cleanup_push "${cmd[@]}"
    fi

    # decrypt backup
    backup_file=${backup_fullpath}
    logging "${STAGE}" "Decrypt backup: ${vars[encrypt]}"
    if [ "${vars[encrypt]}" = "yes" ]
    then
        if ! decrypt_backup "${backup_fullpath}" backup_file
        then
            logging "${STDOUT}" "${ERR}" "${output_msg}"
            do_cleanup
            return 1
        fi
    fi

    # untar backup, mkdir backup directory, upload backup files
    backup_name=$( tar tf "${vars[directory]}/${backup_file}" |grep meta |head -1 2>/dev/null )
    if [ "${backup_name}" = "" ]
    then
        output_msg="Unable to find backup name from '${backup_fullpath}'."
        logging "${STDOUT}" "${ERR}" "${output_msg}"
        do_cleanup
        return 1
    fi
    backup_name=${backup_name%%/*}
    vars[backup]=${backup_name}

    untar_cmd=( tar xf ${vars[directory]}/${backup_file} -C ${vars[directory]} )
    mkdir_cmd=( ${kexec_cmd[@]} mkdir -p "${BACKUP_PATH}" )

    if [ "${extract_only}" = "" ]
    then
        cmd=( rm -rf "${vars[directory]}/${backup_name}" )
        cleanup_push "${cmd[@]}"
    fi

    logging "${STAGE}" "Unpack backup '${backup_file}'"
    if ! proceed ${rc} ${untar_cmd[@]}
    then
        output_msg="Failed to untar backup '${backup_file}'."
        logging "${STDOUT}" "${ERR}" "${output_msg}"
        rc=1
    fi

    logging "${STAGE}" "Verify backup info"
    if [ "${vars[force]}" = "no" ] && ! proceed ${rc} verify_backup_info ${backup_name}
    then
        logging "${STDOUT}" "${ERR}" "${output_msg}"
        rc=1
    fi

    if [ "${extract_only}" = "extract_only" ]
    then
        do_cleanup
        return ${rc}
    fi

    logging "${STAGE}" "Create backup directory in InfluxDB container"
    if ! proceed ${rc} ${mkdir_cmd[@]}
    then
        output_msg="Failed to create a backup directory in '${INFLUXDB_POD}'."
        logging "${STDOUT}" "${ERR}" "${output_msg}"
        rc=1
    fi

    upload_cmd=( ${kubectl_cmd[@]} cp ${vars[directory]}/${backup_name}/ ${INFLUXDB_POD}:${BACKUP_PATH}/ )

    if [ "${vars[dryrun]}" = "yes" ]
    then
        logging "DryRun: ${upload_cmd[@]}"
        logging "DryRun: stop federatorai"
        logging "DryRun: drop databases ${backup_name}"
        logging "DryRun: restore backup ${backup_name}"
        logging "DryRun: start federatorai"
    else
        cmd=( ${kexec_cmd[@]} rm -rf "${BACKUP_PATH}" )
        cleanup_push "${cmd[@]}"
        cmd=( start_federatorai )
        cleanup_push "${cmd[@]}"

        logging "${STAGE}" "Upload backup files to InfluxDB container"
        if ! proceed ${rc} ${upload_cmd[@]}
        then
            output_msg="Failed to upload backup files to '${INFLUXDB_POD}'."
            logging "${STDOUT}" "${ERR}" "${output_msg}"
            rc=1
        fi
        logging "${STAGE}" "Stop Federator.ai deployments"
        stop_federatorai

        logging "${STAGE}" "Restore InfluxDB databases"
        if ! proceed ${rc} influxdb_restore ${backup_name}
        then
            logging "${STDOUT}" "${ERR}" "${output_msg}"
            rc=1
        fi
    fi

    do_cleanup
    return ${rc}
}

final_report()
{
    end_timestamp=$( date -u "+%s" )
    elapsed=$((${end_timestamp} - ${start_timestamp}))
    logging "${STDOUT}" "The ${vars[operation]} time elapsed is ${elapsed} seconds."
}

on_exit()
{
    local rc=1
    if [ "$1" != "" ]
    then
        rc=$1
    fi
    trap - EXIT # Disable exit handler
    do_cleanup
    exit ${rc}
}

parse_options()
{
    optspec="x:d:e:c:f:p:u:l:n:-:"
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
                    context)
                        vars[context]="${OPT_VAL}" ;;
                    dryrun)
                        vars[dryrun]="${OPT_VAL}" ;;
                    encrypt)
                        vars[encrypt]="${OPT_VAL}" ;;
                    directory)
                        vars[directory]="${OPT_VAL}" ;;
                    force)
                        vars[force]="${OPT_VAL}" ;;
                    password)
                        vars[password]="${OPT_VAL}" ;;
                    alwaysup)
                        vars[always_up]="${OPT_VAL}" ;;
                    logfile)
                        vars[logfile]="${OPT_VAL}" ;;
                    cleanup)
                        vars[cleanup]="${OPT_VAL}" ;;
                    *)
                        if [ "$OPTERR" = 1 ] && [ "${optspec:0:1}" != ":" ]; then
                            echo "ERROR: Invalid argument '--${OPT_ARG}'."
                        fi
                        show_usage
                        exit 1 ;;
                esac ;;
            x)
                vars[context]="${OPTARG}" ;;
            d)
                vars[dryrun]="${OPTARG}" ;;
            e)
                vars[encrypt]="${OPTARG}" ;;
            c)
                vars[directory]="${OPTARG}" ;;
            f)
                vars[force]="${OPTARG}" ;;
            p)
                vars[password]="${OPTARG}" ;;
            u)
                vars[always_up]="${OPTARG}" ;;
            l)
                vars[logfile]="${OPTARG}" ;;
            n)
                vars[cleanup]="${OPTARG}" ;;
            *)
                echo "ERROR: Invalid argument '-${o}'."
                show_usage
                exit 1 ;;
        esac
    done
}

show_usage()
{
    cat << __EOF__

${PROG} command [options]

Commands:
     help           Show usage
   backup           Back up Federator.ai InfluxDB databases
  restore <file>    Restore Federator.ai InfluxDB databases from a backup file
  extract <file>    Decrypt and extract backup file without restore

Options:
  -x, --context=''       Kubeconfig context name (DEFAULT: '')
  -d, --dryrun=no        Dry run backup or restore (DEFAULT: 'no')
  -e, --encrypt=yes      Encrypt/Decrypt backup (DEFAULT: 'yes')
  -c, --directory=''     Working directory for storing backup files (DEFAULT: 'backup')
  -f, --force=no         Restore the backup to a different Federator.ai cluster
  -p, --password=''      Encryption/Decryption password (or read from 'INFLUX_BACKUP_PASSWORD')
  -u, --alwaysup=no      Always scale up Federator.ai deployments (DEFAULT: 'no')
  -l, --logfile=''       Log path/file (DEFAULT: '/var/log/influxdb-backup.log')
  -n, --cleanup=yes      (For debugging) clean up/revert operations have been done (DEFAULT: 'yes')

Examples:
  # Back up InfluxDB databases
  ${PROG} backup --directory=/root/backup --encrypt=yes --logfile=/var/log/influxdb-backup.log

  # Restore InfluxDB databases from a backup
  ${PROG} restore backup/InfluxDB-backup-h2-63-20230104-145839-UTC.backup.enc --directory=/root/backup --encrypt=yes --force=yes

__EOF__
    exit 1
}

banner()
{
    banner_string="Federator.ai InfluxDB Backup/Restore Utility v${VER}"
    echo ${banner_string}
    logging "${banner_string}"
    echo
}

### main
trap on_exit EXIT INT  ## Assign exit handler
PROG=${0##*/}
banner

# parse command
case "$1" in
    ""|help)
        show_usage
        exit 0
        ;;
    backup)
        vars[operation]="$1"
        shift
        ;;
    restore|extract)
        vars[operation]="$1"
        shift
        source_backup_file="$1"
        shift
        if [ "${source_backup_file}" = "" -o "${source_backup_file:0:1}" = "-" ]
        then
            echo "ERROR: Invalid argument '$1 <file>'."
            show_usage
            exit 1
        fi
        ;;
    *)
        echo "ERROR: Invalid argument '$1'."
        show_usage
        exit 1
        ;;
esac

# parse options
parse_options "$@"

logging "Arguments: $@"
for i in "${!vars[@]}"
do
    logging "vars[${i}]=${vars[${i}]}"
done

# pre-checks
if ! precheck_architecture || ! precheck_kubectl || ! precheck_federatorai || ! precheck_free_space
then
    logging "${STDOUT}" "${ERR}" ${output_msg}
    exit 1
fi
# optional openssl
precheck_openssl

kubectl_cmd=( ${KUBECTL} -n ${vars[namespace]} )
kexec_cmd=( ${kubectl_cmd[@]} exec ${INFLUXDB_POD} -- )

retcode=0
# start operation
case "${vars[operation]}" in
    backup)
        logging "${STDOUT}" "Start creating backup for '${vars[cluster]}'. It will take several minutes to complete."
        if ! run_backup
        then
            output_msg="Back up Federator.ai InfluxDB databases is failed!"
            retcode=1
        else
            output_msg="Successfully created backup '${vars[directory]}/${vars[backup]}'."
        fi
        ;;
    restore)
        logging "${STDOUT}" "${WARN}" "Restore databases to '${vars[cluster]}' will stop Federator.ai services and destroy existing data!"
        echo
        read -p "Do you want to proceed? Type 'YES' to confirm: " confirm
        if [ "${confirm}" != "YES" ]
        then
            exit 1
        fi
        read -p "Do you want to create a backup before restoring databases?[Y|n] " do_backup
        echo
        do_backup=$(lower_case ${do_backup})
        if [ "${do_backup}" = "" -o "${do_backup}" = "y" -o "${do_backup}" = "yes" ]
        then
            logging "${STDOUT}" "Start creating backup for '${vars[cluster]}'."
            if ! run_backup
            then
                output_msg="Back up Federator.ai InfluxDB databases is failed!"
                logging "${STDOUT}" "${ERR}" "${output_msg}"
                exit 1
            else
                output_msg="Successfully created backup '${vars[directory]}/${vars[backup]}'."
                logging "${STDOUT}" "${INFO}" "${output_msg}"
            fi
        fi

        logging "${STDOUT}" "Start restoring databases. It will take several minutes to complete."
        if ! run_restore ${source_backup_file}
        then
            retcode=1
            output_msg="Restore Federator.ai InfluxDB databases is failed!"
        else
            output_msg="Successfully restore Federator.ai InfluxDB databases from backup '${source_backup_file}'."
        fi
        ;;
    extract)
        logging "${STDOUT}" "Start extracting backup '${source_backup_file}'."
        if ! run_restore ${source_backup_file} "extract_only"
        then
            retcode=1
            output_msg="Extract backup '${source_backup_file}' is failed!"
        else
            echo
            cat ${vars[directory]}/${vars[backup]}/${BACKUP_INFO_FILE} 2>/dev/null
            output_msg="Successfully extract backup to '${vars[directory]}/${vars[backup]}'."
        fi
        ;;
esac

echo
echo "${output_msg}"
if [ ${retcode} -eq 0 ]
then
    level=${INFO}
else
    level=${ERR}
fi
logging "${level}" "${output_msg}"

final_report
exit ${retcode}
