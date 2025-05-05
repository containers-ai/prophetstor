#!/usr/bin/env bash

show_usage()
{
    cat << __EOF__

    Usage:
        Scenario:
        i.  Backup
            [Requirement]:
            --backup
            --url <Rest API URL>                             [e.g., --url https://172.31.2.49:31011]
            --path <Backup folder path to store backup file> [e.g., --path /opt/backup]
            --annotation "<Backup annotation>"               [e.g., --annotation "annotation inside double quotes"]

            [Optional]:
            --cluster-identifier "<Identify>"
            [e.g., --cluster-identifier "identifier inside double quotes"]
            --encryption-key "<key>"
            [e.g., --encryption-key "mySecurePhrase"]

        ii. Restore
            [Requirement]:
            --restore
            --url <Rest API URL>                             [e.g., --url https://172.31.2.49:31011]
            --path <Restore file absolute path>
            [e.g., --path /opt/backup/f8ai-172.31.2.49-2022-03-30-08-55-33-766596203-5.1.0.bak]

            [Optional]:
            --encryption-key "<key>"
            [e.g., --encryption-key "mySecurePhrase"]

        [Optional]:
        --verbose
        # If user/password info isn't provided, program will run into interactive mode
        --user <account to login into REST API>              [e.g., --user admin]
        --password <pw>                                      [e.g., --password password]

__EOF__
}

wait_until_job_done()
{
    job="$1"
    period="$2"
    interval="$3"
    job_id="$4"

    for ((i=0; i<$period; i+=$interval)); do
        if [ "$job" = "backup" ]; then
            exec_cmd="curl -sS -k -w \"\n%{http_code}\" -X GET \"$api_url/apis/v1/configurations/backups/$job_id/progress\" -H \"accept: application/json\" -H \"Authorization: Bearer $access_token\""
        else
            exec_cmd="curl -sS -k -w \"\n%{http_code}\" -X GET \"$api_url/apis/v1/configurations/restores/$job_id/progress\" -H \"accept: application/json\" -H \"Authorization: Bearer $access_token\""
        fi
        output=$(eval $exec_cmd)

        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Failed to get $job (id: $job_id) progress from REST API.$(tput sgr 0)"
            exit 3
        fi
        parse_output "$output"
        if [ "$rest_code" != "200" ]; then
            display_error_and_leave "Failed to get $job (id: $job_id) progress from REST API"
        fi
        progress=$(echo "$rest_output" | grep -o "\"progress\":[0-9]*"|cut -d ':' -f2)
        if [ "$progress" = "" ]; then
            echo -e "\n$(tput setaf 1)Failed to retrieve $job (id: $job_id) progress.$(tput sgr 0)"
            exit 3
        fi

        if [ "$progress" = "100" ]; then
            if [ "$job" = "backup" ]; then
                encryption_done=$(echo "$rest_output" | grep -o "\"encryption_done\":[a-z]*"|cut -d ':' -f2)
                if [ "$encryption_done" != "true" ]; then
                    echo "Encryption not done yet. Waiting for $job to be ready..."
                    sleep "$interval"
                    continue
                fi
                echo -e "$job (id: $job_id) is done."
                # Get file path
                backup_file_name=$(echo "$rest_output"|grep -o "\"file_path\":\"[^\"]*\""|cut -d ':' -f2|sed 's/"//g'|awk -F'/' '{print $NF}')
                if [ "$backup_file_name" = "" ]; then
                    err_code="13"
                    echo -e "\n$(tput setaf 1)Failed to retrieve backup file name.$(tput sgr 0)"
                    exit 3
                fi
            fi
            return 0
        fi
        echo "Waiting for $job to be ready..."
        sleep "$interval"
    done
    echo -e "\n$(tput setaf 1)Error! Waited for $period seconds, but $job (id: $job_id) is not ready yet.$(tput sgr 0)"
    exit 31
}

prepare_folder(){
    # Prepare external backup folder
    if [ ! -d "$specific_path" ]; then
        mkdir -p $specific_path
        if [ "$?" != 0 ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to create backup folder ($specific_path).$(tput sgr 0)"
            exit 3
        fi
    fi
}

parse_output(){
    out="$1"
    rest_code=$(echo "$out"|tail -1)
    rest_output=$(echo "$out"|sed '$d')
}

display_error_and_leave(){
    msg="$1"
    echo -e "\n$(tput setaf 1)${msg}. Return code = $rest_code$(tput sgr 0)"
    if [ "$verbose" = "y" ]; then
        echo -e "$rest_output"
    fi
    exit 3
}

get_login_token(){
    auth_string="${login_account}:${login_password}"
    auth_cipher=$(echo -n "$auth_string"|base64)
    if [ "$auth_cipher" = "" ]; then
        echo -e "\n$(tput setaf 1)Failed to encode login string using base64 command.$(tput sgr 0)"
        exit 3
    fi

    output=$(curl -sS -k -w "\n%{http_code}" -X POST "$api_url/apis/v1/users/login" -H "accept: application/json" -H "authorization: Basic ${auth_cipher}")
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Failed to login to REST API.$(tput sgr 0)"
        exit 3
    fi
    parse_output "$output"
    if [ "$rest_code" != "200" ]; then
        display_error_and_leave "Failed to login to REST API"
    fi
    access_token="$(echo $rest_output|tr -d '\n'|grep -o "\"accessToken\":[^\"]*\"[^\"]*\""|sed -E 's/".*".*"(.*)"/\1/')"
    if [ "$access_token" = "null" ] || [ "$access_token" = "" ]; then
        echo -e "\n$(tput setaf 1)Failed to get access token.$(tput sgr 0)"
        exit 3
    fi
}

backup(){
    prepare_folder
    get_login_token

    #
    # Trigger backup job
    #
    echo "Starting backup job..."
    exec_cmd="curl -sS -k -w \"\n%{http_code}\" -X PUT \"$api_url/apis/v1/configurations/backups\" -H \"accept: application/json\" -H \"Authorization: Bearer $access_token\" -H \"Content-Type: application/json\" -d \"{\\\"annotation\\\": \\\"$annotation\\\", \\\"cluster_identifier\\\": \\\"$cluster_identifier\\\", \\\"username\\\": \\\"$login_account\\\", \\\"enable_encryption\\\": $enable_encryption, \\\"encryption_key\\\": \\\"$encryption_key\\\"}\""
    output=$(eval $exec_cmd)
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Failed to trigger backup job(Command: $exec_cmd)$(tput sgr 0)"
        exit 3
    fi
    parse_output "$output"
    if [ "$rest_code" != "200" ]; then
        display_error_and_leave "Failed to trigger backup job(Command: $exec_cmd)"
    fi

    backup_series_id=$(echo "$rest_output"|grep -o "backup-series-id\":\"[^\"]*\""|cut -d ':' -f2|sed 's/"//g')
    if [ "$backup_series_id" = "" ]; then
        echo -e "\n$(tput setaf 1)Failed to retrieve backup series id.$(tput sgr 0)"
        exit 3
    fi

    wait_until_job_done "backup" $max_wait_time 10 "$backup_series_id"

    #
    # Download backup file
    #
    cd $specific_path
    exec_cmd="curl -sS -k -w \"\n%{http_code}\" -X GET \"$api_url/apis/v1/configurations/backups/$backup_series_id/file\" -H \"accept: application/json\" -H \"Authorization: Bearer $access_token\" -o $backup_file_name"
    output=$(eval $exec_cmd)
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error, Failed to download backup (id: $backup_series_id) file.$(tput sgr 0)"
        cd - > /dev/null
        exit 3
    fi
    cd - > /dev/null
    parse_output "$output"
    if [ "$rest_code" != "200" ]; then
        display_error_and_leave "Failed to download backup (id: $backup_series_id) file"
    fi
    if [ "$enable_encryption" = "false" ]; then
        # No encryption, backup file will have check feature.
        sh $specific_path/$backup_file_name --check >/dev/null 2>&1
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error, MD5 checksum verification is failed (file: $specific_path/$backup_file_name).$(tput sgr 0)"
            exit 3
        fi
    fi
    echo -e "\n$(tput setaf 6)Backup Federator.ai successfully. (File: $specific_path/$backup_file_name)$(tput sgr 0)"
}

restore(){
    get_login_token
    echo "Starting restore job..."
    file_name=$(echo $specific_path|awk -F'/' '{print $NF}')

    # No encryption, backup file will have check feature.
    if [ "$enable_encryption" = "false" ]; then
        sh $specific_path --check >/dev/null 2>&1
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error, MD5 checksum verification is failed (file: $specific_path).$(tput sgr 0)"
            exit 3
        fi
    fi
    #
    # Upload backup file
    #
    exec_cmd="curl -sS -k -w \"\n%{http_code}\" -X POST \"$api_url/apis/v1/configurations/restores\" -H \"accept: application/json\" -H \"Authorization: Bearer $access_token\" -H \"Content-Type: multipart/form-data\" -F \"file=@$specific_path\" -F \"enable_encryption=$enable_encryption\" -F \"encryption_key=$encryption_key\""
    output=$(eval $exec_cmd)
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error, Failed to upload backup file ($specific_path).$(tput sgr 0)"
        exit 3
    fi
    parse_output "$output"
    if [ "$rest_code" != "200" ]; then
        display_error_and_leave "Failed to upload backup file ($specific_path)"
    fi
    #
    # Trigger restore
    #
    exec_cmd="curl -sS -k -w \"\n%{http_code}\" -X PUT \"$api_url/apis/v1/configurations/restores\" -H \"accept: application/json\" -H \"Authorization: Bearer $access_token\" -H \"Content-Type: application/json\" -d \"{\\\"file_name\\\": \\\"$file_name\\\"}\""
    output=$(eval $exec_cmd)
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error, Failed to trigger restore job.$(tput sgr 0)"
        exit 3
    fi
    parse_output "$output"
    if [ "$rest_code" != "200" ]; then
        display_error_and_leave "Failed to trigger restore job"
    fi
    restore_series_id=$(echo "$rest_output"|grep -o "\"restore-series-id\":\"[^\"]*\""|cut -d ':' -f2|sed 's/"//g')
    if [ "$restore_series_id" = "" ]; then
        echo -e "\n$(tput setaf 1)Failed to retrieve restore series id.$(tput sgr 0)"
        exit 3
    fi

    echo "Waiting for REST API response..."
    sleep 30
    response="n"
    for i in `seq 1 29`
    do
        token=$(curl -sS -k -X POST "$api_url/apis/v1/users/login" -H "accept: application/json" -H "authorization: Basic ${auth_cipher}"|tr -d '\n'|grep -o "\"accessToken\":[^\"]*\"[^\"]*\""|sed -E 's/".*".*"(.*)"/\1/')
        if [ "$token" != "" ]; then
            response="y"
            break
        fi
        echo "Waiting for REST API respond..."
        sleep 30
    done
    if [ "$response" = "n" ]; then
        echo -e "\n$(tput setaf 1)Error! Waited for 900 seconds, but REST API is not ready yet.$(tput sgr 0)"
        exit 3
    else
        echo "Done."
    fi

    wait_until_job_done "restore" $max_wait_time 10 "$restore_series_id"
    echo -e "\n$(tput setaf 6)Restore Federator.ai successfully.$(tput sgr 0)"
}

type curl > /dev/null 2>&1
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)curl command is needed for this tool.$(tput sgr 0)"
    exit 3
fi

type base64 > /dev/null 2>&1
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)base64 command is needed for this tool.$(tput sgr 0)"
    exit 3
fi

type awk > /dev/null 2>&1
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)awk command is needed for this tool.$(tput sgr 0)"
    exit 3
fi

type sed > /dev/null 2>&1
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)sed command is needed for this tool.$(tput sgr 0)"
    exit 3
fi

while getopts "h-:" o; do
    case "${o}" in
        -)
            case "${OPTARG}" in
                url)
                    api_url="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$api_url" = "" ]; then
                        echo -e "\n$(tput setaf 1)Missing --${OPTARG} value.$(tput sgr 0)"
                        show_usage
                        exit 3
                    fi
                    ;;
                user)
                    login_account="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$login_account" = "" ]; then
                        echo -e "\n$(tput setaf 1)Missing --${OPTARG} value.$(tput sgr 0)"
                        show_usage
                        exit 3
                    fi
                    ;;
                password)
                    login_password="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$login_password" = "" ]; then
                        echo -e "\n$(tput setaf 1)Missing --${OPTARG} value.$(tput sgr 0)"
                        show_usage
                        exit 3
                    fi
                    ;;
                encryption-key)
                    encryption_key="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$encryption_key" = "" ]; then
                        echo -e "\n$(tput setaf 1)Missing --${OPTARG} value.$(tput sgr 0)"
                        show_usage
                        exit 3
                    fi
                    ;;
                annotation)
                    annotation="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$annotation" = "" ]; then
                        echo -e "\n$(tput setaf 1)Missing --${OPTARG} value.$(tput sgr 0)"
                        show_usage
                        exit 3
                    fi
                    ;;
                cluster-identifier)
                    cluster_identifier="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$cluster_identifier" = "" ]; then
                        echo -e "\n$(tput setaf 1)Missing --${OPTARG} value.$(tput sgr 0)"
                        show_usage
                        exit 3
                    fi
                    ;;
                path)
                    specific_path="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$specific_path" = "" ]; then
                        echo -e "\n$(tput setaf 1)Missing --${OPTARG} value.$(tput sgr 0)"
                        show_usage
                        exit 3
                    fi
                    ;;
                verbose)
                    verbose="y"
                    ;;
                backup)
                    do_backup="y"
                    ;;
                restore)
                    do_restore="y"
                    ;;
                help)
                    show_usage
                    exit 0
                    ;;
                *)
                    echo -e "\n$(tput setaf 1)Unknown option --${OPTARG}.$(tput sgr 0)"
                    show_usage
                    exit 3
                    ;;
            esac;;
        h)
            show_usage
            exit 0
            ;;
        *)
            echo -e "\n$(tput setaf 1)Wrong parameter.$(tput sgr 0)"
            show_usage
            exit 3
            ;;
    esac
done

[ "$max_wait_time" = "" ] && max_wait_time=600

if [ "$do_backup" != "y" ] && [ "$do_restore" != "y" ]; then
    echo -e "\n$(tput setaf 1)Error, Please specify the job you want to run (backup/restore).$(tput sgr 0)"
    show_usage
    exit 3
fi

if [ "$do_backup" = "y" ] && [ "$do_restore" = "y" ]; then
    echo -e "\n$(tput setaf 1)Error, Backup and restore can't be run at the same time.$(tput sgr 0)"
    exit 3
fi

if [ "$do_backup" = "y" ]; then
    if [ "$specific_path" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Please specify backup target folder.$(tput sgr 0)"
        show_usage
        exit 1
    fi

    if [ "$annotation" = "" ]; then
        echo -e "\n$(tput setaf 1)Error, Missing annotation info.$(tput sgr 0)"
        show_usage
        exit 3
    fi
fi

if [ "$do_restore" = "y" ]; then
    if [ ! -f "$specific_path" ]; then
      echo -e "\n$(tput setaf 1)Error! Restore file doesn't exist.$(tput sgr 0)"
      exit 1
    fi
fi

if [ "$api_url" = "" ]; then
    echo -e "\n$(tput setaf 1)Error, Missing REST API info.$(tput sgr 0)"
    show_usage
    exit 3
fi

if [ "$cluster_identifier" = "" ]; then
    if [[ $api_url =~ ^http[s]?://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
        # http://ip:port, parse cluster_identifier
        cluster_identifier=$(echo $api_url|cut -d '/' -f3|cut -d ':' -f1)
    else
        # e.g. federatorai-rest-federatorai.apps.ocp4.172-31-7-16.nip.io
        cluster_identifier=$(echo $api_url|cut -d '.' -f2-)
    fi
    if [ "$cluster_identifier" = "" ]; then
        echo -e "\n$(tput setaf 1)Failed to parse cluster identifier. Please specify it through parameter (--cluster-identifier)$(tput sgr 0)"
        exit 3
    fi
fi

if [ "$login_account" = "" ]; then
    read -r -p "$(tput setaf 2)Please enter the REST API login account: $(tput sgr 0) " login_account </dev/tty
fi

if [ "$login_password" = "" ]; then
    read -s -p "$(tput setaf 2)Please enter the REST API login password: $(tput sgr 0) " login_password </dev/tty
    echo
fi

if [ "$encryption_key" = "" ]; then
    enable_encryption="false"
else
    enable_encryption="true"
fi

if [ "$do_backup" = "y" ]; then
    backup
fi

if [ "$do_restore" = "y" ]; then
    restore
fi
