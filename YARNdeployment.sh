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

gitRepo="https://github.com/apache/incubator-openwhisk.git"
macCLI="https://github.com/apache/incubator-openwhisk-cli/releases/download/latest/OpenWhisk_CLI-latest-mac-amd64.zip"
linuxCLI="https://github.com/apache/incubator-openwhisk-cli/releases/download/latest/OpenWhisk_CLI-latest-linux-amd64.tgz"
#windowsCLI="https://github.com/apache/incubator-openwhisk-cli/releases/download/latest/OpenWhisk_CLI-latest-windows-amd64.zip"

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
  if [ -d "$OPENWHISK_PROJECT_HOME" ]; then
    echo "Source directory already exists"
  else
  	echo "Cloning repo...."
    git clone "$gitRepo" "$OPENWHISK_PROJECT_HOME"
  fi
}
function build-docker(){
	echo "building the OpenWhisk core docker images ... "
  cd "$OPENWHISK_PROJECT_HOME"
  ./gradlew distDocker -PdockerImagePrefix=$DOCKER_IMAGE_PREFIX
  cd "$HOME"
}
function pull-images(){
  docker pull "$DOCKER_IMAGE_PREFIX/apigateway"
  docker pull "$DOCKER_IMAGE_PREFIX/controller"
  docker pull "$DOCKER_IMAGE_PREFIX/invoker"
  docker pull "$DOCKER_IMAGE_PREFIX/nodejs6action"
  docker pull "$DOCKER_IMAGE_PREFIX/dockerskeleton"
  docker pull "redis:2.8"
}
function download-cli(){
	echo "downloading the CLI tool ... "
	mkdir -p $OPENWHISK_PROJECT_HOME/bin/
  if [ "$UNAME_STR" = "Darwin" ]; then
    echo "downloading cli for mac"
    curl -o "$OPENWHISK_PROJECT_HOME/bin/wsk.zip" -L "$macCLI"
    cd "$OPENWHISK_PROJECT_HOME/bin/"
    unzip -o wsk.zip;
    rm wsk.zip
    cd "$HOME"
  elif [ "$UNAME_STR" = "Linux" ]; then
    echo "downloading cli for linux"
    curl -o "$OPENWHISK_PROJECT_HOME/bin/wsk.tgz" -L "$linuxCLI"
      cd "$OPENWHISK_PROJECT_HOME/bin/"
      tar -xf wsk.tgz
      rm wsk.tgz
      cd "$HOME"
  fi
}

function getHostnames(){
  case "$1" in
    "minio" | "couchdb" | "zookeeper" | "kafka" | \
    "redis" | "controller" | "invoker" | "apigateway")
                  printf "ow_$1" ;;
    "stateful")   printf "ow_minio ow_couchdb ow_zookeeper ow_kafka" ;;
    "stateless")  printf "ow_redis ow_controller ow_invoker ow_apigateway" ;;
    "all")        printf "ow_minio ow_couchdb ow_zookeeper ow_kafka ow_redis ow_controller ow_invoker ow_apigateway" ;;
    *)            exit 1;;
  esac
}
function start-local(){
  hostnames=$(getHostnames $1)
  if [[ !  -z  $hostnames  ]]; then
    docker start "$hostnames"
  fi
}
function stop-local(){
  hostnames=$(getHostnames $1)
  if [[ !  -z  $hostnames  ]]; then
    docker stop "$hostnames"
  fi
}
function restart-local(){
  hostnames=$(getHostnames $1)
  if [[ !  -z  $hostnames  ]]; then
    docker stop "$hostnames"
    docker start "$hostnames"
  fi
}
function remove-local(){
  hostnames=$(getHostnames $1)
  if [[ !  -z  $hostnames  ]]; then
    for hostname in $hostnames; do
      docker rm -f "$hostname"
    done;
  fi
}

function run-minio-local(){
  DOCKER_NETWORK="$1"

  echo "Starting Minio"
  docker run -d \
    -p "9001:9000" \
    --network $DOCKER_NETWORK \
    -e "MINIO_ACCESS_KEY=${s3AccessKey}" \
    -e "MINIO_SECRET_KEY=${s3SecretKey}" \
    -v "$TEMP_DIR/minio:/data:rw" \
    --hostname ow_minio \
    --name ow_minio \
    minio/minio:RELEASE.2018-07-13T00-09-07Z server /data
}
function load-file-minio(){
  MINIO_HOST="$1"

  echo "pinging minio... $MINIO_HOST"
  while ! nc -z $LOCAL_IP 9001 ; do printf '.'; sleep 5; done

  echo "loading configs into minio..."
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
function run-couchdb-local(){
  DOCKER_NETWORK="$1"

  echo "Starting CouchDB"
  docker run -d \
    -p 5984:5984 \
    --network $DOCKER_NETWORK \
    -e "COUCHDB_USER=whisk_admin" \
    -e "COUCHDB_PASSWORD=some_passw0rd" \
    -v "$TEMP_DIR/couchdb:/usr/local/var/lib/couchdb:rw" \
    --hostname ow_couchdb \
    --name ow_couchdb \
    apache/couchdb:2.1

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
function run-zookeeper-local(){
  DOCKER_NETWORK="$1"

  echo "Starting Zookeeper"
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
}
function run-kafka-local(){
  DOCKER_NETWORK="$1"

  echo "Starting Kafka"
  docker run -d \
    -p 6667:6667 \
    --network $DOCKER_NETWORK \
    -e "KAFKA_ZOOKEEPER_CONNECT=ow_zookeeper:2181" \
    -e "KAFKA_ADVERTISED_HOST_NAME=ow_kafka" \
    -e "KAFKA_PORT=6667" \
    -e "KAFKA_ADVERTISED_PORT=6667" \
    -v "/var/run/docker.sock:/var/run/docker.sock" \
    -v "$TEMP_DIR/kafka:/kafka:rw" \
    --hostname ow_kafka \
    --name ow_kafka \
    wurstmeister/kafka:0.11.0.1
}
function run-redis-local(){
  DOCKER_NETWORK="$1"

  docker run -d \
    -p 6379:6379 \
    --network $DOCKER_NETWORK \
    --hostname ow_redis \
    --name ow_redis \
    redis:2.8
}
function run-controller-local(){
  DOCKER_NETWORK="$1"
  COUCHDB_HOST="$2"
  ZOOKEEPER_HOST="$3"
  KAFKA_HOST="$4"
  withJaaS="$5"

  jaasMounts=""
  if [ ! -z $withJaaS ]; then
    jaasMounts="-v \"/etc/krb5.conf:/etc/krb5.conf\" -v \"$HOME/login.conf:/login.conf\" -v \"$HOME/master0.keytab:/master0.keytab\""
  fi

  touch "$LOG_DIR/controller-local_logs.log"
  chmod 666 "$LOG_DIR/controller-local_logs.log"

  docker run -d \
    -p 8888:8888 \
    -p 2551:2551 \
    --network $DOCKER_NETWORK \
    --env-file docker-whisk-controller.env \
    -e "COMPONENT_NAME=controller" \
    -e "PORT=8888"  \
    -e "KAFKA_HOSTS=$KAFKA_HOST:6667" \
    -e "ZOOKEEPER_HOSTS=$ZOOKEEPER_HOST:2181" \
    -e "CONFIG_whisk_couchdb_provider=CouchDB" \
    -e "CONFIG_whisk_couchdb_protocol=http" \
    -e "CONFIG_whisk_couchdb_port=5984" \
    -e "CONFIG_whisk_couchdb_host=$COUCHDB_HOST" \
    -e "CONFIG_whisk_couchdb_username=whisk_admin" \
    -e "CONFIG_whisk_couchdb_password=some_passw0rd" \
    -e "CONFIG_akka_remote_netty_tcp_hostname=$LOCAL_IP" \
    -e "CONFIG_akka_remote_netty_tcp_port=2551" \
    -e "CONFIG_akka_remote_netty_tcp_bindPort=2551" \
    -e "CONFIG_akka_actor_provider=cluster" \
    -e "LOADBALANCER_HOST=${LOCAL_IP}" \
    -e "LOADBALANCER_HOST_PORT=443" \
    -v "$LOG_DIR:/logs" \
    $jaasMounts \
    --name ow_controller \
    "${DOCKER_OW_IMAGE_PREFIX:-openwhisk}/controller" \
    /bin/sh -c "exec /init.sh 0 >> /logs/controller-local_logs.log 2>&1"
}
function run-invoker-local(){
  DOCKER_NETWORK="$1"
  COUCHDB_HOST="$2"
  ZOOKEEPER_HOST="$3"
  KAFKA_HOST="$4"
  withJaaS="$5"

  jaasMounts=""
  if [ ! -z $withJaaS ]; then
    jaasMounts="-v \"/etc/krb5.conf:/etc/krb5.conf\" -v \"$HOME/login.conf:/login.conf\" -v \"$HOME/master0.keytab:/master0.keytab\""
  fi

  docker run -d \
    -p 8085:8085 \
    --network $DOCKER_NETWORK \
    --privileged \
    --pid "host" \
    --userns "host" \
    --env-file docker-whisk-controller.env \
    -e "COMPONENT_NAME=invoker" \
    -e "SERVICE_NAME=invoker0" \
    -e "PORT=8085" \
    -e "KAFKA_HOSTS=$KAFKA_HOST:6667" \
    -e "ZOOKEEPER_HOSTS=$ZOOKEEPER_HOST:2181" \
    -e "CONFIG_whisk_couchdb_provider=CouchDB" \
    -e "CONFIG_whisk_couchdb_protocol=http" \
    -e "CONFIG_whisk_couchdb_port=5984" \
    -e "CONFIG_whisk_couchdb_host=$COUCHDB_HOST" \
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
    /bin/sh -c "exec /init.sh --id 0 >> /logs/invoker0-local_logs.log 2>&1"
}
function run-apigateway-local(){
  DOCKER_NETWORK="$1"
  CONTROLLER_HOST="$2"
  REDIS_HOST="$3"
  MINIO_HOST="$4"

  echo "  ... preparing api-gateway configuration"
  rm -rf "$TEMP_DIR/api-gateway-config"
  mkdir -p "$TEMP_DIR/api-gateway-config/api-gateway"
  cp -r ./apigateway/* "$TEMP_DIR/api-gateway-config/api-gateway/"
  cp -r ./apigateway/rclone "$TEMP_DIR"

  # Update hosts
  if [ "$UNAME_STR" = "Linux" ]; then
    sed -i "s/MINIO_HOST/$MINIO_HOST/g" "$TEMP_DIR/api-gateway-config/api-gateway/rclone/rclone.conf"
    sed -i "s/CONTROLLER_HOST/$CONTROLLER_HOST/g" "$TEMP_DIR/api-gateway-config/api-gateway/generated-conf.d/api-gateway.conf"
  else
    sed -i '' "s/MINIO_HOST/$MINIO_HOST/g" "$TEMP_DIR/api-gateway-config/api-gateway/rclone/rclone.conf"
    sed -i '' "s/CONTROLLER_HOST/$CONTROLLER_HOST/g" "$TEMP_DIR/api-gateway-config/api-gateway/generated-conf.d/api-gateway.conf"
  fi

  #put config into minio
  load-file-minio "$MINIO_HOST"

  # Generate SSL certs
  mkdir -p "$TEMP_DIR"/api-gateway-ssl
  "$OPENWHISK_PROJECT_HOME/ansible/files/genssl.sh" $LOCAL_IP server "$TEMP_DIR"/api-gateway-ssl "" "" generateKey

  docker run -d \
    -p 80:80 \
    -p 443:443 \
    -p 9000:9000 \
    -p 8081:8080 \
    --network $DOCKER_NETWORK \
    -e "REDIS_HOST=$REDIS_HOST" \
    -e "REDIS_PORT=6379" \
    -e "PUBLIC_MANAGEDURL_PORT=8081" \
    -e "PUBLIC_MANAGEDURL_HOST=${LOCAL_IP}" \
    -e "REMOTE_CONFIG=minio:api-gateway" \
    -v "$TEMP_DIR/api-gateway-ssl:/etc/ssl:ro" \
    -v "$TEMP_DIR/api-gateway-config/api-gateway/generated-conf.d:/etc/api-gateway/generated-conf.d" \
    -v "$TEMP_DIR/rclone:/root/.config/rclone:rw" \
    -v "$LOG_DIR:/var/log/api-gateway" \
    --name ow_apigateway \
    "openwhisk/apigateway:latest"

    echo "initializing CLI ... "
    "$WSK_CLI" property set --apihost "https://$LOCAL_IP"
    "$WSK_CLI" property set --auth $(cat openwhisk-src/ansible/files/auth.guest)
}
function run-local(){

  DOCKER_NETWORK="$2"
  if [ -z $DOCKER_NETWORK ]; then
    DOCKER_NETWORK="host"
  fi

  withJaaS="$6"

  mkdir -p "$LOG_DIR"
  chmod 777 "$LOG_DIR"

  case "$1" in
    "minio")      run-minio-local $DOCKER_NETWORK ;;
    "couchdb")    run-couchdb-local $DOCKER_NETWORK ;;
    "zookeeper")  run-zookeeper-local $DOCKER_NETWORK ;;
    "kafka")      run-kafka-local $DOCKER_NETWORK ;;
    "redis")      run-redis-local $DOCKER_NETWORK ;;
    "controller") run-controller-local $DOCKER_NETWORK "ow_couchdb" "ow_zookeeper" "ow_kafka" "$withJaaS" ;;
    "invoker")    run-invoker-local $DOCKER_NETWORK "ow_couchdb" "ow_zookeeper" "ow_kafka" "$withJaaS" ;;
    "apigateway") run-apigateway-local $DOCKER_NETWORK "ow_controller" "ow_redis" "ow_minio";;
    "stateful")
                  run-minio-local $DOCKER_NETWORK;
                  run-couchdb-local $DOCKER_NETWORK;
                  run-zookeeper-local $DOCKER_NETWORK;
                  run-kafka-local $DOCKER_NETWORK ;;
    "stateless")
                  run-redis-local $DOCKER_NETWORK;
                  run-controller-local $DOCKER_NETWORK "ow_couchdb" "ow_zookeeper" "ow_kafka" "$withJaaS";
                  run-invoker-local $DOCKER_NETWORK "ow_couchdb" "ow_zookeeper" "ow_kafka" "$withJaaS";
                  run-apigateway-local $DOCKER_NETWORK "ow_controller" "ow_redis" "ow_minio" ;;
    "all")
                  run-minio-local $DOCKER_NETWORK;
                  run-couchdb-local $DOCKER_NETWORK;
                  run-zookeeper-local $DOCKER_NETWORK;
                  run-kafka-local $DOCKER_NETWORK;
                  run-redis-local $DOCKER_NETWORK;
                  run-controller-local $DOCKER_NETWORK "ow_couchdb" "ow_zookeeper" "ow_kafka" "$withJaaS";
                  run-invoker-local $DOCKER_NETWORK "ow_couchdb" "ow_zookeeper" "ow_kafka" "$withJaaS";
                  run-apigateway-local $DOCKER_NETWORK "ow_controller" "ow_redis" "ow_minio" ;;
    *)            echo "unknown container or container group type" ;;
  esac

}

function run-yarn-stateless(){
  DOCKER_NETWORK="$1"
  YARN_RM="$2"
  MINIO_HOST="$3"
  COUCHDB_HOST="$4"
  ZOOKEEPER_HOST="$5"
  KAFKA_HOST="$6"

  username="$USER"
  EXTRA_ENV=$(cat docker-whisk-controller.env | grep "^[^#]" | sed s/\"/\\\\\"/g | sed s/}}/}\ }/g | sed s/=/\`/| awk -F\` '{print "\x22"$1"\x22:" "\x22"$2"\x22,"}')

  YARN_Service_Def=$(cat openwhisk.json)
  YARN_Service_Def="${YARN_Service_Def//COUCHDB_HOST/$COUCHDB_HOST}"
  YARN_Service_Def="${YARN_Service_Def//ZOOKEEPER_HOST:/$ZOOKEEPER_HOST:}"
  YARN_Service_Def="${YARN_Service_Def//KAFKA_HOST:/$KAFKA_HOST:}"
  YARN_Service_Def="${YARN_Service_Def//INVOKER_EXTRA_ENV/$EXTRA_ENV}"
  YARN_Service_Def="${YARN_Service_Def//CONTROLLER_EXTRA_ENV/$EXTRA_ENV}"
  curl -X POST -H "Content-Type: application/json" "$YARN_RM/app/v1/services?user.name=$username" -d "$YARN_Service_Def"
  echo "" #formatting

  getcontainerIPscript="import json,sys;"
  getcontainerIPscript+="obj=json.load(sys.stdin);"
  getcontainerIPscript+="containers=next((c['containers'] for c in obj['components'] if c['name'] == 'COMPONENT_NAME'), []);"
  getcontainerIPscript+="print next((c['ip'] for c in containers if c['state'] == 'READY'), \"\");"

  controllerIP=""
  redisIP=""
  while [[ -z $controllerIP || -z $redisIP ]]; do
    echo "Waiting for service start"
    sleep 1
    status=$(curl -s "$YARN_RM/app/v1/services/openwhisk-master-service?user.name=$username")
    controllerIP=$(echo "$status" | python -c "${getcontainerIPscript//COMPONENT_NAME/controller}")
    redisIP=$(echo "$status" | python -c "${getcontainerIPscript//COMPONENT_NAME/redis}")
  done

  run-apigateway-local "$DOCKER_NETWORK" "$controllerIP" "$redisIP" "$MINIO_HOST"
}
function remove-yarn-stateless(){
  YARN_RM=$1
  curl -X DELETE "$YARN_RM/app/v1/services/openwhisk-master-service?user.name=$USER"
  echo "" #formatting
  remove-local "apigateway"
}

case "$1" in
  download-source) download-source ;;
  build-docker)    build-docker ;;
  pull-images)     pull-images ;;
  download-cli)    download-cli ;;

  run-local)    run-local $2 $3 ;;
  start-local)  start-local $2 ;;
  stop-local)   stop-local $2 ;;
  remove-local) remove-local $2 ;;
  restart-local)
      stop-local  $2
      start-local $2 ;;
  rerun-local)
      remove-local $2
      run-local    $2 $3 ;;

  run-yarn)
      if [ $2 != "stateless" ]; then
        echo "Only stateless is supported for YARN at this time"
        exit 1
      fi
      run-yarn-stateless $3 $4 $5 $6 $7 $8 ;;
  remove-yarn)
      if [ $2 != "stateless" ]; then
        echo "Only stateless is supported for YARN at this time"
        exit 1
      fi
      remove-yarn-stateless $3 ;;
  rerun-yarn)
      if [ $2 != "stateless" ]; then
        echo "Only stateless is supported for YARN at this time"
        exit 1
      fi
      remove-yarn-stateless $4
      run-yarn-stateless $3 $4 $5 $6 $7 $8 ;;

  quick-start-local)
      download-source
      pull-images
      download-cli
      run-local "all" $2
      ;;
  quick-start-yarn)
      download-source
      pull-images
      download-cli
      run-local "stateful" $2
      run-yarn-stateless $2 $3 "ow_minio" "ow_couchdb" "ow_zookeeper" "ow_kafka"
      ;;
  *)
      echo "Usage"
      echo "------------------------------------------------------------------------------------------"
      echo ""
      echo "Setup:"
      echo "$ScriptName download-source - Git clones the OpenWhisk main branch into ./openwhisk-src"
      echo "$ScriptName build-docker    - Compiles the OpenWhisk source and builds the OpenWhisk images with a prefix of 'openwhisk'"
      echo "$ScriptName pull-images     - Pulls the latest OpenWhisk images"
      echo "$ScriptName download-cli    - Downloads the OpenWhisk cli into ./openwhisk-src/bin"
      echo ""
      echo "Container Types:"
      echo "  Container groups:     stateful, stateless, all"
      echo "  Stateful containers:  minio, couchdb, zookeeper, kafka"
      echo "  Stateless containers: redis, controller, invoker, apigateway"
      echo ""
      echo "Local Machine Operations:"
      echo "$ScriptName run-local     <Container | Container Group> <docker network> [withJaaS] -runs the container or container group"
      echo "$ScriptName rerun-local   <Container | Container Group> <docker network> [withJaaS] -removes and runs the container or container group"
      echo "$ScriptName start-local   <Container | Container Group>                             -starts the container or container group"
      echo "$ScriptName stop-local    <Container | Container Group>                             -stops the container or container group"
      echo "$ScriptName restart-local <Container | Container Group>                             -stops and starts the container or container group"
      echo "$ScriptName remove-local  <Container | Container Group>                             -removes the container or container group"
      echo ""
      echo "YARN Operations (stateless only):"
      echo "$ScriptName run-yarn    stateless <docker network> <RM URL> <minio host> <couchdb host> <zookeeper host> <kafka host>"
      echo "$ScriptName rerun-yarn  stateless <docker network> <RM URL> <minio host> <couchdb host> <zookeeper host> <kafka host>"
      echo "$ScriptName remove-yarn stateless <RM URL>"
      echo ""
      echo "Shortcuts:"
      echo "$ScriptName quick-start-local <docker network> - Executes download-source, pull-images, download-cli, run-local all"
      echo "$ScriptName quick-start-yarn  <docker network> <RM URL> - Executes download-source, pull-images, download-cli, run-local stateful, run-yarn stateless"
      ;;
esac
