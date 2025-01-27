source env.sh
source utils.sh

export VTDATAROOT="${VTDATAROOT:-${PWD}/vtdataroot}"
mkdir -p "$VTDATAROOT/etcd"
mkdir -p "$VTDATAROOT/tmp"
mkdir -p "$VTDATAROOT/backups"

hostname="172.16.33.48"
vtctld_web_port=15000
ETCD_SERVER="localhost:2379"
TOPOLOGY_FLAGS="--topo_implementation etcd2 --topo_global_server_address $ETCD_SERVER --topo_global_root /vitess/global"
cell="otter-zone"

alias mysql="command mysql --no-defaults -h 127.0.0.1 -P 15306 --binary-as-hex=false"
alias vtctldclient="command vtctldclient --server localhost:15999"



for TABLET_UID in 102; do
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
for TABLET_UID in 102; do
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



