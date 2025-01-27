source env.sh
source utils.sh

export VTDATAROOT="${VTDATAROOT:-${PWD}/vtdataroot}"
mkdir -p "$VTDATAROOT/etcd"
mkdir -p "$VTDATAROOT/tmp"
mkdir -p "$VTDATAROOT/backups"

hostname=$(hostname -I | awk '{print $1}')
vtctld_web_port=15000
ETCD_SERVER="localhost:2379"
TOPOLOGY_FLAGS="--topo_implementation etcd2 --topo_global_server_address $ETCD_SERVER --topo_global_root /vitess/global"
cell="otter-zone"

alias mysql="command mysql --no-defaults -h 127.0.0.1 -P 15306 --binary-as-hex=false"
alias vtctldclient="command vtctldclient --server localhost:15999"


################### ETCD
echo "Starting etcd..."
curl "http://${ETCD_SERVER}" > /dev/null 2>&1 && fail "etcd is already running. Exiting."

etcd --data-dir "${VTDATAROOT}/etcd/"  \
     --listen-client-urls "http://${ETCD_SERVER}" \
     --advertise-client-urls "http://${ETCD_SERVER}" 2>&1 &
echo $! > "${VTDATAROOT}/tmp/etcd.pid"
sleep 3

echo "add ${cell} CellInfo"
command vtctldclient \
  AddCellInfo \
  --server internal \
  --root "/vitess/${cell}" \
  --server-address "${ETCD_SERVER}" \
  "${cell}"

echo "etcd is running!"


################### VTCTLD
grpc_port=15999

echo "Starting vtctld..."
vtctld \
 $TOPOLOGY_FLAGS \
 --cell $cell \
 --service_map 'grpc-vtctl,grpc-vtctld' \
 --backup_storage_implementation file \
 --file_backup_storage_root $VTDATAROOT/backups \
 --log_dir $VTDATAROOT/tmp \
 --port $vtctld_web_port \
 --grpc_port $grpc_port \
 --pid_file $VTDATAROOT/tmp/vtctld.pid \
 --pprof-http \
  > $VTDATAROOT/tmp/vtctld.out 2>&1 &

for _ in {0..300}; do
 curl -I "http://${hostname}:${vtctld_web_port}/debug/status" &>/dev/null && break
 sleep 0.1
done
echo -e "vtctld is running!"


################### CREATE KEYSPACE
vtctldclient CreateKeyspace \
  --durability-policy=semi_sync commerce || fail "Failed to create and configure the commerce keyspace"


for TABLET_UID in 100 101; do
  uid=$TABLET_UID
  mysql_port=$[17000 + $uid]
  printf -v alias '%s-%010d' $cell $uid
  printf -v tablet_dir 'vt_%010d' $uid

  echo "Starting MySQL for tablet $alias..."
  mysqlctl \
    --log_dir $VTDATAROOT/tmp \
    --tablet_uid $uid \
    --mysql_port $mysql_port \
    init
  echo -e "MySQL for tablet $alias is running!"
done
echo "mysqlctls are running!"

# start vttablets for keyspace commerce
for TABLET_UID in 100 101; do
  keyspace=${KEYSPACE:-'commerce'}
  shard=${SHARD:-'0'}
  uid=$TABLET_UID
  port=$[15000 + $uid]
  grpc_port=$[16000 + $uid]
  printf -v alias '%s-%010d' $cell $uid
  printf -v tablet_dir 'vt_%010d' $uid
  tablet_hostname=''
  printf -v tablet_logfile 'vttablet_%010d_querylog.txt' $uid

  tablet_type=replica
  if [[ "${uid: -1}" -gt 1 ]]; then
    tablet_type=rdonly
  fi

  echo "Starting vttablet for $alias..."
  vttablet \
    $TOPOLOGY_FLAGS \
    --log_dir $VTDATAROOT/tmp \
    --log_queries_to_file $VTDATAROOT/tmp/$tablet_logfile \
    --tablet-path $alias \
    --tablet_hostname "$tablet_hostname" \
    --init_keyspace $keyspace \
    --init_shard $shard \
    --init_tablet_type $tablet_type \
    --health_check_interval 5s \
    --backup_storage_implementation file \
    --file_backup_storage_root $VTDATAROOT/backups \
    --restore_from_backup \
    --port $port \
    --grpc_port $grpc_port \
    --service_map 'grpc-queryservice,grpc-tabletmanager,grpc-updatestream' \
    --pid_file $VTDATAROOT/$tablet_dir/vttablet.pid \
    --heartbeat_on_demand_duration=5s \
    --pprof-http \
    > $VTDATAROOT/$tablet_dir/vttablet.out 2>&1 &

   for i in $(seq 0 300); do
     curl -I "http://$hostname:$port/debug/status" >/dev/null 2>&1 && break
     sleep 0.1
   done
   echo -e "vttablet for $alias is running!"
done


################### VTORC
log_dir="${VTDATAROOT}/tmp"
vtorc_port=16000

echo "Starting vtorc..."
vtorc \
  $TOPOLOGY_FLAGS \
  --logtostderr \
  --alsologtostderr \
  --config-path="./" \
  --config-name="vtorc_config.yaml" \
  --config-type="yml" \
  --port $vtorc_port \
  > "${log_dir}/vtorc.out" 2>&1 &

vtorc_pid=$!
echo ${vtorc_pid} > "${log_dir}/vtorc.pid"

echo "\
vtorc is running!
  - UI: http://localhost:${port}
  - Logs: ${log_dir}/vtorc.out
  - PID: ${vtorc_pid}
"

#wait_for_healthy_shard commerce 0 || exit 1
wait_for_healthy_shard_primary commerce 0 || exit 1


################### CREATE TABLES
vtctldclient ApplySchema --sql-file create_commerce_schema.sql commerce || fail "Failed to apply schema for the commerce keyspace"

vtctldclient ApplyVSchema --vschema-file vschema_commerce_initial.json commerce || fail "Failed to apply vschema for the commerce keyspace"


################### VTGATE
web_port=15001
grpc_port=15991
mysql_server_port=15306
mysql_server_socket_path="/tmp/mysql.sock"

echo "Starting vtgate..."
# shellcheck disable=SC2086
vtgate \
  $TOPOLOGY_FLAGS \
  --log_dir $VTDATAROOT/tmp \
  --log_queries_to_file $VTDATAROOT/tmp/vtgate_querylog.txt \
  --port $web_port \
  --grpc_port $grpc_port \
  --mysql_server_port $mysql_server_port \
  --mysql_server_socket_path $mysql_server_socket_path \
  --cell $cell \
  --cells_to_watch $cell \
  --tablet_types_to_wait PRIMARY,REPLICA \
  --service_map 'grpc-vtgateservice' \
  --pid_file $VTDATAROOT/tmp/vtgate.pid \
  --enable_buffer \
  --mysql_auth_server_impl none \
  --pprof-http \
  > $VTDATAROOT/tmp/vtgate.out 2>&1 &

while true; do
 curl -I "http://$hostname:$web_port/debug/status" >/dev/null 2>&1 && break
 sleep 0.1
done;
echo "vtgate is up!"

echo "Access vtgate at http://$hostname:$web_port/debug/status"
disown -a


################### VTADMIN
cluster_name="local"
log_dir="${VTDATAROOT}/tmp"
web_dir="../web/vtadmin"
vtadmin_api_port=14200
vtadmin_web_port=14201
case_insensitive_hostname=$(echo "$hostname" | tr '[:upper:]' '[:lower:]')

echo -e "\n\033[1;32mvtadmin-api expects vtadmin-web at, and set http-origin to \"http://${case_insensitive_hostname}:${vtadmin_web_port}\"\033[0m"

vtadmin \
  --addr "${case_insensitive_hostname}:${vtadmin_api_port}" \
  --http-origin "http://${case_insensitive_hostname}:${vtadmin_web_port}" \
  --http-tablet-url-tmpl "http://{{ .Tablet.Hostname }}:15{{ .Tablet.Alias.Uid }}" \
  --tracer "opentracing-jaeger" \
  --grpc-tracing \
  --http-tracing \
  --logtostderr \
  --alsologtostderr \
  --rbac \
  --rbac-config="rbac.yaml" \
  --cluster "id=${cluster_name},name=${cluster_name},discovery=staticfile,discovery-staticfile-path=discovery.json,tablet-fqdn-tmpl=http://{{ .Tablet.Hostname }}:15{{ .Tablet.Alias.Uid }},schema-cache-default-expiration=1m" \
  > "${log_dir}/vtadmin-api.out" 2>&1 &

vtadmin_api_pid=$!
echo ${vtadmin_api_pid} > "${log_dir}/vtadmin-api.pid"

echo "\
vtadmin-api is running!
  - API: http://${case_insensitive_hostname}:${vtadmin_api_port}
  - Logs: ${log_dir}/vtadmin-api.out
  - PID: ${vtadmin_api_pid}
"


################### VTADMIN-WEB
echo "Building vtadmin-web..."
source "${web_dir}/build.sh"

expected_cluster_result="{\"result\":{\"clusters\":[{\"id\":\"${cluster_name}\",\"name\":\"${cluster_name}\"}]},\"ok\":true}"
for _ in {0..100}; do
  result=$(curl -s "http://${case_insensitive_hostname}:${vtadmin_api_port}/api/clusters")
  if [[ ${result} == "${expected_cluster_result}" ]]; then
    break
  fi
  sleep 0.1
done

"${web_dir}/node_modules/.bin/serve" --no-clipboard -l $vtadmin_web_port -s "${web_dir}/build" \
  > "${log_dir}/vtadmin-web.out" 2>&1 &

vtadmin_web_pid=$!
echo ${vtadmin_web_pid} > "${log_dir}/vtadmin-web.pid"

echo "\
vtadmin-web is running!
  - Browser: http://${case_insensitive_hostname}:${vtadmin_web_port}
  - Logs: ${log_dir}/vtadmin-web.out
  - PID: ${vtadmin_web_pid}
"
