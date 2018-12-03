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

DOCKER_REGISTRY=""
DOCKER_IMAGE_PREFIX="openwhisk"
DOCKER_CONTAINER_PREFIX="ow_"
DOCKER_BINARY=$(which docker)
DOCKER_NETWORK="yarnnetwork"
OPENWHISK_PROJECT_HOME="openwhisk-src"
WSK_CLI="$OPENWHISK_PROJECT_HOME/bin/wsk"
OPEN_WHISK_DB_PREFIX="local_"
TEMP_DIR=$(pwd)/tmp
LOG_DIR=$(pwd)/logs

function download-source(){
	echo "Cloning repo...."
  rm -rf "$OPENWHISK_PROJECT_HOME"
  git clone $1 "$OPENWHISK_PROJECT_HOME"
}
function build-docker(){
	echo "building the OpenWhisk core docker images ... "
  cd "$OPENWHISK_PROJECT_HOME" && \
  ./gradlew distDocker -PdockerImagePrefix=$DOCKER_IMAGE_PREFIX
}

function download-cli(){
	echo "downloading the CLI tool ... "
	mkdir $OPENWHISK_PROJECT_HOME/bin/
  if [ "$UNAME_STR" = "Darwin" ]; then
    echo "downloading cli for mac"
    curl -o "$OPENWHISK_PROJECT_HOME/bin/wsk.zip" -L https://github.com/apache/incubator-openwhisk-cli/releases/download/latest/OpenWhisk_CLI-latest-mac-amd64.zip
    cd "$OPENWHISK_PROJECT_HOME/bin/"
    unzip -o wsk.zip;
    rm wsk.zip
  elif [ "$UNAME_STR" = "Linux" ]; then
    echo "downloading cli for linux"
    curl -o "$OPENWHISK_PROJECT_HOME/bin/wsk.tgz" -L https://github.com/apache/incubator-openwhisk-cli/releases/download/latest/OpenWhisk_CLI-latest-linux-amd64.tgz
      cd "$OPENWHISK_PROJECT_HOME/bin/"
      tar -xf wsk.tgz
      rm wsk.tgz
  fi
}
function setup(){
	  echo "Running Setup"
	  mkdir "$TEMP_DIR"
    mkdir "$LOG_DIR"
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
	if [ ! -f "$TEMP_DIR/local.env" ]; then
          setup
  fi
  docker run -d \
    -p "9001:9000" \
    -e "MINIO_ACCESS_KEY=5VCTEQOQ0GR0NV1T67GN" \
    -e "MINIO_SECRET_KEY=8MBK5aJTR330V1sohz4n1i7W5Wv/jzahARNHUzi3" \
    -v "$TEMP_DIR/minio:/data:rw" \
    --name ${DOCKER_CONTAINER_PREFIX}minio \
    minio/minio:RELEASE.2018-07-13T00-09-07Z server /data

  echo "pinging minio..."
  while ! nc -z $LOCAL_IP 9001 ; do printf '.'; sleep 5; done
  echo "loading configs into minio..."
  post_config_to_minio

  docker run -d \
    -p 5984:5984 \
    --network $DOCKER_NETWORK \
    -e "COUCHDB_USER=whisk_admin" \
    -e "COUCHDB_PASSWORD=some_passw0rd" \
    -v "$TEMP_DIR/couchdb:/usr/local/var/lib/couchdb:rw" \
    --name ${DOCKER_CONTAINER_PREFIX}couchdb \
    apache/couchdb:2.1
  init-couchdb
  docker run -d \
    -p 2181:2181 \
    -p 2888:2888 \
    -p 3888:3888 \
    --network $DOCKER_NETWORK \
    -e "ZOO_SERVERS='server.1=0.0.0.0:2888:3888'" \
    -e "ZOO_MY_ID=1" \
    --name ${DOCKER_CONTAINER_PREFIX}zookeeper \
    zookeeper:3.4
  docker run -d \
    -p 9092:9092 \
    --network $DOCKER_NETWORK \
    -e "KAFKA_ZOOKEEPER_CONNECT=$LOCAL_IP:2181" \
    -e "KAFKA_ADVERTISED_HOST_NAME=$LOCAL_IP" \
    -v "/var/run/docker.sock:/var/run/docker.sock" \
    -v "$TEMP_DIR/kafka:/kafka:rw" \
    --name ${DOCKER_CONTAINER_PREFIX}kafka \
    wurstmeister/kafka:0.11.0.1
  docker run -d -p 6379:6379 --name ${DOCKER_CONTAINER_PREFIX}redis redis:2.8
}

function run-stateless(){
  withJaaS=$1
	if [ ! -f "$TEMP_DIR/local.env" ]; then
    setup
  fi
  #update minio host
  if [ "$UNAME_STR" = "Linux" ]; then
    sed -i "s/MINIO_HOST/$LOCAL_IP/g" "apigateway/rclone/rclone.conf"
  else
    sed -i '' "s/MINIO_HOST/$LOCAL_IP/g" "apigateway/rclone/rclone.conf"
  fi

  docker run -d \
    -p 8888:8888 \
    -p 2551:2551 \
    --network $DOCKER_NETWORK \
    --env-file docker-whisk-controller.env \
    --env-file "$TEMP_DIR/local.env" \
    -e "COMPONENT_NAME=controller" \
    -e "PORT=8888"  \
    -e "KAFKA_HOSTS=$LOCAL_IP:9092" \
    -e "ZOOKEEPER_HOSTS=$LOCAL_IP:2181" \
    -e "CONFIG_whisk_couchdb_provider=CouchDB" \
    -e "CONFIG_whisk_couchdb_protocol=http" \
    -e "CONFIG_whisk_couchdb_port=5984" \
    -e "CONFIG_whisk_couchdb_host=$LOCAL_IP" \
    -e "CONFIG_whisk_couchdb_username=whisk_admin" \
    -e "CONFIG_whisk_couchdb_password=some_passw0rd" \
    -e "CONFIG_akka_remote_netty_tcp_hostname=$LOCAL_IP" \
    -e "CONFIG_akka_remote_netty_tcp_port=2551" \
    -e "CONFIG_akka_remote_netty_tcp_bindPort=2551" \
    -e "CONFIG_akka_actor_provider=cluster" \
    -e "LOADBALANCER_HOST=${LOCAL_IP}" \
    -e "LOADBALANCER_HOST_PORT=443" \
    -v "$LOG_DIR:/logs" \
    --name ${DOCKER_CONTAINER_PREFIX}controller \
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
    -e "KAFKA_HOSTS=$LOCAL_IP:9092" \
    -e "ZOOKEEPER_HOSTS=$LOCAL_IP:2181" \
    -e "CONFIG_whisk_couchdb_provider=CouchDB" \
    -e "CONFIG_whisk_couchdb_protocol=http" \
    -e "CONFIG_whisk_couchdb_port=5984" \
    -e "CONFIG_whisk_couchdb_host=$LOCAL_IP" \
    -e "CONFIG_whisk_couchdb_username=whisk_admin" \
    -e "CONFIG_whisk_couchdb_password=some_passw0rd" \
    -e "EDGE_HOST=${LOCAL_IP}" \
    -e "EDGE_HOST_APIPORT=443" \
    -e "CONFIG_whisk_containerFactory_containerArgs_network=$DOCKER_NETWORK" \
    -v "$LOG_DIR:/logs" \
    -v "/var/run/docker.sock:/var/run/docker.sock" \
    -v "/var/lib/docker/containers:/containers" \
    -v "/sys/fs/cgroup:/sys/fs/cgroup" \
    -v "/etc/krb5.conf:/etc/krb5.conf" \
    -v "/opt/YARNdeployment/login.conf:/login.conf" \
    -v "/opt/YARNdeployment/master0.keytab:/master0.keytab" \
    -e "WHISK_API_HOST_NAME=${LOCAL_IP}" \
    --name ${DOCKER_CONTAINER_PREFIX}invoker \
    "${DOCKER_OW_IMAGE_PREFIX:-openwhisk}/invoker" \
    /bin/sh -c "exec /init.sh --id 0 >> /logs/invoker-local_logs.log 2>&1"

  docker run -d \
    -p 80:80 \
    -p 443:443 \
    -p 9000:9000 \
    -p 9090:8080 \
    --network $DOCKER_NETWORK \
    -e "REDIS_HOST=${LOCAL_IP}" \
    -e "REDIS_PORT=6379" \
    -e "PUBLIC_MANAGEDURL_PORT=9090" \
    -e "PUBLIC_MANAGEDURL_HOST=${LOCAL_IP}" \
    -e "REMOTE_CONFIG=minio:api-gateway" \
    -v "$TEMP_DIR/api-gateway-ssl:/etc/ssl:ro" \
    -v "$TEMP_DIR/api-gateway-config/api-gateway/generated-conf.d:/etc/api-gateway/generated-conf.d" \
    -v "$TEMP_DIR/rclone:/root/.config/rclone:rw" \
    --add-host whisk.controller:${LOCAL_IP} \
    --name ${DOCKER_CONTAINER_PREFIX}apigateway \
    "openwhisk/apigateway:latest"
}
function run-all(){
  run-stateful
  run-stateless
}
function stop-stateless(){
  docker stop ${DOCKER_CONTAINER_PREFIX}controller ${DOCKER_CONTAINER_PREFIX}invoker ${DOCKER_CONTAINER_PREFIX}apigateway
}
function stop-stateful(){
  docker stop ${DOCKER_CONTAINER_PREFIX}minio ${DOCKER_CONTAINER_PREFIX}couchdb ${DOCKER_CONTAINER_PREFIX}zookeeper ${DOCKER_CONTAINER_PREFIX}kafka ${DOCKER_CONTAINER_PREFIX}redis
}
function stop-all(){
  stop-stateful
  stop-stateless
}
function start-stateless(){
  docker start ${DOCKER_CONTAINER_PREFIX}controller ${DOCKER_CONTAINER_PREFIX}invoker ${DOCKER_CONTAINER_PREFIX}apigateway
}
function start-stateful(){
  docker start ${DOCKER_CONTAINER_PREFIX}minio ${DOCKER_CONTAINER_PREFIX}couchdb ${DOCKER_CONTAINER_PREFIX}zookeeper ${DOCKER_CONTAINER_PREFIX}kafka ${DOCKER_CONTAINER_PREFIX}redis
}
function start-all(){
  start-stateful
  start-stateless
}
function remove-stateless(){
  docker rm -f ${DOCKER_CONTAINER_PREFIX}controller ${DOCKER_CONTAINER_PREFIX}invoker ${DOCKER_CONTAINER_PREFIX}apigateway
}
function remove-stateful(){
  docker rm -f ${DOCKER_CONTAINER_PREFIX}minio ${DOCKER_CONTAINER_PREFIX}couchdb ${DOCKER_CONTAINER_PREFIX}zookeeper ${DOCKER_CONTAINER_PREFIX}kafka ${DOCKER_CONTAINER_PREFIX}redis
}
function remove-all(){
  remove-stateful
  remove-stateless
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
            --add-host="db:$LOCAL_IP" \
            ddragosd/ansible:2.4.0.0-debian8  \
            sh -c "ansible-playbook setup.yml && ansible-playbook couchdb.yml --tags=ini && ansible-playbook initdb.yml wipe.yml \
                    -e db_host=$LOCAL_IP -e openwhisk_home=/openwhisk -e db_prefix=$OPEN_WHISK_DB_PREFIX"
    rm -rf "$TEMP_DIR/src"
}

function post_config_to_minio(){
  s3Bucket="api-gateway"
  file="apigateway/generated-conf.d/api-gateway.conf"
  s3AccessKey="5VCTEQOQ0GR0NV1T67GN"
  s3SecretKey="8MBK5aJTR330V1sohz4n1i7W5Wv/jzahARNHUzi3"

  contentType="application/octet-stream"
  host="$LOCAL_IP:9001"

  dateFormatted=`date -R`
  relativePath="/${s3Bucket}"
  stringToSign="PUT\n\n${contentType}\n${dateFormatted}\n${relativePath}"
  signature=`echo -en ${stringToSign} | openssl sha1 -hmac ${s3SecretKey} -binary | base64`
  curl \
  -H "Host: ${host}" \
  -H "Date: ${dateFormatted}" \
  -H "Content-Type: ${contentType}" \
  -H "Authorization:AWS ${s3AccessKey}:${signature}" \
  -X PUT \
  "http://${host}${relativePath}"

  dateFormatted=`date -R`
  relativePath="/${s3Bucket}/$(basename $file)"
  stringToSign="PUT\n\n${contentType}\n${dateFormatted}\n${relativePath}"
  signature=`echo -en ${stringToSign} | openssl sha1 -hmac ${s3SecretKey} -binary | base64`
  curl -T "${file}" \
  -H "Host:${host}" \
  -H "Date: ${dateFormatted}" \
  -H "Content-Type: ${contentType}" \
  -H "Content-Length: $(wc -c < $file)" \
  -H "Authorization: AWS ${s3AccessKey}:${signature}" \
  -X PUT \
  "http://${host}${relativePath}"
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
      run-stateful
      ;;
  run-stateless)
      run-stateless
      ;;
  run-all)
      run-all
      ;;
  stop-stateful)
      stop-stateful
      ;;
  stop-stateless)
      stop-stateless
      ;;
  stop-all)
      stop-all
      ;;
  start-stateful)
      start-stateful
      ;;
  start-stateless)
      start-stateless
      ;;
  start-all)
      start-all
      ;;
  remove-stateful)
      remove-stateful
      ;;
  remove-stateless)
      remove-stateless
      ;;
  remove-all)
      remove-all
      ;;
  init-cli)
      init-cli
      ;;
  quick-start)
      download-source $2
      build-docker
      download-cli
      run-stateful
      run-stateless
      init-cli
      ;;
  launch)
      run-stateful
      run-stateless
      init-cli
      ;;
  *)
      echo "Usage"
      echo ""
      echo "Setup:"
      echo "$0 download-source <git url> - Git clones the provided repo into ./openwhisk-src"
      echo "$0 download-cli - Downloads the OpenWhisk cli into ./openwhisk-src/bin"
      echo "$0 build-docker - Compiles the OpenWhisk source and builds the OpenWhisk images with a prefix of 'openwhisk'"
      echo "$0 init-cli - Initializes the cli with the gateway endpoint and guest auth. All containers must be running"
      echo ""
      echo "Container operations:"
      echo "  Stateful containers:  ow_minio, ow_couchdb, ow_zookeeper, ow_kafka, ow_redis"
      echo "  Stateless containers: ow_controller, ow_invoker, ow_apigateway"
      echo "$0 run-[stateful|stateless|all]    - Runs the specified containers"
      echo "$0 stop-[stateful|stateless|all]   - Stops the specified containers"
      echo "$0 start-[stateful|stateless|all]  - Starts the specified containers if they are stopped"
      echo "$0 remove-[stateful|stateless|all] - Removes the specified containers"
      echo ""
      echo "Shortcuts:"
      echo "$0 quick-start <git url> - Executes download-source, build-docker, download-cli, run-stateful, run-stateless, init-cli"
      echo "$0 launch - Executes run-stateful, run-stateless, init-cli"
      ;;
esac
