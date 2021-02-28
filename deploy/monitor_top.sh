#!/usr/bin/env bash

rm -rf monitory.csv
while true
do
    kubectl top pod alameda-influxdb-0 -n federatorai | while read name cpu memory junk; do echo `date +%s` $name $cpu $memory; done | grep -v NAME >> monitor_$1_$2.csv
    sleep 5m
done
