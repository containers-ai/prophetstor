#!/usr/bin/env bash
set -e

function number::of::spaces() {
  echo "$1" | tr -cd ' ' | wc -c
}

function neat::yaml() {
  #tab=$(printf '\t')
  local tab="  "

  local status="^status:"
  local ownerrefs="^${tab}ownerReferences:"
  local generation="^${tab}generation:"
  local managedfields="^${tab}managedFields:"
  local creattimestamp="^${tab}creationTimestamp:"
  local resourcever="^${tab}resourceVersion:"
  local selflink="^${tab}selfLink:"
  local uid="^${tab}uid:"
  local rmfields="$status\|$ownerrefs\|$generation\|$managedfields\|$creattimestamp\|$resourcever\|$selflink\|$uid"

  local skip="false"
  local currmfield=""

  while IFS= read -r; do
    if [ "$skip" = "true" ]; then
      local chkpos=$(number::of::spaces "$currmfield")
      chkpos=$((chkpos+1))
      local chchk="$(echo "$REPLY" | cut -c$chkpos)"
      if [ "$chchk" != " " -a "$chchk" != "-" ]; then
        if ! echo "$REPLY" | grep -q "$rmfields"; then
          skip="false"
          echo "$REPLY"
        fi
        continue
      fi
    fi
    if echo "$REPLY" | grep -q "$rmfields"; then
      currmfield="$REPLY"
      skip="true"
      continue
    fi
    if [ "$skip" = "false" ]; then
      echo "$REPLY"
    fi
  done <<< "$1"
}

function download::github::assets() {
  local account="$1"
  local repo="$2"
  local tagorbranch="$3"
  local relativedir="$(echo $4 | sed 's|^/||' | sed 's|/$||')"
  local opfiles=""

  opfiles=`curl --silent https://api.github.com/repos/${account}/${repo}/contents/${relativedir}?ref=${tagorbranch} 2>&1|grep "\"name\":"|cut -d ':' -f2|cut -d '"' -f2`
  if [ "$opfiles" = "" ]; then
    echo -e "\n$(tput setaf 1)Abort, download ${relativedir} file list of ${repo} failed!!!$(tput sgr 0)"
    echo "Please check tag name and network"
    exit 1
  fi

  for file in `echo $opfiles`; do
    echo "Downloading file $file ..."
    if ! curl -sL --fail https://raw.githubusercontent.com/${account}/${repo}/${tagorbranch}/${relativedir}/${file} -O; then
      echo -e "\n$(tput setaf 1)Abort, download file failed!!!$(tput sgr 0)"
      echo "Please check tag name and network"
      exit 1
    fi
  done
}

function get::installed::ns() {
  if ! kubectl get sts --all-namespaces | grep -q "alameda-influxdb\|fedemeter-influxdb"; then
    echo "cannot find installed namespace" >&2
    return 1
  fi

  local retns=$(kubectl get sts --all-namespaces | grep "alameda-influxdb\|fedemeter-influxdb" | head -1 | awk '{print $1}')
  echo $retns
  return 0
}

function backup::ns::cr() {
  for nsres in $(kubectl api-resources --namespaced=true 2>/dev/null | grep \\.containers\\.ai | awk '{print $1}'); do
    if [ "$nsres" = "alamedarecommendations" ]; then
      continue
    fi

    # to prevent from Error "executing template: not in range, nothing to end"
    if [ "$(kubectl get $nsres --all-namespaces -o=name | wc -l)" = "0" ]; then
      continue
    fi
    kubectl get $nsres --all-namespaces --sort-by=.metadata.creationTimestamp \
      -o=jsonpath="{range .items[*]}kubectl -n {.metadata.namespace} get $nsres {.metadata.name} {'\n'}{end}" \
       | while IFS= read -r cmd ; do

      ns=$(eval "${cmd} -ojsonpath={.metadata.namespace}")
      name=$(eval "${cmd} -ojsonpath={.metadata.name}")
      opfile="$TEMP_CFG_DIR/${nsres}_${ns}_${name}.yaml"
      if [ "$nsres" = "alamedaservices" ]; then
        opfile="$TEMP_DIR/${nsres}_${ns}_${name}.yaml"
      fi

      neat::yaml "`eval ${cmd} -oyaml`" > "$opfile"
      # only backup oldest service
      if [ "$nsres" = "alamedaservices" ]; then
        break
      fi
    done
  done
}

function backup::cr() {
  for res in $(kubectl api-resources --namespaced=false 2>/dev/null | grep \\.containers\\.ai | awk '{print $1}'); do
    # to prevent from Error "executing template: not in range, nothing to end"
    if [ "$(kubectl get $res -o=name | wc -l)" = "0" ]; then
      continue
    fi
    kubectl get $res --sort-by=.metadata.creationTimestamp \
      -o=jsonpath="{range .items[*]}kubectl get $res {.metadata.name} {'\n'}{end}" | while IFS= read -r cmd ; do

      name=$(eval "${cmd} -ojsonpath={.metadata.name}")
      opfile="$TEMP_CFG_DIR/${res}_${name}.yaml"
      neat::yaml "`eval ${cmd} -oyaml`" > "$opfile"
    done
  done
}

function backup::cluster::info::cm() {
  local cns=default
  local cname=cluster-info
  if kubectl -n $cns get cm $cname | grep -q $cname; then
    neat::yaml "`kubectl -n $cns get cm $cname -oyaml`" > $TEMP_INFO_DIR/configmaps_${cns}_${cname}.yaml
  fi
}

function backup::op::deploy() {
  local opfile="$TEMP_UPSTREAM_DIR/deployments_${INSTALLED_NS}_${OP_NAME}.yaml"
  neat::yaml "`kubectl -n $INSTALLED_NS get deploy $OP_NAME -oyaml`" > "$opfile"
}

function save::to::backup::dir() {
  local backupts="$(date +%s)"
  local dirname="federatorai-backup-$backupts"
  local backdir="${USER_DEF_SAVED_DIR:-/tmp}/$dirname"
  local opfile="$TEMP_UPSTREAM_DIR/deployments_${INSTALLED_NS}_${OP_NAME}.yaml"

  cat > $TEMP_DIR/info.txt << EOF
version: $(parse::image::tag "$(get::op::image::name "$opfile")")
time: $(date -d @$backupts)
script version: $SCRIPT_TAG
EOF

  mv "$TEMP_DIR" "$backdir"
  md5sum `find "$backdir" -type f` > "$backdir/md5sum.txt"
  echo "backup yamls saved to folder $backdir"
}

function backup() {
  USER_DEF_SAVED_DIR="$1"
  TEMP_DIR=`mktemp -d`
  if [ "$USER_DEF_SAVED_DIR" != "" ]; then
    TEMP_DIR=`mktemp -d -p "$USER_DEF_SAVED_DIR"`
  fi
  INSTALLED_NS="$(get::installed::ns)"
  TEMP_CFG_DIR="$TEMP_DIR/configs"
  TEMP_INFO_DIR="$TEMP_DIR/infos"
  TEMP_UPSTREAM_DIR="$TEMP_DIR/upstream"
  mkdir -p "$TEMP_CFG_DIR" "$TEMP_INFO_DIR" "$TEMP_UPSTREAM_DIR"

  cp "${BASH_SOURCE[0]}" "$TEMP_DIR"
  backup::ns::cr
  backup::cr
  backup::cluster::info::cm
  backup::op::deploy
  save::to::backup::dir
}

function get::op::image::name() {
  local opimage="$(grep "image:" "$1" | head -1)"
  echo $opimage | sed 's/image: //'
}

function get::op::ns() {
  local opns="$(grep "namespace:" "$1" | head -1)"
  echo $opns | sed 's/namespace: //'
}

function parse::image::prefix::url() {
  echo "$1" | awk -F/$(echo "$1" | awk -F/ '{print $NF}') '{print $1}'
}

function parse::image::tag() {
  echo "$1" | awk -F: '{print $2}'
}

function download::and::apply::op::upstream() {
  local opimgname="$(get::op::image::name "$OP_FILE")"
  local opns="$(get::op::ns "$OP_FILE")"
  local imgprefixurl="$(echo $(parse::image::prefix::url "$opimgname"))"
  local imagetag="$(echo $(parse::image::tag "$opimgname"))"
  local repo=prophetstor

  if echo "$imagetag" | grep "^v4.2\|^v4.3"; then
    repo=federatorai-operator
  fi
  cd "$ORIGIN_OP_UPSTREAM_DIR"
  download::github::assets containers-ai "$repo" "$imagetag" deploy/upstream
  sed -i "s/name:.*/name: ${opns}/g" 00*.yaml
  sed -i "s|\bnamespace:.*|namespace: ${opns}|g" *.yaml
  cd -

  cp "$OP_FILE" "$(grep -rl image:.*federatorai-operator "$ORIGIN_OP_UPSTREAM_DIR")"
  kubectl apply -f "$ORIGIN_OP_UPSTREAM_DIR"
}

function restore::service() {
  until kubectl apply -f "$SVC_FILE"; do
    echo "Service CRD or webhook is not ready, retrying..."
    sleep 30
  done
}

function patch::pvs() {
  for pv in $(kubectl get pv -o=jsonpath='{.items[?(@.spec.claimRef.namespace=="federatorai")].metadata.name}'); do
    kubectl patch pv $pv -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain", "claimRef": {"resourceVersion":"", "uid":""}}}'
  done
}

function restore::backup::crs() {
  until kubectl apply -f "$RESTORE_CFG_DIR"; do
    echo "CRDs or webhook is not ready, retrying..."
    sleep 30
  done
}

function restore() {
  RESTORE_DIR="$1"
  if [ "$RESTORE_DIR" = "" ]; then
    echo "Please give the restore folder"
    exit 1
  fi
  if [ ! -d "$RESTORE_DIR" ]; then
    echo "Restore folder $RESTORE_DIR is not existed"
    exit 1
  fi
  RESTORE_CFG_DIR="$RESTORE_DIR/configs"
  RESTORE_INFO_DIR="$RESTORE_DIR/infos"
  RESTORE_UPSTREAM_DIR="$RESTORE_DIR/upstream"

  ORIGIN_OP_UPSTREAM_DIR=`mktemp -d -p "$RESTORE_DIR"`

  if ! find $RESTORE_UPSTREAM_DIR | grep -q "deployments_.*_${OP_NAME}.yaml"; then
    echo "Operator deployment restore config is not found"
    exit 1
  fi
  OP_FILE=$(find $RESTORE_UPSTREAM_DIR | grep "deployments_.*_${OP_NAME}.yaml")

  if ! find $RESTORE_DIR | grep -q "alamedaservices_.*.yaml"; then
    echo "Service restore config is not found"
    exit 1
  fi
  SVC_FILE=$(find $RESTORE_DIR | grep "alamedaservices_.*.yaml")

  echo "Download origin operator upstream files and apply"
  download::and::apply::op::upstream
  echo "Restore service"
  restore::service
  echo "Patch pv if necessary"
  patch::pvs
  echo "Restore CRs"
  restore::backup::crs
  echo "Restore complete"
}

function show::usage() {
  cat << __EOF__

    Usage:
      -b,    backup, cannot use with restore(-r) at the same time
      -r,    restore, cannot use with backup(-b) at the same time
      -d,    backup or restore folder

__EOF__
  exit 1
}

function on::exit() {
  local ret=$?
  rm -rf "$TEMP_DIR" "$ORIGIN_OP_UPSTREAM_DIR"
  trap - EXIT
  exit $ret
}
trap on::exit EXIT

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  IS_BACKUP="false"
  IS_RESTORE="false"
  OP_NAME=federatorai-operator
  while getopts "d:t:br" arg; do
    case "${arg}" in
      b)
        IS_BACKUP="true"
        ;;
      r)
        IS_RESTORE="true"
        ;;
      d)
        USER_SPECIFIC_DIR=${OPTARG}
        ;;
      t)
        SCRIPT_TAG=${OPTARG}
        ;;
    esac
  done

  if [ "$IS_BACKUP" = "true" -a "$IS_RESTORE" = "true" ]; then
    show::usage
    exit 1
  fi

  if [ "$IS_BACKUP" = "true" ]; then
    backup "$USER_SPECIFIC_DIR"
  elif [ "$IS_RESTORE"="true" ]; then
    if [ "$USER_SPECIFIC_DIR" = "" ]; then
      restore "$(dirname "${BASH_SOURCE}")"
    else
      restore "$USER_SPECIFIC_DIR"
    fi
  else
    show::usage
  fi
fi