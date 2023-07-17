#!/bin/bash

read -p "Enter your URL [https://s4.sandbox.prophetstor.com]: " URL
read -p "Enter your cluster name [jean3-61]: " CLUSTER

URL=${URL:-https://s4.sandbox.prophetstor.com}
CLUSTER=${CLUSTER:-jean3-61}
METRICS_URL="${URL}/series_postgres/getMetricsConfig"
SERIES_URL="${URL}/series_datahub/getSeries"
HEADER="Content-Type: application/json"
MILLICORES_A_CORE=1000
FIFTEEN_MINS=900
NOW=$(date +"%s")
FIFTEEN_MINS_AGO=$((NOW-FIFTEEN_MINS))
declare -A DATASOURCE_MAP
DATASOURCE_MAP[prometheus]=1
DATASOURCE_MAP[datadog]=2
DATASOURCE_MAP[sysdig]=3
DATASOURCE_MAP[vmware]=10
DATASOURCE_MAP[aws]=9

concat_array=()
i=0
declare -A lookup_table
declare -A node_meta
clusterDatasource=""
nodeCpuID=""
nodeMemID=""
nodeDiskCapID=""
nodeDiskIOID=""
nodeTXID=""
nodeRXID=""

function getClusterMeta(){
    echo "Fetching cluster datasource"
    results=$(curl -sS -k -X POST "$SERIES_URL" \
    -H "$HEADER" \
    --data '{
        "queries":[
            {
                "key":"readClusters",
                "datahub_method":"readResourceMeta",
                "request_body":{
                    "query_condition":{
                        "where_condition":[
                            {
                                "keys":[ "global_config", "cluster_name"],
                                "values":["false", '\"${CLUSTER}\"'],
                                "operators":[ "=", "="]
                            }
                        ]
                    }
                }
            }
        ]
    }')

    clusterDatasource=$(echo $results | jq '.results[0].values[0].data_source' --raw-output)
    echo "Fetching cluster datasource is completed"
}

function getNodeMetaByCluster() {
    echo "Fetching node metadata"
    results=$(curl -sS -k -X POST "$SERIES_URL" \
    -H "$HEADER" \
    --data '{
        "queries":[
            {
                "key":"readNodes",
                "datahub_method":"readResourceMeta",
                "request_body":{
                    "query_condition":{
                        "where_condition":[
                            {
                                "keys":["cluster_name"],
                                "values":['\"${CLUSTER}\"'],
                                "operators":["="]
                            }
                        ]
                    }
                }
            }
        ]
    }')

    series=$(echo $results | jq '.results[0].values')
    for s in $(echo "${series}" | jq -c '.[]')
    do
        mem_bytes=$(echo $s | jq '.memory_bytes' --raw-output)
        cpu_cores=$(echo $s | jq '.cpu_cores' --raw-output)
        name=$(echo $s | jq '.node_name' --raw-output)
        node_meta[$name]="${cpu_cores},${mem_bytes}"
    done
    #echo "${node_meta[@]}"
    echo "Fetching node metadata is completed"
}

function getMetricsConfig() {
    echo "Fetching metric config id."
    metricRes=$(curl -sS -k -X POST "$METRICS_URL" \
    -H "$HEADER" \
    --data '{
        "queries": [
            {
                "key": "getBuiltinMetricConfigs",
                "method": "get_builtin_metric_configs",
                "isPostgres": true
            }
        ]
    }')

    nodeCpuID=$(echo $metricRes | jq ".results[0].values.builtin_metric_configs_operation_type.node_cpu_operationType_${DATASOURCE_MAP[$clusterDatasource]}.builtin_metric_config_id" --raw-output)
    nodeMemID=$(echo $metricRes | jq ".results[0].values.builtin_metric_configs_operation_type.node_memory_operationType_${DATASOURCE_MAP[$clusterDatasource]}.builtin_metric_config_id" --raw-output)
    nodeDiskCapID=$(echo $metricRes | jq ".results[0].values.builtin_metric_configs_operation_type.node_fs_bytes_usage_pct_operationType_${DATASOURCE_MAP[$clusterDatasource]}.builtin_metric_config_id" --raw-output)
    nodeDiskIOID=$(echo $metricRes | jq ".results[0].values.builtin_metric_configs_operation_type.node_disk_io_util_operationType_${DATASOURCE_MAP[$clusterDatasource]}.builtin_metric_config_id" --raw-output)
    nodeTXID=$(echo $metricRes | jq ".results[0].values.builtin_metric_configs_operation_type.node_network_transmit_bytes_operationType_${DATASOURCE_MAP[$clusterDatasource]}.builtin_metric_config_id" --raw-output)
    nodeRXID=$(echo $metricRes | jq ".results[0].values.builtin_metric_configs_operation_type.node_network_receive_bytes_operationType_${DATASOURCE_MAP[$clusterDatasource]}.builtin_metric_config_id" --raw-output)
    echo "Fetching metric config id is completed."
}

function getResponseByID() {
    # $1 means metric config id.
    results=$(curl -sS -k -X POST "$SERIES_URL" \
    -H "$HEADER" \
    --data '{
        "queries": [
            {
                "key": "readNodeMetrics",
                "datahub_method": "readNodeMetrics",
                "request_body": {
                    "read_metrics": [
                        {
                            "granularity": "60",
                            "purpose": "0",
                            "metric_config_id":'\"${1}\"',
                            "query_condition": {
                                "time_range": {
                                    "start_time": {
                                        "seconds": '\"${FIFTEEN_MINS_AGO}\"'
                                    },
                                    "end_time": {
                                        "seconds": '\"${NOW}\"'
                                    }
                                },
                                "where_condition": [
                                    {
                                        "keys": [
                                            "cluster_name"
                                        ],
                                        "values": [
                                            '\"${CLUSTER}\"'
                                        ],
                                        "operators": [
                                            "="
                                        ]
                                    }
                                ],
                                "groups": [
                                    "node_name"
                                ]
                            }
                        }
                    ]
                }
            }
        ]
    }')
    echo $results
}

function formatBytes() {
    SUFFIX=('KiB' 'MiB' 'GiB' 'TiB' 'PiB' 'EiB' 'ZiB' 'YiB')
    base=1024
    counter=0
    value=$1
    quotient_int=$(echo "result = ($value/$base); scale=0; result / 1" | bc -l)
    quotient_float=$(echo "result = ($value/$base); scale=2; result / 1" | bc -l)

    while [[ "$quotient_int" -ge 1024 ]]
    do
        ((counter++))
        quotient_int=$(echo "result = ($quotient_int/$base); scale=0; result / 1" | bc -l)
        quotient_float=$(echo "result = ($quotient_float/$base); scale=2; result / 1" | bc -l)
    done

    echo "$quotient_float ${SUFFIX[$counter]}"
}

function writeCSV() {
    echo "Writing data to CSV file"
    HEADER_COLS="Node Name,Disk Capacity,Disk IO Utilization,Network Transmit Bytes,Network Receive Bytes, CPU Utilization, Memory Utilization"
    echo $HEADER_COLS > node_util.csv
    rows=("${!1}")
    for row in "${rows[@]}"
    do
        echo $row >> node_util.csv
    done
    echo "Writing data to CSV file is completed."
}

function all_checks() {
    echo "Fetching metric util."
    ids=($nodeDiskCapID $nodeDiskIOID $nodeTXID $nodeRXID $nodeCpuID $nodeMemID)
    counter=0
    commas=''
    #ids=($nodeRXID)
    for id in "${ids[@]}"
    do
        ((counter++))
        result=$(getResponseByID $id)
        series=$(echo $result | jq '.results[0].series')
        series_arr=$(echo "${series}" | jq -c '.[]?')

        if [ -z "$series_arr" ];
        then
            commas+=','
            continue
        fi


        #echo $id, $CLUSTER, $FIFTEEN_MINS_AGO, $NOW
        for s in $(echo "${series}" | jq -c '.[]')
        do
            name=$(echo $s | jq '.tags.node_name' --raw-output)
            sum=$(echo $s | jq '.data[] | .value' | awk '{s+=$1} END {printf "%.0f", s}')
            num=$(echo $s | jq '.data[].value' | wc -l)
            avg=$(echo $sum/$num | bc -l)

            if [[ $counter -eq 3 ]] || [[ $counter -eq 4 ]] #network tx/rx
            then
                avg=$(formatBytes $avg)
            elif [[ $counter -eq 5 ]] #cpu
            then
                target="${node_meta[$name]}"
                IFS=',' read total_cpu total_mem <<< "${target}"
                total=$((total_cpu))
                total=$((total*MILLICORES_A_CORE))
                #sum=$(echo $s | jq --arg total $total'.data[] | .value / $total' | awk '{s+=$1} END {printf "%.0f", s}')
                avg=$(echo $sum/$total/$num*100 | bc -l) ## *100 means to PCT. e.g, 0.47872 to 47.872
                avg=$(echo "scale=2; $avg/1" | bc -l) ## 47.87
                avg="$avg%"
            elif [[ $counter -eq 6 ]] #mem
            then
                target="${node_meta[$name]}"
                IFS=',' read total_cpu total_mem <<< "${target}"
                total=$((total_mem))
                #sum=$(echo $s | jq --arg total $total'.data[] | .value / $total' | awk '{s+=$1} END {printf "%.0f", s}')
                avg=$(echo $sum/$total/$num*100 | bc -l) # *100 means to PCT. e.g., 0.01375 to 1.375
                avg=$(echo "scale=2; $avg/1" | bc -l) # 1.38
                avg="$avg%"
            else #disk cap./io
                avg=$(echo "scale=2; $avg/1" | bc -l)
                avg="$avg%"
            fi

            if [[ " ${concat_array[*]} " == *"${name}"* ]];
            then
                idx=lookup_table[$name]
                concat_array[$idx]+="${commas},${avg}"
                #echo "Included"
            else
                concat_array[$i]="$name${commas},${avg}"
                lookup_table[$name]=$i
                i=$(($i + 1))
                #echo "Not Included"
            fi
            commas=""
            #echo $name, $sum, $avg, $num
        done
    done
    echo "Fetching metric util is completed."
}

getClusterMeta
getNodeMetaByCluster
getMetricsConfig
all_checks
writeCSV concat_array[@]