#!/bin/bash

UNAME_STR=$(uname)
# detect local ip of host as this is needed within containers to find the OpenWhisk API container
if [ "$UNAME_STR" = "Linux" ]; then
        LOCAL_IP=$(route | grep default | tr -s " " | cut -d " " -f 8 | xargs /sbin/ifconfig | grep "inet addr:" | cut -d ":" -f 2 | cut -d " " -f 1)
        # inet addr: not present, trying with inet.
        if [ -z "$LOCAL_IP" ]; then
                LOCAL_IP=$(route | grep default | tr -s " " | cut -d " " -f 8 | xargs /sbin/ifconfig | grep "inet " | tr -s " " | cut -d " " -f 3)
        fi
else
        LOCAL_IP=$(ifconfig | grep "inet " | grep -v 127.0.0.1 | cut -d\  -f2 | head -1)
fi
# if no IP was found, fallback to "localhost"
if [ -z "$LOCAL_IP" ]; then
        LOCAL_IP="localhost"
fi

HOME="$( cd "$(dirname "$0")" ; pwd -P )"
cd "$HOME" || exit
ScriptName=`basename "$0"`

DOCKER_REGISTRY=""
DOCKER_IMAGE_PREFIX="openwhisk"
DOCKER_BINARY=$(which docker)
OPENWHISK_PROJECT_HOME="$HOME/openwhisk-src"
WSK_CLI="$OPENWHISK_PROJECT_HOME/bin/wsk"
OPEN_WHISK_DB_PREFIX="local_"
TEMP_DIR="$HOME/tmp"
LOG_DIR=$TEMP_DIR/logs
s3AccessKey="5VCTEQOQ0GR0NV1T67GN"
s3SecretKey="8MBK5aJTR330V1sohz4n1i7W5Wv/jzahARNHUzi3"

function download-source(){
  if [ -z $1 ]; then
    echo "Source repo must be provided"
    exit 1
  fi
  if [ -d "$OPENWHISK_PROJECT_HOME" ]; then
    echo "Source directory already exists"
  else
  	echo "Cloning repo...."
    git clone $1 "$OPENWHISK_PROJECT_HOME"
  fi
}
function build-docker(){
	echo "building the OpenWhisk core docker images ... "
  cd "$OPENWHISK_PROJECT_HOME"
  ./gradlew distDocker -PdockerImagePrefix=$DOCKER_IMAGE_PREFIX
  cd "$HOME"
}

function download-cli(){
	echo "downloading the CLI tool ... "
	mkdir -p $OPENWHISK_PROJECT_HOME/bin/
  if [ "$UNAME_STR" = "Darwin" ]; then
    echo "downloading cli for mac"
    curl -o "$OPENWHISK_PROJECT_HOME/bin/wsk.zip" -L https://github.com/apache/incubator-openwhisk-cli/releases/download/latest/OpenWhisk_CLI-latest-mac-amd64.zip
    cd "$OPENWHISK_PROJECT_HOME/bin/"
    unzip -o wsk.zip;
    rm wsk.zip
    cd "$HOME"
  elif [ "$UNAME_STR" = "Linux" ]; then
    echo "downloading cli for linux"
    curl -o "$OPENWHISK_PROJECT_HOME/bin/wsk.tgz" -L https://github.com/apache/incubator-openwhisk-cli/releases/download/latest/OpenWhisk_CLI-latest-linux-amd64.tgz
      cd "$OPENWHISK_PROJECT_HOME/bin/"
      tar -xf wsk.tgz
      rm wsk.tgz
      cd "$HOME"
  fi
}
function setup(){
	  echo "Running Setup"
    mkdir -p "$LOG_DIR"
    chmod 777 "$LOG_DIR"
    printf "DOCKER_BINARY=$DOCKER_BINARY\n" > "$TEMP_DIR/local.env"
    printf "DOCKER_REGISTRY=$DOCKER_REGISTRY\n" >> "$TEMP_DIR/local.env"
    printf "DOCKER_IMAGE_PREFIX=$DOCKER_IMAGE_PREFIX\n" >> "$TEMP_DIR/local.env"

    echo "  ... preparing api-gateway configuration"
    rm -rf "$TEMP_DIR/api-gateway-config"
    mkdir -p "$TEMP_DIR/api-gateway-config/api-gateway"
    cp -r ./apigateway/* "$TEMP_DIR/api-gateway-config/api-gateway/"
    cp -r ./apigateway/rclone "$TEMP_DIR"

    "$OPENWHISK_PROJECT_HOME/ansible/files/genssl.sh" $LOCAL_IP server "$OPENWHISK_PROJECT_HOME/ansible/roles/nginx/files"
    mkdir -p "$TEMP_DIR"/api-gateway-ssl
    cp "$OPENWHISK_PROJECT_HOME"/ansible/roles/nginx/files/*.pem "$TEMP_DIR/api-gateway-ssl"

    touch "$LOG_DIR/controller-local_logs.log"
    chmod 666 "$LOG_DIR/controller-local_logs.log"
}

function init_cli(){
	  echo "waiting for the Whisk controller to come up ... "
    until [ $(curl --output /dev/null --silent --head --fail "http://$LOCAL_IP:8888/ping") ]; do printf '.'; sleep 5; done
    echo "initializing CLI ... "
    $(WSK_CLI) -v property set --namespace guest --auth `cat "$OPENWHISK_PROJECT_HOME/ansible/files/auth.guest"` --apihost "https://$LOCAL_IP" -i
}
function run-stateful(){

  DOCKER_NETWORK="$1"
  if [ -z $DOCKER_NETWORK ]; then
    DOCKER_NETWORK="host"
  fi

	if [ ! -f "$TEMP_DIR/local.env" ]; then
    setup
  fi
  docker run -d \
    -p "9001:9000" \
    -e "MINIO_ACCESS_KEY=${s3AccessKey}" \
    -e "MINIO_SECRET_KEY=${s3SecretKey}" \
    -v "$TEMP_DIR/minio:/data:rw" \
    --hostname ow_minio \
    --name ow_minio \
    minio/minio:RELEASE.2018-07-13T00-09-07Z server /data

  echo "pinging minio..."
  while ! nc -z $LOCAL_IP 9001 ; do printf '.'; sleep 5; done
  echo "loading configs into minio..."
  post_config_to_minio
  echo ""
  docker run -d \
    -p 5984:5984 \
    --network $DOCKER_NETWORK \
    -e "COUCHDB_USER=whisk_admin" \
    -e "COUCHDB_PASSWORD=some_passw0rd" \
    -v "$TEMP_DIR/couchdb:/usr/local/var/lib/couchdb:rw" \
    --hostname ow_couchdb \
    --name ow_couchdb \
    apache/couchdb:2.1

  init-couchdb
  docker run -d \
    -p 2181:2181 \
    -p 2888:2888 \
    -p 3888:3888 \
    --network $DOCKER_NETWORK \
    -e "ZOO_SERVERS='server.1=0.0.0.0:2888:3888'" \
    -e "ZOO_MY_ID=1" \
    --hostname ow_zookeeper \
    --name ow_zookeeper \
    zookeeper:3.4
  docker run -d \
    -p 9092:9092 \
    --network $DOCKER_NETWORK \
    -e "KAFKA_ZOOKEEPER_CONNECT=ow_zookeeper:2181" \
    -e "KAFKA_ADVERTISED_HOST_NAME=ow_kafka" \
    -v "/var/run/docker.sock:/var/run/docker.sock" \
    -v "$TEMP_DIR/kafka:/kafka:rw" \
    --hostname ow_kafka \
    --name ow_kafka \
    wurstmeister/kafka:0.11.0.1
}

function run-stateless-local(){
  DOCKER_NETWORK="$1"
  if [ -z $DOCKER_NETWORK ]; then
    DOCKER_NETWORK="host"
  fi
  withJaaS="$2"
	if [ ! -f "$TEMP_DIR/local.env" ]; then
    setup
  fi
  #update minio host
  if [ "$UNAME_STR" = "Linux" ]; then
    sed -i "s/MINIO_HOST/$LOCAL_IP/g" "apigateway/rclone/rclone.conf"
  else
    sed -i '' "s/MINIO_HOST/$LOCAL_IP/g" "apigateway/rclone/rclone.conf"
  fi

  jaasMounts=""
  if [ ! -z $withJaaS ]; then
    jaasMounts="-v \"/etc/krb5.conf:/etc/krb5.conf\" -v \"$HOME/login.conf:/login.conf\" -v \"$HOME/master0.keytab:/master0.keytab\""
  fi

  docker run -d \
    -p 6379:6379 \
    --hostname ow_redis \
    --name ow_redis \
    redis:2.8

  docker run -d \
    -p 8888:8888 \
    -p 2551:2551 \
    --network $DOCKER_NETWORK \
    --env-file docker-whisk-controller.env \
    --env-file "$TEMP_DIR/local.env" \
    -e "COMPONENT_NAME=controller" \
    -e "PORT=8888"  \
    -e "KAFKA_HOSTS=ow_kafka:9092" \
    -e "ZOOKEEPER_HOSTS=ow_zookeeper:2181" \
    -e "CONFIG_whisk_couchdb_provider=CouchDB" \
    -e "CONFIG_whisk_couchdb_protocol=http" \
    -e "CONFIG_whisk_couchdb_port=5984" \
    -e "CONFIG_whisk_couchdb_host=ow_couchdb" \
    -e "CONFIG_whisk_couchdb_username=whisk_admin" \
    -e "CONFIG_whisk_couchdb_password=some_passw0rd" \
    -e "CONFIG_akka_remote_netty_tcp_hostname=$LOCAL_IP" \
    -e "CONFIG_akka_remote_netty_tcp_port=2551" \
    -e "CONFIG_akka_remote_netty_tcp_bindPort=2551" \
    -e "CONFIG_akka_actor_provider=cluster" \
    -e "LOADBALANCER_HOST=${LOCAL_IP}" \
    -e "LOADBALANCER_HOST_PORT=443" \
    -v "$LOG_DIR:/logs" \
    --name ow_controller \
    "${DOCKER_OW_IMAGE_PREFIX:-openwhisk}/controller" \
    /bin/sh -c "exec /init.sh 0 >> /logs/controller-local_logs.log 2>&1"
  docker run -d \
    -p 8085:8085 \
    --network $DOCKER_NETWORK \
    --privileged \
    --pid "host" \
    --userns "host" \
    --env-file docker-whisk-controller.env \
    --env-file "$TEMP_DIR/local.env" \
    -e "COMPONENT_NAME=invoker" \
    -e "SERVICE_NAME=invoker0" \
    -e "PORT=8085" \
    -e "KAFKA_HOSTS=ow_kafka:9092" \
    -e "ZOOKEEPER_HOSTS=ow_zookeeper:2181" \
    -e "CONFIG_whisk_couchdb_provider=CouchDB" \
    -e "CONFIG_whisk_couchdb_protocol=http" \
    -e "CONFIG_whisk_couchdb_port=5984" \
    -e "CONFIG_whisk_couchdb_host=ow_couchdb" \
    -e "CONFIG_whisk_couchdb_username=whisk_admin" \
    -e "CONFIG_whisk_couchdb_password=some_passw0rd" \
    -e "EDGE_HOST=${LOCAL_IP}" \
    -e "EDGE_HOST_APIPORT=443" \
    -e "CONFIG_whisk_containerFactory_containerArgs_network=$DOCKER_NETWORK" \
    -v "$LOG_DIR:/logs" \
    -v "/var/run/docker.sock:/var/run/docker.sock" \
    -v "/var/lib/docker/containers:/containers" \
    -v "/sys/fs/cgroup:/sys/fs/cgroup" \
    $jaasMounts \
    -e "WHISK_API_HOST_NAME=${LOCAL_IP}" \
    --name ow_invoker \
    "${DOCKER_OW_IMAGE_PREFIX:-openwhisk}/invoker" \
    /bin/sh -c "exec /init.sh --id 0 >> /logs/invoker-local_logs.log 2>&1"

  docker run -d \
    -p 80:80 \
    -p 443:443 \
    -p 9000:9000 \
    -p 8081:8080 \
    --network $DOCKER_NETWORK \
    -e "REDIS_HOST=ow_redis" \
    -e "REDIS_PORT=6379" \
    -e "PUBLIC_MANAGEDURL_PORT=8081" \
    -e "PUBLIC_MANAGEDURL_HOST=${LOCAL_IP}" \
    -e "REMOTE_CONFIG=minio:api-gateway" \
    -v "$TEMP_DIR/api-gateway-ssl:/etc/ssl:ro" \
    -v "$TEMP_DIR/api-gateway-config/api-gateway/generated-conf.d:/etc/api-gateway/generated-conf.d" \
    -v "$TEMP_DIR/rclone:/root/.config/rclone:rw" \
    -v "$LOG_DIR:/var/log/api-gateway" \
    --add-host whisk.controller:${LOCAL_IP} \
    --name ow_apigateway \
    "openwhisk/apigateway:latest"
}
function run-stateless-yarn(){
  YARN_RM=$1
	if [ ! -f "$TEMP_DIR/local.env" ]; then
    setup
  fi
  #update minio host
  if [ "$UNAME_STR" = "Linux" ]; then
    sed -i "s/MINIO_HOST/$LOCAL_IP/g" "apigateway/rclone/rclone.conf"
  else
    sed -i '' "s/MINIO_HOST/$LOCAL_IP/g" "apigateway/rclone/rclone.conf"
  fi

  #--env-file docker-whisk-controller.env \
  #--env-file "$TEMP_DIR/local.env" \
  username="ambari-qa"
  KAFKA_IP=${LOCAL_IP}
  ZOOKEEPER_IP=${LOCAL_IP}
  COUCHDB_IP=${LOCAL_IP}
  HDFS_DIR="/user/ambari-qa/"
  EXTRA_ENV=$(cat docker-whisk-controller.env | grep "^[^#]" | sed s/\"/\\\\\"/g | sed s/}}/}\ }/g | awk -F= '{print "\x22"$1"\x22:" "\x22"$2"\x22,"}')

  #apigateway/generated-conf.d/api-gateway.conf ow_controller

  apigatewayconf_content=$(cat $TEMP_DIR/api-gateway-config/api-gateway/generated-conf.d/api-gateway.conf)
  apigatewayconf_content="${apigatewayconf_content//ow_controller/apigateway-0.openwhisk-master-service.$username.EXAMPLE.COM}"

  curl -L -X PUT "http://$YARN_RM:50070/webhdfs/v1/user/ambari-qa/api-gateway.conf?user.name=ambari-qa&op=CREATE&overwrite=true" -d "${apigatewayconf_content}"
  curl -L -X PUT "http://$YARN_RM:50070/webhdfs/v1/user/ambari-qa/rclone.conf?user.name=ambari-qa&op=CREATE&overwrite=true" -T "$TEMP_DIR/rclone/rclone.conf"
  curl -L -X PUT "http://$YARN_RM:50070/webhdfs/v1/user/ambari-qa/openwhisk-server-cert.pem?user.name=ambari-qa&op=CREATE&overwrite=true" -T "$TEMP_DIR/api-gateway-ssl/openwhisk-server-cert.pem"
  curl -L -X PUT "http://$YARN_RM:50070/webhdfs/v1/user/ambari-qa/openwhisk-server-key.pem?user.name=ambari-qa&op=CREATE&overwrite=true" -T "$TEMP_DIR/api-gateway-ssl/openwhisk-server-key.pem"

  YARN_Service_Def=$(cat openwhisk.json)
  YARN_Service_Def="${YARN_Service_Def//KAFKA_IP/$KAFKA_IP}"
  YARN_Service_Def="${YARN_Service_Def//ZOOKEEPER_IP/$ZOOKEEPER_IP}"
  YARN_Service_Def="${YARN_Service_Def//COUCHDB_IP/$COUCHDB_IP}"
  YARN_Service_Def="${YARN_Service_Def//HDFS_DIR/$HDFS_DIR}"
  YARN_Service_Def="${YARN_Service_Def//INVOKER_EXTRA_ENV/$EXTRA_ENV}"
  YARN_Service_Def="${YARN_Service_Def//CONTROLLER_EXTRA_ENV/$EXTRA_ENV}"
  curl -X POST -H "Content-Type: application/json" "$YARN_RM:8088/app/v1/services?user.name=$username" -d "$YARN_Service_Def"
}
function stop-stateless(){
  docker stop ow_redis ow_controller ow_invoker ow_apigateway
}
function stop-stateful(){
  docker stop ow_minio ow_couchdb ow_zookeeper ow_kafka
}
function start-stateless(){
  docker start ow_redis ow_controller ow_invoker ow_apigateway
}
function start-stateful(){
  docker start ow_minio ow_couchdb ow_zookeeper ow_kafka
}
function remove-stateless-local(){
  docker rm -f ow_redis ow_controller ow_invoker ow_apigateway
}
function remove-stateless-yarn(){
  YARN_RM=$1
  curl -X DELETE "$YARN_RM:8088/app/v1/services/openwhisk-master-service?user.name=ambari-qa"
}
function remove-stateful(){
  docker rm -f ow_minio ow_couchdb ow_zookeeper ow_kafka
}
function init-cli(){
    echo "waiting for the Whisk controller to come up ... "
    while ! nc -z $LOCAL_IP 8888 ; do printf '.'; sleep 5; done
    echo "initializing CLI ... "
    "$WSK_CLI" -v property set --namespace guest --auth $(cat "$OPENWHISK_PROJECT_HOME/ansible/files/auth.guest") --apihost "https://$LOCAL_IP" -i
}
function init-couchdb() {
    echo "waiting for the database to come up ... on $LOCAL_IP"
    while ! nc -z $LOCAL_IP 5984 ; do printf '.'; sleep 5; done
    echo "initializing the database ... on $LOCAL_IP"
    # make sure the src files are in a shared folder for docker
    mkdir -p "$TEMP_DIR"
    rm -rf "$TEMP_DIR/src"
    rsync -a "$OPENWHISK_PROJECT_HOME/"* "$TEMP_DIR/src" --exclude .git --exclude build --exclude tests
    echo 'Setting up db using ansible container....'
    docker run --rm -v "$TEMP_DIR/src:/openwhisk" -w "/openwhisk/ansible" \
            --network="$DOCKER_NETWORK" -t \
            ddragosd/ansible:2.4.0.0-debian8  \
            sh -c "ansible-playbook setup.yml && ansible-playbook couchdb.yml --tags=ini && ansible-playbook initdb.yml wipe.yml \
                    -e db_host=ow_couchdb -e openwhisk_home=/openwhisk -e db_prefix=$OPEN_WHISK_DB_PREFIX"
    rm -rf "$TEMP_DIR/src"
}

function post_config_to_minio(){
  s3Bucket="api-gateway"
  file="apigateway/generated-conf.d/api-gateway.conf"
  host="$LOCAL_IP:9001"

  contentType="application/octet-stream"
  dateFormatted=`date -R`
  relativePath="/${s3Bucket}"
  stringToSign="PUT\n\n${contentType}\n${dateFormatted}\n${relativePath}"
  signature=`echo -en ${stringToSign} | openssl sha1 -hmac ${s3SecretKey} -binary | base64`

  returnCode=-1
  until [ $returnCode -eq 0 ]; do
    curl -s \
      -H "Host: ${host}" \
      -H "Date: ${dateFormatted}" \
      -H "Content-Type: ${contentType}" \
      -H "Content-Length: 0" \
      -H "Authorization:AWS ${s3AccessKey}:${signature}" \
      -X PUT \
      "http://${host}${relativePath}"
    returnCode=$?
    printf '.'
    sleep 1
  done

  dateFormatted=`date -R`
  relativePath="/${s3Bucket}/$(basename $file)"
  stringToSign="PUT\n\n${contentType}\n${dateFormatted}\n${relativePath}"
  signature=`echo -en ${stringToSign} | openssl sha1 -hmac ${s3SecretKey} -binary | base64`

  returnCode=-1
  until [ $returnCode -eq 0 ]; do
    curl -s \
      -T "${file}" \
      -H "Host:${host}" \
      -H "Date: ${dateFormatted}" \
      -H "Content-Type: ${contentType}" \
      -H "Content-Length: $(wc -c < $file)" \
      -H "Authorization: AWS ${s3AccessKey}:${signature}" \
      -X PUT \
      "http://${host}${relativePath}"
    returnCode=$?
    printf '.'
    sleep 1
  done
}

case "$1" in
  download-cli)
      download-cli
      ;;
  download-source)
      download-source $2
      ;;
  build-docker)
      build-docker
      ;;
  run-stateful)
      run-stateful $2
      ;;
  run-stateless-local)
      run-stateless-local $2 $3
      ;;
  run-stateless-yarn)
      run-stateless-yarn $2
      ;;
  run-all)
      run-stateful $2
      run-stateless $2 $3
      ;;
  stop-stateful)
      stop-stateful
      ;;
  stop-stateless)
      stop-stateless
      ;;
  stop-all)
      stop-stateful
      stop-stateless
      ;;
  start-stateful)
      start-stateful
      ;;
  start-stateless)
      start-stateless
      ;;
  start-all)
      start-stateful
      start-stateless
      ;;
  remove-stateful)
      remove-stateful
      ;;
  remove-stateless-local)
      remove-stateless-local
      ;;
  remove-stateless-yarn)
      remove-stateless-yarn $2
      ;;
  remove-all)
      remove-stateful
      remove-stateless-local
      ;;
  init-cli)
      init-cli
      ;;
  quick-start)
      download-source $2
      build-docker
      download-cli
      run-stateful $3
      run-stateless-local $3
      init-cli
      ;;
  launch)
      run-stateful $2
      run-stateless-local $2
      init-cli
      ;;
  *)
      echo "Usage"
      echo ""
      echo "Setup:"
      echo "$ScriptName download-source <git url> - Git clones the provided repo into ./openwhisk-src"
      echo "$ScriptName download-cli - Downloads the OpenWhisk cli into ./openwhisk-src/bin"
      echo "$ScriptName build-docker - Compiles the OpenWhisk source and builds the OpenWhisk images with a prefix of 'openwhisk'"
      echo "$ScriptName init-cli - Initializes the cli with the gateway endpoint and guest auth. All containers must be running"
      echo ""
      echo "Container operations:"
      echo "  Stateful containers:  ow_minio, ow_couchdb, ow_zookeeper, ow_kafka"
      echo "  Stateless containers: ow_redis, ow_controller, ow_invoker, ow_apigateway"
      echo "$ScriptName run-stateful <docker network>                  - Runs the stateful containers locally"
      echo "$ScriptName run-stateless-local <docker network> [withJaaS]- Runs the stateless containers locally"
      echo "$ScriptName run-stateless-yarn <RM URL>                    - Runs the stateless containers on YARN"
      echo "$ScriptName run-all <docker network> [withJaaS]            - Runs all containers locally"
      echo "$ScriptName stop-[stateful|stateless|all]                  - Stops the specified local containers"
      echo "$ScriptName start-[stateful|stateless|all]                 - Starts the specified local containers if they are stopped"
      echo "$ScriptName remove-[stateful|stateless-local|stateless-yarn|all] - Removes the specified containers"
      echo ""
      echo "Shortcuts:"
      echo "$ScriptName quick-start <git url> <docker network> - Executes download-source, build-docker, download-cli, run-stateful, run-stateless-local, init-cli"
      echo "$ScriptName launch <docker network> - Executes run-stateful, run-stateless-local, init-cli"
      ;;
esac
