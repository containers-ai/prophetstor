#!/usr/bin/env bash

#################################################################################################################
#
#   This script is created for demo purpose.
#   Usage:
#       [-d] # Specify datahub address
#       [-h] # Display script usage
#
#################################################################################################################

show_usage()
{
    cat << __EOF__
    
    Usage:
        [-a] # Specify cluster name
        [-c] # Specify time range count
        [-u] # Specify monitor preload data time range unity "hour/day/month"
        [-d] # Specify datahub address
        [-h] # Display script usage

__EOF__
    exit 1
}

clean_database()
{
    bash ./preloader-util.sh -d -c 2> /dev/null
    if [ "$?" != "0" ];then
        echo "Failed to clean database"
        exit 1
    fi
}

enable_preloader()
{
    bash ./preloader-util.sh -p -e -a $cluster_name 2> /dev/null
    if [ "$?" != "0" ];then
        echo "Failed to enable preloader"
        exit 1
    fi
}

trigger_preloader()
{
    bash ./preloader-util.sh -o -a $cluster_name 2> /dev/null
    if [ "$?" != "0" ];then
        echo "Failed to trigger preloader load data"
        exit 1
    fi
}

get_preloader_time_range()
{
    current_preloader_pod_name="`kubectl get pods -n $install_namespace |grep "federatorai-agent-preloader-"|awk '{print $1}'|head -1`"
    echo "current_preloader_pod_name = $current_preloader_pod_name"

    startTime=`kubectl logs $current_preloader_pod_name -n federatorai | grep "Preloader start timestamp:" | cut -d":" -f 4 | cut -d" " -f 2 | cut -d "," -f 1`
    endTime=`kubectl logs $current_preloader_pod_name -n federatorai | grep "Preloader start timestamp:" | cut -d":" -f 5 | cut -d" " -f 2`

    if [ "$startTime" == "" ] || [ "$endTime" == "" ]; then
        echo "Failed to get preloader load data time range"
        exit 1
    fi
    echo "Get preloader time range $startTime - $endTime"
}

patch_alamedaservice()
{
    echo "Patch alameda servcie $1 $2"
    cat patch_preloader | sed 's/$COUNT/'$1'/g' | sed 's/$UNIT/'$2'/g' > patch_context
    kubectl -n federatorai patch alamedaservice my-alamedaservice  --type merge --patch "`cat patch_context`" 2> /dev/null
    if [ "$?" != "0" ];then
        echo "Failed to patch alameda service"
        exit 1
    fi
}

query_database()
{
    echo "List controller metrics"
    echo "federatorai-dataclient listmetrics --db-address="$datahub_address" --type=controller --metric-type=cpu --start-time=$startTime --end-time=$endTime"
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=controller --metric-type=cpu --start-time=$startTime --end-time=$endTime
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=controller --metric-type=memory --start-time=$startTime --end-time=$endTime

    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=controller --metric-type=cpu --start-time=$startTime --end-time=$endTime --granularity=3600
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=controller --metric-type=memory --start-time=$startTime --end-time=$endTime --granularity=3600

    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=controller --metric-type=cpu --start-time=$startTime --end-time=$endTime --granularity=21600
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=controller --metric-type=memory --start-time=$startTime --end-time=$endTime --granularity=21600

    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=controller --metric-type=cpu --start-time=$startTime --end-time=$endTime --granularity=86400
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=controller --metric-type=memory --start-time=$startTime --end-time=$endTime --granularity=86400

    echo "List namespace metrics"
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=namespace --metric-type=cpu --start-time=$startTime --end-time=$endTime
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=namespace --metric-type=memory --start-time=$startTime --end-time=$endTime

    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=namespace --metric-type=cpu --start-time=$startTime --end-time=$endTime --granularity=3600
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=namespace --metric-type=memory --start-time=$startTime --end-time=$endTime --granularity=3600

    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=namespace --metric-type=cpu --start-time=$startTime --end-time=$endTime --granularity=21600
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=namespace --metric-type=memory --start-time=$startTime --end-time=$endTime --granularity=21600

    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=namespace --metric-type=cpu --start-time=$startTime --end-time=$endTime --granularity=86400
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=namespace --metric-type=memory --start-time=$startTime --end-time=$endTime --granularity=86400

    echo "List application metrics"
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=application --metric-type=cpu --start-time=$startTime --end-time=$endTime
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=application --metric-type=memory --start-time=$startTime --end-time=$endTime

    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=application --metric-type=cpu --start-time=$startTime --end-time=$endTime --granularity=3600
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=application --metric-type=memory --start-time=$startTime --end-time=$endTime --granularity=3600

    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=application --metric-type=cpu --start-time=$startTime --end-time=$endTime --granularity=21600
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=application --metric-type=memory --start-time=$startTime --end-time=$endTime --granularity=21600

    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=application --metric-type=cpu --start-time=$startTime --end-time=$endTime --granularity=86400
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=application --metric-type=memory --start-time=$startTime --end-time=$endTime --granularity=86400

    echo "List node metrics"
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=node --metric-type=cpu --start-time=$startTime --end-time=$endTime
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=node --metric-type=memory --start-time=$startTime --end-time=$endTime

    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=node --metric-type=cpu --start-time=$startTime --end-time=$endTime --granularity=3600
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=node --metric-type=memory --start-time=$startTime --end-time=$endTime --granularity=3600

    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=node --metric-type=cpu --start-time=$startTime --end-time=$endTime --granularity=21600
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=node --metric-type=memory --start-time=$startTime --end-time=$endTime --granularity=21600

    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=node --metric-type=cpu --start-time=$startTime --end-time=$endTime --granularity=86400
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=node --metric-type=memory --start-time=$startTime --end-time=$endTime --granularity=86400

    echo "List cluster metrics"
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=cluster --metric-type=cpu --start-time=$startTime --end-time=$endTime
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=cluster --metric-type=memory --start-time=$startTime --end-time=$endTime

    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=cluster --metric-type=cpu --start-time=$startTime --end-time=$endTime --granularity=3600
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=cluster --metric-type=memory --start-time=$startTime --end-time=$endTime --granularity=3600

    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=cluster --metric-type=cpu --start-time=$startTime --end-time=$endTime --granularity=21600
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=cluster --metric-type=memory --start-time=$startTime --end-time=$endTime --granularity=21600

    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=cluster --metric-type=cpu --start-time=$startTime --end-time=$endTime --granularity=86400
    ./federatorai-dataclient listmetrics --db-address="$datahub_address" --type=cluster --metric-type=memory --start-time=$startTime --end-time=$endTime --granularity=86400
}

on_exit()
{
    ret=$?
    [ "${pid_helper}" != "" ] && kill ${pid_helper} 2> /dev/null
    trap - EXIT # Disable exit handler
    exit ${ret}
}

trap on_exit EXIT INT

if [ "$#" -eq "0" ]; then
    show_usage
    exit
fi

while getopts "a:c:u:d:h" o; do
    case "${o}" in
        a)
            cluster_name=${OPTARG}
            ;;
        c)
            monitor_time_range_count=${OPTARG}
            ;;
        u)
            monitor_time_range_unit=${OPTARG}
            ;;
        d)
            datahub_address=${OPTARG}
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

install_namespace="`kubectl get pods --all-namespaces |grep "alameda-datahub-"|awk '{print $1}'|head -1`"

if [ "$install_namespace" = "" ];then
    echo -e "\n$(tput setaf 1)Error! Please Install Federatorai before running this script.$(tput sgr 0)"
    exit 3
fi

if [ "$datahub_address" = "" ]; then
    echo -e "\n$(tput setaf 1)Error! Please specify datahub address.$(tput sgr0)"
fi

# Clean database
echo "Start to clean database measurement"
clean_database

echo "\n$(tput setaf 10)Patch alameda service count: $monitor_time_range_count, unit: $monitor_time_range_unit, cluster name: $cluster_name$(tput sgr 0)"
patch_alamedaservice $monitor_time_range_count $monitor_time_range_unit

echo "Trigger monitory memory usage"
bash ./monitor_top.sh $monitor_time_range_count $monitor_time_range_unit 2>&1 &
pid_helper=$!

echo "Enable preloader"
enable_preloader

echo "Trigger preloader preload data"
trigger_preloader
kubectl top pod alameda-influxdb-0 -n federatorai | while read name cpu memory junk; do echo `date +%s` $name $cpu $memory; done | echo "`grep -v NAME` *" >> "monitor_$(monitor_time_range_count)_$(monitor_time_range_unit).csv"

echo "Trigger database query"
get_preloader_time_range
query_database

sleep 1h

