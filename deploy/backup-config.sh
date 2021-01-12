#!/usr/bin/env bash
set -e

TEMP_DIR=`mktemp -d`
function on::exit(){
  local ret=$?
  rm -rf $TEMP_DIR
  trap - EXIT
  exit $ret
}

trap on::exit EXIT

TEMP_CFG_DIR=$TEMP_DIR/configs
mkdir -p $TEMP_CFG_DIR
#tab=$(printf '\t')
tab="  "

function is::line::skip(){
  if echo $1 | grep -q "^${tab}- apiVersion:\|^${tab}  blockOwnerDeletion:\|^${tab}  controller:\|^${tab}  kind:\|^${tab}  name:\|^${tab}  uid:"; then
    return 0
  fi
  if echo $1 | grep -q "^${tab}generation:\|^${tab}creationTimestamp:\|^${tab}ownerReferences:\|^${tab}resourceVersion:\|^${tab}selfLink:\|^${tab}uid:"; then
    return 0
  fi
  return 1
}

function backup::ns::cr(){
  for nsres in $(kubectl api-resources --namespaced=true | grep \\.containers\\.ai | awk '{print $1}'); do
    if [ "$nsres" == "alamedarecommendations" ]; then
      continue
    fi
    kubectl get $nsres --all-namespaces --sort-by=.metadata.creationTimestamp -o=jsonpath="{range .items[*]}kubectl -n {.metadata.namespace} get $nsres {.metadata.name} {'\n'}{end}" | while IFS= read -r cmd ; do
      ns=$(eval "${cmd} -ojsonpath={.metadata.namespace}")
      name=$(eval "${cmd} -ojsonpath={.metadata.name}")
      opfile=$TEMP_CFG_DIR/${nsres}_${ns}_${name}.yaml
      if [ "$nsres" == "alamedaservices" ]; then
        opfile=$TEMP_DIR/${nsres}_${ns}_${name}.yaml
      fi
      echo "" > $opfile

      IFS=''
      eval "${cmd} -oyaml" | while IFS=$'\t' read -r line ; do
        if echo "$line" | grep -q "^status:"; then
          break
        fi
        if is::line::skip "$line"; then
          continue
        fi
        echo $line >> $opfile
      done

      # only backup oldest service
      if [ "$nsres" == "alamedaservices" ]; then
        break
      fi
    done
  done
}

function backup::cr(){
  for res in $(kubectl api-resources --namespaced=false | grep \\.containers\\.ai | awk '{print $1}'); do
    kubectl get $res --sort-by=.metadata.creationTimestamp -o=jsonpath="{range .items[*]}kubectl get $res {.metadata.name} {'\n'}{end}" | while IFS= read -r cmd ; do
      name=$(eval "${cmd} -ojsonpath={.metadata.name}")
      opfile=$TEMP_CFG_DIR/${res}_${name}.yaml
      echo "" > $opfile

      IFS=''
      eval "${cmd} -oyaml" | while IFS=$'\t' read -r line ; do
        if echo "$line" | grep -q "^status:"; then
          break
        fi
        if is::line::skip "$line"; then
          continue
        fi
        echo $line >> $opfile
      done
    done
  done
}

backup::ns::cr
backup::cr

BACKUP_DIR=/tmp/federatorai-backup-$(date +%s)
mv $TEMP_DIR $BACKUP_DIR
echo "backup yamls saved to folder $BACKUP_DIR"