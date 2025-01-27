# mysqld might be in /usr/sbin which will not be in the default PATH
PATH="/usr/sbin:$PATH"
for binary in mysqld etcd etcdctl curl vtctldclient vttablet vtgate vtctld mysqlctl; do
  command -v "$binary" > /dev/null || fail "${binary} is not installed in PATH. See https://vitess.io/docs/get-started/local/ for install instructions."
done;

# vtctldclient has a separate alias setup below
for binary in vttablet vtgate vtctld mysqlctl vtorc vtctl; do
  alias $binary="$binary --config-file-not-found-handling=ignore"
done;

# If using bash, make sure aliases are expanded in non-interactive shell
if [[ -n ${BASH} ]]; then
    shopt -s expand_aliases
fi

